"""Positive and negative geometric fixtures for the topology checker itself."""
import json
import subprocess
from pathlib import Path
import numpy as np

folder = Path('.build-cache/particle-surface/validator-fixture')
folder.mkdir(exist_ok=True)
width, height, layers = 256, 544, 48
x = ((np.arange(width)+.5)*2/width-1)[None,None,:]
y = (2.12-(np.arange(height)+.5)*4.24/height)[None,:,None]
z = (.18-(np.arange(layers)+.5)*.36/layers)[:,None,None]
cases = [('one',[-.3],[-.3],[0],True),
         ('separate',[-.3,.3],[-.3,.3],[0,1],True),
         ('merged',[-.03,.03],[-.03,.03],[0,1],False),
         ('unseeded',[-.3,.3],[-.3],[0],False),
         ('split',[-.3,.3],[-.3,.3],[0,0],False),
         ('absent',[-.3],[.3],[0],False)]
results = []
for name,centers,seeds,groups,expected in cases:
    phi = np.full((layers,height,width),2.,dtype=np.float32)
    for cx in centers:
        np.minimum(phi,np.sqrt((x-cx)**2+y*y+z*z)-.075,out=phi)
    phi.astype('<f4').tofile(folder/'phi.f32')
    np.asarray([[v,0,0] for v in seeds],dtype='<f4').tofile(folder/'particles.f32')
    np.asarray(groups,dtype='<i4').tofile(folder/'particle-components.i32')
    run = subprocess.run(['.build-cache/particle-surface/topology-check',str(folder)],capture_output=True,text=True)
    record = json.loads((folder/'topology.json').read_text())
    assert record['pass']==expected and run.returncode==(0 if expected else 2),(name,run.stdout,run.stderr)
    results.append({'fixture':name,'expectedPass':expected,'observed':record})
    print('PASS validator fixture',name,flush=True)
Path('.build-cache/particle-surface/validator-checks.json').write_text(json.dumps(results,indent=2))
