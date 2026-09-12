"""Conservative homogeneous-block bounds for the sampled trilinear field.

Each block spans four interpolation cells and includes all 5^3 corner samples.
Trilinear values are convex combinations of those samples. This permits skips
inside a homogeneous block; it does not approximate or move the liquid surface.
"""
from pathlib import Path
import numpy as np, json, hashlib, time
root=Path.cwd();source=Path(__file__).read_bytes()
for index in (0,12,24,36,47):
    out=root/f'.build-cache/fast-material/{index:03d}';started=time.time()
    fieldBytes=(out/'field.f16').read_bytes()
    a=np.frombuffer(fieldBytes,dtype='<f2').reshape(48,544,256)
    assert np.isfinite(a).all()
    padded=np.pad(a,((0,1),(0,1),(0,1)),mode='edge')
    lo=np.full((12,136,64),np.inf,dtype=np.float32);hi=-lo
    for z in range(5):
        for y in range(5):
            for x in range(5):
                q=padded[z:z+48:4,y:y+544:4,x:x+256:4]
                lo=np.minimum(lo,q);hi=np.maximum(hi,q)
    data=np.stack((lo,hi),axis=-1).astype('<f2').tobytes()
    decoded=np.frombuffer(data,dtype='<f2').reshape(12,136,64,2)
    assert np.isfinite(decoded).all() and (decoded[:,:,:,0]<=decoded[:,:,:,1]).all()
    # Separate scalar checks: includes edge blocks and random physical points.
    rng=np.random.default_rng(913+index)
    blocks=[(0,0,0),(11,135,63),(0,135,63),(11,0,0)]
    blocks+=list(zip(rng.integers(0,12,100),rng.integers(0,136,100),rng.integers(0,64,100)))
    for bz,by,bx in blocks:
        values=a[bz*4:min(bz*4+5,48),by*4:min(by*4+5,544),bx*4:min(bx*4+5,256)]
        assert decoded[bz,by,bx,0]==values.min() and decoded[bz,by,bx,1]==values.max()
    for _ in range(1000):
        grid=rng.uniform([-.5,-.5,-.5],[255.5,543.5,47.5]);base=np.floor(grid).astype(int);f=grid-base
        value=0.
        for z in range(2):
            for y in range(2):
                for x in range(2):
                    ix,iy,iz=np.clip(base+[x,y,z],[0,0,0],[255,543,47])
                    value+=float(a[iz,iy,ix])*(f[0] if x else 1-f[0])*(f[1] if y else 1-f[1])*(f[2] if z else 1-f[2])
        bx,by,bz=np.clip(np.floor(grid/4).astype(int),[0,0,0],[63,135,11])
        assert float(decoded[bz,by,bx,0])-1e-8<=value<=float(decoded[bz,by,bx,1])+1e-8
    (out/'bounds.f16').write_bytes(data);(out/'bounds.source.py').write_bytes(source)
    result={'frame':index,'dimensions':[64,136,12],'format':'RG16Float min/max',
            'sourceSHA256':hashlib.sha256(source).hexdigest(),'fieldSHA256':hashlib.sha256(fieldBytes).hexdigest(),
            'boundsSHA256':hashlib.sha256(data).hexdigest(),'scalarBlocksChecked':len(blocks),
            'trilinearPointsChecked':1000,'elapsedSeconds':time.time()-started,'checks':'PASS',
            'appAdopted':False}
    (out/'bounds.json').write_text(json.dumps(result,indent=2));print(json.dumps(result),flush=True)
