#!/usr/bin/env python3
"""Build a disposable palette-review source tree from the approved art commit.

Never edits the working app. Pass an empty directory under the system temp folder.
All app-layout, simulation, motion, optics and artwork bytes remain unchanged.
Only the review palette mapping, preview bundle ID and still-review enumeration differ.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, tarfile, tempfile

here = Path(__file__).resolve().parent
repo = here.parents[2]
palette = json.loads((here/'palette.json').read_text())
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
out = args.output.resolve()
if Path('/private/tmp') not in out.parents:
    parser.error('Preview output must be inside /private/tmp')
if out.exists() and (not out.is_dir() or any(out.iterdir())):
    parser.error('Use a new empty preview directory')
out.mkdir(parents=True, exist_ok=True)
paths = ['SmallWave', 'SmallWaveWidget', 'SmallWave.xcodeproj', 'Tests', 'scripts', 'Config']
with tempfile.TemporaryFile() as archive:
    subprocess.run(['git','archive',palette['baselineCommit'],*paths],cwd=repo,stdout=archive,check=True)
    archive.seek(0)
    with tarfile.open(fileobj=archive,mode='r:') as bundle:
        # The trusted local archive contains regular source files and directories only.
        for member in bundle.getmembers():
            target=(out/member.name).resolve()
            if not (out in target.parents or target == out):
                raise ValueError('Archive path escapes the preview directory')
            if not (member.isfile() or member.isdir()):
                raise ValueError('Archive contains a non-regular entry')
        bundle.extractall(out)
original = {str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in out.rglob('*') if p.is_file()}
variants = palette['variants'] + [palette['baselinePaint']]
style = out/'SmallWave/Core/OceanStyle.swift'
s = style.read_text(); start = s.index('/// Three paint colors')
s = s[:start] + '\n'.join([
    '/// Disposable red-paint review mapping. Not an app preference migration.',
    'enum MiniatureStyle: Int, CaseIterable, Identifiable {',
    '    case '+', '.join(v['case'] for v in variants),
    '    var id: Int { rawValue }',
    '    var textureAssetName: String { "toy-boat-blue" }',
    '    var assetName: String {',
    '        switch self {',
    *[f'        case .{v["case"]}: return "red-{v["id"]}"' for v in variants],
    '        }', '    }',
    '    var title: String {', '        switch self {',
    *[f'        case .{v["case"]}: return "{v["label"]}"' for v in variants],
    '        }', '    }',
    '    var detail: String { "상아색 천 돛 · 나무 돛대 · 작은 남색 구명환" }',
    '}', ''
])
style.write_text(s)
shader = out/'SmallWave/Rendering/LiquidShaders.metal'; s=shader.read_text()
for old,new in [
    ('uint(clamp(u.miniatureArt.x,0.0,2.0))','uint(clamp(u.miniatureArt.x,0.0,4.0))'),
    ('    if(variant==0) return float4(material*texel.a,texel.a);\n',''),
    ('    if(variant==2) {','    { // The same navy life ring for every red paint.')
]:
    assert s.count(old)==1,old
    s=s.replace(old,new)
paints=[]
for v in variants:
    channels = [f'{n}.0/255.0' for n in v['rgb255']] if 'rgb255' in v else [str(n) for n in v['shaderRGB']]
    paints.append('float3('+','.join(channels)+')')
old='    float3 paint=variant==1 ? float3(0.93,0.71,0.32) : float3(0.76,0.235,0.17);'
assert s.count(old)==1
s=s.replace(old,'    constexpr float3 redPaints[5]={'+','.join(paints)+'};\n    float3 paint=redPaints[variant];')
shader.write_text(s)
project=out/'SmallWave.xcodeproj/project.pbxproj';s=project.read_text()
s=s.replace('dev.smallwave.prototype','dev.smallwave.redcolorways.review')
project.write_text(s)
review=out/'Tests/MiniatureArtReview.swift';s=review.read_text()
s=s.replace('for variant in -1...2 {','for variant in -1...4 {')
s=s.replace('baseline and three variants','procedural reference and five red paints')
s=s.replace('180 motion states × 3 variants','180 motion states × 5 red paints')
review.write_text(s)
expected={'SmallWave/Core/OceanStyle.swift','SmallWave/Rendering/LiquidShaders.metal','SmallWave.xcodeproj/project.pbxproj','Tests/MiniatureArtReview.swift'}
changed={rel for rel,sha in original.items() if hashlib.sha256((out/rel).read_bytes()).hexdigest()!=sha}
assert changed==expected, changed
(out/'preview-source.json').write_text(json.dumps({'baselineCommit':palette['baselineCommit'],'originalSHA256':original,'changedOnlyForPreview':sorted(changed),'previewBundleID':'dev.smallwave.redcolorways.review'},indent=2)+'\n')
print(out)
print('Palette-only disposable app; shared app sources unchanged.')
