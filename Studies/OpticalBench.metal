#include <metal_stdlib>
using namespace metal;

// Mac-only optical experiment. Analytic geometry, NOT a two-fluid simulation.
// IOR and dye values are study parameters, not measurements of the reference toy.
struct BenchSettings {
    uint width, height, samples, state;
    float clearIOR, blueIOR, viewPitch, halfDepth;
    uint maximumEvents, maximumSearchSteps, diagnosticFlags, reserved;
};
struct DielectricEvent { float3 transmitted; float reflectance; };
DielectricEvent dielectricEvent(float3 incoming, float3 faceNormal, float n1, float n2) {
    float cosine=clamp(-dot(incoming,faceNormal),0.0,1.0);
    float ratio=n1/n2;
    float sine2=ratio*ratio*max(0.0,1.0-cosine*cosine);
    DielectricEvent result;
    if(sine2>=1.0) { result.transmitted=float3(0); result.reflectance=1; return result; }
    float cosineT=sqrt(max(0.0,1.0-sine2));
    result.transmitted=normalize(ratio*incoming+(ratio*cosine-cosineT)*faceNormal);
    float rs=(n1*cosine-n2*cosineT)/max(n1*cosine+n2*cosineT,1e-7);
    float rp=(n2*cosine-n1*cosineT)/max(n2*cosine+n1*cosineT,1e-7);
    result.reflectance=clamp(0.5*(rs*rs+rp*rp),0.0,1.0);
    return result;
}
float3 segmentTransmission(float3 coefficient,float distance) {
    return exp(-coefficient*max(0.0,distance));
}
uint nextRandom(thread uint &seed) {
    seed=seed*747796405u+2891336453u;
    uint word=((seed>>((seed>>28u)+4u))^seed)*277803737u;
    return (word>>22u)^word;
}
float randomUnit(thread uint &seed) { return float(nextRandom(seed)>>8u)/16777216.0; }

float layerHeight(float x,float z,uint state) {
    if(state==0) return -0.6+0.015*cos(x*3.0+z*2.0);
    return -0.6-0.43*tanh(x*2.6)+0.055*sin(x*5.0+z*3.0);
}
float smoothMaximum(float a,float b,float width) {
    float h=clamp(0.5+0.5*(a-b)/width,0.0,1.0);
    return mix(b,a,h)+width*h*(1.0-h);
}
float blueField(float3 p,uint state) {
    float field=p.y-layerHeight(p.x,p.z,state);
    if(state<2) return field;
    // Clear inclusions at several depths. Open and closed shapes are prescribed;
    // they do not prove phase separation, coalescence, buoyancy or surface tension.
    constexpr float4 inclusions[12]={
        float4(-0.78,-0.38,0.10,0.11),float4(-0.55,-0.36,-0.12,0.085),
        float4(-0.32,-0.53,0.04,0.15),float4(-0.12,-0.61,-0.12,0.105),
        float4(0.10,-0.78,0.10,0.135),float4(0.35,-0.93,-0.10,0.095),
        float4(0.58,-1.01,0.04,0.15),float4(0.81,-1.07,-0.10,0.075),
        float4(-0.62,-0.76,0.13,0.09),float4(-0.36,-0.96,-0.09,0.07),
        float4(0.03,-1.14,0.02,0.12),float4(0.52,-1.34,-0.06,0.065)
    };
    for(uint i=0;i<12;i++) {
        float sphere=length(p-inclusions[i].xyz)-inclusions[i].w;
        field=smoothMaximum(field,-sphere,0.022);
    }
    // Blue drops in the upper clear medium, distinct from clear inclusions below.
    field=min(field,length(p-float3(-0.06,-0.20,0.02))-0.085);
    field=min(field,length(p-float3(0.52,-0.52,-0.06))-0.057);
    return field;
}
float3 fieldNormal(float3 p,uint state) {
    const float e=0.0006;
    return normalize(float3(blueField(p+float3(e,0,0),state)-blueField(p-float3(e,0,0),state),
                            blueField(p+float3(0,e,0),state)-blueField(p-float3(0,e,0),state),
                            blueField(p+float3(0,0,e),state)-blueField(p-float3(0,0,e),state)));
}
struct WallHit { float distance; float3 outward; };
WallHit exitWall(float3 p,float3 ray,float halfDepth) {
    float3 extent=float3(1,2.12,halfDepth);
    WallHit hit; hit.distance=1e6; hit.outward=float3(0);
    for(uint axis=0;axis<3;axis++) {
        if(abs(ray[axis])<1e-7) continue;
        float side=ray[axis]>0?1.0:-1.0;
        float distance=(side*extent[axis]-p[axis])/ray[axis];
        if(distance<hit.distance&&distance>=0) {
            hit.distance=distance; hit.outward=float3(0); hit.outward[axis]=side;
        }
    }
    return hit;
}
// A conservative step for the bounded analytic field; bracket and bisect roots.
// Return -1 on no crossing, -2 on exhausted search (recorded, not a silent exit).
float nextInterface(float3 p,float3 ray,float limit,uint state,uint maximumSteps) {
    float t=0;
    float prior=blueField(p,state);
    for(uint i=0;i<maximumSteps;i++) {
        float step=clamp(abs(prior)*0.35,0.0004,0.045);
        float next=min(t+step,limit);
        float value=blueField(p+ray*next,state);
        if((value<0)!=(prior<0)) {
            float lo=t,hi=next;
            for(uint b=0;b<12;b++) {
                float middle=(lo+hi)*0.5;
                if((blueField(p+ray*middle,state)<0)==(prior<0)) lo=middle;
                else hi=middle;
            }
            return (lo+hi)*0.5;
        }
        if(next>=limit) return -1;
        t=next; prior=value;
    }
    return -2;
}
float3 studio(float3 p,float3 direction) {
    // Neutral illumination and broad light cards only; no scenery asset.
    float3 light=mix(float3(0.62,0.67,0.70),float3(0.98,0.985,0.97),smoothstep(-0.8,0.5,direction.y));
    if(direction.z<-0.001) {
        float3 hit=p+direction*((-2.0-p.z)/direction.z);
        light=float3(0.90,0.925,0.93)*(0.90+0.10*exp(-dot(hit.xy,hit.xy)*0.11));
        // A soft charcoal flag outside the left view reveals bending/reflection.
        float flag=1.0-smoothstep(0.0,0.24,abs(hit.x+1.55)-0.16);
        light*=1.0-flag*0.55;
    }
    float3 l=normalize(float3(-0.6,0.85,1.0));
    float softbox=pow(max(0.0,dot(direction,l)),70.0);
    light+=float3(1.8,1.85,1.9)*softbox;
    float strip=pow(max(0.0,dot(direction,normalize(float3(0.8,0.2,0.55)))),180.0);
    return light+float3(1.4)*strip;
}
float3 benchLight(float3 p,float3 direction,uint flags) {
    return (flags&1u)?float3(1):studio(p,direction);
}
struct PathResult { float3 light; bool unresolved; };
PathResult traceBench(float2 screen,constant BenchSettings &u,thread uint &seed) {
    float3 ray=normalize(float3(screen.x*0.025,-u.viewPitch+screen.y*0.01,-1));
    float3 p=float3(screen,u.halfDepth);
    bool blue=blueField(p,u.state)<0;
    float ior=blue?u.blueIOR:u.clearIOR;
    DielectricEvent entry=dielectricEvent(ray,float3(0,0,1),1.0,ior);
    float3 result=benchLight(p,reflect(ray,float3(0,0,1)),u.diagnosticFlags)*entry.reflectance;
    float3 throughput=float3(1.0-entry.reflectance);
    ray=entry.transmitted;
    p+=ray*0.0008;
    const float3 blueAbsorption=float3(8.5,1.25,0.075);
    for(uint event=0;event<u.maximumEvents;event++) {
        blue=blueField(p,u.state)<0;
        ior=blue?u.blueIOR:u.clearIOR;
        WallHit wall=exitWall(p,ray,u.halfDepth);
        float crossing=nextInterface(p,ray,wall.distance,u.state,u.maximumSearchSteps);
        if(crossing<-1.5) { PathResult r={result,true}; return r; }
        bool exits=crossing<0;
        float distance=exits?wall.distance:crossing;
        float3 absorption=(u.diagnosticFlags&2u)?float3(0):(blue?blueAbsorption:float3(0.002));
        throughput*=segmentTransmission(absorption,distance);
        float3 hit=p+ray*distance;
        float3 normal=exits?-wall.outward:fieldNormal(hit,u.state);
        if(dot(ray,normal)>0) normal=-normal;
        float nextIOR=exits?1.0:(blue?u.clearIOR:u.blueIOR);
        DielectricEvent dielectric=dielectricEvent(ray,normal,ior,nextIOR);
        if(randomUnit(seed)<dielectric.reflectance) {
            ray=reflect(ray,normal);
            p=hit+normal*0.0008;
        } else {
            ray=dielectric.transmitted;
            if(exits) {
                result+=throughput*benchLight(hit,ray,u.diagnosticFlags);
                PathResult r={result,false}; return r;
            }
            p=hit-normal*0.0008;
        }
    }
    PathResult r={result,true}; return r;
}
kernel void opticalBench(texture2d<float,access::write> output [[texture(0)]],
                         constant BenchSettings &u [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=u.width||gid.y>=u.height) return;
    uint seed=gid.x+gid.y*u.width+19391u;
    float3 light=float3(0); float failures=0;
    for(uint sample=0;sample<u.samples;sample++) {
        float2 jitter=float2(randomUnit(seed),randomUnit(seed));
        float2 uv=(float2(gid)+jitter)/float2(u.width,u.height);
        float2 screen=(uv*2.0-1.0)*float2(1,-2.12);
        PathResult path=traceBench(screen,u,seed);
        light+=path.light; failures+=path.unresolved?1.0:0.0;
    }
    output.write(float4(light/float(u.samples),failures/float(u.samples)),gid);
}
// Analytic fixtures call the exact optical functions used above on the GPU.
kernel void opticalFixtures(device float4 *output [[buffer(0)]], uint index [[thread_position_in_grid]]) {
    float3 normal=float3(0,0,1);
    float3 incident=float3(0.5,0,-sqrt(0.75));
    DielectricEvent value;
    if(index==0) value=dielectricEvent(float3(0,0,-1),normal,1.0,1.5);
    else if(index==1) value=dielectricEvent(incident,normal,1.0,1.5);
    else if(index==2) value=dielectricEvent(float3(sqrt(0.75),0,-0.5),normal,1.5,1.0);
    else if(index==3) value=dielectricEvent(incident,normal,1.33,1.33);
    else if(index==4) {
        DielectricEvent first=dielectricEvent(incident,normal,1.0,1.5);
        value=dielectricEvent(first.transmitted,normal,1.5,1.0);
    } else if(index==5) {
        float3 direct=segmentTransmission(float3(2,1,0.2),0.6);
        float3 split=segmentTransmission(float3(2,1,0.2),0.2)*segmentTransmission(float3(2,1,0.2),0.4);
        output[index]=float4(direct-split,1); return;
    } else if(index==6) {
        // Isolated prescribed clear sphere: center z=.13, radius=.09.
        // At x=-.62,y=-.76 its z intersections are .22 and .04.
        float3 origin=float3(-0.62,-0.76,0.32),direction=float3(0,0,-1);
        float entry=nextInterface(origin,direction,0.64,2,4096);
        float3 inside=origin+direction*(entry+0.001);
        float exit=entry+0.001+nextInterface(inside,direction,0.64,2,4096);
        bool phases=blueField(origin,2)<0&&blueField(inside,2)>0
                    &&blueField(origin+direction*(exit+0.001),2)<0;
        output[index]=float4(entry,exit,phases?1:0,fieldNormal(origin+direction*entry,2).z);
        return;
    } else {
        output[index]=float4(segmentTransmission(float3(0.2,0.5,1),2),1); return;
    }
    output[index]=float4(value.transmitted,value.reflectance);
}
