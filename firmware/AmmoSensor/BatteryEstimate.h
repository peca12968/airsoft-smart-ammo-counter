#pragma once
#include <stdint.h>
namespace Ammo {
// Nominal original Sense divider: 1M top / 510k bottom; 3.0V ADC reference.
inline float batteryVoltage(uint16_t adc) { return float(adc) * (3.0f / 4095.0f) * (1510.0f / 510.0f); }
// Provisional resting-voltage estimate. Must be calibrated with the actual protected LiPo.
inline uint8_t batteryPercent(float volts) {
    if(volts<2.8f || volts>4.35f) return 255;
    const float voltage[]={3.30f,3.60f,3.70f,3.80f,3.90f,4.00f,4.10f,4.20f};
    const uint8_t percent[]={0,10,20,40,60,75,90,100};
    if(volts<=voltage[0]) return 0;
    for(int i=1;i<8;++i) if(volts<=voltage[i]) return percent[i-1]+uint8_t((volts-voltage[i-1])/(voltage[i]-voltage[i-1])*(percent[i]-percent[i-1]));
    return 100;
}
}
