// Native live transport: colored liquid, clear liquid, and analytic air pockets.
// Authored optical indices are not measured product composition.
// Live bounded specular transport. The standalone translation unit shares the
// existing vertex/miniature ABI. Preview harnesses concatenate the app source.
// Optical indices and absorption are authored toy parameters, not measured composition.
#ifndef LIVE_CONCATENATED_SHADER
#include <metal_stdlib>
using namespace metal;
struct OceanUniforms { float4 viewport; float4 boat; float4 movement; float4 color; float4 optics; float4 miniatureArt; };
struct QuadOut { float4 position [[position]]; float2 local; float2 uv; float weight; };
float2 rotate2(float2 p,float angle);
float3 displayToLight(float3 color);
float3 lightToDisplay(float3 light);
float4 miniature(float2 world,constant OceanUniforms &u);
float4 craftedMiniature(float2 world,constant OceanUniforms &u,texture2d<float> art);
float miniatureContact(float2 world,constant OceanUniforms &u);
#endif
float liveDensity(texture3d<float> field,float3 p) {
    // Hardware trilinear reconstruction of the live samples. The geometric
    // normal below remains the analytic derivative of the float interpolant.
    constexpr sampler linearField(coord::normalized,address::clamp_to_edge,filter::linear);
    float3 uv=float3(p.x*.5+.5,.5-p.y/4.24,.5-p.z/.36);
    return field.sample(linearField,uv).r-.6;
}
float3 liveNormal(texture3d<float> field,float3 p) {
#ifdef FAST_CUBIC_FIELD
    float3 gradient=continuousField(field,p,true).yzw;
    return -gradient/max(length(gradient),1e-9);
#else
    // Differentiate the SAME trilinear interpolant used for crossings. A normal
    // averaged across adjacent cells can send a transmitted ray back into the
    // wrong medium and cause repeated zero-length crossings at a curved rim.
    int3 size=int3(field.get_width(),field.get_height(),field.get_depth());
    float3 grid=float3(p.x*.5+.5,.5-p.y/4.24,.5-p.z/.36)*float3(size)-.5;
    int3 base=int3(floor(grid));float3 f=fract(grid);
    float c[8];
    for(uint z=0;z<2;z++) for(uint y=0;y<2;y++) for(uint x=0;x<2;x++)
        c[x+2*y+4*z]=field.read(uint3(clamp(base+int3(x,y,z),int3(0),size-1))).r;
    float dx=mix(mix(c[1]-c[0],c[3]-c[2],f.y),mix(c[5]-c[4],c[7]-c[6],f.y),f.z);
    float dy=mix(mix(c[2]-c[0],c[3]-c[1],f.x),mix(c[6]-c[4],c[7]-c[5],f.x),f.z);
    float dz=mix(mix(c[4]-c[0],c[5]-c[1],f.x),mix(c[6]-c[2],c[7]-c[3],f.x),f.y);
    float3 g=float3(dx*float(size.x)*.5,-dy*float(size.y)/4.24,-dz*float(size.z)/.36);
    return -g/max(length(g),1e-9);
#endif
}
float3 liveShadingNormal(texture3d<float> field,float3 p) {
    // Smooth optical shading over adjacent voxels, without changing the
    // isosurface used by tracing. Geometric normals still govern offsets and
    // the side checks below reject a shading direction in the wrong medium.
    float h=.010;
    float3 gradient=float3(
        liveDensity(field,p+float3(h,0,0))-liveDensity(field,p-float3(h,0,0)),
        liveDensity(field,p+float3(0,h,0))-liveDensity(field,p-float3(0,h,0)),
        liveDensity(field,p+float3(0,0,h))-liveDensity(field,p-float3(0,0,h)));
    return -gradient/max(length(gradient),1e-9);
}
float liveFresnel(float cosi,float etaI,float etaT) {
    cosi=clamp(cosi,0.0,1.0);
    float sint2=pow(etaI/etaT,2.0)*(1-cosi*cosi);
    if(sint2>=1) return 1;
    float cost=sqrt(max(0.0,1-sint2));
    float rs=(etaI*cosi-etaT*cost)/(etaI*cosi+etaT*cost);
    float rp=(etaT*cosi-etaI*cost)/(etaT*cosi+etaI*cost);
    return .5*(rs*rs+rp*rp);
}
float liveBoxExit(float3 p,float3 d,thread float3 &normal) {
    float3 h=float3(1,2.12,.18),t=float3(1e9);
    for(uint k=0;k<3;k++) if(abs(d[k])>1e-8) t[k]=((d[k]>0?h[k]:-h[k])-p[k])/d[k];
    uint axis=t.x<t.y ? (t.x<t.z?0:2) : (t.y<t.z?1:2);
    normal=float3(0);normal[axis]=d[axis]>0?1:-1;
    return max(t[axis],0.0);
}
float3 liveAbsorption(float3 transmission) { return -log(transmission)/.32; }
float3 liveDisplay(float3 light) {
    // Bounded filmic display, not Cycles/AgX equivalence.
    light=max(light,float3(0));
    float3 mapped=(light*(2.51*light+.03))/(light*(2.43*light+.59)+.14);
    return lightToDisplay(clamp(mapped,0.0,1.0));
}
float liveNextStep(texture3d<float> bounds,float3 p,float3 d,float traveled,
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
float3 liveRearIllumination(float2 xy) {
    float pool=exp(-pow((xy.y-.5)*.34,2.0)-pow((xy.x+.4)*.28,2.0));
    return mix(float3(.48,.56,.61),float3(.90,.92,.89),pool);
}
float3 liveStudio(float3 p,float3 d,bool softLights,bool sourceAOV,bool softFloor) {
    // Studio axes are the app axes: X right / Y up / Z toward the camera.
    // Window centers are outside the direct front view of the phone vessel.
    float3 color=sourceAOV ? float3(1,0,0) : float3(.62,.65,.68);
    float nearest=1e9;
    // Finite rear studio wall: the same spatial backdrop is sampled by clear
    // and refracted paths, making displacement and depth visible in motion.
    if(d.z<-.000001) {
        float t=(-.95-p.z)/d.z;
        if(t>0) {
            float3 q=p+d*t;nearest=t;
            color=liveRearIllumination(q.xy);
        }
    }
    if(d.y<-.000001) {
        float t=(-2.20-p.y)/d.y;
        if(t>0&&t<nearest) {
            float3 q=p+d*t;nearest=t;
            float pool=exp(-pow(q.x*.22,2.0)-pow(q.z*.16,2.0));
            float3 floorLight=float3(.35,.40,.44)+float3(.20,.22,.23)*pool;
            // A locally illuminated floor approaches the same ambient level
            // as the surrounding studio in the distance. The previous floor
            // stayed bright out to infinity, creating a sharp reflected horizon.
            if(softFloor) floorLight=mix(float3(.62,.65,.68),floorLight,exp(-dot(q.xz,q.xz)/18.0));
            // Both studio planes meet at the same radiance. The old near
            // corner created a horizontal color step through a flat liquid
            // slab; the distant floor/ambient behavior is preserved.
            float distanceFromCorner=abs(q.z+.95);
            floorLight=mix(liveRearIllumination(float2(q.x,-2.20)),floorLight,
                           smoothstep(0.0,.65,distanceFromCorner));
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

struct LiveToyOutput {
    float4 color [[color(0)]];
    // total march samples / 256, residual tail weight, boundaries / 8, numerical error
    float4 diagnostics [[color(1)]];
};
fragment float4 liveResolveFragment(QuadOut in [[stage_in]],texture2d<float> source [[texture(0)]]) {
    constexpr sampler reconstruction(coord::normalized,address::clamp_to_edge,filter::linear);
    return source.sample(reconstruction,in.uv);
}


#ifndef LIVE_AIR_INDEX
#define LIVE_AIR_INDEX 1.0
#endif

constant uint liveAirClear = 0;
constant uint liveAirBlue = 1;
constant uint liveAirAir = 2;

bool liveAirContains(float3 p, const device float4 *bubbles, uint count) {
    for (uint i = 0; i < count; ++i) {
        float3 delta = p - bubbles[i].xyz;
        if (dot(delta, delta) < bubbles[i].w * bubbles[i].w) return true;
    }
    return false;
}

// Finds the first union boundary.  At an entry, the earliest positive sphere
// root is valid.  At an exit, overlapping spheres are handled by accepting a
// root only if a small step beyond it is outside every sphere.
float liveAirBoundary(float3 p, float3 d, bool inside,
                           const device float4 *bubbles, uint count,
                           thread float3 &normal) {
    float best = 1e9; normal = float3(0, 0, 1);
    for (uint i = 0; i < count; ++i) {
        float3 oc = p - bubbles[i].xyz;
        float b = dot(oc, d), c = dot(oc, oc) - bubbles[i].w * bubbles[i].w;
        float disc = b*b-c;
        if (disc < 0) continue;
        float root = sqrt(disc);
        float roots[2] = { -b-root, -b+root };
        for (uint r = 0; r < 2; ++r) {
            float t = roots[r];
            if (t <= .00004 || t >= best) continue;
            bool beyond = liveAirContains(p+d*(t+.00008), bubbles, count);
            if ((inside && beyond) || (!inside && !beyond)) continue;
            best = t; normal = normalize(p+d*t-bubbles[i].xyz);
        }
    }
    return best;
}

// This is the baseline bounded field crossing search, factored so that it is
// never called while the ray is in air. Hidden blue/clear crossings inside an
// analytic bubble cannot therefore create false medium transitions.
float liveAirFieldBoundary(texture3d<float> field, texture3d<float> bounds,
                                float3 p, float3 d, float wallDistance, bool blue,
                                thread uint &samples, thread bool &exhausted) {
    float traveled = 0;
    for (uint step = 0; step < 256; ++step) {
        if (traveled >= wallDistance) break;
        if (samples >= 256) { exhausted = true; break; }
        samples++;
        float next = liveNextStep(bounds, p, d, traveled, wallDistance, blue, true, 0);
        if ((liveDensity(field, p+d*next) > 0) != blue) {
            float lo = traveled, hi = next;
            for (uint refine = 0; refine < 7; ++refine) {
                float mid = (lo+hi)*.5;
                if ((liveDensity(field, p+d*mid) > 0) == blue) lo = mid; else hi = mid;
            }
            return (lo+hi)*.5;
        }
        traveled = next;
    }
    if (traveled < wallDistance) exhausted = true;
    return wallDistance;
}

fragment LiveToyOutput liveToyFragment(QuadOut in [[stage_in]],
                                       texture3d<float> field [[texture(0)]],
                                       texture3d<float> bounds [[texture(1)]],
                                       texture2d<float> miniatureTexture [[texture(3)]],
                                       constant OceanUniforms &u [[buffer(0)]],
                                       const device float4 *airBubbles [[buffer(1)]],
                                       constant uint &airBubbleCount [[buffer(2)]]) {
    float2 screen=(in.uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    float2 world=rotate2(screen,u.viewport.w);
    float2 viewDirection=world*.12-float2(0,u.optics.z);
    float3 p=float3(world,.17998), incoming=normalize(float3(viewDirection,-1));
    float clearIndex=u.optics.x>0 ? u.optics.x : 1.46;
    float blueIndex=u.optics.y>0 ? u.optics.y : 1.333;
    float3 coeff=liveAbsorption(u.color.rgb);
    uint medium=liveAirContains(p,airBubbles,airBubbleCount) ? liveAirAir :
                (liveDensity(field,p)>0 ? liveAirBlue : liveAirClear);
    float initialIndex=medium==liveAirBlue ? blueIndex : (medium==liveAirAir ? LIVE_AIR_INDEX : clearIndex);
    float3 d=refract(incoming,float3(0,0,1),1.0/initialIndex);
    float frontF=liveFresnel(-incoming.z,1,initialIndex);
    float3 radiance=frontF*liveStudio(p,reflect(incoming,float3(0,0,1)),true,false,true);
    float3 weight=float3(1-frontF);
    uint samples=0,boundaries=0,blueTIR=0;
    float blueLength=0;
    bool exhausted=false,invalid=false;
    for(uint bounce=0;bounce<8;++bounce) {
        if(max(max(weight.x,weight.y),weight.z)<.002) break;
        float3 wallNormal;
        float wallDistance=liveBoxExit(p,d,wallNormal), hitDistance=wallDistance;
        float3 normal=float3(0), offsetNormal=float3(0);
        uint hitKind=0; // 0 box, 1 field, 2 bubble union
        if(medium==liveAirAir) {
            float bubbleDistance=liveAirBoundary(p,d,true,airBubbles,airBubbleCount,normal);
            if(bubbleDistance<wallDistance) { hitDistance=bubbleDistance; hitKind=2; }
        } else {
            bool blue=medium==liveAirBlue;
            // A nearer bubble is a real medium boundary, so never consume field
            // march samples behind it before testing its analytic entry.
            float3 bubbleNormal;
            float bubbleDistance=liveAirBoundary(p,d,false,airBubbles,airBubbleCount,bubbleNormal);
            float limit=min(wallDistance,bubbleDistance);
            float fieldDistance=liveAirFieldBoundary(field,bounds,p,d,limit,blue,samples,exhausted);
            if(exhausted) break;
            if(fieldDistance<limit) { hitDistance=fieldDistance; hitKind=1; }
            else if(bubbleDistance<wallDistance) { hitDistance=bubbleDistance; normal=bubbleNormal; offsetNormal=bubbleNormal; hitKind=2; }
        }
        float toyT=abs(d.z)>1e-8 ? (u.boat.w-p.z)/d.z : -1;
        if(toyT>1e-5&&toyT<hitDistance) {
            float2 toyPoint=(p+d*toyT).xy;
            float4 toy=craftedMiniature(toyPoint,u,miniatureTexture);
            if(u.miniatureArt.x>=0 && toy.a<.98 && medium==liveAirBlue) {
                float3 contactPoint=p+d*toyT;
                float nearSurface=1-smoothstep(.04,.15,abs(liveDensity(field,contactPoint)));
                float contact=miniatureContact(toyPoint,u)*nearSurface*(1-toy.a);
                toy.rgb+=float3(.19,.32,.31)*contact;
                toy.a+=contact;
            }
            float3 attenuation=medium==liveAirBlue ? exp(-coeff*toyT) : float3(1);
            radiance+=weight*attenuation*displayToLight(toy.rgb/max(toy.a,1e-5))*toy.a;
            weight*=1-toy.a;
        }
        if(medium==liveAirBlue) { blueLength+=hitDistance; weight*=exp(-coeff*hitDistance); }
        p+=d*hitDistance; boundaries++;
        if(hitKind==1 || hitKind==2) {
            float ni=medium==liveAirBlue ? blueIndex : (medium==liveAirAir ? LIVE_AIR_INDEX : clearIndex);
            uint nextMedium;
            if(hitKind==1) {
                float3 outward=liveNormal(field,p), shading=liveShadingNormal(field,p);
                if(length(outward)<.5) { invalid=true; break; }
                bool blue=medium==liveAirBlue;
                normal=blue ? -shading : shading;
                float3 geometric=blue ? -outward : outward;
                if(dot(normal,d)>0) normal=-normal;
                float ntTest=blue ? clearIndex : blueIndex;
                float3 transmittedTest=refract(d,normal,ni/ntTest);
                if(dot(reflect(d,normal),geometric)<0 || (length(transmittedTest)>.5&&dot(transmittedTest,geometric)>0)) normal=geometric;
                nextMedium=blue ? liveAirClear : liveAirBlue;
                offsetNormal=outward;
            } else if(medium==liveAirAir) {
                // The union exit selects its exterior by the uncarved field.
                nextMedium=liveDensity(field,p+normal*.00004)>0 ? liveAirBlue : liveAirClear;
                offsetNormal=normal;
            } else {
                nextMedium=liveAirAir;
            }
            float nt=nextMedium==liveAirBlue ? blueIndex : (nextMedium==liveAirAir ? LIVE_AIR_INDEX : clearIndex);
            if(dot(normal,d)>0) normal=-normal;
            float f=liveFresnel(-dot(normal,d),ni,nt);
            float3 reflected=liveStudio(p,reflect(d,normal),true,false,true);
            if(medium==liveAirBlue) reflected*=exp(-coeff*.18);
            if(f>.99999) { if(medium==liveAirBlue) blueTIR++; d=reflect(d,normal); }
            else { radiance+=weight*f*reflected; weight*=1-f; d=refract(d,normal,ni/nt); medium=nextMedium; }
            // Field offsets retain the baseline geometric-side rule. Sphere
            // offsets use the union's unflipped outward normal, so reflection
            // remains on its current side and transmission reaches its target.
            p+=(hitKind==1 ? (medium==liveAirBlue ? -offsetNormal : offsetNormal)
                           : (medium==liveAirAir ? -offsetNormal : offsetNormal))*.00004;
        } else {
            float ni=medium==liveAirBlue ? blueIndex : (medium==liveAirAir ? LIVE_AIR_INDEX : clearIndex);
            float f=liveFresnel(dot(d,wallNormal),ni,1);
            if(medium==liveAirBlue&&f>.99999) blueTIR++;
            if(f<.99999) radiance+=weight*(1-f)*liveStudio(p,refract(d,-wallNormal,ni),true,false,true);
            weight*=f; d=reflect(d,wallNormal); p-=wallNormal*.00004;
        }
        if(!all(isfinite(p))||!all(isfinite(d))) { invalid=true; break; }
    }
    float tail=max(max(weight.x,weight.y),weight.z); float3 tailNormal;
    float tailDistance=liveBoxExit(p,d,tailNormal);
    radiance+=weight*(medium==liveAirBlue ? exp(-coeff*tailDistance) : float3(1))*liveStudio(p+d*tailDistance,d,true,false,true);
    invalid=invalid||!all(isfinite(radiance));
    LiveToyOutput out;
    out.color=float4(invalid?float3(1,0,1):liveDisplay(radiance),1);
    out.diagnostics=float4(float(samples)/256,tail,float(boundaries)/8,invalid?1:0);
#ifdef LIVE_PATH_DIAGNOSTICS
    out.diagnostics=float4(blueLength,medium==liveAirBlue?tailDistance:0,float(blueTIR),invalid?1:0);
#endif
    return out;
}

// Bounded post-ray edge resolve.  `source` is already display/gamma encoded;
// this deliberately operates on display luma and never changes ray geometry
// or any transport/material value.
fragment float4 liveEdgeResolveFragment(QuadOut in [[stage_in]],
                                        texture2d<float> source [[texture(0)]]) {
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 pixel = 1.0 / float2(source.get_width(), source.get_height());
    float4 center = source.sample(linearClamp, in.uv);
    float4 nw = source.sample(linearClamp, in.uv + pixel * float2(-1,-1));
    float4 ne = source.sample(linearClamp, in.uv + pixel * float2( 1,-1));
    float4 sw = source.sample(linearClamp, in.uv + pixel * float2(-1, 1));
    float4 se = source.sample(linearClamp, in.uv + pixel * float2( 1, 1));
    float3 lumaWeight = float3(.299,.587,.114);
    float lumaCenter = dot(center.rgb,lumaWeight);
    float lumaNW = dot(nw.rgb,lumaWeight), lumaNE = dot(ne.rgb,lumaWeight);
    float lumaSW = dot(sw.rgb,lumaWeight), lumaSE = dot(se.rgb,lumaWeight);
    float localMin = min(lumaCenter,min(min(lumaNW,lumaNE),min(lumaSW,lumaSE)));
    float localMax = max(lumaCenter,max(max(lumaNW,lumaNE),max(lumaSW,lumaSE)));
    if (localMax-localMin < max(.035,.10*localMax)) return center;

    // This is perpendicular to the luma gradient, hence it samples only along
    // the detected edge.  The reduce floor prevents a nearly-flat denominator.
    float2 tangent = float2(-((lumaNW+lumaNE)-(lumaSW+lumaSE)),
                              (lumaNW+lumaSW)-(lumaNE+lumaSE));
    float reduce = max((lumaNW+lumaNE+lumaSW+lumaSE)*.125,1.0/128.0);
    float reciprocal = 1.0/(min(abs(tangent.x),abs(tangent.y))+reduce);
    tangent = clamp(tangent*reciprocal,float2(-4),float2(4))*pixel;
    float4 twoSample = .5*(source.sample(linearClamp,in.uv+tangent*(1.0/3.0-.5))+
                            source.sample(linearClamp,in.uv+tangent*(2.0/3.0-.5)));
    float4 fourSample = twoSample*.5 + .25*(source.sample(linearClamp,in.uv-tangent*.5)+
                                             source.sample(linearClamp,in.uv+tangent*.5));
    float lumaFour = dot(fourSample.rgb,lumaWeight);
    return (lumaFour < localMin || lumaFour > localMax) ? twoSample : fourSample;
}
