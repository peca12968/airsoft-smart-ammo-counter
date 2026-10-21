#include "../AmmoSensor/VibrationDetector.h"
#include <assert.h>
#include <stdio.h>
int main(){ const uint8_t b[64]={65,77,68,49,1,3,16,1,42,0,0,0,1,0,200,0,143,194,245,60,205,204,76,62,10,215,163,61,0,0,160,64,143,194,245,60,10,215,35,60,0,0,0,64,0,0,16,65,10,215,163,61,143,194,117,60,210,4,0,0,80,0,120,79};
Ammo::DetectorProfile p;assert(p.decode(b,64));assert(p.id()==42);assert(p.accepts(.2f,.08f,5));assert(!p.accepts(.065f,.002f,35));assert(!p.decode(b,63));
uint8_t bad[64];memcpy(bad,b,64);bad[24]^=1;assert(!p.decode(bad,64));memcpy(bad,b,64);Ammo::w32(bad+20,0x7f800000);Ammo::w32(bad+60,Ammo::crc32(bad,60));assert(!p.decode(bad,64));
Ammo::MotionPipeline m;Ammo::MotionFeature f;uint32_t us=1000;int events=0,usable=0;
for(int i=0;i<1600;++i){us+=2404;float a=(i==600||i==1000)?.2f:0;if(m.push(a,0,1,0,0,0,us,.03f,.015f,200,f)){if(f.flags==1)++events;if(!(f.flags&14))++usable;}}assert(events==2&&usable>20);
m.reset();bool gap=false,clip=false;for(int i=0;i<32;++i){us+=i==2?12000:2404;if(m.push(i==1?8.f:0,0,1,0,0,0,us,.03f,.015f,200,f)){gap|=f.flags&4;clip|=f.flags&2;}}assert(gap&&clip);puts("PASS: CRC/finite checks, profile match, onset/rearm, timing gaps, clipping");}
