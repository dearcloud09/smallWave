"""Create bounded, local resolution-study sources; never edit the app sources.

Exact replacements deliberately fail when the baseline changes. This is an
experiment with remaining numerical/physical confounders, not convergence proof.
"""
from pathlib import Path
import hashlib
import json

root = Path(__file__).resolve().parents[1]
core = (root / "SmallWave/Core/LiquidSimulation.swift").read_text()
shader = (root / "SmallWave/Rendering/LiquidShaders.metal").read_text()
renderer = (root / "SmallWave/Rendering/LiquidRenderer.swift").read_text()
destination = root / ".build-cache/resolution"

def replace_once(source, old, new):
    if source.count(old) != 1:
        raise ValueError(f"Study baseline changed; expected exactly one: {old[:90]}")
    return source.replace(old, new, 1)

fine = core
for old, new in [
    ("let spacing: Float = 0.098", "let spacing: Float = 0.049"),
    ("let smoothingRadius: Float = 0.177", "let smoothingRadius: Float = 0.0885"),
    ("let fixedStep: Float = 1 / 120", "let fixedStep: Float = 1 / 240"),
    ("budget < 6", "budget < 12"),
    ("if budget == 6", "if budget == 12"),
    ("particles[i].velocity *= 0.998", "particles[i].velocity *= sqrt(0.998)"),
    ("(gradientSum + 0.6)", "(gradientSum + 2.4)"),
    ("let antiClump = -0.000012", "let antiClump = -0.000003"),
    ("velocity + diffusion * 0.055", "velocity + diffusion * 0.11"),
    ("- energy) * 0.08", "- energy) * (1 - sqrt(0.92))"),
    ("let margin = spacing * 0.35", "let margin: Float = 0.098 * 0.35"),
]:
    fine = replace_once(fine, old, new)
fine = fine.replace("r2 > 0.000001", "r2 > 0.00000025")

start = fine.index("        var z = -halfDepth + spacing * 0.6")
end = fine.index("        lambda = Array", start)
seed = fine[start:end].replace("spacing", "seedSpacing")
seed = replace_once(seed,
    "                    particles.append(LiquidParticle(position: p, previous: p))",
    """                    // Split each identical coarse seed into eight equal masses.
                    // Children preserve the parent's center and velocity; unlike
                    // simply changing the fill-loop spacing this adds no fluid.
                    for oz in [Float(-0.25),Float(0.25)] {
                        for oy in [Float(-0.25),Float(0.25)] {
                            for ox in [Float(-0.25),Float(0.25)] {
                                let child = p + SIMD3(ox,oy,oz)*seedSpacing
                                particles.append(LiquidParticle(position: child, previous: child))
                            }
                        }
                    }""")
fine = fine[:start] + "        let seedSpacing: Float = 0.098\n" + seed + fine[end:]

# A 3D halving gives 8x particles and 1/4 projected kernel area: halve
# projected kernel amplitude so its image integral remains unchanged.
fine_shader = replace_once(shader,
    "float density = pow(max(0.0,1.0-radius2),3.0);",
    "float density = 0.5 * pow(max(0.0,1.0-radius2),3.0);")

for name, generated_core, generated_shader in [("coarse",core,shader),("fine",fine,fine_shader)]:
    folder = destination / name
    folder.mkdir(parents=True, exist_ok=True)
    for filename, contents in [("LiquidSimulation.swift",generated_core),
                               ("LiquidShaders.metal",generated_shader),
                               ("LiquidRenderer.swift",renderer)]:
        (folder / filename).write_text(contents)
manifest = {"baseline_sha256": {
    "core": hashlib.sha256(core.encode()).hexdigest(),
    "renderer": hashlib.sha256(renderer.encode()).hexdigest(),
    "shader": hashlib.sha256(shader.encode()).hexdigest()},
    "variants": {"coarse": {"spacing":0.098,"hz":120}, "fine":{"spacing":0.049,"hz":240}},
    "limitations":["cohesion coefficient and three constraint iterations not calibrated across resolutions",
                   "density probe support and surface particles change; motion is not held identical",
                   "XSPH diffusivity scaling is an approximation, not a matched viscosity measurement"]}
(destination / "manifest.json").write_text(json.dumps(manifest, indent=2)+"\n")
print("Prepared local coarse/fine study copies. App sources unchanged.")
