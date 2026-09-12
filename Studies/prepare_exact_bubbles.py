"""Keep sphere geometry and optical normals coherent at grazing incidence.

The blue outer field is unchanged. Existing bubble centers/radii are subtracted
analytically at each ray query instead of carving into a grid then interpolating.
This is a representation experiment, not a new bubble fluid solver.
"""
import hashlib
import json
from pathlib import Path

folder = Path('.build-cache/particle-surface-exact-bubbles')
folder.mkdir(parents=True,exist_ok=True)
inputs = [Path('SmallWave/Rendering/LiquidShaders.metal'),
          Path('Studies/VolumeRay.metal'),Path('Studies/SharedStudio.metal')]
source = inputs[0].read_text()+'\n#define VR_CUBIC_FIELD 1\n'+inputs[1].read_text()

def replace_once(old, new):
    global source
    assert source.count(old) == 1, old
    source = source.replace(old, new)

replace_once('float3 reference=clamp(u.color.rgb,float3(0.02),float3(0.98));',
             'float3 reference=clamp(u.color.rgb,float3(0.00001),float3(0.99999));')
replace_once('float3 vrStudioBackdrop(float2 p) {',inputs[2].read_text()+'\nfloat3 vrStudioBackdrop(float2 p) {')
replace_once('radiance+=reflectedWeight*vrEnvironment(lightingDirection,study);',
             'radiance+=reflectedWeight*sharedStudioRadiance(p,lightingDirection);')
replace_once('float3 scene=direction.z<0?displayToLight((uint(study.w)&64)!=0?vrStudioBackdrop(q):backdrop(q,u)):vrEnvironment(direction,study);',
             'float3 scene=sharedStudioRadiance(p,direction);')

# Keep the original 80-byte uniform header, append a 16-byte count and 36 spheres.
end = source.index('\n};', source.index('struct OceanUniforms'))
source = source[:end] + '\n    uint4 studyCounts;\n    float4 studyBubbles[36];' + source[end:]
replace_once('VRField vrField(texture2d_array<float> volume,',
             'VRField vrRawField(texture2d_array<float> volume,')
wrapper = r'''
VRField vrField(texture2d_array<float> volume,float3 p,constant OceanUniforms &u) {
    VRField result=vrRawField(volume,p,u);
    for(uint i=0;i<min(u.studyCounts.x,36u);i++) {
        float3 delta=p-u.studyBubbles[i].xyz;
        float distance=length(delta);
        float value=u.optics.z+4*(distance-u.studyBubbles[i].w);
        if(value<result.value) {
            result.value=value;
            result.gradient=distance>0.000001?4*delta/distance:float3(0);
        }
    }
    return result;
}
'''
replace_once('float vrDensity(texture2d_array<float> volume,',
             wrapper+'\nfloat vrDensity(texture2d_array<float> volume,')
path = folder/'exact-bubble-shader.metal'
if path.exists():
    print('Existing source byte-identical:',path.read_text()==source)
path.write_text(source)
manifest = {'sourceSHA256': hashlib.sha256(source.encode()).hexdigest(),
            'inputs':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs},
            'uniformBytes':672, 'bubbleGeometry':'analytic sphere union subtraction at query',
            'outerVolume': 'volume-uncarved.f16', 'adopted':False}
(folder/'exact-bubble-source.json').write_text(json.dumps(manifest, indent=2))
print(path)
