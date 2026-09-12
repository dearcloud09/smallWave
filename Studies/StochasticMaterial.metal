// Full sampled specular paths through both media. This is a different candidate
// from FastMaterial's deterministic secondary-environment approximation.
// Finite loops remain visible failures. Russian roulette is an unbiased random
// path termination, not filling unfinished rays with a guessed background.

uint pathRandomBits(thread uint &state) {
    state=state*747796405u+2891336453u;
    uint word=((state>>((state>>28u)+4u))^state)*277803737u;
    return (word>>22u)^word;
}
float pathRandom(thread uint &state) {return (float(pathRandomBits(state)>>8)+.5)/16777216.0;}
float pathNextStep(texture3d<float> bounds,float3 p,float3 d,float traveled,
                   float wallDistance,bool blue,bool skip,uint maxMip) {
    float next=min(wallDistance,traveled+.00375);
    if(!skip) return next;
    float3 q=p+d*traveled;
    float3 grid=float3(q.x*.5+.5,.5-q.y/4.24,.5-q.z/.36)*float3(256,544,48)-.5;
    float3 speed=d*float3(128,-544.0/4.24,-48.0/.36);
    for(int mip=int(min(maxMip,bounds.get_num_mip_levels()-1));mip>=0;mip--) {
        int cells=4*(1<<mip);
        int3 size=int3(bounds.get_width(mip),bounds.get_height(mip),bounds.get_depth(mip));
        int3 block=clamp(int3(floor(grid/float(cells))),int3(0),size-1);
        float2 range=bounds.read(uint3(block),mip).rg;
        if(blue ? range.x<=.60001 : range.y>=.59999) continue;
        float distance=1e9;
        for(uint axis=0;axis<3;axis++) if(abs(speed[axis])>1e-8) {
            float face=float(block[axis]*cells+(speed[axis]>0?cells:0));
            distance=min(distance,(face-grid[axis])/speed[axis]);
        }
        // End inside the certified parent block. Its child bounds are a true
        // min/max union; no unchecked interpolation cell is skipped.
        return max(next,min(wallDistance,traveled+distance-.0001));
    }
    return next;
}
float3 pathStudio(float3 p,float3 d,bool softLights,bool sourceAOV,bool softFloor) {
    // Studio axes are the app axes: X right / Y up / Z toward the camera.
    // Window centers are outside the direct front view of the phone vessel.
    float3 color=sourceAOV ? float3(1,0,0) : float3(.1804,.1936,.2090);
    float nearest=1e9;
    if(d.y<-.000001) {
        float t=(-2.20-p.y)/d.y;
        if(t>0) {
            float3 q=p+d*t;nearest=t;
            float pool=exp(-pow(q.x*.22,2.0)-pow(q.z*.16,2.0));
            float3 floorLight=float3(.38,.40,.41)+float3(.23,.22,.19)*pool;
            // A locally illuminated floor approaches the same ambient level
            // as the surrounding studio in the distance. The previous floor
            // stayed bright out to infinity, creating a sharp reflected horizon.
            if(softFloor) floorLight=mix(float3(.1804,.1936,.2090),floorLight,exp(-dot(q.xz,q.xz)/18.0));
            color=sourceAOV ? float3(0,1,0) : floorLight;
        }
    }
    const float3 locations[3]={float3(-3,6,4),float3(3,4,-2),float3(0,3,-2.5)};
    const float2 dimensions[3]={float2(4,4),float2(3,2),float2(3,.22)};
    const float3 emissions[3]={float3(6.5,6.4,6.15),float3(5.0,5.2,5.4),float3(4.8,5.0,5.2)};
    float distances[3]={1e9,1e9,1e9};
    float gates[3]={0,0,0};
    uint order[3]={0,1,2};
    for(uint l=0;l<3;l++) {
        float3 n=normalize(locations[l]);
        float3 right=normalize(cross(float3(0,1,0),n)),up=cross(n,right);
        float denom=dot(d,n);
        if(abs(denom)<1e-6) continue;
        float t=dot(locations[l]-p,n)/denom;
        if(t<=0||t>=nearest) continue;
        float3 delta=p+d*t-locations[l];
        if(abs(dot(delta,right))<=dimensions[l].x*.5 && abs(dot(delta,up))<=dimensions[l].y*.5) {
            distances[l]=t;gates[l]=1;
            if(softLights) {
                float2 edge=(dimensions[l]*.5-abs(float2(dot(delta,right),dot(delta,up))))/(dimensions[l]*.2);
                float2 ramp=smoothstep(float2(0),float2(1),edge);
                gates[l]=ramp.x*ramp.y;
            }
        }
    }
    // Composite finite cards from far to near. The soft profile has the same
    // support and integrated emitted radiance: each 20%-width edge ramp gives
    // a 1D integral of .8*width, hence the 1/.64 emission normalization.
    // A feathered edge also transmits the light behind it; it is not a black
    // opaque strip with a discontinuity at the outside edge.
    for(uint i=0;i<2;i++) for(uint j=i+1;j<3;j++)
        if(distances[order[i]]<distances[order[j]]) {uint tmp=order[i];order[i]=order[j];order[j]=tmp;}
    for(uint i=0;i<3;i++) {
        uint l=order[i];
        if(distances[l]<nearest) color=mix(color,sourceAOV ? float3(0,0,1) : emissions[l]/(softLights?.64:1.0),gates[l]);
    }
    return color;
}
float3 sampledLiquidPath(texture3d<float> field,texture3d<float> bounds,float2 world,
                         constant OceanUniforms &u,thread uint &rng,thread bool &error) {
    float3 p=float3(world,.17998),d=float3(0,0,-1),throughput=float3(1);
    bool sourceAOV=u.optics.w< -3.5;
    float3 coeff=fastAbsorption(u.color.rgb);
    float frontF=fastFresnel(1,1,1.46);
    if(pathRandom(rng)<frontF) return pathStudio(p,float3(0,0,1),(uint(u.color.w)&1u)!=0,sourceAOV,(uint(u.color.w)&2u)!=0);
    bool blue=fastDensity(field,p)>0;
    uint totalSteps=0;
    for(uint bounce=0;bounce<96;bounce++) {
        // Unbiased roulette, with a guaranteed chance to end long reflected
        // paths. Surviving paths carry the reciprocal probability weight.
        if(bounce>=6) {
            float survival=clamp(max(max(throughput.x,throughput.y),throughput.z),.10,.75);
            if(pathRandom(rng)>survival) return float3(0);
            throughput/=survival;
        }
        float3 wallNormal;
        float wallDistance=fastBoxExit(p,d,wallNormal);
        float traveled=0,hitDistance=wallDistance;bool interfaceHit=false;
        for(uint step=0;step<4096;step++) {
            if(traveled>=wallDistance) break;
            if(++totalSteps>4096) {error=true;return float3(0);}
            float next=pathNextStep(bounds,p,d,traveled,wallDistance,blue,u.optics.z>.5,u.optics.z>1.5 ? 2:0);
            if((fastDensity(field,p+d*next)>0)!=blue) {
                float lo=traveled,hi=next;
                for(uint refine=0;refine<9;refine++) {
                    float mid=(lo+hi)*.5;
                    if((fastDensity(field,p+d*mid)>0)==blue) lo=mid;else hi=mid;
                }
                hitDistance=(lo+hi)*.5;interfaceHit=true;break;
            }
            traveled=next;
        }
        float toyT=abs(d.z)>1e-8 ? (u.boat.w-p.z)/d.z : -1;
        if(toyT>1e-5&&toyT<hitDistance) {
            float4 toy=miniature((p+d*toyT).xy,u);
            if(pathRandom(rng)<toy.a) {
                if(blue) throughput*=exp(-coeff*toyT);
                return sourceAOV ? float3(1,1,0) : throughput*displayToLight(toy.rgb/max(toy.a,1e-5));
            }
        }
        if(blue) throughput*=exp(-coeff*hitDistance);
        p+=d*hitDistance;
        if(interfaceHit) {
            float3 outward=fastNormal(field,p),n=blue?-outward:outward;
            if(dot(n,d)>0) n=-n;
            float ni=blue?1.333:1.46,nt=blue?1.46:1.333;
            float f=fastFresnel(-dot(n,d),ni,nt);
            if(pathRandom(rng)<f) d=reflect(d,n);
            else {d=refract(d,n,ni/nt);blue=!blue;}
            // Offset along the known geometric side, avoiding a tangential
            // direction offset that may fail to clear the root bracket.
            p+=(blue?-outward:outward)*.000025;
        } else {
            float ni=blue?1.333:1.46,f=fastFresnel(dot(d,wallNormal),ni,1);
            if(pathRandom(rng)>=f) {
                float3 exitLight=pathStudio(p,refract(d,-wallNormal,ni),(uint(u.color.w)&1u)!=0,sourceAOV,(uint(u.color.w)&2u)!=0);
                return sourceAOV ? exitLight : throughput*exitLight;
            }
            d=reflect(d,wallNormal);p-=wallNormal*.000025;
        }
    }
    error=true;return float3(0);
}
float3 liquidSurfaceAOV(texture3d<float> field,float2 world,int mode) {
    float3 start=float3(world,.18),direction=float3(0,0,-1);
    float previous=fastDensity(field,start),first=-1,insideStart=0,occupied=0;
    bool inside=previous>0;
    if(inside) first=0;
    float previousT=0;
    for(uint slice=1;slice<=192;slice++) {
        float t=.36*float(slice)/192;
        float value=fastDensity(field,start+direction*t);bool nextInside=value>0;
        if(nextInside!=inside) {
            float lo=previousT,hi=t;
            for(uint refine=0;refine<10;refine++) {
                float mid=(lo+hi)*.5;
                if((fastDensity(field,start+direction*mid)>0)==inside) lo=mid;else hi=mid;
            }
            float crossing=(lo+hi)*.5;
            if(nextInside) {if(first<0) first=crossing;insideStart=crossing;}
            else occupied+=crossing-insideStart;
        }
        inside=nextInside;previousT=t;previous=value;
    }
    if(inside) occupied+=.36-insideStart;
    if(first<0) return float3(0);
    if(mode==1) return fastNormal(field,start+direction*first)*.5+.5;
    if(mode==2) return float3(1-first/.36);
    return float3(occupied/.36);
}
fragment float4 stochasticToyFragment(QuadOut in [[stage_in]],
                                      texture3d<float> field [[texture(0)]],
                                      texture3d<float> bounds [[texture(1)]],
                                      constant OceanUniforms &u [[buffer(0)]]) {
    if(u.optics.w<0 && u.optics.w> -3.5) {
        float2 screen=(in.uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
        return float4(liquidSurfaceAOV(field,rotate2(screen,u.viewport.w),int(-u.optics.w)),1);
    }
    uint2 pixel=uint2(in.position.xy);
    uint rng=pixel.x*1973u+pixel.y*9277u+uint(u.viewport.z)*26699u+911u;
    uint count=uint(u.optics.x);
    float3 sum=float3(0);bool error=false;
    // fwidth is evaluated outside divergent ray loops. It maps subpixel samples
    // to the existing full-screen orthographic phone view.
    float2 pixelUV=float2(dfdx(in.uv.x),dfdy(in.uv.y));
    for(uint sample=0;sample<count;sample++) {
        float2 jitter=float2(pathRandom(rng)-.5,pathRandom(rng)-.5)*pixelUV;
        float2 screen=((in.uv+jitter)*float2(2,-2)+float2(-1,1))*u.viewport.xy;
        sum+=sampledLiquidPath(field,bounds,rotate2(screen,u.viewport.w),u,rng,error);
    }
    bool progressive=u.optics.y<0;
    if(error||!all(isfinite(sum)))
        return progressive ? float4(0,0,0,1) : float4(1,0,1,1);
    float3 radiance=sum/float(count);
    // Progressive inspection: add linear radiance before display conversion.
    // Alpha is an error count, never coverage. One failed sample stays visible
    // after accumulation rather than being diluted by the other samples.
    if(progressive) return float4(radiance*(-u.optics.y),0);
    return float4(fastDisplay(radiance),1);
}

fragment float4 stochasticResolveFragment(QuadOut in [[stage_in]],
                                          texture2d<float> accumulation [[texture(0)]]) {
    float4 total=accumulation.read(uint2(in.position.xy));
    if(total.a>0||!all(isfinite(total))) return float4(1,0,1,1);
    return float4(fastDisplay(total.rgb),1);
}
