// One world-space radiance scene for the material study. The same planes are
// visible to transmission and reflection; no screen-space highlight is painted
// on the liquid. Values are art-directed linear radiance, not measured lamps.
float3 sharedStudioRadiance(float3 origin, float3 direction) {
    const float3 low=float3(-3.0,-2.30,-1.20);
    const float3 high=float3(3.0,4.0,2.40);
    float nearest=1e20;
    int face=-1;
    for(int axis=0;axis<3;axis++) {
        if(abs(direction[axis])<0.000001) continue;
        float side=direction[axis]>0?high[axis]:low[axis];
        float t=(side-origin[axis])/direction[axis];
        if(t>0 && t<nearest) { nearest=t; face=axis*2+(direction[axis]>0?1:0); }
    }
    if(face<0) return float3(0.1);
    float3 p=origin+direction*nearest;
    if(face==4) {
        // A softly lit rear card. Its broad shadow provides a feature whose
        // displacement can reveal the liquid's curvature and thickness.
        float shade=0.67+0.30*smoothstep(-1.7,1.4,p.x+0.40*p.y);
        return shade*float3(0.965,0.982,1.0);
    }
    if(face==5) {
        float2 key=abs(p.xy-float2(-0.85,0.85))-float2(0.54,1.5);
        float2 fill=abs(p.xy-float2(1.15,-0.2))-float2(0.12,1.65);
        float k=1-smoothstep(-0.035,0.035,max(key.x,key.y));
        float f=1-smoothstep(-0.025,0.025,max(fill.x,fill.y));
        return float3(0.018,0.025,0.034)+3.0*k*float3(1,0.97,0.93)+1.5*f*float3(0.90,0.96,1);
    }
    if(face==2) return float3(0.22,0.27,0.31);
    if(face==3) return float3(0.86,0.89,0.94);
    return float3(0.065,0.085,0.105);
}
