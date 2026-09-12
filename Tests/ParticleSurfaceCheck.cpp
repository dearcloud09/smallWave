// Offline topology vetoes on one frozen surface. No physics/optical claims.
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <queue>
#include <set>
#include <sstream>
#include <string>
#include <vector>
template<class T> std::vector<T> read(const std::string &p) {
    std::ifstream f(p,std::ios::binary|std::ios::ate);
    if(!f) throw std::runtime_error("Cannot open "+p);
    auto n=f.tellg(); if(n<0 || static_cast<size_t>(n)%sizeof(T)) throw std::runtime_error("Bad file size");
    std::vector<T> v(static_cast<size_t>(n)/sizeof(T)); f.seekg(0); f.read(reinterpret_cast<char*>(v.data()),n);
    if(!f) throw std::runtime_error("Short read"); return v;
}
int main(int argc,char **argv) { try {
    if(argc!=2) throw std::runtime_error("Expected output directory");
    std::string path=argv[1]; constexpr int nx=256,ny=544,nz=48,layer=nx*ny,total=layer*nz;
    constexpr double dx=2./nx,dy=4.24/ny,dz=.36/nz,spacing=.098;
    auto phi=read<float>(path+"/phi.f32"), particles=read<float>(path+"/particles.f32");
    auto groups=read<int>(path+"/particle-components.i32");
    if(phi.size()!=total || particles.size()!=groups.size()*3) throw std::runtime_error("Dimensions mismatch");
    std::vector<int> labels(total,-1),sizes;
    std::vector<int> queue; queue.reserve(total/2);
    for(int at=0;at<total;at++) {
        if(!std::isfinite(phi[at])) throw std::runtime_error("Nonfinite surface");
        if(phi[at]>=0 || labels[at]>=0) continue;
        int id=static_cast<int>(sizes.size()); queue.clear(); queue.push_back(at); labels[at]=id;
        for(size_t head=0;head<queue.size();head++) {
            int i=queue[head], x=i%nx,y=(i/nx)%ny,z=i/layer;
            auto visit=[&](int j) { if(labels[j]<0&&phi[j]<0) { labels[j]=id; queue.push_back(j); } };
            if(x>0) visit(i-1); if(x+1<nx) visit(i+1);
            if(y>0) visit(i-nx); if(y+1<ny) visit(i+nx);
            if(z>0) visit(i-layer); if(z+1<nz) visit(i+layer);
        }
        sizes.push_back(static_cast<int>(queue.size()));
    }
    int graphCount=*std::max_element(groups.begin(),groups.end())+1;
    std::vector<std::set<int>> voxelToParticle(sizes.size()),particleToVoxel(graphCount);
    int absent=0; double maxDistance=0;
    for(size_t p=0;p<groups.size();p++) {
        double px=particles[p*3],py=particles[p*3+1],pz=particles[p*3+2];
        int cx=static_cast<int>((px+1)/dx),cy=static_cast<int>((2.12-py)/dy),cz=static_cast<int>((.18-pz)/dz);
        int found=-1; double best=spacing*spacing;
        // Bubble cutouts can contain particle centers; look for the closest blue
        // seed in a fixed physical neighborhood, recording the displacement.
        for(int z=std::max(0,cz-14);z<=std::min(nz-1,cz+14);z++)
        for(int y=std::max(0,cy-14);y<=std::min(ny-1,cy+14);y++)
        for(int x=std::max(0,cx-14);x<=std::min(nx-1,cx+14);x++) {
            int label=labels[(z*ny+y)*nx+x]; if(label<0) continue;
            double a=(-1+(x+.5)*dx)-px,b=(2.12-(y+.5)*dy)-py,c=(.18-(z+.5)*dz)-pz;
            double d=a*a+b*b+c*c; if(d<best) { best=d; found=label; }
        }
        if(found<0) { absent++; continue; }
        maxDistance=std::max(maxDistance,std::sqrt(best));
        particleToVoxel[groups[p]].insert(found); voxelToParticle[found].insert(groups[p]);
    }
    int split=0,merged=0,unseeded=0;
    for(auto &s:particleToVoxel) if(s.size()!=1) split++;
    for(auto &s:voxelToParticle) { if(s.empty()) unseeded++; if(s.size()>1) merged++; }
    std::cout<<"Particle graph components="<<graphCount<<"; 6-connected surface components="<<sizes.size()<<"\n";
    std::cout<<"Absent particle neighborhoods="<<absent<<"; split/missing graph groups="<<split<<"; merged groups="<<merged<<"; unseeded blobs="<<unseeded<<"\n";
    std::cout<<"Maximum particle-to-blue seed distance="<<maxDistance<<"; volume voxels=";
    for(auto n:sizes) std::cout<<n<<","; std::cout<<"\n";
    bool pass=absent==0&&split==0&&merged==0&&unseeded==0;
    std::ostringstream details,merges;
    bool firstDetail=true,firstMerge=true;
    for(size_t id=0;id<sizes.size();id++) {
        if(voxelToParticle[id].empty()) {
            std::array<int,3> lower={nx,ny,nz},upper={0,0,0};
            double nearest=1e10; int nearestParticle=-1;
            for(int i=0;i<total;i++) if(labels[i]==static_cast<int>(id)) {
                int x=i%nx,y=(i/nx)%ny,z=i/layer;
                lower[0]=std::min(lower[0],x); lower[1]=std::min(lower[1],y); lower[2]=std::min(lower[2],z);
                upper[0]=std::max(upper[0],x); upper[1]=std::max(upper[1],y); upper[2]=std::max(upper[2],z);
                for(size_t p=0;p<groups.size();p++) {
                    double a=(-1+(x+.5)*dx)-particles[p*3],b=(2.12-(y+.5)*dy)-particles[p*3+1],c=(.18-(z+.5)*dz)-particles[p*3+2];
                    double d=a*a+b*b+c*c; if(d<nearest) { nearest=d; nearestParticle=static_cast<int>(p); }
                }
            }
            if(!firstDetail) details<<","; firstDetail=false;
            details<<"{\"label\":"<<id<<",\"voxels\":"<<sizes[id]<<",\"nearestParticle\":"<<nearestParticle
                   <<",\"nearestParticleDistance\":"<<std::sqrt(nearest)<<",\"boxWorld\":["
                   <<-1+lower[0]*dx<<","<<2.12-(upper[1]+1)*dy<<","<<.18-(upper[2]+1)*dz<<","
                   <<-1+(upper[0]+1)*dx<<","<<2.12-lower[1]*dy<<","<<.18-lower[2]*dz<<"]}";
        }
        if(voxelToParticle[id].size()>1) {
            double nearest=1e10; int pi=-1,pj=-1;
            for(size_t a=0;a<groups.size();a++) if(voxelToParticle[id].count(groups[a]))
            for(size_t b=a+1;b<groups.size();b++) if(groups[a]!=groups[b]&&voxelToParticle[id].count(groups[b])) {
                double d=0; for(int c=0;c<3;c++) { double t=particles[a*3+c]-particles[b*3+c]; d+=t*t; }
                if(d<nearest) { nearest=d; pi=static_cast<int>(a); pj=static_cast<int>(b); }
            }
            if(!firstMerge) merges<<","; firstMerge=false;
            merges<<"{\"label\":"<<id<<",\"particleGroups\":[";
            bool first=true; for(int g:voxelToParticle[id]) { if(!first) merges<<","; first=false; merges<<g; }
            merges<<"],\"nearestPair\":["<<pi<<","<<pj<<"],\"minimumParticleGap\":"<<std::sqrt(nearest)<<"}";
        }
    }
    std::cout<<"Unseeded locations: ["<<details.str()<<"]\nMerged particle groups: ["<<merges.str()<<"]\n";
    std::ofstream out(path+"/topology.json");
    out<<"{\"pass\":"<<(pass?"true":"false")<<",\"graphComponents\":"<<graphCount<<",\"surfaceComponents\":"<<sizes.size()
       <<",\"absent\":"<<absent<<",\"split\":"<<split<<",\"merged\":"<<merged<<",\"unseeded\":"<<unseeded<<",\"maxSeedDistance\":"<<maxDistance
       <<",\"unseededDetails\":["<<details.str()<<"],\"mergeDetails\":["<<merges.str()<<"]}\n";
    std::cout<<(pass?"PASS":"FAIL")<<" topology only; contact graph is a conservative diagnostic, not physical truth.\n";
    return pass?0:2;
} catch(const std::exception &e) { std::cerr<<"FAIL "<<e.what()<<"\n"; return 1; } }
