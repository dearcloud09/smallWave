#include <metal_stdlib>
using namespace metal;

// This file is appended to the frozen ray shader only for the local probe.
// It deliberately uses that shader's OceanUniforms, VRBranch, vrDensity,
// vrNormal, vrFresnel, miniature and displayToLight definitions.
struct OpticalFailureRecord {
    float4 summary;       // reason bits, travelled / 1.28, crossings / 320, TIR / 320
    float4 terminal;      // terminal xyz, finished (1) / unfinished (0)
    float4 normal;        // failing/crossing normal xyz, length
    float4 phase;         // initial phase, terminal phase, branch count, crossing index
    float4 original;      // unmodified frozen vrSample return
};

struct OpticalFailureResult {
    float4 summary;
    float4 terminal;
    float4 normal;
    float4 phase;
};

OpticalFailureResult opticalFailureSample(float2 uv, texture2d_array<float> volume,
                                          constant OceanUniforms &u, constant float4 &study,
                                          device float4 *trace=nullptr) {
    const float clearIOR=1.46;
    float blueIOR=u.optics.x>1.5?clearIOR:1.333;
    bool straight=u.optics.x>2.5;
    float3 direction=study.z>0.5?normalize(float3(0.10,-0.38,-1)):float3(0,0,-1);
    float2 world=(uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    float3 p=float3(world+direction.xy/direction.z*0.19,0.19);
    float3 reference=clamp(u.color.rgb,float3(0.02),float3(0.98));
    if(study.x>0.5) reference=displayToLight(reference);
    float3 dye=-log(reference)*0.72/0.24;
    float3 weight=float3(1);
    float travelled=0;
    uint crossings=0,tir=0;
    bool finished=false,mediumMismatch=false,unresolved=false,normalFailure=false;
    float3 observedNormal=float3(0);
    float density=vrDensity(volume,p,u);
    bool inside=density>=u.optics.z;
    float initialPhase=inside?1:0;
    bool secondary=(uint(study.w)&16)!=0;
    VRBranch pending[8]; uint pendingCount=0,depth=0;
    bool halfStep=(uint(study.w)&1)!=0;
    float marchStep=halfStep?0.002:0.004;
    uint limit=halfStep?4096:2048;
    uint branchCount=0;
    for(uint branch=0;branch<16;branch++) {
      branchCount++;
      finished=false;
      for(uint i=0;i<limit;i++) {
        float distance=marchStep;
        float3 next=p+direction*distance;
        float3 beforePoint=p,afterPoint=next;
        float nextDensity=vrDensity(volume,next,u);
        bool crossing=(nextDensity>=u.optics.z)!=inside;
        if(crossing) {
            float low=0,high=distance;
            for(uint b=0;b<16;b++) {
                float mid=(low+high)*0.5;
                float3 point=p+direction*mid;
                if((vrDensity(volume,point,u)>=u.optics.z)==inside) { low=mid; beforePoint=point; }
                else { high=mid; afterPoint=point; }
            }
            distance=(low+high)*0.5; next=p+direction*distance;
        }
        bool crossesToy=(p.z<u.boat.w && next.z>=u.boat.w)||(p.z>u.boat.w && next.z<=u.boat.w);
        if(crossesToy && abs(direction.z)>0.0001) {
            float portion=clamp((u.boat.w-p.z)/(next.z-p.z),0.0,1.0);
            float2 q=mix(p.xy,next.xy,portion);
            float4 toy=miniature(q,u);
            weight*=1-toy.a;
        }
        if(inside) weight*=exp(-dye*distance);
        travelled+=distance; p=next;
        if(crossing) {
            float3 normal=vrNormal(volume,p,u,false);
            observedNormal=normal;
            if(!all(isfinite(normal)) || length_squared(normal)<0.5) { normalFailure=true; break; }
            if(dot(normal,direction)>0) normal=-normal;
            float n1=inside?blueIOR:clearIOR,n2=inside?clearIOR:blueIOR;
            float f=straight?0:vrFresnel(clamp(-dot(normal,direction),0.0,1.0),n1,n2);
            float3 transmitted=straight?direction:refract(direction,normal,n1/n2);
            crossings++;
            bool expected=inside;
            bool reflectedOnly=false;
            if(length_squared(transmitted)<0.000001) {
                direction=reflect(direction,normal); tir++; reflectedOnly=true;
            } else {
                float3 reflected=reflect(direction,normal),reflectedWeight=weight*f;
                if(secondary && depth<3 && pendingCount<8 && max(reflectedWeight.r,max(reflectedWeight.g,reflectedWeight.b))>0.002) {
                    pending[pendingCount++]={beforePoint,reflected,reflectedWeight,inside,depth+1};
                }
                depth++; weight*=1-f; direction=normalize(transmitted); expected=!inside;
            }
            float3 moved=reflectedOnly?beforePoint:afterPoint;
            if(trace && crossings<=2048) {
                uint k=(crossings-1)*5;
                trace[k]=float4(p,travelled);
                trace[k+1]=float4(direction,distance);
                trace[k+2]=float4(weight,inside?1:0);
                trace[k+3]=float4(normal,reflectedOnly?1:0);
                trace[k+4]=float4(moved,float(crossings));
            }
            bool actual=vrDensity(volume,moved,u)>=u.optics.z;
            if(actual!=expected) mediumMismatch=true;
            p=moved; inside=actual; density=vrDensity(volume,p,u);
        } else { density=nextDensity; inside=density>=u.optics.z; }
        if(p.z< -0.19||p.z>0.20||abs(p.x)>u.viewport.x+0.01||abs(p.y)>u.viewport.y+0.01||max(weight.r,max(weight.g,weight.b))<0.00001) { finished=true; break; }
      }
      unresolved=unresolved||!finished;
      if(pendingCount==0) break;
      VRBranch nextBranch=pending[--pendingCount];
      p=nextBranch.position; direction=nextBranch.direction; weight=nextBranch.weight;
      inside=nextBranch.inside; depth=nextBranch.depth;
    }
    finished=!unresolved && pendingCount==0;
    uint reason=(normalFailure?1u:0u)|(mediumMismatch?2u:0u)|(!finished?4u:0u);
    OpticalFailureResult result;
    result.summary=float4(float(reason),travelled/1.28,float(crossings)/320.0,float(tir)/320.0);
    result.terminal=float4(p,finished?1:0);
    result.normal=float4(observedNormal,length(observedNormal));
    result.phase=float4(initialPhase,inside?1:0,float(branchCount),float(crossings));
    return result;
}

kernel void opticalFailureTrace(const device float2 *uvs [[buffer(0)]],
                                device float4 *trace [[buffer(1)]],
                                texture2d_array<float,access::sample> volume [[texture(0)]],
                                constant OceanUniforms &u [[buffer(2)]],
                                constant float4 &study [[buffer(3)]],
                                uint gid [[thread_position_in_grid]]) {
    if(gid>0) return;
    opticalFailureSample(uvs[14],volume,u,study,trace);
}

kernel void opticalFailureProbe(const device float2 *uvs [[buffer(0)]],
                                device OpticalFailureRecord *records [[buffer(1)]],
                                texture2d_array<float,access::sample> volume [[texture(0)]],
                                constant OceanUniforms &u [[buffer(2)]],
                                constant float4 &study [[buffer(3)]],
                                uint gid [[thread_position_in_grid]]) {
    float2 uv=uvs[gid];
    OpticalFailureResult result=opticalFailureSample(uv,volume,u,study);
    records[gid].summary=result.summary;
    records[gid].terminal=result.terminal;
    records[gid].normal=result.normal;
    records[gid].phase=result.phase;
    records[gid].original=vrSample(uv,volume,u,study);
}

fragment float4 opticalFailurePixelProbe(QuadOut in [[stage_in]],
                                         texture2d_array<float> volume [[texture(0)]],
                                         constant OceanUniforms &u [[buffer(0)]],
                                         constant float4 &study [[buffer(1)]]) {
    float2 pixel=float2(dfdx(in.uv.x),dfdy(in.uv.y));
    uint mask=0, reasons=0;
    for(int y=0;y<2;y++) for(int x=0;x<2;x++) {
        float2 offset=float2(x?0.25:-0.25,y?0.25:-0.25)*pixel;
        uint index=uint(x+2*y);
        float4 original=vrSample(in.uv+offset,volume,u,study);
        if(original.a<0) {
            mask|=1u<<index;
            reasons|=uint(opticalFailureSample(in.uv+offset,volume,u,study).summary.x)<<(3u*index);
        }
    }
    return float4(float(mask),float(reasons),0,1);
}
