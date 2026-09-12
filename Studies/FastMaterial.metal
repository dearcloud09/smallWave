// Front view of the shallow two-medium vessel. This candidate uses filtered
// density samples with explicit trilinear interpolation. It is not equivalent
// to the slower exact cubic field or a complete path tracer. Specular secondary
// rays use a bounded environment approximation; total internal reflection stays
// inside the actual field. Unfinished primary rays are visible magenta errors.

#ifdef FAST_CUBIC_FIELD
float4 continuousWeights(float t) {
    float s=1-t;
    return float4(s*s*s,3*t*t*t-6*t*t+4,-3*t*t*t+3*t*t+3*t+1,t*t*t)/6;
}
float4 continuousDerivatives(float t) {
    return float4(-.5*(1-t)*(1-t),1.5*t*t-2*t,-1.5*t*t+t+.5,.5*t*t);
}
float4 continuousField(texture3d<float> field,float3 p,bool needGradient) {
    // Controlled C2 B-spline reconstruction of the SAME prepared samples.
    // This slightly changes the isosurface; it is not merely normal smoothing.
    // No hardware-filtering approximation or homogeneous-block skip is used.
    int3 size=int3(field.get_width(),field.get_height(),field.get_depth());
    float3 grid=float3(p.x*.5+.5,.5-p.y/4.24,.5-p.z/.36)*float3(size)-.5;
    int3 base=int3(floor(grid))-1;float3 f=fract(grid);
    float4 wx=continuousWeights(f.x),wy=continuousWeights(f.y),wz=continuousWeights(f.z);
    float4 dx=continuousDerivatives(f.x),dy=continuousDerivatives(f.y),dz=continuousDerivatives(f.z);
    float value=0;float3 gradient=float3(0);
    for(uint z=0;z<4;z++) for(uint y=0;y<4;y++) for(uint x=0;x<4;x++) {
        float c=field.read(uint3(clamp(base+int3(x,y,z),int3(0),size-1))).r;
        value+=c*wx[x]*wy[y]*wz[z];
        if(needGradient) gradient+=c*float3(dx[x]*wy[y]*wz[z],wx[x]*dy[y]*wz[z],wx[x]*wy[y]*dz[z]);
    }
    gradient*=float3(float(size.x)*.5,-float(size.y)/4.24,-float(size.z)/.36);
    return float4(value-.6,gradient);
}
#endif

float fastDensity(texture3d<float> field,float3 p) {
#ifdef FAST_CUBIC_FIELD
    return continuousField(field,p,false).x;
#else
    // Explicit weights keep sub-voxel crossings and normals on exactly the
    // same continuous interpolant; hardware filtering is a separate candidate.
    int3 size=int3(field.get_width(),field.get_height(),field.get_depth());
    float3 grid=float3(p.x*.5+.5,.5-p.y/4.24,.5-p.z/.36)*float3(size)-.5;
    int3 base=int3(floor(grid));float3 f=fract(grid);float c[8];
    for(uint z=0;z<2;z++) for(uint y=0;y<2;y++) for(uint x=0;x<2;x++)
        c[x+2*y+4*z]=field.read(uint3(clamp(base+int3(x,y,z),int3(0),size-1))).r;
    return mix(mix(mix(c[0],c[1],f.x),mix(c[2],c[3],f.x),f.y),
               mix(mix(c[4],c[5],f.x),mix(c[6],c[7],f.x),f.y),f.z)-.6;
#endif
}
float3 fastNormal(texture3d<float> field,float3 p) {
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
float fastFresnel(float cosi,float etaI,float etaT) {
    cosi=clamp(cosi,0.0,1.0);
    float sint2=pow(etaI/etaT,2.0)*(1-cosi*cosi);
    if(sint2>=1) return 1;
    float cost=sqrt(max(0.0,1-sint2));
    float rs=(etaI*cosi-etaT*cost)/(etaI*cosi+etaT*cost);
    float rp=(etaT*cosi-etaI*cost)/(etaT*cosi+etaI*cost);
    return .5*(rs*rs+rp*rp);
}
float3 fastEnvironment(float3 p,float3 d) {
    // One shared simple studio for reflection and transmission. Bright cards
    // have finite positions; there is no inverted copy of a 2D backdrop.
    float3 light=float3(.24,.27,.29);
    float best=1e9;
    if(d.z<-.00001) {
        float t=(-3.0-p.z)/d.z;
        if(t>0&&t<best) {
            float3 q=p+t*d;best=t;
            float pool=exp(-pow((q.y+1.6)*.6,2.0)-pow(q.x*.45,2.0));
            light=mix(float3(.31,.34,.35),float3(.70,.73,.71),pool);
        }
    }
    if(d.z>.00001) {
        float t=(3.0-p.z)/d.z;
        if(t>0&&t<best) {
            float3 q=p+t*d;best=t;light=float3(.025,.031,.038);
            float window=smoothstep(-1.9,-1.82,q.x)*(1-smoothstep(-.42,-.34,q.x))
                         *smoothstep(-.5,-.42,q.y)*(1-smoothstep(3.1,3.18,q.y));
            float strip=smoothstep(1.5,1.53,q.x)*(1-smoothstep(1.70,1.73,q.x))
                        *smoothstep(-1.8,-1.7,q.y)*(1-smoothstep(2.2,2.3,q.y));
            light+=float3(3.0,2.96,2.8)*window+float3(1.2,1.4,1.5)*strip;
        }
    }
    if(d.y<-.00001) {
        float t=(-2.20-p.y)/d.y;
        if(t>0&&t<best) {
            float3 q=p+t*d;best=t;
            float pool=exp(-pow(q.x*.45,2.0)-pow(q.z*.3,2.0));
            light=float3(.36,.40,.42)+float3(.25,.26,.24)*pool;
        }
    }
    if(d.y>.00001) {
        float t=(4.5-p.y)/d.y;
        if(t>0&&t<best) light=float3(.76,.80,.83);
    }
    return light;
}
float fastBoxExit(float3 p,float3 d,thread float3 &normal) {
    float3 h=float3(1,2.12,.18),t=float3(1e9);
    for(uint k=0;k<3;k++) if(abs(d[k])>1e-8) t[k]=((d[k]>0?h[k]:-h[k])-p[k])/d[k];
    uint axis=t.x<t.y ? (t.x<t.z?0:2) : (t.y<t.z?1:2);
    normal=float3(0);normal[axis]=d[axis]>0?1:-1;
    return max(t[axis],0.0);
}
float3 fastAbsorption(float3 transmission) { return -log(transmission)/.32; }
float3 fastDisplay(float3 light) {
    // Bounded filmic display, not Cycles/AgX equivalence.
    light=max(light,float3(0));
    float3 mapped=(light*(2.51*light+.03))/(light*(2.43*light+.59)+.14);
    return lightToDisplay(clamp(mapped,0.0,1.0));
}
bool fastTailResolved(float3 radiance,float3 remaining) {
    // All studio and toy radiance in this candidate is <=5 per channel, and
    // subsequent throughput factors are in [0,1]. Bound the missing primary
    // tail in the ACTUAL monotone display transform: <=1/4 of an 8-bit code.
    // This does not bound the separate secondary-reflection approximation.
    float3 span=fastDisplay(radiance+remaining*5)-fastDisplay(radiance);
    return max(max(span.x,span.y),span.z)<=.25/255.0;
}
fragment float4 fastToyFragment(QuadOut in [[stage_in]],
                                texture3d<float> field [[texture(0)]],
                                constant OceanUniforms &u [[buffer(0)]]
#ifdef FAST_PROBE
                                ,device float4 *trace [[buffer(1)]]
#endif
                                ) {
#ifdef FAST_PROBE
    if(any(uint2(in.position.xy)!=uint2(586,874))) return float4(0,0,0,1);
#endif
    float2 screen=(in.uv*float2(2,-2)+float2(-1,1))*u.viewport.xy;
    float2 world=rotate2(screen,u.viewport.w);
    float3 p=float3(world,.17998),d=float3(0,0,-1);
    float3 coeff=fastAbsorption(u.color.rgb);
    float firstF=fastFresnel(1,1,1.46);
    float3 radiance=firstF*fastEnvironment(p,float3(0,0,1));
    float3 weight=float3(1-firstF);
    bool blue=fastDensity(field,p)>0;
#ifdef FAST_PROBE
    trace[0]=float4(in.uv,fastDensity(field,p),100);
#endif
    bool finished=false;
    uint samplesUsed=0;
    for(uint bounce=0;bounce<32;bounce++) {
#ifdef FAST_PROBE
        uint record=1+bounce*7;
        trace[record]=float4(p,blue?1:0);
        trace[record+1]=float4(d,float(samplesUsed));
        trace[record+2]=float4(weight,fastDensity(field,p));
#endif
        if(fastTailResolved(radiance,weight)) {finished=true;break;}
        float3 wallNormal;
        float wallDistance=fastBoxExit(p,d,wallNormal);
        float traveled=0,previous=fastDensity(field,p),hitDistance=wallDistance;
        bool interfaceHit=false;
        for(uint step=0;step<2048;step++) {
            if(traveled>=wallDistance) break;
            if(++samplesUsed>2048) {
#ifdef FAST_PROBE
                trace[255]=float4(2048,float(bounce),traveled,float(samplesUsed));
#endif
                return float4(1,0,1,1);
            }
            float next=min(wallDistance,traveled+.00375);
            float value=fastDensity(field,p+d*next);
            if((value>0)!=blue) {
                float lo=traveled,hi=next;
                for(uint r=0;r<9;r++) {
                    float mid=(lo+hi)*.5;
                    if((fastDensity(field,p+d*mid)>0)==blue) lo=mid;else hi=mid;
                }
                hitDistance=(lo+hi)*.5;interfaceHit=true;break;
            }
            previous=value;traveled=next;
        }
        // Intersect the existing toy artwork at its actual depth along this
        // refracted segment. Opaque coverage terminates energy, not the ray.
        float toyT=abs(d.z)>1e-8 ? (u.boat.w-p.z)/d.z : -1;
        if(toyT>1e-5&&toyT<hitDistance) {
            float4 toy=miniature((p+d*toyT).xy,u);
            float3 before=blue?exp(-coeff*toyT):float3(1);
            radiance+=weight*before*displayToLight(toy.rgb/max(toy.a,1e-5))*toy.a;
            weight*=1-toy.a;
        }
        if(blue) weight*=exp(-coeff*hitDistance);
        p+=d*hitDistance;
#ifdef FAST_PROBE
        trace[record+3]=float4(p,hitDistance);
        trace[record+4]=float4(wallNormal,interfaceHit?1:0);
#endif
        if(interfaceHit) {
            float3 outward=fastNormal(field,p);
            float3 n=blue ? -outward : outward;
            if(dot(n,d)>0) n=-n;
            float ni=blue?1.333:1.46,nt=blue?1.46:1.333;
            float f=fastFresnel(-dot(n,d),ni,nt);
            float3 reflected=reflect(d,n);
#ifdef FAST_PROBE
            trace[record+5]=float4(n,f);
#endif
            if(f>.999999) {
                d=reflected;p+=d*.000025;
#ifdef FAST_PROBE
                trace[record+6]=float4(p,fastDensity(field,p));
#endif
                continue;
            }
            // Explicit approximation: low-energy non-TIR secondary reflection
            // queries the studio directly. The dominant transmission continues.
            float3 reflection=fastEnvironment(p,reflected);
            if(blue) reflection*=exp(-coeff*.18);
            radiance+=weight*f*reflection;weight*=1-f;
            d=refract(d,n,ni/nt);blue=!blue;p+=d*.000025;
        } else {
            float ni=blue?1.333:1.46;
            float f=fastFresnel(dot(d,wallNormal),ni,1.0);
#ifdef FAST_PROBE
            trace[record+5]=float4(wallNormal,f);
#endif
            if(f<.999999) radiance+=weight*(1-f)*fastEnvironment(p,refract(d,-wallNormal,ni));
            weight*=f;d=reflect(d,wallNormal);p+=d*.000025;
        }
#ifdef FAST_PROBE
        trace[record+6]=float4(p,fastDensity(field,p));
#endif
    }
#ifdef FAST_PROBE
    trace[255]=float4(finished?0:32,float(samplesUsed),max(max(weight.x,weight.y),weight.z),0);
#endif
    if(!finished&&!fastTailResolved(radiance,weight)) return float4(1,0,1,1);
    if(!all(isfinite(radiance))) return float4(1,0,1,1);
    float3 color=fastDisplay(radiance);
    float edge=min(1-abs(world.x),2.12-abs(world.y));
    float line=exp(-pow((edge-.010)*350.0,2.0));
    color=mix(color,float3(.83,.88,.90),line*.35);
    return float4(color,1);
}
