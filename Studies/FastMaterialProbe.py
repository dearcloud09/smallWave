#!/usr/bin/env python3
"""One-ray CPU diagnosis for Studies/FastMaterial.metal explicit interpolant.

It intentionally reproduces only density, normal, crossing/refraction and
throughput state.  Toy/environment radiance is excluded because neither can
make the shader return its magenta unfinished-primary sentinel.
"""
import json
import math
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
FRAME = ROOT / ".build-cache/fast-material/000"
OUT = ROOT / ".build-cache/fast-material/probe"
W, H = 600, 1272
EPS = np.float32(0.000025)


def f(v): return np.float32(v)
def v3(a): return np.asarray(a, dtype=np.float32)
def dot(a, b): return f(np.dot(a, b))
def length(a): return f(np.sqrt(dot(a, a)))
def norm(a): return a / max(length(a), f(1e-9))
def reflect(i, n): return i - f(2) * dot(n, i) * n
def refract(i, n, eta):
    c = -dot(n, i); k = f(1) - eta * eta * (f(1) - c * c)
    return eta * i + (eta * c - f(math.sqrt(max(0.0, float(k))))) * n


class Probe:
    def __init__(self):
        raw = np.fromfile(FRAME / "field.f16", dtype="<f2")
        if raw.size != 256 * 544 * 48 or not np.isfinite(raw).all():
            raise ValueError("invalid field.f16")
        self.field = raw.reshape(48, 544, 256).astype(np.float32)

    def density(self, p):
        grid = (v3((p[0] * .5 + .5, .5 - p[1] / 4.24, .5 - p[2] / .36))
                * v3((256, 544, 48)) - f(.5))
        base = np.floor(grid).astype(np.int32); q = grid - base
        c = np.empty(8, dtype=np.float32)
        for z in range(2):
            for y in range(2):
                for x in range(2):
                    i = np.clip(base + (x, y, z), (0, 0, 0), (255, 543, 47))
                    c[x + 2*y + 4*z] = self.field[i[2], i[1], i[0]]
        def mix(a, b, t): return a * (f(1)-t) + b*t
        return f(mix(mix(mix(c[0],c[1],q[0]),mix(c[2],c[3],q[0]),q[1]),
                     mix(mix(c[4],c[5],q[0]),mix(c[6],c[7],q[0]),q[1]),q[2])-.6)

    def normal(self, p):
        grid = (v3((p[0] * .5 + .5, .5 - p[1] / 4.24, .5 - p[2] / .36))
                * v3((256, 544, 48)) - f(.5))
        base = np.floor(grid).astype(np.int32); q = grid-base; c=np.empty(8,np.float32)
        for z in range(2):
            for y in range(2):
                for x in range(2):
                    i=np.clip(base+(x,y,z),(0,0,0),(255,543,47)); c[x+2*y+4*z]=self.field[i[2],i[1],i[0]]
        def mix(a,b,t): return a*(f(1)-t)+b*t
        dx=mix(mix(c[1]-c[0],c[3]-c[2],q[1]),mix(c[5]-c[4],c[7]-c[6],q[1]),q[2])
        dy=mix(mix(c[2]-c[0],c[3]-c[1],q[0]),mix(c[6]-c[4],c[7]-c[5],q[0]),q[2])
        dz=mix(mix(c[4]-c[0],c[5]-c[1],q[0]),mix(c[6]-c[2],c[7]-c[3],q[0]),q[1])
        return -norm(v3((dx*128, -dy*544/4.24, -dz*48/.36)))

    @staticmethod
    def fresnel(cosi, ni, nt):
        cosi=max(0.,min(1.,float(cosi))); sint2=(ni/nt)**2*(1-cosi*cosi)
        if sint2 >= 1: return f(1)
        cost=math.sqrt(max(0.,1-sint2)); rs=(ni*cosi-nt*cost)/(ni*cosi+nt*cost); rp=(nt*cosi-ni*cost)/(nt*cosi+ni*cost)
        return f(.5*(rs*rs+rp*rp))

    @staticmethod
    def box_exit(p, d):
        h=v3((1,2.12,.18)); ts=np.full(3,f(1e9),np.float32)
        for k in range(3):
            if abs(float(d[k])) > 1e-8: ts[k]=((h[k] if d[k]>0 else -h[k])-p[k])/d[k]
        axis=int(np.argmin(ts)); n=np.zeros(3,np.float32); n[axis]=1 if d[axis]>0 else -1
        return max(f(0),ts[axis]),n

    def trace(self, x, y):
        uv=v3(((x+.5)/W,(y+.5)/H)); screen=(uv*v3((2,-2))+v3((-1,1)))*v3((1,2.12))
        p=v3((screen[0],screen[1],.17998)); d=v3((0,0,-1)); blue=bool(self.density(p)>0); weight=f(1-self.fresnel(1,1,1.46)); samples=0; logs=[]; reason="bounce_limit"
        for bounce in range(32):
            if weight < 1e-6: reason="weight_finished"; break
            startp=p.copy(); startd=d.copy(); wall,nwall=self.box_exit(p,d); traveled=f(0); hit=wall; interface=False; pre=self.density(p)
            for step in range(2048):
                if traveled >= wall: break
                samples += 1
                if samples > 2048:
                    reason="global_samples_over_2048"; logs.append(self.record(bounce,startp,startd,blue,wall,hit,weight,samples,pre,None,None,"sample_cap")); return reason,logs
                nxt=min(wall,traveled+f(.00375)); value=self.density(p+d*nxt)
                if bool(value>0) != blue:
                    lo,hi=traveled,nxt
                    for _ in range(9):
                        mid=(lo+hi)*f(.5)
                        if bool(self.density(p+d*mid)>0)==blue: lo=mid
                        else: hi=mid
                    hit=(lo+hi)*f(.5); interface=True; break
                traveled=nxt
            p=p+d*hit
            if interface:
                outward=self.normal(p); n=-outward if blue else outward
                if dot(n,d)>0: n=-n
                ni,nt=(f(1.333),f(1.46)) if blue else (f(1.46),f(1.333)); fr=self.fresnel(-dot(n,d),ni,nt)
                if fr > f(.999999):
                    d=reflect(d,n); p=p+d*EPS; action="tir_reflect"
                else:
                    weight*=f(1-fr); d=refract(d,n,f(ni/nt)); blue=not blue; p=p+d*EPS; action="transmit"
                logs.append(self.record(bounce,startp,startd,not blue if action=="transmit" else blue,wall,hit,weight,samples,pre,fr,self.density(p),action))
            else:
                ni=f(1.333) if blue else f(1.46); fr=self.fresnel(dot(d,nwall),ni,f(1)); weight*=f(fr); d=reflect(d,nwall); p=p+d*EPS
                logs.append(self.record(bounce,startp,startd,blue,wall,hit,weight,samples,pre,fr,self.density(p),"wall_reflect"))
        return reason,logs

    @staticmethod
    def record(b,p,d,blue,wall,travel,weight,samples,pre,fr,next_density,action):
        return {"bounce":b,"p":[float(q) for q in p],"d":[float(q) for q in d],"blue":bool(blue),"wallDistance":float(wall),"travel":float(travel),"zeroDistanceCrossing":bool(action in ("transmit","tir_reflect") and travel<=1e-7),"fresnel":None if fr is None else float(fr),"nextMediumSample":None if next_density is None else float(next_density),"weightMax":float(weight),"cumulativeSteps":samples,"startDensity":float(pre),"action":action}


def choose_magenta():
    a=np.asarray(Image.open(FRAME/"explicit-interpolant-600/frame.png").convert("RGB"))
    mask=(a[:,:,0]>245)&(a[:,:,1]<20)&(a[:,:,2]>245); ys,xs=np.where(mask)
    if not len(xs): raise ValueError("no magenta pixels")
    # Prefer an isolated edge pixel; tie-break toward a noncentral screen point.
    best=None
    for x,y in zip(xs,ys):
        nearby=int(mask[max(0,y-3):y+4,max(0,x-3):x+4].sum()); score=(nearby,-((x-W/2)**2+(y-H/2)**2))
        if best is None or score<best[0]: best=(score,int(x),int(y))
    return best[1],best[2],int(mask.sum())


def refraction_sanity():
    normal = v3((0, 0, 1)); eta = f(1 / 1.46)
    normal_incidence = refract(v3((0, 0, -1)), normal, eta)
    oblique_incidence = refract(norm(v3((.3, 0, -math.sqrt(.91)))), normal, eta)
    values = {"normalIncidence": [float(q) for q in normal_incidence],
              "obliqueLength": float(length(oblique_incidence))}
    if abs(float(normal_incidence[2]) + 1) > 1e-5 or abs(values["obliqueLength"] - 1) > 1e-5:
        raise ValueError("refract unit-length sanity failed")
    return values


if __name__ == "__main__":
    OUT.mkdir(parents=True,exist_ok=True); x,y,count=choose_magenta(); reason,events=Probe().trace(x,y)
    result={"image":".build-cache/fast-material/000/explicit-interpolant-600/frame.png","pixel":{"x":x,"y":y,"uv":[(x+.5)/W,(y+.5)/H]},"magentaPixelCount":count,"cpuResult":reason,"events":events,"refractionSanity":refraction_sanity(),"reproduction":"CPU geometry/weight trace only; GPU similarity is not established","limitation":"Blue absorption is omitted, so weightMax/weight-finished does not equal GPU throughput termination."}
    (OUT/"one-ray-v2.json").write_text(json.dumps(result,indent=2)+"\n")
    print(json.dumps({"pixel":result["pixel"],"reason":reason,"events":len(events)},indent=2))
