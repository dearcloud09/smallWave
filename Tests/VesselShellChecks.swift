import Foundation
import Metal

@main struct VesselShellChecks {
    static func fresnel(_ c:Double,_ a:Double,_ b:Double)->Double {
        let s2=(a/b)*(a/b)*(1-c*c)
        if s2>=1 { return 1 }
        let t=sqrt(1-s2)
        let rs=(a*c-b*t)/(a*c+b*t),rp=(b*c-a*t)/(b*c+a*t)
        return (rs*rs+rp*rp)/2
    }
    static func main() throws {
        let source=try String(contentsOfFile:".build-cache/material-vessel-shell/shell-shader.metal",encoding:.utf8)+"""
        \nkernel void shellChecks(device float4 *out [[buffer(0)]],constant OceanUniforms &u [[buffer(1)]],uint i [[thread_position_in_grid]]) {
            if(i>=27) return;
            float angles[9]={0,20,40,43,44,60,80,89,89.9};
            uint kind=i/9; float theta=angles[i%9]*M_PI_F/180.0;
            float n1=kind==0?1.0:(kind==1?1.46:1.333),n3=kind==0?1.46:1.0;
            float3 d=float3(sin(theta),0,cos(theta)),facing=float3(0,0,-1);
            float r=0,t=vesselShellSlabT(cos(theta),n1,1.49,n3,r);
            float3 glass=refract(d,facing,n1/1.49),outside=refract(glass,facing,1.49/n3);
            out[3*i]=float4(r,t,length_squared(outside),n1);
            VesselShellHit hit=vesselShellInner(float3(0),d,u);
            float3 at=d*hit.t,landed=vesselShellLanding(at,hit.normal,u);
            out[3*i+1]=float4(hit.t,hit.hit,all(abs(landed)<float3(u.viewport.xy,u.optics.y)),dot(hit.normal,d));
            out[3*i+2]=float4(outside,n3);
        }
        """
        guard let device=MTLCreateSystemDefaultDevice(),let queue=device.makeCommandQueue() else { fatalError("Metal") }
        let library=try device.makeLibrary(source:source,options:nil), pipeline=try device.makeComputePipelineState(function:library.makeFunction(name:"shellChecks")!)
        let output=device.makeBuffer(length:27*3*16,options:.storageModeShared)!
        var u=Data(count:672)
        u.withUnsafeMutableBytes { raw in
            raw.storeBytes(of:SIMD4<Float>(1,2.12,0,0),toByteOffset:0,as:SIMD4<Float>.self)
            raw.storeBytes(of:SIMD4<Float>(0,0.18,0.6,48),toByteOffset:64,as:SIMD4<Float>.self)
        }
        let command=queue.makeCommandBuffer()!,e=command.makeComputeCommandEncoder()!
        e.setComputePipelineState(pipeline);e.setBuffer(output,offset:0,index:0)
        u.withUnsafeBytes { e.setBytes($0.baseAddress!,length:$0.count,index:1) }
        e.dispatchThreads(MTLSize(width:27,height:1,depth:1),threadsPerThreadgroup:MTLSize(width:27,height:1,depth:1));e.endEncoding();command.commit();command.waitUntilCompleted()
        if let error=command.error { throw error }
        let values=output.contents().bindMemory(to:SIMD4<Float>.self,capacity:81)
        let angles:[Double]=[0,20,40,43,44,60,80,89,89.9]
        var rows=[[String:Any]](),maxError=0.0
        for i in 0..<27 {
            let a=values[3*i],b=values[3*i+1],c=values[3*i+2]
            let theta=angles[i%9]*Double.pi/180,n1=i/9==0 ? 1.0:(i/9==1 ? 1.46:1.333),n3=i/9==0 ? 1.46:1.0
            let r1=fresnel(cos(theta),n1,1.49),cosGlass=sqrt(max(0,1-pow(n1/1.49*sin(theta),2)))
            let r2=fresnel(cosGlass,1.49,n3)
            // Independent repeated-bounce energy sum, rather than the closed
            // geometric-series expression evaluated by Metal.
            var reflected=r1,transmitted=0.0,packet=1-r1
            for _ in 0..<1000 {
                transmitted+=packet*(1-r2)
                reflected+=packet*r2*(1-r1)
                packet*=r2*r1
            }
            let error=max(abs(Double(a.x)-reflected),abs(Double(a.y)-transmitted));maxError=max(maxError,error)
            let tir=pow(n1/n3*sin(theta),2)>=1
            let directZ=tir ? 0:sqrt(1-pow(n1/n3*sin(theta),2))
            let directionOK=tir ? a.z<0.00001:abs(Double(c.z)-directZ)<0.00003
            let pass=a.x.isFinite && a.y.isFinite && error<0.00003 && abs(a.x+a.y-1)<0.00003 && directionOK && b.x>0 && b.y==1 && b.z==1 && b.w>0
            rows.append(["case":i,"angle":angles[i%9],"fromIOR":n1,"toIOR":n3,"R":a.x,"T":a.y,"independentError":error,"pass":pass])
        }
        let pass=rows.allSatisfy { $0["pass"] as! Bool }
        let result:[String:Any]=["pass":pass,"cases":rows,"maxIndependentError":maxError,"device":device.name]
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:".build-cache/material-vessel-shell/interface-checks.json"))
        print("\(pass ? "PASS":"FAIL") shell interface cases=27 maxError=\(maxError)")
        if !pass { exit(1) }
    }
}
