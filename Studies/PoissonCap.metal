// A render-only connected cap: (-Laplacian + 4/H^2) q = 4, h = sqrt(q).
// q=0 at the original density contour; zero normal derivative at the screen wall.
// Small isolated disks approach q=R^2-r^2. Screening limits broad bodies to H.
// This inferred surface is not a reconstruction of particle z or conserved volume.
constant float capHalfDepth = 0.12;

kernel void capInitialize(texture2d<float,access::read> field [[texture(0)]],
                          texture2d<float,access::write> q [[texture(1)]],
                          uint2 p [[thread_position_in_grid]]) {
    if(p.x>=q.get_width() || p.y>=q.get_height()) return;
    q.write(float4(field.read(p).r>=0.52 ? capHalfDepth*capHalfDepth : 0),p);
}

kernel void capJacobi(texture2d<float,access::read> field [[texture(0)]],
                     texture2d<float,access::read> source [[texture(1)]],
                     texture2d<float,access::write> target [[texture(2)]],
                     constant OceanUniforms &u [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    int2 size=int2(field.get_width(),field.get_height()), p=int2(gid);
    if(any(p>=size)) return;
    float center=field.read(gid).r-0.52;
    if(center<0) { target.write(float4(0),gid); return; }
    float2 spacing=2*u.viewport.xy/float2(size);
    float diagonal=4/(capHalfDepth*capHalfDepth), rhs=4;
    // Shortley-Weller distances place the zero value at the interpolated contour,
    // instead of rounding its Dirichlet boundary to a grid-cell center.
    for(int axis=0;axis<2;axis++) {
        int2 offset=axis==0 ? int2(1,0) : int2(0,1);
        int2 a=p-offset, b=p+offset;
        bool wallA=any(a<0), wallB=any(b>=size);
        float da=wallA ? center : field.read(uint2(a)).r-0.52;
        float db=wallB ? center : field.read(uint2(b)).r-0.52;
        float distanceA=da<0 ? max(0.01,center/(center-da)) : 1;
        float distanceB=db<0 ? max(0.01,center/(center-db)) : 1;
        float scale=1/(spacing[axis]*spacing[axis]);
        float ca=2*scale/(distanceA*(distanceA+distanceB));
        float cb=2*scale/(distanceB*(distanceA+distanceB));
        if(!wallA) { diagonal+=ca; if(da>=0) rhs+=ca*source.read(uint2(a)).r; }
        if(!wallB) { diagonal+=cb; if(db>=0) rhs+=cb*source.read(uint2(b)).r; }
    }
    target.write(float4(rhs/diagonal),gid);
}
