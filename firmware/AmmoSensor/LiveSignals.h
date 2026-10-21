#pragma once
#include <PDM.h>
#include "AudioSpectrum.h"
static_assert(PIN_PDM_PWR==19 && PIN_PDM_CLK==20 && PIN_PDM_DIN==21,"Original Sense microphone pins required");
BLECharacteristic liveSignalChar(GATT::liveSignal);
bool microphoneActive=false;uint16_t liveSequence=0;uint32_t lastLive=0;
volatile uint64_t audioSquares=0;volatile uint32_t audioCount=0,audioTotalSamples=0;volatile uint16_t audioPeak=0;volatile bool audioClipped=false;
uint16_t lastAudioPeak=0,lastAudioRMS=0;volatile uint16_t maximumAudioPeak=0;
void audioReceive() {
    int16_t samples[64];
    while(PDM.available()>0) {
        int bytes=PDM.read(samples,sizeof(samples)),n=bytes/2;if(n<=0)break;
        int32_t sum=0;for(int i=0;i<n;++i)sum+=samples[i];int32_t mean=sum/n;
        for(int i=0;i<n;++i){pushAudioPCM(samples[i]);int32_t x=int32_t(samples[i])-mean;if(x>32767)x=32767;if(x< -32768)x=-32768;uint32_t magnitude=x<0 ? uint32_t(-x):uint32_t(x);if(magnitude>audioPeak)audioPeak=magnitude;if(magnitude>maximumAudioPeak)maximumAudioPeak=magnitude;audioSquares+=uint64_t(magnitude)*magnitude;if(samples[i]>=32760 || samples[i]<=-32760)audioClipped=true;}
        audioCount+=n;audioTotalSamples+=n;
    }
}
void stopLiveAudio(){if(microphoneActive){PDM.end();microphoneActive=false;}liveRequested=false;}
void beginLiveSignals(){
    beginAudioSpectrum();
    PDM.setPins(PIN_PDM_DIN,PIN_PDM_CLK,PIN_PDM_PWR);PDM.onReceive(audioReceive);
    liveSignalChar.setProperties(CHR_PROPS_READ|CHR_PROPS_NOTIFY);liveSignalChar.setPermission(SECMODE_OPEN,SECMODE_NO_ACCESS);liveSignalChar.setFixedLen(20);liveSignalChar.begin();
}
void updateLiveSignals(){
    if(previewOwner!=BLE_CONN_HANDLE_INVALID && (!Bluefruit.connected(previewOwner) || sessions[previewOwner]!=previewSession || int32_t(millis()-previewDeadline)>=0))previewOwner=BLE_CONN_HANDLE_INVALID;
    const bool capturing=trainingMode==1 || trainingMode==2;
    const bool wanted=runEnabled && safety.ready() && (capturing || previewOwner!=BLE_CONN_HANDLE_INVALID || diagnosticMotion || (detectorEnabled && detector.audio()));
    liveRequested=wanted;
    if(wanted && !microphoneActive){maximumAudioPeak=0;audioTotalSamples=0;audioCount=0;audioSquares=0;audioPeak=0;spectrumReady=255;spectrumIndex=0;clearSpectrumAccumulator();spectrumStarted=millis();acousticArmed=false;acousticQuietSince=acousticLastEvent=0;microphoneActive=PDM.begin(1,16000)==1;}
    if(!wanted && microphoneActive)stopLiveAudio();
    if(uint32_t(millis()-lastLive)<100)return;lastLive=millis();
    uint32_t count=0;uint64_t squares=0;uint16_t peak=0;bool clipped=false;
    if(microphoneActive){NVIC_DisableIRQ(PDM_IRQn);count=audioCount;squares=audioSquares;peak=audioPeak;clipped=audioClipped;audioCount=0;audioSquares=0;audioPeak=0;audioClipped=false;NVIC_EnableIRQ(PDM_IRQn);}
    lastAudioRMS=count?uint16_t(fminf(32768,sqrtf(float(squares)/count))):0;lastAudioPeak=peak;
    uint8_t p[20]={1,uint8_t((microphoneActive&&count?1:0) | (clipped?2:0) | (imuOK?4:0))};
    if(++liveSequence==0)++liveSequence;Ammo::w16(p+2,liveSequence);Ammo::w32(p+4,millis());Ammo::w16(p+8,lastAudioRMS);Ammo::w16(p+10,peak);Ammo::w16(p+12,uint16_t(fminf(32000,lastMotionPeak*1000)));Ammo::w16(p+14,uint16_t(count>16000?16000:count));Ammo::w32(p+16,engine.state.boot);liveSignalChar.write(p,20);
    uint16_t owner=capturing?captureOwner:previewOwner;uint32_t session=capturing?captureSession:previewSession;
    if(owner<BLE_MAX_CONNECTION && Bluefruit.connected(owner) && sessions[owner]==session)queueNotification(liveSignalChar,owner,p,20,true);
}
