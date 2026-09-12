"""Offline Zhu–Bridson component surface from a frozen, real app state.

Not a new fluid solver or exact signed-distance field. Original paper section 5:
https://cg.informatik.uni-freiburg.de/intern/seminar/surfaceReconstruction_zhu-siggraph05-sandfluid.pdf
Component-local radii fit nominal blue volume, with explicit topology vetoes in
ParticleSurfaceCheck.cpp. Only real positions enter the weighted center. The
surface is intersected with the actual vessel; no ghost centers or curvature flow.
"""
import hashlib
import json
import sys
import time
from pathlib import Path
import numpy as np

source = Path(sys.argv[1])
folder = Path(sys.argv[2])
folder.mkdir(parents=True, exist_ok=True)
began = time.monotonic()
state = json.loads(source.read_text())
points = np.asarray(state['particles'], dtype=np.float32)
spacing = float(state['spacing'])
support = 2 * spacing
hard_wall_film = '--hard-wall-film' in sys.argv[3:]
wall_film = '--wall-film' in sys.argv[3:] or hard_wall_film
film_depth = 0.009
join_width = 0.025
nx, ny, nz = 256, 544, 48
dx, dy, dz = 2 / nx, 4.24 / ny, .36 / nz
voxel_volume = dx * dy * dz
x = ((np.arange(nx, dtype=np.float32) + .5) * dx - 1)
y = (2.12 - (np.arange(ny, dtype=np.float32) + .5) * dy)
z = (.18 - (np.arange(nz, dtype=np.float32) + .5) * dz)

def surface(distance, radius, local_z):
    value = distance-radius
    if wall_film:
        # A prescribed clear coating, not a measured wetting/contact-angle law.
        # This rounds the join between the particle surface and the depth wall
        # in geometry; the lighting shader still sees one coherent scalar field.
        wall = np.abs(local_z[:,None,None])-(.18-film_depth)
        if hard_wall_film:
            value = np.maximum(value,wall)
        else:
            h = np.maximum(join_width-np.abs(value-wall),0)/join_width
            value = np.maximum(value,wall)+h*h*(join_width*.25)
    return value

# The graph is a conservative diagnostic definition, not a physical contact law.
parent = list(range(len(points)))
def root(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i
for i in range(len(points)):
    distance2 = np.sum((points[i+1:] - points[i]) ** 2, axis=1)
    for j in np.flatnonzero(distance2 < (1.4 * spacing) ** 2) + i + 1:
        a, b = root(i), root(int(j))
        if a != b:
            parent[b] = a
groups = {}
for i in range(len(points)):
    groups.setdefault(root(i), []).append(i)
groups = sorted(groups.values(), key=lambda g: (-len(g), g[0]))
print('Particle components:', [len(g) for g in groups], flush=True)

# Live scratch is bounded by one eight-layer tile, not four full XYZ volumes.
phi = np.full((nz, ny, nx), 2.0, dtype=np.float32)
clear = np.zeros_like(phi, dtype=bool)
for bx, by, bz, radius in state['bubbles']:
    for lo in range(0, nz, 8):
        zz = z[lo:lo+8, None, None]
        d2 = (x[None,None,:]-bx)**2 + (y[None,:,None]-by)**2 + (zz-bz)**2
        clear[lo:lo+8] |= d2 < radius**2
stats = []
seed_labels = np.empty(len(points), dtype=np.int32)
for component, ids in enumerate(groups):
    seed_labels[ids] = component
    samples = points[ids]
    # Mirrored centers can average into a fictitious second drop at the wall,
    # even for ONE real particle. Pressure boundary support is not fluid geometry.
    xi = np.flatnonzero((x >= points[ids,0].min()-support) & (x <= points[ids,0].max()+support))
    yi = np.flatnonzero((y >= points[ids,1].min()-support) & (y <= points[ids,1].max()+support))
    zi = np.flatnonzero((z >= samples[:,2].min()-support) & (z <= samples[:,2].max()+support))
    if not (len(xi) and len(yi) and len(zi)):
        raise RuntimeError('Component left vessel')
    xs, ys, zs = slice(xi[0],xi[-1]+1), slice(yi[0],yi[-1]+1), slice(zi[0],zi[-1]+1)
    shape = (len(zi), len(yi), len(xi))
    distance = np.full(shape, 2.0, dtype=np.float32)
    for lo in range(0, len(zi), 8):
        zz = z[zi[lo:lo+8],None,None]
        yy, xx = y[yi][None,:,None], x[xi][None,None,:]
        tile_shape = (len(zz),len(yi),len(xi))
        weight = np.zeros(tile_shape, dtype=np.float32)
        sx = np.zeros_like(weight); sy = np.zeros_like(weight); sz = np.zeros_like(weight)
        relevant = samples[(samples[:,2] >= zz.min()-support) & (samples[:,2] <= zz.max()+support)]
        for px, py, pz in relevant:
            lx = np.flatnonzero(np.abs(x[xi]-px)<support)
            ly = np.flatnonzero(np.abs(y[yi]-py)<support)
            if not (len(lx) and len(ly)):
                continue
            ix, iy = slice(lx[0],lx[-1]+1), slice(ly[0],ly[-1]+1)
            r2 = ((xx[:,:,ix]-px)**2+(yy[:,iy,:]-py)**2+(zz-pz)**2)/(support*support)
            w = np.maximum(0,1-r2)**3
            slot = (slice(None),iy,ix)
            weight[slot] += w; sx[slot] += w*px; sy[slot] += w*py; sz[slot] += w*pz
        valid = weight > 1e-8
        np.maximum(weight,1e-8,out=weight)
        sx /= weight; sy /= weight; sz /= weight
        value = np.sqrt((xx-sx)**2+(yy-sy)**2+(zz-sz)**2)
        distance[lo:lo+8] = np.where(valid,value,2.0)
    nominal = len(ids)*spacing**3
    active = ~clear[zs,ys,xs]
    low, high = spacing*.25, spacing*1.5
    vlo = np.count_nonzero((surface(distance,low,z[zi])<0)&active)*voxel_volume
    vhi = np.count_nonzero((surface(distance,high,z[zi])<0)&active)*voxel_volume
    # The original fixed search ceiling failed during the settling sequence
    # while still inside the reconstruction kernel's support. Extend only the
    # numerical bracket, never beyond that support; retain the resulting radius
    # for temporal/shape evaluation. A fitted volume is not an adoption pass.
    while vhi < nominal and high < support:
        high = min(support,high+spacing*.125)
        vhi = np.count_nonzero((surface(distance,high,z[zi])<0)&active)*voxel_volume
    bracket_high=high
    if not vlo <= nominal <= vhi:
        raise RuntimeError(f'Cannot bracket volume for {component}: {vlo}, {nominal}, {vhi}')
    best = None
    for iteration in range(8):
        radius = (low+high)*.5
        volume = np.count_nonzero((surface(distance,radius,z[zi])<0)&active)*voxel_volume
        error = abs(volume-nominal)
        if best is None or error < best[0]:
            best = (error,radius,volume)
        if volume < nominal:
            low = radius
        else:
            high = radius
    error, radius, volume = best
    phi[zs,ys,xs] = np.minimum(phi[zs,ys,xs], surface(distance,radius,z[zi]))
    stats.append({'component':component,'particles':len(ids),'radius':radius,'nominal':nominal,
                  'voxelVolume':volume,'relativeVolumeError':error/nominal,'bracketHigh':bracket_high})
    print(f'Component {component}: n={len(ids)}, r={radius:.6f}, volume error={error/nominal:.3%}', flush=True)
    del distance

# Preserve the outer liquid field for exact analytic bubble queries. Carving
# before interpolation distorts near-grazing spherical optical boundaries.
np.maximum(.6-phi*4,0).astype('<f2').tofile(folder/'volume-uncarved.f16')
# Same existing clear bubble spheres; blue volume fitting already excludes them.
for bx,by,bz,radius in state['bubbles']:
    for lo in range(0,nz,8):
        d = np.sqrt((x[None,None,:]-bx)**2+(y[None,:,None]-by)**2+(z[lo:lo+8,None,None]-bz)**2)
        phi[lo:lo+8] = np.maximum(phi[lo:lo+8],radius-d)
assert np.isfinite(phi).all()
phi.astype('<f4').tofile(folder/'phi.f32')
# Existing renderer's scalar/gradient/phase all use the same smooth field.
np.maximum(.6-phi*4,0).astype('<f2').tofile(folder/'volume.f16')
points.astype('<f4').tofile(folder/'particles.f32')
seed_labels.astype('<i4').tofile(folder/'particle-components.i32')
nominal = len(points)*spacing**3
occupied = np.count_nonzero(phi<0)*voxel_volume
report = {'algorithm':'component-local Zhu-Bridson; 8 radius bisections, real centers only, vessel intersection, no curvature flow',
          'prescribedWallFilm':{'enabled':wall_film,'depth':film_depth,'joinWidth':0 if hard_wall_film else join_width,'measured':False},
          'shape':[nx,ny,nz],'spacing':spacing,'components':stats,'nominalVolume':nominal,
          'unionVoxelVolume':occupied,'unionRelativeVolumeError':abs(occupied-nominal)/nominal,
          'voxelVolume':voxel_volume,'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
          'scriptSHA256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'seconds':time.monotonic()-began,'adopted':False,'topologyCheck':'NOT_RUN',
          'volumeCaveat':'Nominal Nm/rho0 is a constraint, not a measured exact instantaneous physical volume. Voxel quadrature error is separate.'}
(folder/'reconstruction.json').write_text(json.dumps(report,indent=2))
print('Reconstructed in',report['seconds'],'seconds; topology and visual checks pending',flush=True)
