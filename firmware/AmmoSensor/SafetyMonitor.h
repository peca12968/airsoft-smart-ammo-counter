#pragma once
#include "CounterEngine.h"
namespace Ammo {
// Application guardrails for an uncalibrated VBAT rail and MCU die sensor.
// These do not measure cell temperature or disconnect charging/discharging.
enum class SafetyReason : uint8_t { none=0, hot=1, lowVoltage=2, highVoltage=3, temperatureUnavailable=4, watchdog=5, voltageUnavailable=6 };
class SafetyMonitor {
    uint8_t badTemperature=0, lowSamples=0, highSamples=0, badVoltage=0;
    bool hotWarning=false, lowWarning=false, highWarning=false;
    static uint8_t count(bool condition, uint8_t previous) { return condition ? (previous<3 ? previous+1:3):0; }
public:
    bool locked=false, temperatureValid=false, voltageValid=false, usb=false;
    uint8_t chargeActive=255;
    SafetyReason reason=SafetyReason::temperatureUnavailable;
    uint16_t millivolts=0;
    int16_t quarterDegrees=INT16_MIN;
    uint32_t sample=0;
    void latch(SafetyReason value) { if(!locked) { locked=true; reason=value; } }
    bool warning() const { return locked || hotWarning || lowWarning || highWarning || !temperatureValid; }
    bool ready() const { return sample>0 && temperatureValid && !locked; }
    template<class Save> bool event(Engine& engine, Save save) const { return ready() && engine.event(save); }
    template<class Save> Ack command(Engine& engine, const uint8_t* p, size_t n, Save save) const {
        return ready() ? engine.command(p,n,save) : Ack{2,n>=8 ? r32(p+4):0,engine.state.boot,engine.state.sequence};
    }
    void update(uint16_t mv, int16_t temp, bool tempOK, bool usbPresent, uint8_t charging) {
        if(sample<UINT32_MAX) ++sample; else latch(SafetyReason::voltageUnavailable);
        millivolts=mv; usb=usbPresent; chargeActive=charging;
        temperatureValid=tempOK && temp>=-160 && temp<=500;
        quarterDegrees=temperatureValid ? temp:INT16_MIN;
        voltageValid=mv>=1000 && mv<=9000;
        badTemperature=count(!temperatureValid,badTemperature);
        badVoltage=count(!usb && !voltageValid,badVoltage);
        lowSamples=count(!usb && voltageValid && mv<3200,lowSamples);
        highSamples=count(voltageValid && mv>=4350,highSamples);
        if(temperatureValid && temp>=240) latch(SafetyReason::hot); // 60 C die, not cell.
        if(badTemperature>=3) latch(SafetyReason::temperatureUnavailable);
        if(badVoltage>=3) latch(SafetyReason::voltageUnavailable);
        if(lowSamples>=3) latch(SafetyReason::lowVoltage);
        if(highSamples>=3) latch(SafetyReason::highVoltage);
        if(temperatureValid) { if(temp>=180) hotWarning=true; else if(temp<=160) hotWarning=false; }
        if(usb || (voltageValid && mv>=3600)) lowWarning=false;
        else if(voltageValid && mv<3500) lowWarning=true;
        if(voltageValid) { if(mv>=4250) highWarning=true; else if(mv<=4200) highWarning=false; }
        if(!locked) reason=!temperatureValid ? SafetyReason::temperatureUnavailable : hotWarning ? SafetyReason::hot : highWarning ? SafetyReason::highVoltage : lowWarning ? SafetyReason::lowVoltage : SafetyReason::none;
    }
    void encode(uint8_t* p, uint32_t boot) const {
        memset(p,0,20); p[0]=1;
        p[1]=(temperatureValid ? 1:0) | (voltageValid ? 2:0) | (warning() ? 4:0) | (locked ? 8:0);
        w16(p+2,voltageValid ? millivolts:UINT16_MAX); w16(p+4,uint16_t(quarterDegrees));
        p[6]=usb; p[7]=chargeActive; p[8]=uint8_t(reason);
        w32(p+12,sample); w32(p+16,boot);
    }
};
}
