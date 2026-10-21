#pragma once
#include <arm_math.h>
#include <arm_const_structs.h>
BLECharacteristic audioSpectrumChar(GATT::audioSpectrum);
// ISR fills one 128-sample PCM window; main loop owns FFT, BLE and inference.
int16_t spectrumPCM[2][128];volatile uint8_t spectrumWriting=0,spectrumReady=255;volatile uint16_t spectrumIndex=0;
volatile uint32_t spectrumOverruns=0;
float spectrumFFT[256],spectrumHann[128],spectrumBands[8]={0};
uint32_t spectrumPreviousOverruns=0;
uint32_t spectrumSamples=0,spectrumWindows=0,spectrumStarted=0,spectrumFrames=0;
float spectrumSquares=0,spectrumMaximumPower=0;uint16_t spectrumDominant=0,spectrumSequence=0,spectrumCapture=0;bool spectrumClipped=false;
uint32_t acousticLastEvent=0,acousticQuietSince=0;bool acousticArmed=false;
float acousticSimilarity=0;
void pushAudioPCM(int16_t value){
    spectrumPCM[spectrumWriting][spectrumIndex++]=value;
    if(spectrumIndex==128){
        if(spectrumReady==255){spectrumReady=spectrumWriting;spectrumWriting^=1;}else ++spectrumOverruns;
        spectrumIndex=0;
    }
}
void clearSpectrumAccumulator(){memset(spectrumBands,0,sizeof(spectrumBands));spectrumSquares=0;spectrumSamples=spectrumWindows=0;spectrumMaximumPower=0;spectrumDominant=0;spectrumClipped=false;}
void beginAudioSpectrum(){
    for(int i=0;i<128;++i)spectrumHann[i]=.5f-.5f*cosf(2*PI*i/127.f);
    audioSpectrumChar.setProperties(CHR_PROPS_READ|CHR_PROPS_NOTIFY);audioSpectrumChar.setPermission(SECMODE_OPEN,SECMODE_NO_ACCESS);audioSpectrumChar.setFixedLen(20);audioSpectrumChar.begin();
}
void processAudioSpectrum(){
    uint8_t ready=spectrumReady;if(ready==255)return;
    // The producer cannot reuse the ready buffer until it is released below.
    float mean=0;for(int i=0;i<128;++i)mean+=spectrumPCM[ready][i];mean/=128;
    for(int i=0;i<128;++i){float x=(spectrumPCM[ready][i]-mean)/32768.f;spectrumSquares+=x*x;++spectrumSamples;spectrumClipped|=spectrumPCM[ready][i]>=32760 || spectrumPCM[ready][i]<=-32760;spectrumFFT[2*i]=x*spectrumHann[i];spectrumFFT[2*i+1]=0;}
    spectrumReady=255;
    arm_cfft_f32(&arm_cfft_sR_f32_len128,spectrumFFT,0,1);
    for(int bin=1;bin<64;++bin){float re=spectrumFFT[2*bin],im=spectrumFFT[2*bin+1],power=re*re+im*im;int band=bin<2?0:bin<4?1:bin<8?2:bin<16?3:bin<24?4:bin<32?5:bin<48?6:7;spectrumBands[band]+=power;if(power>spectrumMaximumPower){spectrumMaximumPower=power;spectrumDominant=bin*125;}}
    if(++spectrumWindows<4)return; // 32 ms analysis block: bounded FFT and recognition latency.
    const float rms=sqrtf(spectrumSquares/spectrumSamples);float sum=0;for(float x:spectrumBands)sum+=x;
    uint8_t bands[8];for(int i=0;i<8;++i)bands[i]=sum>0 ? uint8_t(fminf(255,spectrumBands[i]*255/sum)):0;
    const uint32_t now=millis();uint8_t flags=(spectrumClipped?2:0) | (now-spectrumStarted<500?8:0) | (spectrumOverruns!=spectrumPreviousOverruns?4:0);spectrumPreviousOverruns=spectrumOverruns;
    const bool capturing=trainingMode==1 || trainingMode==2;uint16_t capture=capturing?captureID:0;
    if(capture!=spectrumCapture){spectrumCapture=capture;spectrumSequence=0;}
    uint8_t p[20]={1,flags};Ammo::w16(p+2,++spectrumSequence);Ammo::w16(p+4,capture);Ammo::w16(p+6,uint16_t(fminf(32768,rms*32768)));memcpy(p+8,bands,8);Ammo::w16(p+16,spectrumDominant);Ammo::w16(p+18,uint16_t(now));audioSpectrumChar.write(p,20);++spectrumFrames;
    uint16_t owner=capturing?captureOwner:previewOwner;uint32_t session=capturing?captureSession:previewSession;
    if(owner<BLE_MAX_CONNECTION && Bluefruit.connected(owner) && sessions[owner]==session)queueNotification(audioSpectrumChar,owner,p,20);
    if(detectorEnabled && trainingMode==3 && detector.audio() && safety.ready() && !flags){
        acousticSimilarity=detector.audioSimilarity(bands);
        if(rms<detector.audioRearm()){if(!acousticQuietSince)acousticQuietSince=now;if(uint32_t(now-acousticQuietSince)>=64)acousticArmed=true;}else acousticQuietSince=0;
        if(acousticArmed && rms>=detector.audioOnset() && acousticSimilarity>=detector.audioMinimumSimilarity() && (!acousticLastEvent || uint32_t(now-acousticLastEvent)>=detector.refractory())){
            acousticArmed=false;acousticLastEvent=now;
            if(!safety.event(engine,saveEngine)){detectorEnabled=false;trainingMode=0;trainingResult=4;publishTraining();}
            publishState();
        }
    }
    clearSpectrumAccumulator();
}
