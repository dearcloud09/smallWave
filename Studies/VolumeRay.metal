// True particle-depth optical study. No silhouette extrusion. The density
// samples come from the existing 3D particle field, not a measured liquid.
vertex VolumeOut bubbleVolumeVertex(uint v [[vertex_id]],uint instance [[instance_id]],
                                    const device float4 *bubbles [[buffer(0)]],
                                    constant OceanUniforms &u [[buffer(1)]]) {
    uint layers=uint(u.optics.w), slice=instance%layers;
    float4 b=bubbles[instance/layers];
    float2 local=corner(v)*1.15;
    float2 p=b.xy+local*b.w;
    float z=u.optics.y-(float(slice)+0.5)*(2*u.optics.y/float(layers));
    VolumeOut out; out.position=float4(p/u.viewport.xy,0,1);
    out.local=float3(local,(z-b.z)/b.w); out.layer=slice; return out;
}
fragment float bubbleVolumeFragment(VolumeOut in [[stage_in]]) {
    // MIN blend intersects the blue isosurface with the outside of a clear
    // inclusion. At radius=1 this field crosses the same 0.6 isovalue.
    return max(0.0,0.6+(length(in.local)-1)*8.0);
}
vertex VolumeOut calibrationVolumeVertex(uint v [[vertex_id]],uint instance [[instance_id]],
                                         constant OceanUniforms &u [[buffer(1)]]) {
    float2 p=corner(v)*u.viewport.xy;
    float z=u.optics.y-(float(instance)+0.5)*2*u.optics.y/u.optics.w;
    VolumeOut out; out.position=float4(p/u.viewport.xy,0,1); out.local=float3(p,z); out.layer=instance; return out;
}
float calibrationHeight(float x,float z) { return -0.75+0.32*sin(x*2.5)+z*0.4; }
fragment float calibrationVolumeFragment(VolumeOut in [[stage_in]]) {
    float3 p=in.local;
    float density=0.6+12*(calibrationHeight(p.x,p.z)-p.y);
    for(int i=0;i<8;i++) {
        float x=-0.70+float(i)*0.20,z=0.065*sin(float(i)*1.7);
        float radius=0.035+0.032*(0.5+0.5*sin(float(i)*2.3));
        float3 c=float3(x,calibrationHeight(x,z)-radius*0.25,z);
        density=min(density,0.6+(length(p-c)/radius-1)*2);
    }
    return max(density,0.0);
}
float vrFilteredDensity(texture2d_array<float> volume,float3 p,constant OceanUniforms &u) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    if(abs(p.x)>u.viewport.x||abs(p.y)>u.viewport.y||abs(p.z)>u.optics.y) return 0;
    float2 uv=p.xy/u.viewport.xy*float2(0.5,-0.5)+0.5;
    float layer=(u.optics.y-p.z)/(2*u.optics.y)*u.optics.w-0.5;
    int lo=int(floor(layer)); float t=fract(layer);
    uint last=volume.get_array_size()-1;
    return mix(volume.sample(smp,uv,uint(clamp(lo,0,int(last)))).r,
               volume.sample(smp,uv,uint(clamp(lo+1,0,int(last)))).r,t);
}
struct VRField { float value; float3 gradient; };
VRField vrFieldLinear(texture2d_array<float> volume,float3 p,constant OceanUniforms &u) {
    if(abs(p.x)>u.viewport.x||abs(p.y)>u.viewport.y||abs(p.z)>u.optics.y) return {0,float3(0)};
    // Evaluate value and derivative with the same float32 interpolation. Keep
    // the hardware-filtered path above only as an explicit diagnostic control.
    int3 size=int3(volume.get_width(),volume.get_height(),volume.get_array_size());
    float3 tex=float3(p.xy/u.viewport.xy*float2(0.5,-0.5)+0.5,
                      (u.optics.y-p.z)/(2*u.optics.y))*float3(size)-0.5;
    int3 cell=int3(floor(tex)); float3 f=fract(tex);
    float v[8];
    for(int z=0;z<2;z++) for(int y=0;y<2;y++) for(int x=0;x<2;x++) {
        int3 at=clamp(cell+int3(x,y,z),int3(0),size-1);
        v[x+2*y+4*z]=volume.read(uint2(at.xy),uint(at.z)).r;
    }
    float dx=mix(mix(v[1]-v[0],v[3]-v[2],f.y),mix(v[5]-v[4],v[7]-v[6],f.y),f.z);
    float dy=mix(mix(v[2]-v[0],v[3]-v[1],f.x),mix(v[6]-v[4],v[7]-v[5],f.x),f.z);
    float dz=mix(mix(v[4]-v[0],v[5]-v[1],f.x),mix(v[6]-v[2],v[7]-v[3],f.x),f.y);
    float value=mix(mix(mix(v[0],v[1],f.x),mix(v[2],v[3],f.x),f.y),
                    mix(mix(v[4],v[5],f.x),mix(v[6],v[7],f.x),f.y),f.z);
    return {value,float3(dx,-dy,-dz)*float3(size)/(2*float3(u.viewport.xy,u.optics.y))};
}
#ifndef VR_CUBIC_FIELD
#define VR_CUBIC_FIELD 0
#endif
float4 vrCubicWeights(float t) {
    float t2=t*t,t3=t2*t,s=1-t;
    return float4(s*s*s,3*t3-6*t2+4,-3*t3+3*t2+3*t+1,t3)/6;
}
float4 vrCubicDerivatives(float t) {
    return float4(-0.5*(1-t)*(1-t),1.5*t*t-2*t,-1.5*t*t+t+0.5,0.5*t*t);
}
VRField vrField(texture2d_array<float> volume,float3 p,constant OceanUniforms &u) {
#if VR_CUBIC_FIELD
    if(abs(p.x)>u.viewport.x||abs(p.y)>u.viewport.y||abs(p.z)>u.optics.y) return {0,float3(0)};
    // Cubic B-spline reconstruction: the value and its derivative come from
    // one smooth scalar field. This slightly filters geometry (not physics),
    // unlike replacing only the optical normal of a piecewise-linear field.
    int3 size=int3(volume.get_width(),volume.get_height(),volume.get_array_size());
    float3 tex=float3(p.xy/u.viewport.xy*float2(0.5,-0.5)+0.5,
                      (u.optics.y-p.z)/(2*u.optics.y))*float3(size)-0.5;
    int3 cell=int3(floor(tex)); float3 f=fract(tex);
    float4 wx=vrCubicWeights(f.x),wy=vrCubicWeights(f.y),wz=vrCubicWeights(f.z);
    float4 dx=vrCubicDerivatives(f.x),dy=vrCubicDerivatives(f.y),dz=vrCubicDerivatives(f.z);
    float value=0; float3 gradient=float3(0);
    for(int z=0;z<4;z++) for(int y=0;y<4;y++) for(int x=0;x<4;x++) {
        int3 at=clamp(cell+int3(x-1,y-1,z-1),int3(0),size-1);
        float v=volume.read(uint2(at.xy),uint(at.z)).r;
        value+=v*wx[x]*wy[y]*wz[z];
        gradient+=v*float3(dx[x]*wy[y]*wz[z],wx[x]*dy[y]*wz[z],wx[x]*wy[y]*dz[z]);
    }
    return {value,gradient*float3(size)*float3(1,-1,-1)/(2*float3(u.viewport.xy,u.optics.y))};
#else
    return vrFieldLinear(volume,p,u);
#endif
}
float vrDensity(texture2d_array<float> volume,float3 p,constant OceanUniforms &u) {
    return vrField(volume,p,u).value;
}
float3 vrNormal(texture2d_array<float> volume,float3 p,constant OceanUniforms &u,bool smooth=false) {
    float3 walls=float3(u.viewport.xy,u.optics.y)-abs(p);
    if(min(walls.x,min(walls.y,walls.z))<0.0000005) {
        if(walls.z<=walls.x && walls.z<=walls.y) return float3(0,0,sign(p.z));
        if(walls.x<=walls.y) return float3(sign(p.x),0,0);
        return float3(0,sign(p.y),0);
    }
    float3 g=-vrField(volume,p,u).gradient;
    if(smooth) {
        // A one-voxel central derivative of the same continuous field avoids
        // the cell-boundary jumps in the trilinear cell's analytic derivative.
        // Geometry/phase remains unchanged; this is a normal approximation.
        float3 h=2*float3(u.viewport.xy,u.optics.y)/float3(volume.get_width(),volume.get_height(),volume.get_array_size());
        g=-float3(vrDensity(volume,p+float3(h.x,0,0),u)-vrDensity(volume,p-float3(h.x,0,0),u),
                  vrDensity(volume,p+float3(0,h.y,0),u)-vrDensity(volume,p-float3(0,h.y,0),u),
                  vrDensity(volume,p+float3(0,0,h.z),u)-vrDensity(volume,p-float3(0,0,h.z),u))/(2*h);
    }
    float magnitude=length(g);
    return magnitude>0.00001?g/magnitude:float3(0);
}
float vrFresnel(float cosine,float n1,float n2) {
    if(abs(n1-n2)<0.000001) return 0;
    float s2=(n1*n1)/(n2*n2)*max(0.0,1-cosine*cosine);
    if(s2>=1) return 1;
    float ct=sqrt(1-s2);
    float s=(n1*cosine-n2*ct)/(n1*cosine+n2*ct);
    float p=(n2*cosine-n1*ct)/(n2*cosine+n1*ct);
    return 0.5*(s*s+p*p);
}
struct VRBranch {
    float3 position, direction, weight;
    bool inside;
    uint depth;
};
float3 vrStudioBackdrop(float2 p) {
    // A lit neutral studio plane, used as transmitted radiance. This is a
    // lighting/material study, not destination scenery or a painted water shade.
    float broad=exp(-pow((p.x+0.38*p.y+0.12)/0.48,2.0));
    float strip=exp(-pow((p.x-0.20*p.y-0.55)/0.14,2.0));
    float brightness=0.95-0.24*broad+0.045*strip;
    return float3(0.96,0.985,1.0)*brightness;
}
float3 vrEnvironment(float3 direction,constant float4 &study) {
    if((uint(study.w)&256)==0) return displayToLight(reflectedStudio(direction));
    // Material-lighting control: bright rectangular cards in a dark studio.
    // Linear HDR radiance; the ordinary transmitted backdrop stays unchanged.
    float3 ambient=float3(0.025,0.034,0.045)*(0.7+0.3*saturate(direction.y));
    if(direction.z<=0.02) return ambient;
    float2 p=direction.xy/direction.z;
    float2 keyEdge=abs(p-float2(-0.45,0.40))-float2(0.32,0.60);
    float2 fillEdge=abs(p-float2(0.58,-0.10))-float2(0.07,0.68);
    float key=1-smoothstep(-0.025,0.025,max(keyEdge.x,keyEdge.y));
    float fill=1-smoothstep(-0.018,0.018,max(fillEdge.x,fillEdge.y));
    return ambient+4*key*float3(1.0,0.96,0.88)+1.5*fill*float3(0.88,0.96,1.0);
}
float4 vrSample(float2 uv,texture2d_array<float> volume,
                constant OceanUniforms &u,constant float4 &study) {
    float2 world=(uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    const float clearIOR=1.46;
    float blueIOR=u.optics.x>1.5?clearIOR:1.333;
    bool straight=u.optics.x>2.5;
    float3 direction=study.z>0.5?normalize(float3(0.10,-0.38,-1)):float3(0,0,-1);
    float3 p=float3(world+direction.xy/direction.z*0.19,0.19);
    float3 reference=clamp(u.color.rgb,float3(0.02),float3(0.98));
    if(study.x>0.5) reference=displayToLight(reference);
    float3 dye=-log(reference)*0.72/0.24;
    float3 weight=float3(1), radiance=float3(0);
    float path=0, firstPath=0, travelled=0;
    uint crossings=0, tir=0;
    bool finished=false, mediumMismatch=false, unresolved=false;
    float density=vrDensity(volume,p,u);
    bool inside=density>=u.optics.z;
    bool secondary=(uint(study.w)&16)!=0;
    VRBranch pending[8]; uint pendingCount=0, depth=0;
    // Fixed small step with bisection at crossings. Thin sub-grid interfaces
    // remain a documented resolution limit; compare step-halving diagnostics.
    bool halfStep=(uint(study.w)&1)!=0;
    float marchStep=halfStep?0.002:0.004;
    // The earlier 1.28-unit budget was shorter than a grazing route across the
    // vessel. Counters observed >1.18 units with only a few crossings, not a
    // self-intersection loop. Allow up to 8.192 units; ordinary rays still exit early.
    uint limit=halfStep?4096:2048;
    for(uint branch=0;branch<16;branch++) {
      finished=false;
      for(uint i=0;i<limit;i++) {
        float distance=marchStep;
        float3 next=p+direction*distance;
        float3 beforePoint=p, afterPoint=next;
        float nextDensity=vrDensity(volume,next,u);
        bool crossing=(nextDensity>=u.optics.z)!=inside;
        if(crossing) {
            float low=0, high=distance;
            for(uint b=0;b<16;b++) {
                float mid=(low+high)*0.5;
                float3 point=p+direction*mid;
                if((vrDensity(volume,point,u)>=u.optics.z)==inside) { low=mid; beforePoint=point; }
                else { high=mid; afterPoint=point; }
            }
            distance=(low+high)*0.5; next=p+direction*distance;
        }
        // Composite an actual ray/sprite-plane encounter into radiance. Earlier
        // liquid reflections remain in radiance; only remaining weight is occluded.
        bool crossesToy=(p.z<u.boat.w && next.z>=u.boat.w)||(p.z>u.boat.w && next.z<=u.boat.w);
        if(crossesToy && abs(direction.z)>0.0001) {
            float portion=clamp((u.boat.w-p.z)/(next.z-p.z),0.0,1.0);
            float2 q=mix(p.xy,next.xy,portion);
            float4 toy=miniature(q,u);
            float3 localWeight=weight*(inside?exp(-dye*distance*portion):float3(1));
            radiance+=localWeight*displayToLight(toy.rgb/max(toy.a,0.00001))*toy.a;
            weight*=1-toy.a;
        }
        if(inside) { weight*=exp(-dye*distance); path+=distance; }
        travelled+=distance; p=next;
        if(crossing) {
            // Transport uses the actual isosurface normal. The optional smooth
            // normal only samples distant lighting; it cannot redirect this ray
            // into the wrong geometric hemisphere.
            float3 normal=vrNormal(volume,p,u,false);
            if(!all(isfinite(normal)) || length_squared(normal)<0.5) break;
            if(dot(normal,direction)>0) normal=-normal;
            float n1=inside?blueIOR:clearIOR, n2=inside?clearIOR:blueIOR;
            float f=straight?0:vrFresnel(clamp(-dot(normal,direction),0.0,1.0),n1,n2);
            float3 transmitted=straight?direction:refract(direction,normal,n1/n2);
            crossings++;
            if(crossings==1) firstPath=path;
            bool expected=inside;
            bool reflectedOnly=false;
            if(length_squared(transmitted)<0.000001) {
                direction=reflect(direction,normal); tir++; reflectedOnly=true;
            } else {
                float3 reflected=reflect(direction,normal), reflectedWeight=weight*f;
                // Optional bounded secondary transport through the same volume.
                // Small/deep branches retain the explicit environment tail
                // approximation; this is not an unbounded path tracer.
                if(secondary && depth<3 && pendingCount<8 && max(reflectedWeight.r,max(reflectedWeight.g,reflectedWeight.b))>0.002) {
                    pending[pendingCount++]={beforePoint,reflected,reflectedWeight,inside,depth+1};
                } else {
                    float3 lightingDirection=reflected;
                    if((uint(study.w)&32)!=0) {
                        float3 lightingNormal=vrNormal(volume,p,u,true);
                        if(length_squared(lightingNormal)>0.5) lightingDirection=reflect(direction,lightingNormal);
                    }
                    radiance+=reflectedWeight*vrEnvironment(lightingDirection,study);
                }
                depth++;
                weight*=1-f; direction=normalize(transmitted); expected=!inside;
            }
            // Retain the two representable points whose phases were actually
            // tested during bisection. An arbitrary epsilon can jump a thin film
            // or land on the wrong side of a crease; these bracket points cannot.
            float3 moved=reflectedOnly?beforePoint:afterPoint;
            bool actual=vrDensity(volume,moved,u)>=u.optics.z;
            if(actual!=expected) mediumMismatch=true;
            p=moved; inside=actual; density=vrDensity(volume,p,u);
        } else { density=nextDensity; inside=density>=u.optics.z; }
        if(p.z< -0.19||p.z>0.20||abs(p.x)>u.viewport.x+0.01||abs(p.y)>u.viewport.y+0.01||max(weight.r,max(weight.g,weight.b))<0.00001) {
            finished=true; break;
        }
      }
      unresolved=unresolved||!finished;
      float2 q=p.xy;
      if(direction.z< -0.02) q+=direction.xy*((-0.24-p.z)/direction.z);
      float3 scene=direction.z<0?displayToLight((uint(study.w)&64)!=0?vrStudioBackdrop(q):backdrop(q,u)):vrEnvironment(direction,study);
      if(finished) radiance+=weight*scene;
      if(pendingCount==0) break;
      VRBranch nextBranch=pending[--pendingCount];
      p=nextBranch.position; direction=nextBranch.direction; weight=nextBranch.weight;
      inside=nextBranch.inside; depth=nextBranch.depth;
    }
    finished=!unresolved && pendingCount==0;
    if(study.y>1.5) return float4(travelled/1.28,float(crossings)/320.0,float(tir)/320.0,finished?0:1);
    if(study.y>0.5) return float4(path/0.5,float(crossings)/16.0,finished?0:1,mediumMismatch?1:0);
    // Unresolved paths remain visibly magenta in a study, never disguised as
    // successful environment illumination.
    if(!finished||mediumMismatch) return float4(0,0,0,-1);
    float3 color=lightToDisplay(radiance);
    float edge=min(1-abs(world.x),2.12-abs(world.y));
    float wall=exp(-max(edge,0.0)*65.0);
    color=mix(color,color*0.70+float3(0.07,0.12,0.13),wall*0.35);
    color+=float3(0.12,0.14,0.13)*exp(-pow((edge-0.021)*190.0,2.0));
    // Leave radiance unclipped until all pixel samples are averaged.
    return float4(displayToLight(max(color,float3(0))),1);
}
fragment float4 volumeRayOceanFragment(QuadOut in [[stage_in]],
                                       texture2d_array<float> volume [[texture(0)]],
                                       constant OceanUniforms &u [[buffer(0)]],
                                       constant float4 &study [[buffer(1)]]) {
    if((uint(study.w)&4)==0 || study.y>1.5) {
        float4 value=vrSample(in.uv,volume,u,study);
        if(study.y>0.5) return value;
        return value.a<0?float4(1,0,1,1):float4(clamp(lightToDisplay(value.rgb),0.0,1.0),1);
    }
    float2 pixel=float2(dfdx(in.uv.x),dfdy(in.uv.y));
    float4 sum=float4(0); bool failed=false;
    for(int y=0;y<2;y++) for(int x=0;x<2;x++) {
        float2 offset=float2(x?0.25:-0.25,y?0.25:-0.25)*pixel;
        float4 value=vrSample(in.uv+offset,volume,u,study);
        if(study.y>0.5) {
            sum.xy+=value.xy*0.25;
            sum.zw=max(sum.zw,value.zw); // any failed sample remains visible
        } else {
            failed=failed || value.a<0;
            sum.rgb+=value.rgb*0.25;
        }
    }
    if(study.y>0.5) return sum;
    return failed?float4(1,0,1,1):float4(clamp(lightToDisplay(sum.rgb),0.0,1.0),1);
}
fragment float4 volumeWallDiagnostic(QuadOut in [[stage_in]],texture2d_array<float> volume [[texture(0)]],
                                     constant OceanUniforms &u [[buffer(0)]]) {
    float2 p=(in.uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    // RGB = front, center, back occupancy. White is blue liquid at all three
    // depths; green is center-only. No optical shading or sprite composite.
    return float4(vrDensity(volume,float3(p,u.optics.y-0.00001),u)>=u.optics.z,
                  vrDensity(volume,float3(p,0),u)>=u.optics.z,
                  vrDensity(volume,float3(p,-u.optics.y+0.00001),u)>=u.optics.z,1);
}
