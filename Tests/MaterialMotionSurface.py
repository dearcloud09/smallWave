"""Build diagnostic geometry for the frozen 48-frame material sequence."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time
import numpy as np

root=Path('.build-cache/material-motion')
began=time.monotonic()
records=[]
previous_radii=None
for index in range(48):
    folder=root/f'{index:03d}'
    result=subprocess.run([sys.executable,'Studies/ParticleSurface.py',str(folder/'state.json'),str(folder),'--hard-wall-film'],capture_output=True,text=True)
    (folder/'reconstruction.log').write_text(result.stdout+result.stderr)
    if result.returncode:
        raise RuntimeError(f'Reconstruction {index}: {result.stderr}')
    test=subprocess.run(['.build-cache/particle-surface/topology-check',str(folder)],capture_output=True,text=True)
    (folder/'topology.log').write_text(test.stdout+test.stderr)
    if test.returncode not in (0,2):
        raise RuntimeError(f'Invalid topology run {index}: {test.stdout} {test.stderr}')
    reconstruction=json.loads((folder/'reconstruction.json').read_text())
    topology=json.loads((folder/'topology.json').read_text())
    labels=np.fromfile(folder/'particle-components.i32',dtype='<i4')
    radii=np.array([c['radius'] for c in reconstruction['components']])[labels]
    delta=0 if previous_radii is None else float(np.max(np.abs(radii-previous_radii)))
    previous_radii=radii
    record={'frame':index,'mainRadius':reconstruction['components'][0]['radius'],
            'componentSizes':[c['particles'] for c in reconstruction['components']],
            'maximumPerParticleRadiusChange':delta,'topologyPass':topology['pass'],
            'nominalVolumeError':reconstruction['unionRelativeVolumeError'],
            'rawVolumeSHA256':hashlib.sha256((folder/'volume-uncarved.f16').read_bytes()).hexdigest()}
    records.append(record)
    # Keep complete intermediate fields at five checkpoints; every actual
    # rendering input, state, checker report and reconstruction log is retained.
    if index not in (0,12,24,36,47):
        (folder/'phi.f32').unlink()
        (folder/'volume.f16').unlink()
    print(f'{index:03d}: groups={record["componentSizes"]}, radiusDelta={delta:.6f}, topologyPass={topology["pass"]}',flush=True)
report={'frames':records,'seconds':time.monotonic()-began,'fps':24,'adopted':False,
        'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'builderSHA256':hashlib.sha256(Path('Studies/ParticleSurface.py').read_bytes()).hexdigest()}
(root/'surfaces.json').write_text(json.dumps(report,indent=2))
print('DONE diagnostic geometry;',report['seconds'],'seconds',flush=True)
