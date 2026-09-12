// Injected before vrSample by prepare_vessel_shell.py.
// Prescribed shell: air (1.0), glass (1.49), thickness 0.006, liquid-side
// clear medium (1.46). This is an incoherent parallel-slab Fresnel model; it
// omits lateral displacement from its untraced internal glass bounces.
constant uint VesselShellStudyBit=1024u;
struct VesselShellHit { float t; float3 normal; bool hit; };
VesselShellHit vesselShellInner(float3 p,float3 d,constant OceanUniforms &u) {
    float3 e=float3(u.viewport.xy,u.optics.y); float best=1e20; float3 n=float3(0);
    for(uint a=0;a<3;a++) if(abs(d[a])>0.000001) {
        float face=d[a]>0?e[a]:-e[a]; float t=(face-p[a])/d[a];
        float3 q=p+d*t; if(t>0 && abs(q[(a+1)%3])<=e[(a+1)%3] && abs(q[(a+2)%3])<=e[(a+2)%3] && t<best) { best=t; n=float3(0); n[a]=d[a]>0?1:-1; }
    }
    return {best,n,best<1e19};
}
float vesselShellSlabT(float cosine,float n1,float n2,float n3,thread float &reflectance) {
    float r12=vrFresnel(cosine,n1,n2); float s2=(n1*n1)/(n2*n2)*max(0.0,1-cosine*cosine);
    if(s2>=1) { reflectance=1; return 0; }
    float c2=sqrt(1-s2),r23=vrFresnel(c2,n2,n3),den=max(1-r12*r23,0.00001);
    reflectance=r12+(1-r12)*(1-r12)*r23/den; return (1-r12)*(1-r23)/den;
}
float3 vesselShellLanding(float3 p,float3 normal,constant OceanUniforms &u) {
    float3 halfSize=float3(u.viewport.xy,u.optics.y);
    for(uint axis=0;axis<3;axis++) if(abs(normal[axis])>0.5) {
        // Two representable steps inside the known plane; no arbitrary world
        // epsilon that can cross an unrelated thin liquid interface.
        p[axis]=nextafter(nextafter(normal[axis]*halfSize[axis],0.0f),0.0f);
    }
    return p;
}
