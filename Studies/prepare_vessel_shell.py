#!/usr/bin/env python3
"""Analytical outer-vessel A/B, preserving the shell-off liquid transport.

Primary transmission is terminated at the world, while its shell-reflected
remainder continues inside and is attenuated by subsequent liquid traversal.
Existing optional fluid reflection tails remain an explicit approximation.
"""
import hashlib
import json
from pathlib import Path

SOURCE=Path('.build-cache/particle-surface-exact-bubbles/exact-bubble-shader.metal')
OUT=Path('.build-cache/material-vessel-shell/shell-shader.metal')
HELPER=Path('Studies/VesselShell.metal')

def once(text,old,new):
    if text.count(old)!=1:
        raise RuntimeError('Missing or ambiguous shader anchor: '+old[:72])
    return text.replace(old,new)

def main():
    source=SOURCE.read_text()
    source=once(source,'float4 vrSample(float2 uv,texture2d_array<float> volume,',
                HELPER.read_text()+'\nfloat4 vrSample(float2 uv,texture2d_array<float> volume,')
    source=once(source,'    float3 weight=float3(1), radiance=float3(0);',r'''
    float3 weight=float3(1), radiance=float3(0);
    bool vesselShell=(uint(study.w)&VesselShellStudyBit)!=0;
    if(vesselShell) {
        const float thickness=0.006;
        float3 normal=float3(0,0,1);
        float3 outerPoint=p+direction*((u.optics.y+thickness-p.z)/direction.z);
        float reflection=0;
        float transmission=vesselShellSlabT(clamp(-dot(normal,direction),0.0,1.0),1.0,1.49,clearIOR,reflection);
        radiance+=reflection*sharedStudioRadiance(outerPoint,reflect(direction,normal));
        weight*=transmission;
        float3 glass=refract(direction,normal,1.0/1.49);
        float3 entered=refract(glass,normal,1.49/clearIOR);
        if(length_squared(entered)<0.000001 || glass.z>=0) return float4(0,0,0,-1);
        float3 innerPoint=outerPoint+glass*(-thickness/glass.z);
        direction=normalize(entered);
        p=vesselShellLanding(innerPoint,normal,u);
    }''')
    source=once(source,r'''        float distance=marchStep;
        float3 next=p+direction*distance;
        float3 beforePoint=p, afterPoint=next;
        float nextDensity=vrDensity(volume,next,u);
        bool crossing=(nextDensity>=u.optics.z)!=inside;
        if(crossing) {''',r'''        float distance=marchStep;
        VesselShellHit shell={1e20,float3(0),false};
        bool shellBoundary=false;
        if(vesselShell) {
            shell=vesselShellInner(p,direction,u);
            shellBoundary=shell.hit && shell.t<=distance;
            if(shellBoundary) distance=shell.t;
        }
        float3 next=p+direction*distance;
        float3 beforePoint=p, afterPoint=next;
        float3 densityPoint=shellBoundary?vesselShellLanding(next,shell.normal,u):next;
        float nextDensity=vrDensity(volume,densityPoint,u);
        bool crossing=(nextDensity>=u.optics.z)!=inside;
        if(crossing) {
            // A fluid interface was encountered before the outer vessel. Its
            // usual bisection runs first; the vessel is considered next step.
            shellBoundary=false;''')
    old=r'''        if(p.z< -0.19||p.z>0.20||abs(p.x)>u.viewport.x+0.01||abs(p.y)>u.viewport.y+0.01||max(weight.r,max(weight.g,weight.b))<0.00001) {
            finished=true; break;
        }'''
    source=once(source,old,r'''        if(vesselShell) {
            if(shellBoundary) {
                float n1=inside?blueIOR:clearIOR, reflection=0;
                float transmission=vesselShellSlabT(clamp(dot(shell.normal,direction),0.0,1.0),n1,1.49,1.0,reflection);
                float3 facing=-shell.normal;
                float3 glass=refract(direction,facing,n1/1.49);
                float3 outgoing=length_squared(glass)>0.000001?refract(glass,facing,1.49):float3(0);
                if(transmission>0) {
                    if(length_squared(outgoing)<0.000001) { mediumMismatch=true; break; }
                    float3 outerPoint=p+glass*(0.006/max(dot(glass,shell.normal),0.000001));
                    radiance+=weight*transmission*sharedStudioRadiance(outerPoint,normalize(outgoing));
                }
                // This remainder has not reached the environment. Trace it
                // back through the actual liquid, including its absorption.
                weight*=reflection;
                direction=reflect(direction,shell.normal);
                p=vesselShellLanding(p,shell.normal,u);
                bool actual=vrDensity(volume,p,u)>=u.optics.z;
                if(actual!=inside) mediumMismatch=true;
                inside=actual;
            }
            if(max(weight.r,max(weight.g,weight.b))<0.00001) {
                weight=float3(0); finished=true; break;
            }
            if(any(abs(p)>float3(u.viewport.xy,u.optics.y)+0.000001)) {
                mediumMismatch=true; break;
            }
        } else {
'''+old+r'''
        }''')
    OUT.parent.mkdir(parents=True,exist_ok=True)
    OUT.write_text(source)
    manifest={'sourceSHA256':hashlib.sha256(source.encode()).hexdigest(),
              'inputs':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [SOURCE,HELPER,Path(__file__)]},
              'modeBit':1024,'shellIOR':1.49,'outsideIOR':1.0,'thickness':0.006,
              'measured':False,'adopted':False,
              'approximation':'incoherent parallel slabs; no lateral shift of repeated glass bounces; existing fluid reflection tails unchanged'}
    OUT.with_suffix('.json').write_text(json.dumps(manifest,indent=2))
    print(OUT)
if __name__=='__main__': main()
