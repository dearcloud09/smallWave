"""Render an actual frozen app state in the calibrated studio.

Offline geometry/material comparison; not the app renderer or realtime proof.
Loads only the locally created calibration scene and verified PLY/state inputs.
"""
import bpy, bmesh, sys, json, hashlib, time, math
from pathlib import Path
from mathutils import Vector, Matrix

args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
width=int(args[args.index('--width')+1]) if '--width' in args else 900
samples=int(args[args.index('--samples')+1]) if '--samples' in args else 96
front='--front' in args
root=Path.cwd(); out=root/'.build-cache/toy-calibration'
name=f'frozen-{("front" if front else "perspective")}-{width}-{samples}'
template=out/'front-rounded-1100-96.blend'
meshPath=root/'.build-cache/material-blender/liquid.ply'
statePath=root/'.build-cache/material-motion/000/state.json'
snapshot=out/(name+'.source.py'); snapshot.write_bytes(Path(__file__).read_bytes())
inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (template,meshPath,statePath,snapshot)}
assert inputs[str(meshPath)]=='c1f103c7dfbdd3a8eaba59346810c3fe3fff17310bf7d65eb82477db2140d0c5'
started=time.time()
bpy.ops.wm.open_mainfile(filepath=str(template),load_ui=False,use_scripts=False)
scene=bpy.context.scene
state=json.loads(statePath.read_text())
oldLiquid=bpy.data.objects['Connected blue liquid']; blue=oldLiquid.data.materials[0]
bpy.data.objects.remove(oldLiquid,do_unlink=True)
bpy.ops.wm.ply_import(filepath=str(meshPath))
liquid=bpy.context.object; liquid.name='Frozen app liquid'
# Proper rotation: app X/Y/Z -> studio X/-Z/Y. No shape rescaling or smoothing.
liquid.data.transform(Matrix(((1,0,0,0),(0,0,-1,0),(0,1,0,0),(0,0,0,1))))
liquid.data.materials.clear(); liquid.data.materials.append(blue)
for p in liquid.data.polygons: p.use_smooth=True
bm=bmesh.new();bm.from_mesh(liquid.data)
nonmanifold=sum(not e.is_manifold for e in bm.edges);volume=bm.calc_volume(signed=True);bm.free()
assert nonmanifold==0 and volume>0

def resize(name,dims,z=0):
    o=bpy.data.objects[name];o.dimensions=dims;o.location=(0,0,z)
    # These are already beveled closed objects; resizing changes their tiny
    # edge bevel proportions too, which is recorded as a comparison limit.
resize('Outer transparent vessel',(2.048,.408,4.288))
resize('Clear liquid filling',(2.016,.376,4.256))
resize('Deep blue base',(2.068,.428,.035),-2.14)
bpy.data.objects['Studio table'].location.z=-2.2175

# Move the stand-in miniature to the recorded boat state; its model is not
# the production 2D artwork. The recorded hull datum, depth and angle are used.
oldHull=bpy.data.objects['Miniature hull stand-in']
origin=oldHull.location.copy();origin.z+=.012
boatParts=[o for o in scene.objects if o.name in (
    'Miniature hull stand-in','Miniature deck stand-in','Main sail stand-in',
    'Small sail stand-in','Cylinder')]
parent=bpy.data.objects.new('Recorded boat pose',None);scene.collection.objects.link(parent)
for o in boatParts:
    matrix=o.matrix_world.copy(); matrix.translation-=origin
    o.parent=parent;o.matrix_parent_inverse=Matrix.Identity(4);o.matrix_basis=matrix
bx,bz,angle,depth=state['boat'];parent.location=(bx,-depth,bz);parent.rotation_euler[1]=-angle

def aim(o,target):o.rotation_euler=(Vector(target)-o.location).to_track_quat('-Z','Y').to_euler()
camera=scene.camera
camera.location=(0,-9.9,0) if front else (2.7,-9.4,2.0)
camera.data.type='PERSP';camera.data.lens=65;aim(camera,(0,0,0))
scene.render.resolution_x=width;scene.render.resolution_y=round(width*2.12)
scene.cycles.samples=samples
scene.render.filepath=str(out/(name+'.png'))
bpy.ops.wm.save_as_mainfile(filepath=str(out/(name+'.blend')))
print('FROZEN_CALIBRATION_START',name,flush=True)
bpy.ops.render.render(write_still=True)
imageHash=hashlib.sha256((out/(name+'.png')).read_bytes()).hexdigest()
result={'artifact':'offline material render of frozen app fluid geometry',
        'actualSimulationState':True,'liveSimulation':False,'appBuild':False,
        'inputSHA256':inputs,'imageSHA256':imageHash,'blender':bpy.app.version_string,
        'width':width,'height':scene.render.resolution_y,'samples':samples,
        'elapsedSeconds':time.time()-started,'nonManifoldEdges':nonmanifold,
        'blueVolume':volume,'vertices':len(liquid.data.vertices),'faces':len(liquid.data.polygons),
        'shapeTransform':'proper rigid rotation X/-Z/Y; no rescale',
        'limitations':['Meshed interpolation of fixed GPU field with .009 clear wall film',
                       'Studio and clear/acrylic interfaces differ from production renderer',
                       'Beveled vessel geometry resized to phone volume',
                       'Generic miniature moved to recorded pose, not production boat asset',
                       'Offline finite-bounce Cycles render, denoised; no performance inference'],
        'phoneValidation':'NOT_RUN'}
(out/(name+'.json')).write_text(json.dumps(result,indent=2))
print('FROZEN_CALIBRATION_DONE',json.dumps(result),flush=True)
