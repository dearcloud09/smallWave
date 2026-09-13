#include <metal_stdlib>
using namespace metal;

struct OceanUniforms {
    float4 viewport;  // screen half-width, half-height, time, screen-to-device rotation
    float4 boat;      // device x, y, angle, depth
    float4 movement;  // gravity xyz, energy
    float4 color;
    float4 optics;    // mode (0 legacy, 1 atlas, 2 clear edge), half-depth, isovalue, slices
    float4 miniatureArt; // variant (-1 procedural), scale, immersion, hull-relative speed
};
struct QuadOut {
    float4 position [[position]];
    float2 local;
    float2 uv;
    float weight;
};

float2 rotate2(float2 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(c*p.x - s*p.y, s*p.x + c*p.y);
}
// Procedural pigments are authored as display colors. Use an approximate 2.2
// transfer for the volume's light transport, then return to the existing UNorm
// display pass. Alpha, density, normals and transmission are not gamma encoded.
float3 displayToLight(float3 color) { return pow(max(color,float3(0)),float3(2.2)); }
float3 lightToDisplay(float3 light) { return pow(max(light,float3(0)),float3(1.0/2.2)); }
float2 corner(uint i) {
    constexpr float2 vertices[6] = {
        float2(-1,-1),float2(1,-1),float2(-1,1),
        float2(-1,1),float2(1,-1),float2(1,1)
    };
    return vertices[i];
}
vertex QuadOut fieldVertex(uint v [[vertex_id]], uint instance [[instance_id]],
                           const device float4 *particles [[buffer(0)]],
                           constant OceanUniforms &u [[buffer(1)]]) {
    float4 particle = particles[instance];
    float2 local = corner(v);
    float2 p = rotate2(particle.xy, -u.viewport.w) + local * particle.w;
    QuadOut out;
    out.position = float4(p/u.viewport.xy, 0, 1);
    out.local = local;
    out.uv = p/u.viewport.xy*0.5+0.5;
    out.weight = particle.z;
    return out;
}
fragment float4 fieldFragment(QuadOut in [[stage_in]]) {
    float radius2 = dot(in.local,in.local);
    float density = pow(max(0.0,1.0-radius2),3.0);
    return float4(density, density*in.weight, 0, 0);
}
struct SurfaceKernel { float4 center; float4 axes; };
vertex QuadOut continuousFieldVertex(uint v [[vertex_id]], uint instance [[instance_id]],
                                      const device SurfaceKernel *kernels [[buffer(0)]],
                                      constant OceanUniforms &u [[buffer(1)]]) {
    SurfaceKernel footprint=kernels[instance];
    float2 local=corner(v);
    float2 offset=footprint.axes.xy*local.x+footprint.axes.zw*local.y;
    float2 p=rotate2(footprint.center.xy+offset,-u.viewport.w);
    QuadOut out;
    out.position=float4(p/u.viewport.xy,0,1);
    out.local=local;
    out.uv=p/u.viewport.xy*0.5+0.5;
    out.weight=footprint.center.z;
    return out;
}
struct VolumeOut {
    float4 position [[position]];
    float3 local;
    uint layer [[render_target_array_index]];
};
vertex VolumeOut volumeVertex(uint v [[vertex_id]],uint instance [[instance_id]],
                               const device float4 *particles [[buffer(0)]],
                               constant OceanUniforms &u [[buffer(1)]]) {
    uint slices=uint(u.optics.w);
    float4 particle=particles[instance/slices];
    uint slice=instance%slices;
    float2 local=corner(v);
    float2 p=rotate2(particle.xy,-u.viewport.w)+local*particle.w;
    float z=u.optics.y-(float(slice)+0.5)*(2.0*u.optics.y/float(slices));
    VolumeOut out;
    out.position=float4(p/u.viewport.xy,0,1);
    out.local=float3(local,(z-particle.z)/particle.w);
    out.layer=slice;
    return out;
}
fragment float volumeFragment(VolumeOut in [[stage_in]]) {
    float falloff=max(0.0,1.0-dot(in.local,in.local));
    return falloff*falloff*falloff;
}
kernel void extractDepth(texture2d_array<float,access::read> volume [[texture(0)]],
                         texture2d<float,access::write> target [[texture(1)]],
                         constant OceanUniforms &u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width()||gid.y>=target.get_height()) return;
    uint slices=volume.get_array_size();
    float step=2.0*u.optics.y/float(slices);
    float previous=volume.read(gid,0).r;
    bool inside=previous>=u.optics.z;
    float first=inside?0.0:1.0;
    float start=0.0, last=0.0, occupied=0.0, beforeToy=0.0;
    float toyDepth=clamp(u.optics.y-u.boat.w,0.0,2.0*u.optics.y);
    float previousDepth=step*0.5;
    for(uint i=1;i<slices;i++) {
        float value=volume.read(gid,i).r;
        float d=(float(i)+0.5)*step;
        bool nowInside=value>=u.optics.z;
        if(nowInside!=inside) {
            float t=clamp((u.optics.z-previous)/(value-previous),0.0,1.0);
            float crossing=mix(previousDepth,d,t);
            if(nowInside) { first=min(first,crossing); start=crossing; }
            else {
                last=crossing;
                occupied+=max(0.0,crossing-start);
                beforeToy+=max(0.0,min(crossing,toyDepth)-start);
            }
        }
        inside=nowInside;
        previous=value;
        previousDepth=d;
    }
    if(inside) {
        last=2.0*u.optics.y;
        occupied+=max(0.0,last-start);
        beforeToy+=max(0.0,min(last,toyDepth)-start);
    }
    if(first>0.5||occupied<=0.0) target.write(float4(1),gid);
    else target.write(float4(first,-last,beforeToy,occupied),gid);
}
kernel void smoothDepth(texture2d<float,access::read> source [[texture(0)]],
                        texture2d<float,access::write> target [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    uint2 size=uint2(source.get_width(),source.get_height());
    if(any(gid>=size)) return;
    float4 center=source.read(gid);
    if(center.r>0.5) { target.write(center,gid); return; }
    float4 total=float4(0);
    float weightSum=0;
    // One isotropic pass is invariant under quarter turns; don't bridge empty pixels.
    for(int y=-2;y<=2;y++) for(int x=-2;x<=2;x++) {
        int2 p=int2(gid)+int2(x,y);
        if(any(p<0)||any(p>=int2(size))) continue;
        float4 sample=source.read(uint2(p));
        if(sample.r>0.5) continue;
        float2 delta=sample.rg-center.rg;
        float weight=exp(-float(x*x+y*y)*0.30-dot(delta,delta)/0.0025);
        total+=sample*weight;
        weightSum+=weight;
    }
    total/=max(weightSum,0.0001);
    target.write(total,gid);
}
struct SurfaceSample { float4 depth; float coverage; };
SurfaceSample sampleSurface(texture2d<float> source, float2 uv) {
    // Invalid depth is metadata, never a physical length. Interpolate only
    // valid taps, keeping their footprint separate for silhouette coverage.
    int2 size=int2(source.get_width(),source.get_height());
    float2 p=uv*float2(size)-0.5;
    int2 base=int2(floor(p));
    float2 f=fract(p);
    float4 total=float4(0);
    float validWeight=0;
    for(int y=0;y<2;y++) for(int x=0;x<2;x++) {
        float weight=(x?f.x:1.0-f.x)*(y?f.y:1.0-f.y);
        float4 value=source.read(uint2(clamp(base+int2(x,y),int2(0),size-1)));
        if(value.r<0.5) { total+=value*weight; validWeight+=weight; }
    }
    SurfaceSample result;
    result.depth=validWeight>0 ? total/validWeight : float4(1);
    result.coverage=validWeight;
    return result;
}
vertex QuadOut screenVertex(uint v [[vertex_id]]) {
    QuadOut out;
    float2 p = corner(v);
    out.position = float4(p,0,1);
    out.uv = p*float2(0.5,-0.5)+0.5;
    out.local = p;
    out.weight = 1;
    return out;
}

float sdSegment(float2 p,float2 a,float2 b) {
    float2 pa=p-a,ba=b-a;
    return length(pa-ba*clamp(dot(pa,ba)/dot(ba,ba),0.0,1.0));
}
float triangle(float2 p, float2 a, float2 b, float2 c) {
    float2 e0=b-a,e1=c-b,e2=a-c;
    float2 v0=p-a,v1=p-b,v2=p-c;
    float2 pq0=v0-e0*clamp(dot(v0,e0)/dot(e0,e0),0.0,1.0);
    float2 pq1=v1-e1*clamp(dot(v1,e1)/dot(e1,e1),0.0,1.0);
    float2 pq2=v2-e2*clamp(dot(v2,e2)/dot(e2,e2),0.0,1.0);
    float s=sign(e0.x*e2.y-e0.y*e2.x);
    float2 d=min(min(float2(dot(pq0,pq0),s*(v0.x*e0.y-v0.y*e0.x)),
                       float2(dot(pq1,pq1),s*(v1.x*e1.y-v1.y*e1.x))),
                       float2(dot(pq2,pq2),s*(v2.x*e2.y-v2.y*e2.x)));
    return -sqrt(d.x)*sign(d.y);
}
float mask(float distance, float feather=0.0025) {
    return 1.0-smoothstep(-feather,feather,distance);
}
void paintToy(thread float3 &color, thread float &opacity, float3 pigment, float coverage) {
    color=mix(color,pigment,coverage);
    opacity=mix(opacity,1.0,coverage);
}
// Premultiplied toy color and coverage let the liquid attenuate the toy without
// subtracting a differently attenuated background (which could create black sails).
float4 miniature(float2 world, constant OceanUniforms &u) {
    float2 p=rotate2(world-u.boat.xy,-u.boat.z);
    if(abs(p.x)>0.32 || p.y< -0.13 || p.y>0.53) return float4(0);
    float3 result=float3(0);
    float opacity=0;
    // Original toy: shaped ivory hull, coral jib, linen main sail, brass mast.
    float ellipse=length(p/float2(0.235,0.076))-1.0;
    float hull=max(ellipse*0.07,p.y-0.018);
    float3 hullColor=mix(float3(0.57,0.50,0.34),float3(0.98,0.94,0.79),
                         smoothstep(-0.075,0.02,p.y));
    paintToy(result,opacity,hullColor,mask(hull));
    float rail=sdSegment(p,float2(-0.22,0.024),float2(0.21,0.024))-0.009;
    paintToy(result,opacity,float3(0.30,0.27,0.21),mask(rail));
    float deck=sdSegment(p,float2(-0.19,0.033),float2(0.17,0.033))-0.005;
    paintToy(result,opacity,float3(1.0,0.96,0.83),mask(deck));
    float mast=sdSegment(p,float2(-0.035,0.02),float2(-0.035,0.49))-0.005;
    paintToy(result,opacity,float3(0.49,0.36,0.18),mask(mast));
    float main=triangle(p,float2(-0.019,0.452),float2(-0.019,0.082),float2(0.193,0.082));
    float fold=0.025*sin((p.x+p.y*0.1)*75.0);
    float3 canvas=float3(0.98,0.965,0.89)-float3(0.11,0.09,0.06)*smoothstep(0.12,-0.03,p.x)+fold;
    paintToy(result,opacity,canvas,mask(main));
    float seam=sdSegment(p,float2(-0.008,0.38),float2(0.153,0.095))-0.001;
    paintToy(result,opacity,float3(0.77,0.74,0.61),mask(seam,0.001)*mask(main));
    float jib=triangle(p,float2(-0.052,0.345),float2(-0.204,0.07),float2(-0.052,0.07));
    paintToy(result,opacity,mix(float3(0.68,0.16,0.11),float3(0.96,0.36,0.22),p.y*2),mask(jib));
    float rig=sdSegment(p,float2(-0.04,0.47),float2(0.23,0.03))-0.0009;
    paintToy(result,opacity,float3(0.63,0.58,0.44),mask(rig,0.0012)*0.55);
    float pennant=triangle(p,float2(-0.029,0.485),float2(-0.029,0.445),float2(0.045,0.472));
    paintToy(result,opacity,float3(0.84,0.27,0.14),mask(pennant));
    return float4(result,opacity);
}

// A tactile toy is sampled at the existing boat's depth. The same ray crosses
// clear liquid, blue liquid and bubbles before reaching its transparent artwork.
float4 craftedMiniature(float2 world, constant OceanUniforms &u,
                        texture2d<float> art) {
    if(u.miniatureArt.x < 0) return miniature(world,u);
    float2 p=rotate2(world-u.boat.xy,-u.boat.z)/u.miniatureArt.y;
    // Every color uses exactly the same alpha, aspect, scale and waterline.
    // The rounded hull is ~71pt wide at 402pt; its lower quarter sits in liquid.
    const float3 r=float3(0.521,0.800,0.696);
    uint variant=uint(clamp(u.miniatureArt.x,0.0,2.0));
    float2 uv=r.xy+float2(p.x,-p.y)*(r.z/.47);
    if(any(uv<0.0)||any(uv>1.0)) return float4(0);
    constexpr sampler artSampler(coord::normalized,address::clamp_to_zero,
        filter::linear,mip_filter::linear);
    // A mild local mip bias keeps the rim, rope and cloth hem legible after
    // the existing mobile resolve, without sharpening the liquid or the alpha.
    float4 texel=art.sample(artSampler,uv,bias(-0.35));
    if(texel.a<0.001) return texel;
    float3 material=texel.rgb/max(texel.a,0.001);
    // Warm cloth needs a little tonal weight at phone size against the clear
    // chamber. Preserve its weave and alpha instead of drawing a flat outline.
    float cloth=smoothstep(0.505,0.54,uv.x)*(1.0-smoothstep(0.565,0.59,uv.y))
                *smoothstep(0.60,0.82,min(material.r,material.g));
    material*=mix(float3(1),float3(0.95,0.91,0.85),cloth);
    if(variant==0) return float4(material*texel.a,texel.a);
    // Replace only cool blue hull paint. Wood, ivory stripe and cloth retain
    // their original colors; the source luminance retains carved grain/wear.
    float hull=smoothstep(0.025,0.10,material.b-material.r)
              *smoothstep(0.015,0.07,material.g-material.r)
              *smoothstep(0.58,0.62,uv.y);
    float shade=clamp(dot(material,float3(0.2126,0.7152,0.0722))/0.34,0.12,1.55);
    float3 paint=variant==1 ? float3(0.93,0.71,0.32) : float3(212.0/255.0,76.0/255.0,56.0/255.0);
    float3 color=mix(material,clamp(paint*shade,0.0,1.0),hull);
    // The red version has a navy ring so the single little accessory stays clear.
    if(variant==2) {
        float ring=smoothstep(0.12,0.35,material.r-max(material.g,material.b))
                   *(1.0-smoothstep(0.41,0.43,uv.x))*smoothstep(0.62,0.65,uv.y);
        float ringShade=clamp(material.r/0.85,0.25,1.3);
        color=mix(color,float3(0.13,0.25,0.34)*ringShade,ring);
    }
    return float4(color*texel.a,texel.a);
}

// Render-only shadow and meniscus weights at the actual blue/clear boundary.
// The caller occludes these with the hull; a wake appears only with existing
// hull-relative velocity. No forces, particles or collision geometry change.
float2 miniatureContact(float2 world, constant OceanUniforms &u) {
    if(u.miniatureArt.x<0) return float2(0);
    float2 p=rotate2(world-u.boat.xy,-u.boat.z)*(0.75/u.miniatureArt.y);
    float speed=clamp(abs(u.miniatureArt.w),0.0,1.0);
    float side=u.miniatureArt.w<0 ? 1.0 : -1.0;
    float span=1.0-smoothstep(.135,.180,abs(p.x));
    float shadow=exp(-pow((p.y+.004)/.0055,2.0))*span*.10;
    float ends=smoothstep(.100,.145,abs(p.x))*(1.0-smoothstep(.164,.186,abs(p.x)));
    float lip=exp(-pow((p.y-.001)/.0035,2.0))*ends*.13;
    float2 q=p-float2(side*(.172+speed*.016),-.004);
    float wake=exp(-pow(q.y/.0045,2.0)-pow(q.x/(.014+speed*.016),2.0))
               *smoothstep(.025,.30,speed)*.10;
    return float2(shadow,lip+wake)*smoothstep(.03,.3,u.miniatureArt.z);
}

float3 backdrop(float2 p, constant OceanUniforms &u) {
    float diagonal=dot(p,float2(-0.2,0.12));
    float3 color=mix(float3(0.88,0.87,0.81),float3(0.98,0.97,0.91),
                    clamp(0.6+diagonal,0.0,1.0));
    float window=exp(-pow((p.x+0.45)*1.4,2.0)-pow((p.y-1.1)*0.8,2.0));
    color+=float3(0.035,0.033,0.026)*window;
    if(u.color.w < 0.5) return color;
    // Original miniature island study, not a photograph or an identified place.
    // It is printed behind the vessel: the liquid samples this same scene at
    // refracted coordinates, rather than flipping the background upside down.
    float2 q=(p-float2(0.48,-0.66))*1.45;
    float2 shadowPoint=(q-float2(0.045,-0.14))/float2(0.55,0.09);
    color*=1.0-0.16*exp(-dot(shadowPoint,shadowPoint)*1.6);
    float sand=(length(q/float2(0.56,0.13))-1.0)*0.10;
    float3 sandColor=mix(float3(0.64,0.56,0.39),float3(0.96,0.88,0.64),
                         clamp((q.y+0.10)/0.20,0.0,1.0));
    color=mix(color,sandColor,mask(sand,0.004));
    // Soft rounded limestone pieces with directional shading, like painted clay.
    for(int i=0;i<3;i++) {
        float f=float(i);
        float2 center=float2(-0.23+f*0.18,0.075+sin(f*1.8)*0.035);
        float2 size=float2(0.15+f*0.015,0.105+f*0.018);
        float2 rock=(q-center)/size;
        float rockDistance=(length(rock)-1.0)*0.12;
        float3 rockNormal=normalize(float3(rock,sqrt(max(0.02,1.0-dot(rock,rock)))));
        float lighting=0.70+0.30*max(0.0,dot(rockNormal,normalize(float3(-0.6,0.75,1.0))));
        color=mix(color,float3(0.87,0.89,0.77)*lighting,mask(rockDistance,0.003));
        float2 crown=rock-float2(-0.08,0.68);
        float moss=(length(crown/float2(0.85,0.25))-1.0)*0.09;
        float3 mossColor=mix(float3(0.20,0.39,0.28),float3(0.49,0.66,0.38),
                             clamp((crown.y-crown.x+0.7)*0.5,0.0,1.0));
        color=mix(color,mossColor,mask(moss,0.004)*mask(rockDistance,0.003));
    }
    // One small curved palm, kept behind the moving foreground sailboat.
    float trunk=sdSegment(q,float2(0.28,0.0),float2(0.34,0.47))-0.012;
    color=mix(color,float3(0.53,0.39,0.24),mask(trunk,0.003));
    float2 top=q-float2(0.34,0.47);
    for(int i=0;i<5;i++) {
        float angle=-0.40+float(i)*0.77;
        float2 leaf=rotate2(top,angle);
        float d=(length((leaf-float2(0.09,0))/float2(0.14,0.035))-1.0)*0.03;
        color=mix(color,float3(0.28,0.53,0.34),mask(d,0.002));
    }
    return color;
}

// An analytic studio environment: broad diffuse light and two narrow softboxes.
// This changes with the simulated surface normal, rather than painting a fixed
// white stripe over the water. It is an optical cue, not a ray-traced environment.
float3 reflectedStudio(float3 direction) {
    float3 ambient=mix(float3(0.40,0.54,0.62),float3(0.91,0.96,0.98),
                       smoothstep(-0.5,0.8,direction.y));
    float softbox=exp(-pow((direction.x+0.48)/0.16,2.0))
                 *smoothstep(-0.45,0.2,direction.y);
    float strip=exp(-pow((direction.x-0.62)/0.07,2.0))
               *exp(-pow((direction.y+0.08)/0.6,2.0));
    return mix(ambient,float3(1.0,0.99,0.94),clamp(softbox+strip*0.55,0.0,1.0));
}

fragment float4 oceanFragment(QuadOut in [[stage_in]],
                              texture2d<float> field [[texture(0)]],
                              texture2d<float> surface [[texture(1)]],
                              texture2d<float> miniatureTexture [[texture(3)]],
                              constant OceanUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 uv=in.uv;
    float2 pixel=1.0/float2(field.get_width(),field.get_height());
    float2 fieldValue=field.sample(smp,uv).rg;
    float density=fieldValue.x;
    float left=field.sample(smp,uv-float2(pixel.x,0)).r;
    float right=field.sample(smp,uv+float2(pixel.x,0)).r;
    float above=field.sample(smp,uv-float2(0,pixel.y)).r;
    float below=field.sample(smp,uv+float2(0,pixel.y)).r;
    float2 gradient=float2(right-left,below-above);
    float2 screen=(uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    float2 world=rotate2(screen,u.viewport.w);
    // Keep the optical interface crisp at the output pixel scale.
    float surfaceAA=max(fwidth(density),0.025);
    float coverage=smoothstep(0.52-surfaceAA,0.52+surfaceAA,density);
    // Kernel density includes a broad smoothing footprint. Map it to a bounded
    // optical path so this footprint doesn't become a wide pale halo. Thin
    // sheets still transmit more light; the vessel limits the interior path.
    // This is an optical approximation, not a reconstructed 3D ray length.
    float depth=max(0.0,dot(world,u.movement.xy));
    float opticalPath=1.5*(1.0-exp(-max(density-0.35,0.0)*0.18));
    float thickness=clamp(opticalPath+depth*0.25,0.0,1.5);
    float2 normal=gradient*0.6;
    float2 refracted=world+rotate2(float2(normal.x,-normal.y),u.viewport.w)*0.028;
    float3 reconstructedNormal=float3(0,0,1);
    float front=0, pathLength=0;
    bool reconstructed=u.optics.x>0.5 && u.optics.x<1.5;
    bool clearInterface=u.optics.x>1.5;
    float3 interfaceNormal=float3(0,0,1);
    float interfaceBand=0;
    if(clearInterface) {
        // Recover a distance near the 2D contour. Do not interpret the full
        // smoothing-kernel footprint as a thick, milky optical transition.
        // The finite slab and narrow rounded lip are visual approximations,
        // not reconstructed ray lengths or measured toy material parameters.
        float2 metricGradient=gradient/(4.0*u.viewport.xy*pixel);
        float distance=max(0.0,(density-0.52)/max(length(metricGradient),0.001));
        float lip=clamp(distance/0.035,0.0,1.0);
        float nz=sqrt(max(0.0001,1.0-pow(1.0-lip,2.0)));
        float2 outward=rotate2(float2(-metricGradient.x,metricGradient.y),u.viewport.w);
        outward/=max(length(outward),0.0001);
        interfaceNormal=normalize(float3(outward*sqrt(max(0.0,1.0-nz*nz)),nz));
        interfaceBand=1.0-smoothstep(0.012,0.04,distance);
        float3 ray=refract(float3(0,0,-1),interfaceNormal,1.0/1.33);
        refracted=world+ray.xy/max(abs(ray.z),0.2)*0.09;
        thickness=clamp(1.1+depth*0.18,0.0,1.5)*sqrt(clamp(distance/0.025,0.0,1.0));
    }
    if(reconstructed) {
        SurfaceSample sampled=sampleSurface(surface,uv);
        float4 s=sampled.depth;
        bool valid=s.r<0.5;
        front=s.r;
        pathLength=valid ? clamp(s.a,0.0,u.optics.y*2.0) : 0.0;
        float4 sl=sampleSurface(surface,uv-float2(pixel.x,0)).depth;
        float4 sr=sampleSurface(surface,uv+float2(pixel.x,0)).depth;
        float4 sa=sampleSurface(surface,uv-float2(0,pixel.y)).depth;
        float4 sb=sampleSurface(surface,uv+float2(0,pixel.y)).depth;
        float dx=((sr.r<0.5?sr.r:front)-(sl.r<0.5?sl.r:front))/(4.0*u.viewport.x*pixel.x);
        float dy=((sa.r<0.5?sa.r:front)-(sb.r<0.5?sb.r:front))/(4.0*u.viewport.y*pixel.y);
        reconstructedNormal=normalize(float3(rotate2(float2(dx,dy),u.viewport.w),1.0));
        // A bounded single-interface ray for this experiment. Oil/plastic layers remain absent.
        float3 ray=refract(float3(0,0,-1),reconstructedNormal,1.0/1.33);
        float2 offset=ray.xy/max(abs(ray.z),0.2)*(pathLength+0.08);
        float offsetLength=length(offset);
        offset*=min(1.0,0.18/max(offsetLength,0.0001));
        refracted=world+offset;
        thickness=pathLength/0.24;
        // The old density contour can cut off the sphere's curved rim. Keep
        // coverage coupled to the reconstructed path instead of that 2D mask.
        coverage=valid ? sampled.coverage*smoothstep(0.0,0.018,pathLength) : 0.0;
    }
    float4 dryToy=craftedMiniature(world,u,miniatureTexture);
    float3 dry=backdrop(world,u)*(1.0-dryToy.a)+dryToy.rgb;
    float3 scene=displayToLight(backdrop(refracted,u));
    // Treat the style color as transmission through a reference thickness.
    // The same dye stays pale in thin liquid and becomes richer with optical depth.
    float3 referenceTransmission=clamp(u.color.rgb,float3(0.02),float3(0.98));
    float3 absorbCoefficients=-log(referenceTransmission)*0.72;
    float3 absorption=exp(-absorbCoefficients*thickness);
    float3 scatteredLight=referenceTransmission*(clearInterface?0.06:0.22);
    float3 water=scene*absorption+scatteredLight*(1.0-absorption);
    // The shallow volume's depth matters when the device lies flat: a boat nearer
    // the viewer than the water isn't painted over as if it were submerged.
    float meanDepth=fieldValue.y/max(density,0.001);
    float waterInFront=smoothstep(-0.11,0.11,meanDepth-u.boat.w);
    float toyPath=thickness*waterInFront;
    if(reconstructed) {
        toyPath=clamp(sampleSurface(surface,uv).depth.b,0.0,pathLength)/0.24;
        waterInFront=clamp(toyPath/max(thickness,0.0001),0.0,1.0);
    }
    float2 boatSample=mix(world,refracted,waterInFront);
    float4 wetToy=craftedMiniature(boatSample,u,miniatureTexture);
    float3 toyTransmission=exp(-absorbCoefficients*toyPath);
    float3 toyLight=displayToLight(wetToy.rgb/max(wetToy.a,0.0001))*wetToy.a;
    float3 submergedToy=toyLight*toyTransmission
                       +scatteredLight*(1.0-toyTransmission)*wetToy.a;
    water=water*(1.0-wetToy.a)+submergedToy;
    float caustic=sin(world.x*13.0+sin(world.y*8.0+u.viewport.z*0.16)*1.5)
                 +sin(world.y*19.0+world.x*7.0-u.viewport.z*0.12);
    float glint=pow(max(0.0,caustic*0.48),7.0)*0.06;
    water+=float3(0.02,0.24,0.29)*glint;
    // Restrict the curved meniscus to the interface; particle density noise in
    // the interior must not turn the entire liquid into a metallic surface.
    float edgeDistance=(density-0.52)/max(length(gradient),0.08);
    float meniscus=exp(-pow(max(edgeDistance,0.0)/0.9,2.0));
    float2 outward=rotate2(float2(-gradient.x,gradient.y),u.viewport.w);
    float3 surfaceNormal=normalize(float3(outward*meniscus*2.0,1.0));
    if(reconstructed) surfaceNormal=reconstructedNormal;
    if(clearInterface) { surfaceNormal=interfaceNormal; meniscus=interfaceBand; }
    float baseReflectance=clearInterface?0.008:0.02;
    float fresnel=baseReflectance+(1.0-baseReflectance)*pow(1.0-surfaceNormal.z,5.0);
    float3 reflection=displayToLight(reflectedStudio(reflect(float3(0,0,-1),surfaceNormal)));
    water=mix(water,reflection,fresnel);
    float3 halfLight=normalize(normalize(float3(-0.55,0.8,1.0))+float3(0,0,1));
    float highlight=pow(max(0.0,dot(surfaceNormal,halfLight)),64.0);
    water+=float3(0.9,0.98,1.0)*highlight*(reconstructed?0.35:meniscus*(clearInterface?0.08:0.30));
    float fineRim=exp(-pow(edgeDistance/0.32,2.0))*min(1.0,length(gradient)*2.0);
    water+=float3(0.40,0.70,0.78)*fineRim*((reconstructed||clearInterface)?0.0:0.14);
    float3 color=mix(dry,lightToDisplay(water),coverage);

    // The device is the vessel; this is an edge refraction, not another box inside the screen.
    float edge=min(1.0-abs(world.x),2.12-abs(world.y));
    float wall=exp(-max(edge,0.0)*65.0);
    color=mix(color,color*0.70+float3(0.07,0.12,0.13),wall*0.35);
    float stripe=exp(-pow((edge-0.021)*190.0,2.0));
    color+=float3(0.12,0.14,0.13)*stripe;
    color*=1.0-0.06*pow(length(screen/u.viewport.xy)*0.7,3.0);
    return float4(clamp(color,0.0,1.0),1);
}

vertex QuadOut bubbleVertex(uint v [[vertex_id]],uint instance [[instance_id]],
                            const device float4 *bubbles [[buffer(0)]],
                            constant OceanUniforms &u [[buffer(1)]]) {
    float4 bubble=bubbles[instance];
    float2 local=corner(v);
    float2 p=rotate2(bubble.xy,-u.viewport.w)+local*bubble.z;
    QuadOut out;
    out.position=float4(p/u.viewport.xy,0,1);
    out.local=local;
    out.uv=p/u.viewport.xy*float2(0.5,-0.5)+0.5;
    out.weight=bubble.w;
    return out;
}
fragment float4 bubbleFragment(QuadOut in [[stage_in]],texture2d<float> field [[texture(0)]],
                               constant OceanUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    float r=length(in.local);
    float aa=max(fwidth(r),0.025);
    float silhouette=1.0-smoothstep(0.90-aa,0.90+aa,r);
    // A clear center with opposing light/dark arcs reads as a small curved
    // interface instead of a uniformly luminous ring. This is a shading cue;
    // the underlying ocean is still composited through the transparent center.
    float rimDistance=(r-0.78)/0.12;
    float rim=exp(-rimDistance*rimDistance);
    // Use the same device-space studio light as the liquid surface.
    float2 litLocal=rotate2(in.local,u.viewport.w);
    float2 radial=litLocal/max(r,0.001);
    float facing=dot(radial,normalize(float2(-0.55,0.83)));
    float brightArc=smoothstep(-0.15,0.8,facing);
    float darkArc=smoothstep(0.0,0.8,-facing);
    float2 sparkleOffset=litLocal-float2(-0.28,0.35);
    float sparkle=exp(-dot(sparkleOffset,sparkleOffset)*65.0);
    float2 echoOffset=litLocal-float2(0.25,-0.39);
    float echo=exp(-dot(echoOffset,echoOffset)*90.0)*0.22;
    float wet=smoothstep(0.25,0.7,field.sample(smp,in.uv).r);
    float lightAlpha=clamp(rim*(0.08+brightArc*0.32)+sparkle*0.72+echo,0.0,0.9);
    float shadowAlpha=rim*darkArc*0.24;
    float alpha=lightAlpha+shadowAlpha*(1.0-lightAlpha);
    float3 premultiplied=float3(0.84,0.97,1.0)*lightAlpha
                       +float3(0.015,0.13,0.20)*shadowAlpha*(1.0-lightAlpha);
    float visibility=silhouette*clamp(in.weight,0.0,1.0)*wet;
    return float4(premultiplied,alpha)*visibility;
}
