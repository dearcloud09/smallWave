#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iomanip>
#include <fstream>
#include <iostream>
#include <map>
#include <set>
#include <stdexcept>
#include <string>
#include <vector>
using std::array; using std::vector;
constexpr int NX=256,NY=544,NZ=48; constexpr float ISO=.6f;
struct V { double x,y,z; }; struct Bubble { float x,y,z,r; };
static V sub(V a,V b){return {a.x-b.x,a.y-b.y,a.z-b.z};}
static V cross(V a,V b){return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
static double dot(V a,V b){return a.x*b.x+a.y*b.y+a.z*b.z;}
static uint16_t hbits(const uint8_t *p){ return uint16_t(p[0])|uint16_t(p[1])<<8; }
static float half(uint16_t h){ uint32_t s=(h>>15)<<31,e=(h>>10)&31,m=h&1023,b; if(!e) { if(!m) b=s; else { e=127-15+1; while(!(m&1024)){m<<=1;--e;} b=s|(e<<23)|((m&1023)<<13); } } else if(e==31) b=s|0x7f800000|(m<<13); else b=s|((e+112)<<23)|(m<<13); float f; std::memcpy(&f,&b,4); return f; }
int main(int argc,char**argv){ try {
  bool shallow=argc>4 && std::string(argv[4])=="--shallow-profile";
  std::string density=argc>1?argv[1]:".build-cache/material-kernel-film/000/filtered.f16";
  std::string bubbles=argc>2?argv[2]:".build-cache/material-blender/bubbles.txt";
  std::string out=argc>3?argv[3]:".build-cache/material-blender/liquid.ply";
  std::ifstream in(density,std::ios::binary); if(!in) throw std::runtime_error("density open"); vector<uint8_t> raw(NX*NY*NZ*2); in.read((char*)raw.data(),raw.size()); if(in.gcount()!=(std::streamsize)raw.size()) throw std::runtime_error("density size");
  vector<float> base(NX*NY*NZ); for(size_t q=0;q<base.size();++q){base[q]=half(hbits(raw.data()+2*q));if(!std::isfinite(base[q]))throw std::runtime_error("nonfinite density");}
  std::ifstream bi(bubbles); if(!bi) throw std::runtime_error("bubbles open"); vector<Bubble> bs; Bubble b; while(bi>>b.x>>b.y>>b.z>>b.r) bs.push_back(b);
  auto at=[&](int x,int y,int z){return base[(z*NY+y)*NX+x];};
  auto pos=[](int x,int y,int z)->V{return {-1.0+(x+.5)*.0078125,2.12-(y+.5)*.00779411765,.18-(z+.5)*.0075};};
  // Padded scalar samples are one half-voxel beyond the centre grid and zero,
  // closing contact cuts at x/y without changing the original grid spacing.
  int PX=NX+2,PY=NY+2,PZ=NZ+2; auto nid=[&](int x,int y,int z){return (z*PY+y)*PX+x;};
  vector<float> f(PX*PY*PZ,0); vector<V> p(PX*PY*PZ); for(int z=0;z<PZ;z++)for(int y=0;y<PY;y++)for(int x=0;x<PX;x++){int id=nid(x,y,z);p[id]=pos(x-1,y-1,z-1);if(x==0||y==0||z==0||x==PX-1||y==PY-1||z==PZ-1)continue;float v=0;for(int dz=-1;dz<=1;dz++)for(int dy=-1;dy<=1;dy++)for(int dx=-1;dx<=1;dx++){int xx=std::clamp(x-1+dx,0,NX-1),yy=std::clamp(y-1+dy,0,NY-1),zz=std::clamp(z-1+dz,0,NZ-1);float w=(dx?1:4)*(dy?1:4)*(dz?1:4)/216.f;v+=w*at(xx,yy,zz);}if(!shallow)for(auto q:bs){V d=sub(p[id],{q.x,q.y,q.z});v=std::min(v,.6f+4.f*(float(std::sqrt(dot(d,d)))-q.r));}f[id]=v;}
  if(shallow) {
    // Geometry control only: preserve the projected silhouette of the largest
    // connected body, give it a shallow rounded-prism depth profile. Detached
    // droplets keep their original depth. This is not a volume-conserving
    // reconstruction or measured capillary/contact-angle model.
    vector<float> projected(PX*PY,0); vector<int> labels(PX*PY,-1),sizes;
    for(int y=1;y<PY-1;y++)for(int x=1;x<PX-1;x++)for(int z=1;z<PZ-1;z++)
      projected[y*PX+x]=std::max(projected[y*PX+x],f[nid(x,y,z)]);
    for(int y=1;y<PY-1;y++)for(int x=1;x<PX-1;x++) {
      int seed=y*PX+x;if(labels[seed]>=0||projected[seed]<ISO)continue;
      int label=sizes.size();vector<int> queue{seed};labels[seed]=label;
      for(size_t k=0;k<queue.size();k++)for(int step:array<int,4>{-1,1,-PX,PX}) {
        int n=queue[k]+step;if(n<0||n>=PX*PY||labels[n]>=0||projected[n]<ISO)continue;
        labels[n]=label;queue.push_back(n);
      }
      sizes.push_back(queue.size());
    }
    int mainLabel=int(std::max_element(sizes.begin(),sizes.end())-sizes.begin());
    constexpr double bevel=.025, depth=.171;
    for(int y=1;y<PY-1;y++)for(int x=1;x<PX-1;x++) {
      int id2=y*PX+x;
      if(labels[id2]==mainLabel) {
        double gx=(projected[id2+1]-projected[id2-1])/(2*.0078125);
        double gy=(projected[id2+PX]-projected[id2-PX])/(2*.00779411765);
        double a=std::clamp((ISO-projected[id2])/std::max(std::hypot(gx,gy),.001),-.2,.2);
        for(int z=1;z<PZ-1;z++) {
          double b=std::abs(p[nid(x,y,z)].z)-depth;
          double qx=a+bevel,qy=b+bevel;
          double phi=std::min(std::max(qx,qy),0.)+std::hypot(std::max(qx,0.),std::max(qy,0.))-bevel;
          f[nid(x,y,z)]=ISO-float(4*phi);
        }
      }
      for(int z=1;z<PZ-1;z++)for(auto q:bs) {
        int id=nid(x,y,z);V d=sub(p[id],{q.x,q.y,q.z});
        f[id]=std::min(f[id],ISO+4.f*(float(std::sqrt(dot(d,d)))-q.r));
      }
    }
  }
  vector<V> verts; vector<array<int,3>> faces; std::map<std::pair<int,int>,int> edge;
  auto vertex=[&](int a,int c){auto k=std::minmax(a,c);auto it=edge.find(k);if(it!=edge.end())return it->second;float t=(ISO-f[a])/(f[c]-f[a]);V q={p[a].x+(p[c].x-p[a].x)*t,p[a].y+(p[c].y-p[a].y)*t,p[a].z+(p[c].z-p[a].z)*t};int n=verts.size();verts.push_back(q);edge[k]=n;return n;};
  auto tri=[&](int a,int c,int d,V toward){V n=cross(sub(verts[c],verts[a]),sub(verts[d],verts[a]));if(dot(n,toward)<0)std::swap(c,d);if(a!=c&&c!=d&&d!=a&&dot(n,n)>1e-28)faces.push_back({a,c,d});};
  int cube[8][3]={{0,0,0},{1,0,0},{0,1,0},{1,1,0},{0,0,1},{1,0,1},{0,1,1},{1,1,1}};int tet[6][4]={{0,1,3,7},{0,3,2,7},{0,2,6,7},{0,6,4,7},{0,4,5,7},{0,5,1,7}};
  for(int z=0;z<PZ-1;z++)for(int y=0;y<PY-1;y++)for(int x=0;x<PX-1;x++){int c[8];for(int q=0;q<8;q++)c[q]=nid(x+cube[q][0],y+cube[q][1],z+cube[q][2]);for(auto &t:tet){vector<int>I,O;V ci{0,0,0},co{0,0,0};for(int q:t)(f[c[q]]>=ISO?I:O).push_back(c[q]);for(int q:I){ci.x+=p[q].x;ci.y+=p[q].y;ci.z+=p[q].z;}for(int q:O){co.x+=p[q].x;co.y+=p[q].y;co.z+=p[q].z;}if(I.empty()||O.empty())continue;ci={ci.x/I.size(),ci.y/I.size(),ci.z/I.size()};co={co.x/O.size(),co.y/O.size(),co.z/O.size()};V toward=sub(co,ci);if(I.size()==1){int a=vertex(I[0],O[0]),bb=vertex(I[0],O[1]),cc=vertex(I[0],O[2]);tri(a,bb,cc,toward);}else if(O.size()==1){int a=vertex(O[0],I[0]),bb=vertex(O[0],I[1]),cc=vertex(O[0],I[2]);tri(a,cc,bb,toward);}else {int a=vertex(I[0],O[0]),bb=vertex(I[0],O[1]),cc=vertex(I[1],O[0]),dd=vertex(I[1],O[1]);tri(a,bb,cc,toward);tri(bb,dd,cc,toward);}}}
  std::map<std::pair<int,int>,vector<std::pair<int,int>>> incidence; double vol=0; for(auto q:faces){for(auto e:array<array<int,2>,3>{{{{q[0],q[1]}},{{q[1],q[2]}},{{q[2],q[0]}}}}){auto k=std::minmax(e[0],e[1]);incidence[k].push_back({e[0],e[1]});}vol+=dot(verts[q[0]],cross(verts[q[1]],verts[q[2]]))/6.;}
  for(auto &e:incidence)if(e.second.size()!=2||e.second[0].first!=e.second[1].second||e.second[0].second!=e.second[1].first)throw std::runtime_error("nonmanifold/orientation edge"); for(auto q:verts)if(!std::isfinite(q.x)||!std::isfinite(q.y)||!std::isfinite(q.z))throw std::runtime_error("nonfinite vertex"); if(!(vol>0))throw std::runtime_error("nonpositive signed volume");
  std::ofstream o(out);if(!o)throw std::runtime_error("PLY open");o<<std::setprecision(17);o<<"ply\nformat ascii 1.0\nelement vertex "<<verts.size()<<"\nproperty float x\nproperty float y\nproperty float z\nelement face "<<faces.size()<<"\nproperty list uchar int vertex_indices\nend_header\n";for(auto q:verts)o<<q.x<<' '<<q.y<<' '<<q.z<<'\n';for(auto q:faces)o<<"3 "<<q[0]<<' '<<q[1]<<' '<<q[2]<<'\n';std::cout<<"{\"vertices\":"<<verts.size()<<",\"faces\":"<<faces.size()<<",\"signedVolume\":"<<vol<<",\"manifold\":true}\n";
 }catch(const std::exception&e){std::cerr<<"FAIL "<<e.what()<<'\n';return 1;}}
