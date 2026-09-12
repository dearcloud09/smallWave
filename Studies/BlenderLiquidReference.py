"""Independent Cycles render of the exported frozen liquid mesh.

This is an offline material reference, never an iPhone renderer. Glass IOR is
relative to its surrounding clear medium, matching Cycles' per-surface IOR.
No external scene/assets/scripts are loaded.
"""
import bpy, math, json, hashlib, sys, time
from pathlib import Path
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
width=int(args[args.index('--width')+1]) if '--width' in args else 600
samples=int(args[args.index('--samples')+1]) if '--samples' in args else 64
vessel='--vessel' in args
shallow='--shallow-profile' in args
edgeLighting='--edge-lighting' in args
appBlue='--app-blue' in args
executedSource=Path(__file__).read_bytes()
folder=Path.cwd()/'.build-cache/material-blender'
name=('vessel' if vessel else 'internal')+('-shallow' if shallow else '')+('-edge-light' if edgeLighting else '')+('-app-blue' if appBlue else '')+f'-{width}'
meshPath=folder/('liquid-shallow.ply' if shallow else 'liquid.ply')
sourceSnapshot=folder/(name+'.source.py')
sourceSnapshot.write_bytes(executedSource)
started=time.time()
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
scene=bpy.context.scene
scene.render.engine='CYCLES';scene.cycles.device='CPU';scene.cycles.samples=samples
scene.cycles.use_denoising=True
scene.cycles.max_bounces=64;scene.cycles.transmission_bounces=64;scene.cycles.glossy_bounces=64
scene.cycles.diffuse_bounces=4;scene.cycles.volume_bounces=0
scene.cycles.transparent_max_bounces=64;scene.cycles.seed=723
scene.cycles.sample_clamp_direct=0;scene.cycles.sample_clamp_indirect=0
scene.cycles.blur_glossy=0;scene.cycles.caustics_reflective=True;scene.cycles.caustics_refractive=True
scene.render.threads_mode='FIXED';scene.render.threads=6
scene.render.resolution_x=width;scene.render.resolution_y=round(width*2.12);scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA';scene.render.image_settings.color_depth='8'
scene.view_settings.view_transform='Standard';scene.view_settings.look='None';scene.view_settings.exposure=0;scene.view_settings.gamma=1
scene.world.color=(0,0,0);scene.world.use_nodes=True
scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(0,0,0,1)
scene.render.film_transparent=False

def material(name):
    m=bpy.data.materials.new(name);m.use_nodes=True;m.node_tree.nodes.clear()
    out=m.node_tree.nodes.new('ShaderNodeOutputMaterial')
    return m,out

def emission(name,color):
    m,out=material(name);n=m.node_tree.nodes.new('ShaderNodeEmission')
    n.inputs['Color'].default_value=(*color,1);n.inputs['Strength'].default_value=1
    m.node_tree.links.new(n.outputs[0],out.inputs['Surface']);return m

def quad(name,verts,mat):
    mesh=bpy.data.meshes.new(name);mesh.from_pydata(verts,[],[(0,1,2,3)]);mesh.update()
    obj=bpy.data.objects.new(name,mesh);scene.collection.objects.link(obj);obj.data.materials.append(mat);return obj

def glass(name,ior,dye=None):
    m,out=material(name);n=m.node_tree.nodes.new('ShaderNodeBsdfGlass')
    n.inputs['Color'].default_value=(1,1,1,1);n.inputs['Roughness'].default_value=0
    n.inputs['IOR'].default_value=ior
    assert abs(n.inputs['IOR'].default_value-ior)<1e-6, 'IOR unexpectedly clamped'
    m.node_tree.links.new(n.outputs[0],out.inputs['Surface'])
    if dye:
        # Blender5.0.1 kernel/svm/closure.h: absorption=(1-color)*density.
        absorb=m.node_tree.nodes.new('ShaderNodeVolumeAbsorption');scale=max(dye)
        absorb.inputs['Color'].default_value=(*(1-v/scale for v in dye),1)
        absorb.inputs['Density'].default_value=scale
        m.node_tree.links.new(absorb.outputs[0],out.inputs['Volume'])
    return m

reference=(.025,.18,.72) if appBlue else (.0001,.075,.96);coefficients=[-math.log(c)*.72/.24 for c in reference]
bpy.ops.wm.ply_import(filepath=str(meshPath))
liquid=bpy.context.object;liquid.name='Frozen liquid — same field, meshed interpolation'
liquid.data.materials.clear();liquid.data.materials.append(glass('Blue in clear',1.333/1.46,coefficients))
for polygon in liquid.data.polygons:polygon.use_smooth=True
if vessel:
    bpy.ops.mesh.primitive_cube_add(size=2,location=(0,0,0))
    box=bpy.context.object;box.name='Clear containing medium'
    box.scale=(1.008,2.128,.188)
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True)
    box.data.materials.append(glass('Clear to air',1.46))

# Same world-space emissive room as SharedStudio, not a scenic background.
rear,out=material('Rear radiance card')
nodes=rear.node_tree.nodes;links=rear.node_tree.links
geo=nodes.new('ShaderNodeNewGeometry');sep=nodes.new('ShaderNodeSeparateXYZ');links.new(geo.outputs['Position'],sep.inputs[0])
mult=nodes.new('ShaderNodeMath');mult.operation='MULTIPLY';mult.inputs[1].default_value=.4;links.new(sep.outputs['Y'],mult.inputs[0])
add=nodes.new('ShaderNodeMath');add.operation='ADD';links.new(sep.outputs['X'],add.inputs[0]);links.new(mult.outputs[0],add.inputs[1])
rng=nodes.new('ShaderNodeMapRange');rng.interpolation_type='SMOOTHSTEP';rng.clamp=True
for key,value in [('From Min',-1.7),('From Max',1.4),('To Min',.67),('To Max',.97)]:rng.inputs[key].default_value=value
links.new(add.outputs[0],rng.inputs['Value'])
em=nodes.new('ShaderNodeEmission');em.inputs['Color'].default_value=(.965,.982,1,1);links.new(rng.outputs[0],em.inputs['Strength']);links.new(em.outputs[0],out.inputs['Surface'])
quad('Rear',[(-3,-2.3,-1.2),(3,-2.3,-1.2),(3,4,-1.2),(-3,4,-1.2)],rear)
quad('Front',[(-3,-2.3,2.4),(3,-2.3,2.4),(3,4,2.4),(-3,4,2.4)],emission('Front ambient',(.018,.025,.034)))
keyLeft,keyRight=(-2.2,-1.5) if edgeLighting else (-1.39,-.31)
quad('Key',[(keyLeft,-.65,2.399),(keyRight,-.65,2.399),(keyRight,2.35,2.399),(keyLeft,2.35,2.399)],emission('Key radiance',(3.018,2.935,2.824)))
quad('Fill',[(1.03,-1.85,2.398),(1.27,-1.85,2.398),(1.27,1.45,2.398),(1.03,1.45,2.398)],emission('Fill radiance',(1.368,1.465,1.534)))
quad('Floor',[(-3,-2.3,-1.2),(3,-2.3,-1.2),(3,-2.3,2.4),(-3,-2.3,2.4)],emission('Floor radiance',(.22,.27,.31)))
quad('Top',[(-3,4,-1.2),(3,4,-1.2),(3,4,2.4),(-3,4,2.4)],emission('Top radiance',(.86,.89,.94)))
for x in (-3,3):quad(f'Side {x}',[(x,-2.3,-1.2),(x,4,-1.2),(x,4,2.4),(x,-2.3,2.4)],emission(f'Side radiance {x}',(.065,.085,.105)))
bpy.ops.object.camera_add(location=(0,0,.4))
camera=bpy.context.object;camera.rotation_euler=(0,0,0);camera.data.type='ORTHO';camera.data.ortho_scale=4.24
camera.data.clip_start=.001;camera.data.clip_end=100;scene.camera=camera
scene.render.filepath=str(folder/(name+'.png'))
bpy.ops.wm.save_as_mainfile(filepath=str(folder/(name+'.blend')))
print('REFERENCE_RENDER_START',name,flush=True)
bpy.ops.render.render(write_still=True)
manifest={'blender':bpy.app.version_string,'engine':'Cycles CPU','renderSeconds':time.time()-started,'width':width,'height':scene.render.resolution_y,'samples':samples,'denoised':True,'maxBounces':64,'appAdopted':False,'vessel':vessel,'shallowProfile':shallow,'edgeLighting':edgeLighting,'appBlue':appBlue,'blueRelativeIOR':1.333/1.46,'referenceTransmission':reference,'absorptionCoefficients':coefficients,'meshVertices':len(liquid.data.vertices),'meshFaces':len(liquid.data.polygons),'differencesFromMetal':['linear triangles through cubic field samples; smooth mesh normals','bubbles represented by sampled mesh','boat and post-frame absent','sharp edges on matched light cards','Cycles stochastic multi-bounce transport with finite64bounce cap','Standard sRGB display; Metal uses approximate exponent2.2']}
manifest['hashes']={str(p.relative_to(Path.cwd())):hashlib.sha256(p.read_bytes()).hexdigest() for p in [meshPath,sourceSnapshot,folder/(name+'.png')]}
(folder/(name+'.json')).write_text(json.dumps(manifest,indent=2))
print('REFERENCE_RENDER_DONE',json.dumps(manifest),flush=True)
