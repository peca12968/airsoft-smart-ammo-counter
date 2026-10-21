#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
namespace Ammo {
// Main-loop-owned FIFO. Never waits for a radio connection event.
// Stream frames remain ordered before their final training-status packet.
template<size_t Capacity> class NotificationQueue {
public:
    struct Packet { uint16_t connection,attribute;uint32_t session;uint16_t length;uint8_t data[20]; };
    bool push(uint16_t connection,uint32_t session,uint16_t attribute,const uint8_t* data,uint16_t length,bool coalesce) {
        if(!data || !length || length>20)return false;
        if(coalesce)for(size_t i=0;i<count_;++i){auto& p=packets_[(head_+i)%Capacity];if(p.connection==connection && p.session==session && p.attribute==attribute){p.length=length;memcpy(p.data,data,length);return true;}}
        if(count_==Capacity)return false;
        auto& p=packets_[(head_+count_)%Capacity];p.connection=connection;p.session=session;p.attribute=attribute;p.length=length;memcpy(p.data,data,length);++count_;return true;
    }
    const Packet* front() const {return count_?&packets_[head_]:nullptr;}
    void pop(){if(count_){head_=(head_+1)%Capacity;--count_;}}
    void clear(){head_=count_=0;}
    size_t size() const{return count_;}
private:
    Packet packets_[Capacity];size_t head_=0,count_=0;
};
}
