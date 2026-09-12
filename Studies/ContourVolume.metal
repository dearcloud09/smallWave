// Standalone optical study. The 2D contour is preserved, but depth is inferred,
// not recovered from the particle distribution. Not part of the app target.
kernel void contourSeeds(texture2d<float,access::read> field [[texture(0)]],
                         texture2d<float,access::write> output [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    int2 size=int2(field.get_width(),field.get_height()), p=int2(gid);
    if(any(p>=size)) return;
    float v=field.read(gid).r-0.52;
    float2 best=float2(-10000);
    float bestD=1e10;
    constexpr int2 offsets[4]={int2(-1,0),int2(1,0),int2(0,-1),int2(0,1)};
    for(int i=0;i<4;i++) {
        int2 q=p+offsets[i];
        if(any(q<0)||any(q>=size)) continue;
        float w=field.read(uint2(q)).r-0.52;
        if((v>=0)!=(w>=0)) {
            float2 crossing=float2(p)+float2(offsets[i])*v/(v-w);
            float d=length_squared(crossing-float2(p));
            if(d<bestD) { best=crossing; bestD=d; }
        }
    }
    output.write(float4(best,0,0),gid);
}
kernel void contourJump(texture2d<float,access::read> source [[texture(0)]],
                        texture2d<float,access::write> target [[texture(1)]],
                        constant uint &jump [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int2 p=int2(gid), size=int2(source.get_width(),source.get_height());
    if(any(p>=size)) return;
    float2 best=float2(-10000); float bestD=1e20;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
        int2 q=p+int2(x,y)*int(jump);
        if(any(q<0)||any(q>=size)) continue;
        float2 seed=source.read(uint2(q)).xy;
        if(seed.x< -1000) continue;
        float d=length_squared(seed-float2(p));
        if(d<bestD) { bestD=d; best=seed; }
    }
    target.write(float4(best,0,0),gid);
}
kernel void contourDistance(texture2d<float,access::read> seeds [[texture(0)]],
                            texture2d<float,access::read> field [[texture(1)]],
                            texture2d<float,access::write> target [[texture(2)]],
                            constant OceanUniforms &u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=target.get_width()||gid.y>=target.get_height()) return;
    float2 seed=seeds.read(gid).xy;
    float2 scale=2.0*u.viewport.xy/float2(target.get_width(),target.get_height());
    float d=seed.x< -1000 ? 4.0 : length((seed-float2(gid))*scale);
    target.write(float4(d*(field.read(gid).r>=0.52?1:-1)),gid);
}
float contourAt(texture2d<float> sdf,float2 p,constant OceanUniforms &u) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 screen=rotate2(p,-u.viewport.w);
    float2 uv=screen/u.viewport.xy*float2(0.5,-0.5)+0.5;
    return sdf.sample(smp,uv).r;
}
float contourVolume(texture2d<float> sdf,float3 p,constant OceanUniforms &u) {
    float d=contourAt(sdf,p.xy,u);
    // Round cross-section near the contour; broad interior saturates at a
    // shallow slab. This invents depth and can join projection-only overlaps.
    const float h=0.16;
    return length(float2(max(0.0,h-d),p.z))-h;
}
float3 contourNormal(texture2d<float> sdf,float3 p,constant OceanUniforms &u) {
    const float e=0.0025;
    float3 g=float3(
        contourVolume(sdf,p+float3(e,0,0),u)-contourVolume(sdf,p-float3(e,0,0),u),
        contourVolume(sdf,p+float3(0,e,0),u)-contourVolume(sdf,p-float3(0,e,0),u),
        contourVolume(sdf,p+float3(0,0,e),u)-contourVolume(sdf,p-float3(0,0,e),u));
    return g/max(length(g),0.00001);
}
float contourFresnel(float cosine,float n1,float n2) {
    float sin2=(n1*n1)/(n2*n2)*max(0.0,1-cosine*cosine);
    if(sin2>=1) return 1;
    float transmitted=sqrt(1-sin2);
    float s=(n1*cosine-n2*transmitted)/(n1*cosine+n2*transmitted);
    float p=(n2*cosine-n1*transmitted)/(n2*cosine+n1*transmitted);
    return 0.5*(s*s+p*p);
}
fragment float4 contourOceanFragment(QuadOut in [[stage_in]],
                                     texture2d<float> field [[texture(0)]],
                                     texture2d<float> sdf [[texture(1)]],
                                     constant OceanUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 screen=(in.uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    float2 world=rotate2(screen,u.viewport.w);
    bool tilted=u.optics.x>4.5 && u.optics.x<5.5;
    float density=field.sample(smp,in.uv).r;
    float aa=max(fwidth(density),0.025);
    float coverage=smoothstep(0.52-aa,0.52+aa,density);
    float4 dryToy=miniature(world,u);
    float3 dry=backdrop(world,u)*(1-dryToy.a)+dryToy.rgb;
    if((!tilted && coverage<0.001) || (tilted && contourAt(sdf,world,u)< -0.12))
        return u.optics.w>0.5 ? float4(0) : float4(dry,1);
    // Study parameters, not measured values of the reference toy.
    const float clearIOR=1.46;
    float blueIOR=u.optics.x>1.5 && u.optics.x<3.5 ? clearIOR : 1.333;
    bool straight=u.optics.x>2.5 && u.optics.x<3.5;
    float3 reference=clamp(u.color.rgb,float3(0.02),float3(0.98));
    if(u.optics.z>0.5) reference=displayToLight(reference);
    float3 dye=-log(reference)*0.72/0.24;
    float3 direction=tilted?normalize(float3(0.10,-0.38,-1)):float3(0,0,-1);
    float3 p=float3(world+direction.xy/direction.z*0.195,0.195);
    float3 transmittance=float3(1), radiance=float3(0);
    float3 toyTrans=float3(1); float2 toyPoint=world;
    bool inside=false, foundToy=false, finished=false;
    float path=0; uint crossings=0, reflections=0;
    float value=contourVolume(sdf,p,u);
    for(uint step=0;step<160;step++) {
        float distance=clamp(abs(value)*0.7,0.0007,0.014);
        float3 next=p+direction*distance;
        float nextValue=contourVolume(sdf,next,u);
        bool crosses=(value<0)!=(nextValue<0);
        if(crosses) {
            float low=0,high=distance;
            for(uint j=0;j<6;j++) {
                float middle=(low+high)*0.5;
                if((contourVolume(sdf,p+direction*middle,u)<0)==(value<0)) low=middle; else high=middle;
            }
            distance=(low+high)*0.5;
            next=p+direction*distance;
        }
        if(!foundToy && direction.z<0 && p.z>=u.boat.w && next.z<=u.boat.w) {
            float part=clamp((p.z-u.boat.w)/max(p.z-next.z,0.00001),0.0,1.0);
            toyPoint=mix(p.xy,next.xy,part);
            toyTrans=transmittance*(inside?exp(-dye*distance*part):float3(1));
            foundToy=true;
        }
        if(inside) { transmittance*=exp(-dye*distance); path+=distance; }
        p=next;
        if(crosses) {
            float3 n=contourNormal(sdf,p,u);
            if(dot(n,direction)>0) n=-n;
            float n1=inside?blueIOR:clearIOR, n2=inside?clearIOR:blueIOR;
            float reflection=straight?0:contourFresnel(clamp(-dot(n,direction),0.0,1.0),n1,n2);
            float3 refracted=straight?direction:refract(direction,n,n1/n2);
            crossings++;
            if(length_squared(refracted)<0.0001) {
                direction=reflect(direction,n); reflections++;
            } else {
                // One transmitted path with environment reflection at boundaries;
                // secondary reflected rays are not traced through the fluid.
                radiance+=transmittance*reflection*displayToLight(reflectedStudio(reflect(direction,n)));
                transmittance*=1-reflection;
                direction=normalize(refracted); inside=!inside;
            }
            p+=direction*0.0015;
            value=contourVolume(sdf,p,u);
        } else value=nextValue;
        if(p.z < -0.19 || p.z > 0.205 || abs(p.x)>1.01 || abs(p.y)>2.13) { finished=true; break; }
    }
    if(u.optics.w>0.5) {
        // Diagnostic: optical path (red), interface count (green), unresolved (blue).
        return float4(path/0.5,float(crossings)/8.0,finished?0:1,1);
    }
    if(tilted) coverage=crossings>0?1:0;
    float2 backgroundPoint=p.xy;
    if(direction.z< -0.02) backgroundPoint+=direction.xy*((-0.24-p.z)/direction.z);
    float3 backdropLight=displayToLight(backdrop(backgroundPoint,u));
    if(!finished) backdropLight=displayToLight(reflectedStudio(direction));
    float3 wet=radiance+transmittance*backdropLight;
    float4 toy=miniature(foundToy?toyPoint:world,u);
    // Toy depth uses integrated blue distance up to its plane. This is still a
    // plane sprite; full miniature geometry is outside the study.
    wet=wet*(1-toy.a)+displayToLight(toy.rgb/max(toy.a,0.00001))*toy.a*(foundToy?toyTrans:float3(1));
    float3 color=mix(dry,lightToDisplay(wet),coverage);
    return float4(clamp(color,0.0,1.0),1);
}
