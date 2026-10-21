#pragma once
#include "CounterEngine.h"
#include <math.h>
namespace Ammo {
inline float rf(const uint8_t* p) { uint32_t u=r32(p); float f; memcpy(&f,&u,4); return f; }
inline bool finiteFloat(float f) { uint32_t bits;memcpy(&bits,&f,4);return (bits & 0x7f800000u)!=0x7f800000u; }
struct DetectorProfile {
    uint8_t bytes[64]={0};
    uint32_t id() const { return r32(bytes+8); }
    bool test() const { return bytes[12]!=0; }
    bool audio() const {return r32(bytes)==0x32444d41;}
    float audioOnset() const {return rf(bytes+16);}
    float audioRearm() const {return rf(bytes+56);}
    float audioMinimumSimilarity() const {return rf(bytes+52);}
    float audioSimilarity(const uint8_t* bands) const {float dot=0,a=0,b=0;for(int i=0;i<8;++i){float x=rf(bytes+20+4*i),y=bands[i]/255.f;dot+=x*y;a+=x*x;b+=y*y;}return a>0 && b>0?dot/sqrtf(a*b):0;}
    bool sensitive() const {return bytes[13]==1;}
    uint16_t refractory() const { return r16(bytes+14); }
    float onset() const { return rf(bytes+16); }
    float rearm() const { return rf(bytes+52); }
    bool decode(const uint8_t* p,size_t n) {
        if(n==64 && r32(p)==0x32444d41){
            if(p[4]!=1 || p[5]!=8 || p[6]!=7 || p[7]!=16 || !r32(p+8) || p[12]>1 || p[13] || r16(p+14)<80 || r16(p+14)>2000 || crc32(p,60)!=r32(p+60))return false;
            for(int at=16;at<=56;at+=4)if(!finiteFloat(rf(p+at)))return false;
            if(rf(p+16)<.0001f || rf(p+16)>.9f || rf(p+56)<=0 || rf(p+56)>=rf(p+16) || rf(p+52)<.5f || rf(p+52)>.99f)return false;
            float sum=0;for(int i=0;i<8;++i){float x=rf(p+20+4*i);if(x<0 || x>1)return false;sum+=x;}if(sum<.9f || sum>1.1f)return false;
            memcpy(bytes,p,64);return true;
        }
        if(n!=64 || r32(p)!=0x31444d41 || p[4]!=1 || p[5]!=3 || p[6]!=16 || p[7]!=1 || !r32(p+8) || p[12]>1 || p[13]>1 || crc32(p,60)!=r32(p+60)) return false;
        if(r16(p+14)<50 || r16(p+14)>2000) return false;
        for(int a=16;a<=52;a+=4) if(!finiteFloat(rf(p+a))) return false;
        const float onset=rf(p+16);
        if(onset<.0019999f || onset>1 || rf(p+44)<.5f || rf(p+44)>100 || rf(p+48)<onset || rf(p+48)>32 || rf(p+52)<=0 || rf(p+52)>=onset) return false;
        for(int i=0;i<3;++i) if(rf(p+20+4*i)<0 || rf(p+20+4*i)>(i==2 ? 3600:32) || rf(p+32+4*i)<.0009999f || rf(p+32+4*i)>3600) return false;
        memcpy(bytes,p,64); return true;
    }
    bool accepts(float peak,float rms,float gyro) const {
        if(peak<rf(bytes+48)) return false;
        if(sensitive())return true;
        const float values[3]={peak,rms,gyro}; float distance=0;
        for(int i=0;i<3;++i) { float z=(values[i]-rf(bytes+20+4*i))/rf(bytes+32+4*i); distance+=z*z; }
        return finiteFloat(distance) && distance<=rf(bytes+44);
    }
};
struct MotionFeature {
    float peak=0,rms=0,gyro=0;
    uint32_t timestamp=0;
    uint8_t flags=0,clipped=0;
    void encode(uint8_t* p,uint16_t capture,uint16_t seq,uint8_t label) const {
        memset(p,0,20); p[0]=1;p[1]=flags;w16(p+2,capture);w16(p+4,seq);p[6]=16;p[7]=label;w32(p+8,timestamp);
        w16(p+12,uint16_t(fminf(32000,roundf(peak*1000))));w16(p+14,uint16_t(fminf(32000,roundf(rms*1000))));
        w16(p+16,uint16_t(fminf(36000,roundf(gyro*10))));p[18]=clipped;
    }
};
// Fixed windows at the actual IMU output rate. No microphone or firing-mechanism control.
struct MotionPipeline {
    float gravity[3]={0},sum=0; MotionFeature frame;
    uint8_t count=0; uint16_t settled=0; uint32_t lastUs=0,lastOnset=0,quietSince=0;
    bool initialized=false,armed=false;
    void reset() { *this=MotionPipeline(); }
    bool push(float ax,float ay,float az,float gx,float gy,float gz,uint32_t us,float onset,float rearm,uint16_t refractory,MotionFeature& out) {
        if(!initialized) {gravity[0]=ax;gravity[1]=ay;gravity[2]=az;initialized=true;}
        if(!count) {frame=MotionFeature();sum=0;frame.timestamp=us/1000;}
        if(lastUs && uint32_t(us-lastUs)>6500) frame.flags|=4;
        lastUs=us; float acc[3]={ax,ay,az},power=0;
        for(int i=0;i<3;++i) { gravity[i]+=.02f*(acc[i]-gravity[i]);float h=acc[i]-gravity[i];power+=h*h; }
        float peak=sqrtf(power),gyro=sqrtf(gx*gx+gy*gy+gz*gz);
        frame.peak=fmaxf(frame.peak,peak);frame.gyro=fmaxf(frame.gyro,gyro);sum+=power;
        if(fabsf(ax)>7.9f || fabsf(ay)>7.9f || fabsf(az)>7.9f || fabsf(gx)>1990 || fabsf(gy)>1990 || fabsf(gz)>1990) {++frame.clipped;frame.flags|=2;}
        if(settled<416) {++settled;frame.flags|=8;}
        if(peak<rearm) { if(!quietSince) quietSince=us; if(uint32_t(us-quietSince)>=8000) armed=true; }
        else quietSince=0;
        if(armed && peak>=onset && (!lastOnset || uint32_t(us-lastOnset)>=uint32_t(refractory)*1000)) { frame.flags|=1;armed=false;lastOnset=us; }
        if(++count!=16) return false;
        frame.rms=sqrtf(sum/16);out=frame;count=0;return true;
    }
};
}
