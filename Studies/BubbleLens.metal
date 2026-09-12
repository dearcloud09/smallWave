// Screen-space clear pockets over the unchanged liquid render. This is a
// bounded visual approximation, not measured water/oil/air optics.
struct LensBubble { float4 positionRadius; float4 life; };
struct LensOut {
    float4 position [[position]];
    float2 local;
    float2 uv;
    float radius;
    float depth;
    float life;
};
struct PocketSample {
    float coverage;
    float path;
    float available;
    float reflection;
    float3 backdrop;
};
float pocketToyAlpha(float2 uv,texture2d<float> field,constant OceanUniforms &u) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 pixel=1.0/float2(field.get_width(),field.get_height());
    float2 fv=field.sample(smp,uv).rg;
    float2 gradient=float2(field.sample(smp,uv+float2(pixel.x,0)).r-field.sample(smp,uv-float2(pixel.x,0)).r,
                           field.sample(smp,uv+float2(0,pixel.y)).r-field.sample(smp,uv-float2(0,pixel.y)).r);
    float2 world=rotate2((uv*float2(2,-2)+float2(-1,1))*u.viewport.xy,u.viewport.w);
    float2 refracted=world+rotate2(float2(gradient.x,-gradient.y)*0.6,u.viewport.w)*0.028;
    float waterInFront=smoothstep(-0.11,0.11,fv.y/max(fv.x,0.001)-u.boat.w);
    float2 boatSample=mix(world,refracted,waterInFront);
    return max(miniature(world,u).a,miniature(boatSample,u).a);
}
PocketSample pocketSample(float2 uv,texture2d<float> field,constant OceanUniforms &u) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    float2 pixel=1.0/float2(field.get_width(),field.get_height());
    float density=field.sample(smp,uv).r;
    float2 gradient=float2(field.sample(smp,uv+float2(pixel.x,0)).r-field.sample(smp,uv-float2(pixel.x,0)).r,
                           field.sample(smp,uv+float2(0,pixel.y)).r-field.sample(smp,uv-float2(0,pixel.y)).r);
    float2 screen=(uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    float2 world=rotate2(screen,u.viewport.w);
    float2 refracted=world+rotate2(float2(gradient.x,-gradient.y)*0.6,u.viewport.w)*0.028;
    float distance=(density-0.52)/max(length(gradient),0.08);
    float meniscus=exp(-pow(max(distance,0.0)/0.9,2.0));
    float2 outward=rotate2(float2(-gradient.x,gradient.y),u.viewport.w);
    float3 n=normalize(float3(outward*meniscus*2,1));
    PocketSample p;
    float aa=max(fwidth(density),0.025);
    p.coverage=smoothstep(0.52-aa,0.52+aa,density);
    p.path=clamp(1.5*(1-exp(-max(density-0.35,0.0)*0.18))+max(0.0,dot(world,u.movement.xy))*0.25,0.0,1.5);
    // Use the actual wet-toy lookup, including intermediate refraction.
    p.available=pocketToyAlpha(uv,field,u)<0.01 ? 1 : 0;
    p.reflection=0.02+0.98*pow(1-n.z,5.0);
    p.backdrop=displayToLight(backdrop(refracted,u));
    return p;
}
vertex LensOut lensBubbleVertex(uint v [[vertex_id]],uint i [[instance_id]],
                               const device LensBubble *bubbles [[buffer(0)]],
                               constant OceanUniforms &u [[buffer(1)]]) {
    LensBubble b=bubbles[i];
    float2 local=corner(v);
    float2 p=rotate2(b.positionRadius.xy,-u.viewport.w)+local*b.positionRadius.w;
    LensOut out;
    out.position=float4(p/u.viewport.xy,0,1);
    out.local=local;
    out.uv=p/u.viewport.xy*float2(0.5,-0.5)+0.5;
    out.radius=b.positionRadius.w;
    out.depth=b.positionRadius.z;
    out.life=b.life.x;
    return out;
}
fragment float4 lensBubbleFragment(LensOut in [[stage_in]],
                                  texture2d<float> field [[texture(0)]],
                                  texture2d<float> scene [[texture(1)]],
                                  constant OceanUniforms &u [[buffer(0)]]) {
    constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
    float r=length(in.local), aa=max(fwidth(r),0.025);
    float silhouette=1-smoothstep(0.90-aa,0.90+aa,r);
    // A small displacement follows the curved pocket. No whole-scene warp.
    float nr=clamp(r/0.90,0.0,1.0);
    float nz=sqrt(max(0.0,1-nr*nr));
    float2 normalXY=in.local/0.90;
    float2 offset=normalXY*(in.radius*0.28*nz)/(2*u.viewport.xy)*float2(1,-1);
    float2 sampleUV=clamp(in.uv+offset,float2(0),float2(1));
    PocketSample destination=pocketSample(in.uv,field,u);
    PocketSample source=pocketSample(sampleUV,field,u);
    // Bilinear scene lookup must not pull in neighbouring toy pixels either.
    float2 scenePixel=1.0/float2(scene.get_width(),scene.get_height());
    float neighbouringToy=0;
    for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++) {
        neighbouringToy=max(neighbouringToy,pocketToyAlpha(sampleUV+float2(x,y)*scenePixel,field,u));
    }
    // Read and write wholly inside liquid. Keep the original anti-aliased
    // water silhouette instead of pulling dry background into its edge.
    float wet=step(0.999,min(destination.coverage,source.coverage));
    float alpha=silhouette*clamp(in.life,0.0,1.0)*wet*destination.available*source.available*(neighbouringToy<0.01 ? 1 : 0);
    if(alpha<=0) return 0;
    float3 sampled=displayToLight(scene.sample(smp,sampleUV).rgb);

    // Approximate removal of a short dyed segment, bounded by the original
    // path estimate. It does not move liquid or assert conserved pocket volume.
    // 0.24 is an explicit style conversion into the base shader's normalized
    // path, not a measured optical length for the photographed toy.
    float removed=min(source.path,2*in.radius*nz/0.24);
    float3 transmission=clamp(u.color.rgb,float3(0.02),float3(0.98));
    float3 absorb=-log(transmission)*0.72;
    float3 scatter=transmission*0.22;
    // Adjust only the estimated transmitted-liquid contribution. Do not
    // apply inverse absorption to the already composited reflection or toy.
    float3 delta=(source.backdrop-scatter)*(exp(-absorb*(source.path-removed))-exp(-absorb*source.path));
    float3 clearLight=clamp(sampled+delta*(1-source.reflection),float3(0),float3(1));

    // Preserve the baseline's opposed glint and dark crescent; the first
    // candidate lost these shape cues and read as a pale filled disc.
    float rim=exp(-pow((r-0.78)/0.12,2.0));
    float2 litLocal=rotate2(in.local,u.viewport.w);
    float facing=dot(litLocal/max(r,0.001),normalize(float2(-0.55,0.83)));
    float brightArc=smoothstep(-0.15,0.8,facing), darkArc=smoothstep(0.0,0.8,-facing);
    float2 a=litLocal-float2(-0.28,0.35), b=litLocal-float2(0.25,-0.39);
    float lightAlpha=clamp(rim*(0.08+brightArc*0.32)+exp(-dot(a,a)*65)*0.72+exp(-dot(b,b)*90)*0.22,0.0,0.9);
    float shadowAlpha=rim*darkArc*0.24;
    float rimAlpha=lightAlpha+shadowAlpha*(1-lightAlpha);
    float3 rimColor=float3(0.84,0.97,1)*lightAlpha+float3(0.015,0.13,0.20)*shadowAlpha*(1-lightAlpha);
    float3 color=clamp(lightToDisplay(clearLight),float3(0),float3(1))*(1-rimAlpha)+rimColor;
    return float4(color*alpha,alpha);
}
