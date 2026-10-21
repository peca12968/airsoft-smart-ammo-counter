#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <limits.h>
#include "GATT.h"
namespace Ammo {
inline uint16_t r16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
inline uint32_t r32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1])<<8 | uint32_t(p[2])<<16 | uint32_t(p[3])<<24; }
inline uint64_t r64(const uint8_t* p) { return uint64_t(r32(p)) | uint64_t(r32(p+4))<<32; }
inline void w16(uint8_t* p, uint16_t v) { p[0]=v; p[1]=v>>8; }
inline void w32(uint8_t* p, uint32_t v) { for (int i=0;i<4;++i) p[i]=v>>(8*i); }
inline void w64(uint8_t* p, uint64_t v) { w32(p,uint32_t(v)); w32(p+4,uint32_t(v>>32)); }
inline uint32_t crc32(const uint8_t* p, size_t n) {
    uint32_t crc=0xffffffff;
    for(size_t i=0;i<n;++i) { crc ^= p[i]; for(int b=0;b<8;++b) crc=(crc>>1) ^ (0xedb88320u & (0u-(crc&1u))); }
    return ~crc;
}
struct State {
    uint16_t capacity=300, remaining=300;
    uint32_t total=0, sequence=0, boot=1;
    uint8_t battery=255, flags=32;
    void encode(uint8_t* p) const {
        p[0]=GATT::version; p[1]=flags; w16(p+2,capacity); w16(p+4,remaining); w32(p+6,total);
        w32(p+10,sequence); w32(p+14,boot); p[18]=battery; p[19]=0;
    }
    bool decode(const uint8_t* p) {
        if(p[0]!=GATT::version || p[19]!=0 || (p[1]&0xc0)) return false;
        State s; s.flags=p[1]; s.capacity=r16(p+2); s.remaining=r16(p+4); s.total=r32(p+6);
        s.sequence=r32(p+10); s.boot=r32(p+14); s.battery=p[18];
        if(s.capacity<1 || s.capacity>9999 || s.remaining>s.capacity || !s.boot || (s.battery>100 && s.battery!=255)) return false;
        *this=s; return true;
    }
};
struct Ack {
    uint8_t result; uint32_t request, boot, sequence;
    void encode(uint8_t* p) const { p[0]=GATT::version; p[1]=result; w32(p+2,request); w32(p+6,boot); w32(p+10,sequence); }
};
struct Engine {
    State state;
    uint64_t generation=0, deviceID=0;
    uint32_t resetBaseline=0,resetGeneration=0;
    bool hasLast=false;
    uint8_t lastCommand[16]={0}, lastAck[14]={0};
    template<class Save> Ack command(const uint8_t* p, size_t n, Save save) {
        const uint32_t request=n>=8 ? r32(p+4):0;
        Ack ack{2,request,state.boot,state.sequence};
        if(n!=16 || p[0]!=GATT::version || !request) return ack;
        if(hasLast && memcmp(p,lastCommand,16)==0) return Ack{lastAck[1],r32(lastAck+2),r32(lastAck+6),r32(lastAck+10)};
        if(r32(p+12)!=state.boot || r32(p+8)!=state.sequence) { ack.result=1; return ack; }
        if(state.sequence==UINT32_MAX) { ack.result=4; return ack; }
        if(state.flags&4) { ack.result=3; return ack; }
        Engine next=*this; const int32_t value=int16_t(r16(p+2));
        if(p[1]==1 || p[1]==3) {
            if(value<1 || value>9999) return ack;
            next.state.capacity=uint16_t(value);
            next.state.remaining=p[1]==1 ? uint16_t(value) : (state.remaining>value ? uint16_t(value):state.remaining);
        } else if(p[1]==2) {
            if(value < -9999 || value > 9999) return ack;
            int32_t remaining=int32_t(state.remaining)+value;
            next.state.remaining=remaining<0 ? 0 : remaining>state.capacity ? state.capacity:uint16_t(remaining);
        } else if(p[1]==4) {
            if(value!=21075 || resetGeneration==UINT32_MAX)return ack;
            next.resetBaseline=state.total;++next.resetGeneration;
        } else return ack;
        ++next.state.sequence; if(next.state.sequence==UINT32_MAX) next.state.flags|=16; ack.result=0; ack.sequence=next.state.sequence;
        next.hasLast=true; memcpy(next.lastCommand,p,16); ack.encode(next.lastAck);
        if(!save(next)) { ack.result=3; ack.sequence=state.sequence; return ack; }
        *this=next; return ack;
    }
    template<class Save> bool event(Save save) {
        if(state.sequence==UINT32_MAX || (state.flags&4)) return false;
        Engine next=*this;
        if(next.state.remaining) --next.state.remaining;
        if(next.state.total<UINT32_MAX) ++next.state.total;
        if(next.state.total==UINT32_MAX) next.state.flags|=8;
        ++next.state.sequence; if(next.state.sequence==UINT32_MAX) next.state.flags|=16;
        if(!save(next)) return false;
        *this=next; return true;
    }
    static constexpr size_t journalSize=83;
    void encodeJournal(uint8_t* p) const {
        w32(p,0x314f4d41); w64(p+4,generation); w64(p+12,deviceID); state.encode(p+20);
        p[40]=hasLast; memcpy(p+41,lastCommand,16); memcpy(p+57,lastAck,14); w32(p+71,resetBaseline);w32(p+75,resetGeneration);w32(p+79,crc32(p,79));
    }
    bool decodeJournal(const uint8_t* p, size_t size) {
        if((size!=75 && size!=journalSize) || r32(p)!=0x314f4d41 || !r64(p+12) || p[40]>1) return false;
        if(size==75 ? r32(p+71)!=crc32(p,71):r32(p+79)!=crc32(p,79))return false;
        Engine next; if(!next.state.decode(p+20)) return false;
        next.generation=r64(p+4); next.deviceID=r64(p+12); next.hasLast=p[40];
        if(size==journalSize){next.resetBaseline=r32(p+71);next.resetGeneration=r32(p+75);if(next.resetBaseline>next.state.total || (!next.resetGeneration && next.resetBaseline))return false;}
        memcpy(next.lastCommand,p+41,16); memcpy(next.lastAck,p+57,14); *this=next; return true;
    }
};
}
