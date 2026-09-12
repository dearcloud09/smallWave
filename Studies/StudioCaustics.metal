// Appended after the cached studio shader. It requires OceanUniforms,
// vrDensity, vrNormal and vrFresnel from that source; it changes none of them.
//
// Model: a finite key-card centre (-.85,.85,2.40) emits one art-directed
// equal-power ray for every stratified backplane target. This is a point-light
// ray bundle, not an area-light integral or physically measured irradiance.
// With no refraction/dye, four 1024x1600 photons land in each 512x800 cell and
// resolve to 1.0. The optional inverse-square/cosine term is deliberately absent.

enum StudioCausticsFlags : uint {
    StudioCausticsEqualIOR = 1u << 0, // clear/blue both 1.46: no Fresnel/bending
    StudioCausticsNoDye    = 1u << 1  // keep refraction but disable Beer loss
};

// Host ABI, 64 bytes / 16-byte alignment. resolution=(mapW,mapH,photonW,photonH)
// must be (512,800,1024,1600) for the normalization stated above. tile is
// (offsetX,offsetY,countX,countY): dispatch countX×countY, so a host can cap
// submission size while retaining one global photon lattice.
struct StudioCausticsDispatch {
    uint4 resolution;
    uint4 tile;
    uint4 controls; // x=StudioCausticsFlags
    float4 scale;   // x=atomicScale, required 4096.0
};

// Host ABI, 96 bytes / 16-byte alignment, one record per photon. RGB is energy;
// w is a terminal-category marker (1 for deposited/outside/reflected/unresolved);
// absorbed.w remains 0 because absorption can coexist with another terminal category.
// Per RGB channel: incident = deposited + outside + absorbed + reflected + unresolved.
struct StudioCausticsPhotonRecord {
    float4 incident;
    float4 deposited;
    float4 outside;
    float4 absorbed;
    float4 reflected;
    float4 unresolved;
};

struct StudioCausticsBoxHit { float enter; float exit; bool hit; };

StudioCausticsBoxHit studioCausticsBox(float3 origin, float3 direction,
                                       constant OceanUniforms &u) {
    float3 extent=float3(u.viewport.xy,u.optics.y);
    float nearT=-INFINITY, farT=INFINITY;
    for(uint axis=0;axis<3;axis++) {
        if(abs(direction[axis])<0.0000001) {
            if(abs(origin[axis])>extent[axis]) return {0,0,false};
            continue;
        }
        float a=(-extent[axis]-origin[axis])/direction[axis];
        float b=( extent[axis]-origin[axis])/direction[axis];
        nearT=max(nearT,min(a,b)); farT=min(farT,max(a,b));
    }
    return {nearT,farT,farT>=max(nearT,0.0)};
}

void studioCausticsDeposit(device atomic_uint *accum, uint2 cell,
                           float3 energy, constant StudioCausticsDispatch &d) {
    uint base=(cell.y*d.resolution.x+cell.x)*3u;
    float scale=d.scale.x;
    atomic_fetch_add_explicit(&accum[base],uint(max(energy.r,0.0)*scale+0.5),memory_order_relaxed);
    atomic_fetch_add_explicit(&accum[base+1],uint(max(energy.g,0.0)*scale+0.5),memory_order_relaxed);
    atomic_fetch_add_explicit(&accum[base+2],uint(max(energy.b,0.0)*scale+0.5),memory_order_relaxed);
}

bool studioCausticsBackplane(float3 p, float3 direction, thread float3 &hit) {
    const float z=-1.20;
    if(direction.z>=-0.0000001) return false;
    float t=(z-p.z)/direction.z;
    if(t<0) return false;
    hit=p+direction*t;
    return abs(hit.x)<=2.0 && abs(hit.y)<=3.12;
}

kernel void causticEmit(texture2d_array<float,access::sample> volume [[texture(0)]],
                                device atomic_uint *accum [[buffer(0)]],
                                device StudioCausticsPhotonRecord *records [[buffer(1)]],
                                constant OceanUniforms &u [[buffer(2)]],
                                constant StudioCausticsDispatch &d [[buffer(3)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if(gid.x>=d.tile.z||gid.y>=d.tile.w) return;
    uint recordIndex=gid.y*d.tile.z+gid.x;
    StudioCausticsPhotonRecord record={float4(0),float4(0),float4(0),float4(0),float4(0),float4(0)};
    // The fixed photon weight makes the four stratified samples per output texel sum to 1.
    float power=float(d.resolution.x*d.resolution.y)/float(d.resolution.z*d.resolution.w);
    float3 weight=float3(power);
    record.incident=float4(weight,1);
    uint2 lattice=gid+d.tile.xy;
    if(any(lattice>=d.resolution.zw)) { record.unresolved=float4(weight,1); records[recordIndex]=record; return; }
    float2 target=float2(-2.0,-3.12)+(float2(lattice)+0.5)/float2(d.resolution.zw)*float2(4.0,6.24);
    const float3 card=float3(-0.85,0.85,2.40);
    float3 direction=normalize(float3(target,-1.20)-card);
    StudioCausticsBoxHit box=studioCausticsBox(card,direction,u);
    if(!box.hit) {
        uint2 cell=uint2(clamp((target-float2(-2.0,-3.12))/float2(4.0,6.24)*float2(d.resolution.xy),float2(0),float2(d.resolution.xy)-1.0));
        studioCausticsDeposit(accum,cell,weight,d); record.deposited=float4(weight,1); records[recordIndex]=record; return;
    }
    // Begin at the finite card in clear medium. The ordinary fixed march then
    // detects the actual blue entry crossing; snapping to box.enter would skip
    // that refraction when the volume is already blue at the box wall.
    float travelled=0.0;
    float3 p=card;
    bool inside=vrDensity(volume,p,u)>=u.optics.z;
    const float clearIOR=1.46;
    float blueIOR=(d.controls.x&StudioCausticsEqualIOR)!=0?clearIOR:1.333;
    float3 reference=clamp(u.color.rgb,float3(0.0001),float3(0.99999));
    float3 dye=-log(reference)*0.72/0.24;
    bool done=false;
    for(uint step=0;step<2048;step++) {
        // Recompute the box exit after every refracted direction change; the
        // original entry-line distance is no longer valid once the ray bends.
        StudioCausticsBoxHit segment=studioCausticsBox(p,direction,u);
        if(!segment.hit || segment.exit<=0) { done=true; break; }
        // Keep the established fixed 0.004 step across the box wall. vrDensity
        // explicitly returns outside=0, so this preserves the same outer-phase
        // crossing/bisection path as the volume tracer and avoids a zero-step
        // endpoint that can stick on an inclusive box face.
        float distance=0.004;
        float3 next=p+direction*distance;
        float3 beforePoint=p,afterPoint=next;
        float nextDensity=vrDensity(volume,next,u);
        bool crossing=(nextDensity>=u.optics.z)!=inside;
        if(crossing) {
            float low=0,high=distance;
            for(uint b=0;b<16;b++) {
                float mid=(low+high)*0.5; float3 point=p+direction*mid;
                if((vrDensity(volume,point,u)>=u.optics.z)==inside) { low=mid; beforePoint=point; }
                else { high=mid; afterPoint=point; }
            }
            distance=(low+high)*0.5; next=p+direction*distance;
        }
        if(inside && (d.controls.x&StudioCausticsNoDye)==0) {
            float3 prior=weight; weight*=exp(-dye*distance);
            record.absorbed.xyz+=prior-weight;
        }
        travelled+=distance; p=next;
        if(crossing) {
            float3 normal=vrNormal(volume,p,u,false);
            if(!all(isfinite(normal)) || length_squared(normal)<0.5) { record.unresolved=float4(weight,1); records[recordIndex]=record; return; }
            if(dot(normal,direction)>0) normal=-normal;
            float n1=inside?blueIOR:clearIOR,n2=inside?clearIOR:blueIOR;
            float fresnel=vrFresnel(clamp(-dot(normal,direction),0.0,1.0),n1,n2);
            float3 transmitted=refract(direction,normal,n1/n2);
            if(length_squared(transmitted)<0.000001) { record.reflected.xyz+=weight; record.reflected.w=1; records[recordIndex]=record; return; }
            float3 reflectedEnergy=weight*fresnel;
            record.reflected.xyz+=reflectedEnergy;
            weight-=reflectedEnergy;
            bool expected=!inside;
            float3 moved=afterPoint;
            bool actual=vrDensity(volume,moved,u)>=u.optics.z;
            if(actual!=expected) { record.unresolved=float4(weight,1); records[recordIndex]=record; return; }
            p=moved; inside=actual; direction=normalize(transmitted);
        } else { inside=nextDensity>=u.optics.z; }
    }
    if(!done) { record.unresolved=float4(weight,1); records[recordIndex]=record; return; }
    float3 hit;
    if(!studioCausticsBackplane(p,direction,hit)) { record.outside=float4(weight,1); records[recordIndex]=record; return; }
    float2 normalized=(hit.xy-float2(-2.0,-3.12))/float2(4.0,6.24);
    uint2 cell=uint2(clamp(normalized*float2(d.resolution.xy),float2(0),float2(d.resolution.xy)-1.0));
    studioCausticsDeposit(accum,cell,weight,d);
    record.deposited=float4(weight,1); records[recordIndex]=record;
}

// Read after causticEmit completes. A normalized separable 3x3 tent
// reduces atomic-grid speckle without changing total interior energy.
kernel void causticResolve(const device atomic_uint *accum [[buffer(0)]],
                                  texture2d<half,access::write> irradiance [[texture(0)]],
                                  constant StudioCausticsDispatch &d [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
    if(any(gid>=d.resolution.xy)) return;
    float3 total=float3(0); float weights=0;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
        int2 at=int2(gid)+int2(x,y);
        if(any(at<0)||any(at>=int2(d.resolution.xy))) continue;
        float w=float((2-abs(x))*(2-abs(y)));
        uint base=(uint(at.y)*d.resolution.x+uint(at.x))*3u;
        total+=float3(atomic_load_explicit(&accum[base],memory_order_relaxed),
                      atomic_load_explicit(&accum[base+1],memory_order_relaxed),
                      atomic_load_explicit(&accum[base+2],memory_order_relaxed))*w;
        weights+=w;
    }
    irradiance.write(half4(half3(total/max(weights,1.0)/d.scale.x),half(1)),gid);
}
