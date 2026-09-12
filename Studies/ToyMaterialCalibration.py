"""Art-directed material calibration, not a fluid simulation or app build.

A continuous wave, clear inclusions and a miniature in a sealed transparent
vessel. Dimensions, IOR and illumination are prescribed visual assumptions.
No external assets or startup scripts are loaded. Blender 5.0.1 / Cycles CPU.
"""
import bpy, bmesh, math, json, hashlib, sys, time
from pathlib import Path
from mathutils import Vector
args=sys.argv[sys.argv.index('--')+1:] if '--' in sys.argv else []
width=int(args[args.index('--width')+1]) if '--width' in args else 1100
samples=int(args[args.index('--samples')+1]) if '--samples' in args else 96
front='--front' in args
rounded='--rounded' in args
out=Path.cwd()/'.build-cache/toy-calibration';out.mkdir(exist_ok=True)
name=('front' if front else 'perspective')+('-rounded' if rounded else '')+f'-{width}-{samples}'
source=Path(__file__).read_bytes();snapshot=out/(name+'.source.py');snapshot.write_bytes(source)
started=time.time()
bpy.ops.object.select_all(action='SELECT');bpy.ops.object.delete(use_global=False)
scene=bpy.context.scene;scene.render.engine='CYCLES';scene.cycles.device='CPU'
scene.cycles.samples=samples;scene.cycles.use_denoising=True;scene.cycles.seed=719
scene.cycles.max_bounces=48;scene.cycles.transmission_bounces=48;scene.cycles.glossy_bounces=32
scene.cycles.diffuse_bounces=4;scene.cycles.volume_bounces=0;scene.cycles.transparent_max_bounces=48
scene.cycles.caustics_reflective=True;scene.cycles.caustics_refractive=True
scene.cycles.sample_clamp_direct=0;scene.cycles.sample_clamp_indirect=0
scene.render.threads_mode='FIXED';scene.render.threads=6
scene.render.resolution_x=width;scene.render.resolution_y=round(width*.60);scene.render.resolution_percentage=100
scene.render.image_settings.file_format='PNG';scene.render.image_settings.color_mode='RGBA';scene.render.image_settings.color_depth='8'
scene.view_settings.view_transform='AgX';scene.view_settings.look='AgX - Medium High Contrast'
scene.view_settings.exposure=0;scene.view_settings.gamma=1
scene.world.use_nodes=True;scene.world.node_tree.nodes['Background'].inputs['Color'].default_value=(.82,.88,.95,1)
scene.world.node_tree.nodes['Background'].inputs['Strength'].default_value=.22

materials={}
def mat(name,color,rough=.3):
    m=bpy.data.materials.new(name);m.use_nodes=True
    p=m.node_tree.nodes.get('Principled BSDF');p.inputs['Base Color'].default_value=(*color,1);p.inputs['Roughness'].default_value=rough
    materials[name]={'color':color,'roughness':rough};return m

def glass(name,ior,transmission=None):
    m=bpy.data.materials.new(name);m.use_nodes=True;nodes=m.node_tree.nodes;nodes.clear()
    output=nodes.new('ShaderNodeOutputMaterial');g=nodes.new('ShaderNodeBsdfGlass')
    g.inputs['Color'].default_value=(1,1,1,1);g.inputs['Roughness'].default_value=0;g.inputs['IOR'].default_value=ior
    assert abs(g.inputs['IOR'].default_value-ior)<1e-6
    m.node_tree.links.new(g.outputs[0],output.inputs['Surface'])
    if transmission:
        # Relative transmission at .32 depth. Pure absorption, no milky scatter.
        coeff=[-math.log(v)/.32 for v in transmission];scale=max(coeff)
        a=nodes.new('ShaderNodeVolumeAbsorption');a.inputs['Color'].default_value=(*(1-v/scale for v in coeff),1);a.inputs['Density'].default_value=scale
        m.node_tree.links.new(a.outputs[0],output.inputs['Volume'])
    materials[name]={'relativeIOR':ior,'transmissionAtDepth0.32':transmission}
    return m

def cube(name,location,dimensions,material,bevel=0):
    bpy.ops.mesh.primitive_cube_add(size=1,location=location);o=bpy.context.object;o.name=name;o.dimensions=dimensions
    bpy.ops.object.transform_apply(location=False,rotation=False,scale=True);o.data.materials.append(material)
    if bevel:
        m=o.modifiers.new('Small polished edge','BEVEL');m.width=bevel;m.segments=3
        bpy.context.view_layer.objects.active=o;bpy.ops.object.modifier_apply(modifier=m.name)
    return o

shell=glass('Acrylic to air',1.49)
clear=glass('Clear medium to acrylic',1.46/1.49)
blue=glass('Blue liquid to clear medium',1.333/1.46,(.006,.22,.76))
outer=cube('Outer transparent vessel',(0,0,0),(3.32,.76,1.04),shell,.016)
inner=cube('Clear liquid filling',(0,0,0),(3.24,.68,.96),clear,.008)
base=cube('Deep blue base',(0,0,-.514),(3.34,.78,.035),mat('Cobalt base',(.006,.030,.22),.10),.015)

# One connected height-field boundary; no overlapping blue spheres. This is
# a prescribed wave shape for material calibration, not simulated motion.
def height(x,y):
    longitudinal=-.12+.18*math.cos(1.60*(x+.85))+.04*math.cos(4.3*(x+.60))
    # Compare a convex liquid cap against the broad flat top, holding the
    # camera, dye and studio fixed. This authored profile is not a solver.
    if rounded:
        return longitudinal+.14*(math.sqrt(max(0,1-(y/.322)**2))-.80)
    return longitudinal+.010*math.cos(math.pi*y/.64)+.009*math.exp(-((abs(y)-.30)/.025)**2)
nx,ny=192,32;stride=nx+1;n=(nx+1)*(ny+1)
verts=[]
for layer in range(2):
    for j in range(ny+1):
        y=-.32+.64*j/ny
        for i in range(nx+1):
            x=-1.60+3.20*i/nx;verts.append((x,y,height(x,y) if layer==0 else -.45))
faces=[]
for j in range(ny):
    for i in range(nx):
        a=j*stride+i;b=a+1;c=a+stride+1;d=a+stride
        faces.extend([(a,b,c,d),(n+d,n+c,n+b,n+a)])
perimeter=list(range(nx+1))+[j*stride+nx for j in range(1,ny+1)]+[ny*stride+i for i in range(nx-1,-1,-1)]+[j*stride for j in range(ny-1,0,-1)]
for k,a in enumerate(perimeter):
    b=perimeter[(k+1)%len(perimeter)];faces.append((a,n+a,n+b,b))
mesh=bpy.data.meshes.new('Continuous blue boundary');mesh.from_pydata(verts,[],faces);mesh.update()
liquid=bpy.data.objects.new('Connected blue liquid',mesh);scene.collection.objects.link(liquid);liquid.data.materials.append(blue)
bm=bmesh.new();bm.from_mesh(mesh);bmesh.ops.recalc_face_normals(bm,faces=bm.faces);bm.to_mesh(mesh);bm.free()
# Narrow polished meniscus at the near/far wall, retaining the continuous wave.
bpy.context.view_layer.objects.active=liquid;liquid.select_set(True)
bevel=liquid.modifiers.new('Small contact rounding','BEVEL');bevel.width=.006;bevel.segments=3;bevel.limit_method='ANGLE';bevel.angle_limit=.45
bpy.ops.object.modifier_apply(modifier=bevel.name)
bubble_specs=[]
for k,x in enumerate([-1.37,-1.13,-.87,-.55,-.21,.14,.51,.88,1.22,1.43]):
    r=[.041,.061,.048,.070,.036,.056,.044,.060,.047,.032][k]
    y=-.235+.032*math.sin(k*2.1);z=height(x,y)-r*(.27 if k%3 else 1.3)
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32,ring_count=20,radius=r,location=(x,y,z))
    cutter=bpy.context.object;cutter.name=f'Clear inclusion {k}'
    bpy.context.view_layer.objects.active=liquid
    mod=liquid.modifiers.new(f'Clear inclusion {k}','BOOLEAN');mod.operation='DIFFERENCE';mod.solver='EXACT';mod.object=cutter
    bpy.ops.object.modifier_apply(modifier=mod.name);bpy.data.objects.remove(cutter,do_unlink=True)
    bubble_specs.append([x,y,z,r])
for p in liquid.data.polygons:p.use_smooth=True
bm=bmesh.new();bm.from_mesh(liquid.data)
nonmanifold=sum(not e.is_manifold for e in bm.edges);volume=bm.calc_volume(signed=True);bm.free()
assert nonmanifold==0 and volume>0,(nonmanifold,volume)

# Small generic 3D float, a calibration stand-in, not the parallel boat design.
ivory=mat('Ivory painted wood',(.83,.79,.64),.28);teal=mat('Teal deck',(.025,.20,.24),.26)
canvas=mat('Warm canvas',(.91,.89,.80),.46);red=mat('Tiny vermilion sail',(.55,.048,.021),.42)
bx,by=.28,.045;bz=height(bx,by)
bpy.ops.mesh.primitive_uv_sphere_add(segments=48,ring_count=24,radius=1,location=(bx,by,bz-.012))
hull=bpy.context.object;hull.name='Miniature hull stand-in';hull.scale=(.245,.085,.063);hull.data.materials.append(ivory)
for p in hull.data.polygons:p.use_smooth=True
cube('Miniature deck stand-in',(bx,by,bz+.025),(.37,.12,.024),teal,.015)
bpy.ops.mesh.primitive_cylinder_add(vertices=16,radius=.008,depth=.34,location=(bx-.04,by,bz+.21))
bpy.context.object.data.materials.append(ivory)
def sail(name,points,material):
    m=bpy.data.meshes.new(name);m.from_pydata(points,[],[(0,1,2)]);m.update();o=bpy.data.objects.new(name,m);scene.collection.objects.link(o);o.data.materials.append(material)
    solid=o.modifiers.new('Miniature fabric thickness','SOLIDIFY');solid.thickness=.002
sail('Main sail stand-in',[(bx-.028,by,bz+.365),(bx+.175,by+.025,bz+.070),(bx-.028,by,bz+.070)],canvas)
sail('Small sail stand-in',[(bx-.058,by,bz+.265),(bx-.195,by-.012,bz+.070),(bx-.058,by,bz+.070)],red)

floor=cube('Studio table',(0,0,-.59),(200,200,.10),mat('Warm light studio',(.73,.74,.75),.28))
def aim(o,target):o.rotation_euler=(Vector(target)-o.location).to_track_quat('-Z','Y').to_euler()
light_info=[]
def area(name,location,power,size,size_y,target):
    data=bpy.data.lights.new(name,'AREA');data.energy=power;data.shape='RECTANGLE';data.size=size;data.size_y=size_y
    obj=bpy.data.objects.new(name,data);scene.collection.objects.link(obj);obj.location=location;aim(obj,target)
    light_info.append({'name':name,'position':location,'power':power,'size':[size,size_y]})
area('Broad window',(-3,-4,6),650,4,4,(0,0,0))
area('Far softbox',(3,2,4),380,3,2,(0,0,0))
area('Top narrow reflection',(0,2.5,3),210,3,.22,(0,0,0))
# A dark flag outside the camera frame gives transparent edges a dark reference.
flag=cube('Dark studio flag',(-3.6,.1,1.5),(.025,3.5,4),mat('Dark flag',(.005,.006,.008),.9))
flag.visible_camera=False
bpy.ops.object.camera_add(location=(0,-7.6,1.0) if front else (4.6,-7.2,3.3))
camera=bpy.context.object;camera.data.type='PERSP';camera.data.lens=65;aim(camera,(0,0,-.04));scene.camera=camera
scene.render.filepath=str(out/(name+'.png'))
bpy.ops.wm.save_as_mainfile(filepath=str(out/(name+'.blend')))
print('CALIBRATION_START',name,flush=True);bpy.ops.render.render(write_still=True)
result={'artifact':'offline art-directed material calibration','fluidSimulation':False,'appBuild':False,'sourceSHA256':hashlib.sha256(source).hexdigest(),'sourceSnapshot':str(snapshot),'imageSHA256':hashlib.sha256((out/(name+'.png')).read_bytes()).hexdigest(),'blender':bpy.app.version_string,'renderer':'Cycles CPU','dimensions':[scene.render.resolution_x,scene.render.resolution_y],'samples':samples,'denoised':True,'elapsedSeconds':time.time()-started,'nonManifoldEdges':nonmanifold,'blueVolume':volume,'blueVertices':len(liquid.data.vertices),'bluePolygons':len(liquid.data.polygons),'materials':materials,'lights':light_info,'clearInclusions':bubble_specs,'assumptions':['Art-directed form and dimensions, not a recorded simulation','Nested relative IOR surfaces, not measured toy materials','Clear inclusions use surrounding clear medium, not separate air','Generic 3D boat stand-in, not a new app asset'],'phoneValidation':'NOT_RUN'}
(out/(name+'.json')).write_text(json.dumps(result,indent=2));print('CALIBRATION_DONE',json.dumps(result),flush=True)
