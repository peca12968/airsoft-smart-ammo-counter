#pragma once
#include <stdint.h>
namespace Ammo {
// Closed D0-to-GND means RUN; open/unwired means standby. No automatic timeout.
class RunSwitch {
    bool candidate = false, stable = false;
    uint32_t candidateSince = 0;
public:
    bool update(bool closed, uint32_t now) {
        if(closed != candidate) { candidate = closed; candidateSince = now; }
        if(candidate != stable && uint32_t(now-candidateSince) >= 50) stable = candidate;
        return stable;
    }
};
}
