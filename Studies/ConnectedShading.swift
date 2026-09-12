import Foundation

/// Preserve the original plump coverage and physical state. Reduce only
/// optical valleys supported by liquid on opposite sides of a connection.
enum ConnectedShading {
    static func source(_ original:String) throws -> String {
        let depth="float opticalPath=1.5*(1.0-exp(-max(density-0.35,0.0)*0.18));"
        guard original.components(separatedBy:depth).count==2 else {
            throw OceanRendererError.unavailable("Connected shading anchors changed")
        }
        let replacement="""
        // Original coverage remains intact. Opposite samples avoid filling
        // the convex end of a droplet as if it were a connection.
        float2 reach=0.060/(2.0*u.viewport.xy);
        float joinedSupport=density;
        float2 axes[4]={float2(1,0),float2(0,1),float2(0.70710678,0.70710678),float2(0.70710678,-0.70710678)};
        for(int i=0;i<4;i++) {
            float2 offset=axes[i]*reach;
            float a=field.sample(smp,uv+offset).r,b=field.sample(smp,uv-offset).r;
            joinedSupport=max(joinedSupport,min(a,b));
        }
        float valley=max(0.0,joinedSupport-density);
        float opticalDensity=density+valley*0.75;
        float opticalPath=1.5*(1.0-exp(-max(opticalDensity-0.35,0.0)*0.18));
        """
        return original.replacingOccurrences(of:depth,with:replacement)
    }
}
