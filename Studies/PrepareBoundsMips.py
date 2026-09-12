"""Reduce validated cell bounds without modifying the liquid field.

Each parent min/max covers the union of eight children. Direct voxel checks
also verify its full 9^3 or 17^3 support, including clamped edge blocks.
"""
from pathlib import Path
import hashlib, json
import numpy as np

root=Path.cwd(); source=Path(__file__).read_bytes()
for index in (0,12,24,36,47):
    folder=root/f'.build-cache/fast-material/{index:03d}'
    field=np.frombuffer((folder/'field.f16').read_bytes(),dtype='<f2').reshape(48,544,256)
    raw=(folder/'bounds.f16').read_bytes()
    bounds=np.frombuffer(raw,dtype='<f2').reshape(12,136,64,2)
    records=[];rng=np.random.default_rng(729+index)
    for level in (1,2):
        z,y,x,_=bounds.shape
        child=bounds.reshape(z//2,2,y//2,2,x//2,2,2)
        lo=child[...,0].min(axis=(1,3,5));hi=child[...,1].max(axis=(1,3,5))
        bounds=np.stack((lo,hi),axis=-1).astype('<f2')
        assert np.isfinite(bounds).all() and np.all(bounds[...,0]<=bounds[...,1])
        z,y,x,_=bounds.shape;cells=4*(2**level)
        blocks=[(0,0,0),(z-1,y-1,x-1)]+list(zip(rng.integers(z,size=64),rng.integers(y,size=64),rng.integers(x,size=64)))
        for bz,by,bx in blocks:
            nodes=field[bz*cells:min((bz+1)*cells+1,48),by*cells:min((by+1)*cells+1,544),bx*cells:min((bx+1)*cells+1,256)]
            assert bounds[bz,by,bx,0]==nodes.min()
            assert bounds[bz,by,bx,1]==nodes.max()
        data=bounds.tobytes();(folder/f'bounds-l{level}.f16').write_bytes(data)
        records.append({'level':level,'dimensions':[x,y,z],'cellsPerBlock':cells,'directVoxelBlocks':len(blocks),'SHA256':hashlib.sha256(data).hexdigest()})
    report={'frame':index,'checks':'PASS','sourceSHA256':hashlib.sha256(source).hexdigest(),'baseBoundsSHA256':hashlib.sha256(raw).hexdigest(),'levels':records,'appAdopted':False}
    (folder/'bounds-mips.source.py').write_bytes(source)
    (folder/'bounds-mips.json').write_text(json.dumps(report,indent=2))
    print(json.dumps(report),flush=True)
