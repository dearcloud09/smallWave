"""Prepare the same sampled cubic field used by the Cycles comparison.

No particle movement or shape fitting. A separable [1,4,1]/6 filter evaluates
the cubic B-spline at voxel centers; analytic clear spheres are then subtracted.
The Metal candidate linearly samples these values (an explicit approximation).
"""
from pathlib import Path
import numpy as np, json, hashlib, time
root=Path.cwd(); source=Path(__file__).read_bytes()
for index in (0,12,24,36,47):
    name=f'{index:03d}'; started=time.time()
    path=root/f'.build-cache/material-kernel-film/{name}/filtered.f16'
    statePath=root/f'.build-cache/material-motion/{name}/state.json'
    state=json.loads(statePath.read_text()); raw=path.read_bytes()
    a=np.frombuffer(raw,dtype='<f2').reshape(48,544,256).astype(np.float32)
    assert np.isfinite(a).all()
    for axis in (0,1,2):
        padding=[(0,0)]*3;padding[axis]=(1,1)
        p=np.pad(a,padding,mode='edge')
        slices=[slice(None)]*3;lo=slices.copy();mid=slices.copy();hi=slices.copy()
        lo[axis]=slice(0,-2);mid[axis]=slice(1,-1);hi[axis]=slice(2,None)
        a=(p[tuple(lo)]+4*p[tuple(mid)]+p[tuple(hi)])/6
    x=(-1+(np.arange(256,dtype=np.float32)+.5)*2/256)[None,None,:]
    y=(2.12-(np.arange(544,dtype=np.float32)+.5)*4.24/544)[None,:,None]
    z=(.18-(np.arange(48,dtype=np.float32)+.5)*.36/48)[:,None,None]
    for bx,by,bz,r in state['bubbles']:
        distance=np.sqrt((x-bx)**2+(y-by)**2+(z-bz)**2)
        a=np.minimum(a,.6+4*(distance-r))
    data=a.astype('<f2').tobytes();out=root/f'.build-cache/fast-material/{name}'
    out.mkdir(exist_ok=True,parents=True);(out/'field.f16').write_bytes(data)
    (out/'prepare.source.py').write_bytes(source)
    result={'index':index,'size':[256,544,48],'elapsedSeconds':time.time()-started,
            'method':'cubic samples at voxel centers; sampled analytic clear inclusions',
            'inputSHA256':hashlib.sha256(raw).hexdigest(),
            'stateSHA256':hashlib.sha256(statePath.read_bytes()).hexdigest(),
            'sourceSHA256':hashlib.sha256(source).hexdigest(),
            'fieldSHA256':hashlib.sha256(data).hexdigest(),
            'finite':bool(np.isfinite(a).all()),'appAdopted':False}
    (out/'prepare.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
