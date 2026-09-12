// Apply the prescribed clear coating to the actual GPU particle-density field
// before cubic reconstruction. No per-component radius fitting, new particle,
// moving threshold, or screen-space painted seam is involved.
kernel void stableWallFilm(texture2d_array<float,access::read> source [[texture(0)]],
                           texture2d_array<float,access::write> target [[texture(1)]],
                           constant OceanUniforms &u [[buffer(0)]],
                           uint3 id [[thread_position_in_grid]]) {
    if(id.x>=source.get_width()||id.y>=source.get_height()||id.z>=source.get_array_size()) return;
    float z=u.optics.y-(float(id.z)+0.5)*2*u.optics.y/float(source.get_array_size());
    float coating=u.optics.z+4*((u.optics.y-0.009)-abs(z));
    target.write(float4(min(source.read(id.xy,id.z).r,coating)),id.xy,id.z);
}
