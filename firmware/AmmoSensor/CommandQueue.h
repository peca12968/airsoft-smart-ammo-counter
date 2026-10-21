#pragma once
#include <stdint.h>
#include <stddef.h>
#include <string.h>
namespace Ammo {
struct QueuedCommand {
    uint16_t connection = 0;
    uint32_t session = 0;
    uint8_t data[16] = {0};
};
// Caller provides the RTOS critical section; never overwrite an older request.
template<size_t Capacity> class CommandQueue {
    static_assert(Capacity > 0, "Queue must have capacity");
    QueuedCommand entries[Capacity];
    size_t head = 0, tail = 0, count = 0;
public:
    void clear() { head = tail = count = 0; }
    bool push(uint16_t connection, uint32_t session, const uint8_t* data, size_t length) {
        if(length != 16 || count == Capacity) return false;
        entries[head].connection = connection; entries[head].session = session;
        memcpy(entries[head].data,data,16); head = (head+1)%Capacity; ++count; return true;
    }
    bool pop(QueuedCommand& result) {
        if(!count) return false;
        result = entries[tail]; tail = (tail+1)%Capacity; --count; return true;
    }
};
}
