"""Offline reconstruction check, not a simulation mass-conservation test.

Validates the B-spline derivative with finite differences and quantifies the
change to sampled occupancy. GPU AOVs remain the actual rendered evidence.
"""
from pathlib import Path
import hashlib, json
import numpy as np

root = Path.cwd()
raw = (root / '.build-cache/fast-material/000/field.f16').read_bytes()
a = np.frombuffer(raw, dtype='<f2').reshape(48,544,256).astype(np.float64)
def weights(t):
    return np.array([(1-t)**3,3*t**3-6*t*t+4,-3*t**3+3*t*t+3*t+1,t**3])/6
def derivative(t):
    return np.array([-.5*(1-t)**2,1.5*t*t-2*t,-1.5*t*t+t+.5,.5*t*t])
def evaluate(grid):
    base = np.floor(grid).astype(int)-1
    f = grid-np.floor(grid)
    w = [weights(t) for t in f]; d = [derivative(t) for t in f]
    value = 0.; gradient = np.zeros(3)
    for z in range(4):
        for y in range(4):
            for x in range(4):
                ix,iy,iz = np.clip(base+[x,y,z],[0,0,0],[255,543,47])
                c = a[iz,iy,ix]
                value += c*w[0][x]*w[1][y]*w[2][z]
                gradient += c*np.array([d[0][x]*w[1][y]*w[2][z],w[0][x]*d[1][y]*w[2][z],w[0][x]*w[1][y]*d[2][z]])
    return value,gradient

rng = np.random.default_rng(919)
points = rng.uniform([-.49,-.49,-.49],[255.49,543.49,47.49],(96,3))
max_error = 0.
for q in points:
    value,g = evaluate(q)
    for axis in range(3):
        offset = np.eye(3)[axis]*1e-4
        fd = (evaluate(q+offset)[0]-evaluate(q-offset)[0])/2e-4
        max_error = max(max_error,abs(fd-g[axis]))
assert max_error < 1e-6, max_error
# At each knot, the left and right derivatives must approach the same limit.
knot_error = 0.
for q in points[:24]:
    for axis in range(3):
        knot = q.copy(); knot[axis] = round(knot[axis])
        offset = np.eye(3)[axis]*1e-6
        knot_error = max(knot_error,float(np.max(np.abs(evaluate(knot-offset)[1]-evaluate(knot+offset)[1]))))
assert knot_error < 1e-5, knot_error
b = a.copy()
for axis in range(3):
    padding=[(0,0)]*3; padding[axis]=(1,1)
    p=np.pad(b,padding,mode='edge'); slices=[slice(None)]*3
    lo=slices.copy(); mid=slices.copy(); hi=slices.copy()
    lo[axis]=slice(0,-2);mid[axis]=slice(1,-1);hi[axis]=slice(2,None)
    b=(p[tuple(lo)]+4*p[tuple(mid)]+p[tuple(hi)])/6
voxel_volume=2*4.24*.36/(256*544*48)
original_count=int(np.count_nonzero(a>.6)); candidate_count=int(np.count_nonzero(b>.6))
report={'finiteDifferencePoints':96,'maxGridDerivativeError':max_error,
        'knotChecks':72,'maxKnotGradientDelta':knot_error,
        'originalCenterSampleOccupancyVolume':original_count*voxel_volume,
        'cubicCenterSampleOccupancyVolume':candidate_count*voxel_volume,
        'centerSampleVolumeRelativeChange':candidate_count/original_count-1,
        'fieldSHA256':hashlib.sha256(raw).hexdigest(),
        'checkSourceSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'shaderSHA256':hashlib.sha256((root/'Studies/FastMaterial.metal').read_bytes()).hexdigest(),
        'checks':'PASS','massConservationClaim':False,'appAdopted':False}
out=root/'.build-cache/fast-material/continuous-check';out.mkdir(exist_ok=True)
(out/'check.source.py').write_bytes(Path(__file__).read_bytes())
(out/'check.json').write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
