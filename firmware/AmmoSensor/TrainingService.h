#pragma once
#include "VibrationDetector.h"
BLECharacteristic trainingControlChar(GATT::trainingControl),trainingDataChar(GATT::trainingData),profileChunkChar(GATT::profileChunk),trainingStatusChar(GATT::trainingStatus);
Ammo::MotionPipeline motion;
bool liveRequested=false;float lastMotionPeak=0;
uint16_t previewOwner=BLE_CONN_HANDLE_INVALID;uint32_t previewSession=0,previewDeadline=0;

uint16_t featureSeen=0,featureUsable=0,featureGaps=0,featureClips=0;
float featureMaximum=0;
bool diagnosticMotion=false;uint32_t diagnosticDeadline=0;
void resetFeatureDiagnostics(){featureSeen=featureUsable=featureGaps=featureClips=0;featureMaximum=0;}

Ammo::DetectorProfile detector;
bool modelAvailable=false,detectorEnabled=false;
uint32_t modelGeneration=0; int modelSlot=-1;
uint8_t trainingMode=0,trainingResult=0;
uint16_t captureOwner=BLE_CONN_HANDLE_INVALID,captureID=0,featureSequence=0,featureSent=0,featureDropped=0;
uint32_t captureSession=0,captureDeadline=0,trainingRequest=0;
uint8_t uploadBytes[64];uint16_t uploadID=0,uploadOwner=BLE_CONN_HANDLE_INVALID;uint8_t uploadIndex=0;
uint32_t uploadSession=0,uploadAt=0;
struct TrainingWrite { uint16_t owner;uint32_t session;uint8_t kind,length,data[20]; };
TrainingWrite trainingQueue[6];uint8_t trainingHead=0,trainingTail=0;
struct LastTraining { uint32_t session=0;uint8_t data[16]={0};bool valid=false; };
LastTraining lastTraining[BLE_MAX_CONNECTION];
const char* modelSlots[2]={"/model0.bin","/model1.bin"};
bool loadModelSlot(int slot,Ammo::DetectorProfile& p,uint32_t& generation,bool& enabled) {
    File file(InternalFS);uint8_t b[80];if(!file.open(modelSlots[slot],FILE_O_READ))return false;
    const size_t size=file.size();const int n=file.read(b,80);file.close();
    if(size!=80 || n!=80 || Ammo::r32(b)!=0x314d5641 || b[8]>1 || b[9] || b[10] || b[11] || Ammo::crc32(b,76)!=Ammo::r32(b+76) || !p.decode(b+12,64))return false;
    generation=Ammo::r32(b+4);enabled=b[8];return generation!=0;
}
bool saveModel(const Ammo::DetectorProfile& profile,bool enabled) {
    if(!storageOK || modelGeneration==UINT32_MAX)return false;
    uint8_t b[80]={0};Ammo::w32(b,0x314d5641);Ammo::w32(b+4,modelGeneration+1);b[8]=enabled;memcpy(b+12,profile.bytes,64);Ammo::w32(b+76,Ammo::crc32(b,76));
    int target=modelSlot==0?1:0;InternalFS.remove(modelSlots[target]);File file(InternalFS);
    if(!file.open(modelSlots[target],FILE_O_WRITE))return false;
    size_t count=file.write(b,80);file.close();Ammo::DetectorProfile verify;uint32_t generation=0;bool on=false;
    if(count!=80 || !loadModelSlot(target,verify,generation,on) || generation!=modelGeneration+1 || on!=enabled || memcmp(verify.bytes,profile.bytes,64))return false;
    modelSlot=target;modelGeneration=generation;detector=verify;detectorEnabled=enabled;modelAvailable=true;return true;
}
void loadDetector() {
    Ammo::DetectorProfile a,b;uint32_t ga=0,gb=0;bool ea=false,eb=false;
    bool va=loadModelSlot(0,a,ga,ea),vb=loadModelSlot(1,b,gb,eb);
    if(!va && !vb)return;modelSlot=va && (!vb || ga>=gb)?0:1;detector=modelSlot==0?a:b;modelGeneration=modelSlot==0?ga:gb;detectorEnabled=modelSlot==0?ea:eb;modelAvailable=true;
}
void publishTraining() {
    uint8_t p[20]={1,trainingMode,trainingResult,uint8_t((modelAvailable?1:0) | (modelAvailable&&detector.test()?2:0) | (imuOK?4:0))};
    Ammo::w32(p+4,trainingRequest);Ammo::w32(p+8,modelAvailable?detector.id():0);Ammo::w16(p+12,featureSent);Ammo::w16(p+14,featureDropped);Ammo::w32(p+16,engine.state.boot);
    trainingStatusChar.write(p,20);uint16_t handles[maxCentrals];uint8_t count=Bluefruit.getConnectedHandles(handles,maxCentrals);
    for(uint8_t i=0;i<count;++i)queueNotification(trainingStatusChar,handles[i],p,20);
}
void receiveTraining(uint16_t handle,BLECharacteristic* characteristic,uint8_t* data,uint16_t length) {
    if(!runEnabled || handle>=BLE_MAX_CONNECTION || (characteristic==&trainingControlChar?length!=16:length!=20))return;
    taskENTER_CRITICAL();uint8_t next=(trainingHead+1)%6;
    if(next!=trainingTail) {TrainingWrite& q=trainingQueue[trainingHead];q.owner=handle;q.session=sessions[handle];q.kind=characteristic==&trainingControlChar?0:1;q.length=length;memcpy(q.data,data,length);trainingHead=next;}
    else ++queueDrops;
    taskEXIT_CRITICAL();
}
void finishCapture(uint8_t result) { trainingMode=0;trainingResult=result;captureOwner=BLE_CONN_HANDLE_INVALID;publishTraining(); }
void processTraining() {
    if(diagnosticMotion && int32_t(millis()-diagnosticDeadline)>=0)diagnosticMotion=false;
    if((trainingMode==1 || trainingMode==2) && (safety.locked || !imuOK || !Bluefruit.connected(captureOwner) || sessions[captureOwner]!=captureSession || int32_t(millis()-captureDeadline)>=0))
        finishCapture(safety.locked?3:0);
    if(trainingMode==3 && (safety.locked || !imuOK)) {detectorEnabled=false;trainingMode=0;trainingResult=3;publishTraining();}
    if(uploadIndex && uint32_t(millis()-uploadAt)>5000) {uploadIndex=0;uploadOwner=BLE_CONN_HANDLE_INVALID;}
    TrainingWrite q;bool have=false;taskENTER_CRITICAL();if(trainingTail!=trainingHead){q=trainingQueue[trainingTail];trainingTail=(trainingTail+1)%6;have=true;}taskEXIT_CRITICAL();
    if(!have || !Bluefruit.connected(q.owner) || sessions[q.owner]!=q.session)return;
    uint8_t* p=q.data;
    if(q.kind==0) {
        uint32_t request=Ammo::r32(p+4);
        if(p[1]==6 || p[1]==7) {
            if(p[0]!=1 || !request || Ammo::r32(p+8)!=engine.state.boot)return;
            if(p[1]==7){if(previewOwner==q.owner && previewSession==q.session)previewOwner=BLE_CONN_HANDLE_INVALID;return;}
            bool occupied=previewOwner!=BLE_CONN_HANDLE_INVALID && Bluefruit.connected(previewOwner) && sessions[previewOwner]==previewSession && int32_t(millis()-previewDeadline)<0;
            if(Ammo::r16(p+2)<1 || Ammo::r16(p+2)>20 || (occupied && (previewOwner!=q.owner || previewSession!=q.session)))return;
            if((trainingMode==1 || trainingMode==2) && (captureOwner!=q.owner || captureSession!=q.session))return;
            previewOwner=q.owner;previewSession=q.session;previewDeadline=millis()+1000*Ammo::r16(p+2);return;
        }
        trainingResult=1;
        if(p[0]!=1 || !request || Ammo::r32(p+8)!=engine.state.boot){trainingRequest=request;publishTraining();return;}
        LastTraining& last=lastTraining[q.owner];
        if(last.valid && last.session==q.session && memcmp(last.data,p,16)==0){trainingResult=0;publishTraining();return;}
        if(last.valid && last.session==q.session && Ammo::r32(last.data+4)==request){uint32_t old=trainingRequest;trainingRequest=request;trainingResult=1;publishTraining();trainingRequest=old;trainingResult=0;return;}
        if((trainingMode==1 || trainingMode==2) && (q.owner!=captureOwner || q.session!=captureSession)) {uint32_t old=trainingRequest;trainingRequest=request;trainingResult=2;publishTraining();trainingRequest=old;trainingResult=0;return;}
        trainingRequest=request;
        if(p[1]==1 || p[1]==2) {
            if(safety.locked || !imuOK || !safety.temperatureValid)trainingResult=3;
            else if(Ammo::r16(p+2)<4 || Ammo::r16(p+2)>20 || !uint16_t(request))trainingResult=1;
            else if(modelAvailable && detectorEnabled && !saveModel(detector,false))trainingResult=4;
            else {
                detectorEnabled=false;trainingMode=p[1];trainingResult=0;captureID=uint16_t(request);captureOwner=q.owner;captureSession=q.session;captureDeadline=millis()+1000*Ammo::r16(p+2);
                featureSequence=featureSent=featureDropped=0;resetFeatureDiagnostics();motion.reset();recording=false;
            }
        } else if(p[1]==3) {trainingMode=0;captureOwner=BLE_CONN_HANDLE_INVALID;trainingResult=0;}
        else if(p[1]==4 || p[1]==5) {
            if(!modelAvailable || Ammo::r32(p+12)!=detector.id())trainingResult=1;
            else if(p[1]==4 && (safety.locked || !imuOK || !safety.temperatureValid))trainingResult=3;
            else if(!saveModel(detector,p[1]==4))trainingResult=4;
            else {trainingMode=detectorEnabled?3:0;trainingResult=0;motion.reset();}
        }
        if(trainingResult==0){last.valid=true;last.session=q.session;memcpy(last.data,p,16);}publishTraining();
    } else {
        if(p[0]!=1 || p[1]>3 || !Ammo::r16(p+2))return;
        if(trainingMode==1 || trainingMode==2){uint32_t old=trainingRequest;trainingRequest=Ammo::r16(p+2);trainingResult=2;publishTraining();trainingRequest=old;trainingResult=0;return;}
        if(safety.locked || !imuOK){trainingResult=3;publishTraining();return;}
        // Index zero can begin a new transfer only after the current owner's transfer expires.
        if(p[1]==0 && (!uploadIndex || (uploadOwner==q.owner && uploadSession==q.session))) {uploadID=Ammo::r16(p+2);uploadOwner=q.owner;uploadSession=q.session;uploadIndex=0;}
        if(q.owner!=uploadOwner || q.session!=uploadSession || Ammo::r16(p+2)!=uploadID || p[1]!=uploadIndex)return;
        memcpy(uploadBytes+16*uploadIndex,p+4,16);++uploadIndex;uploadAt=millis();
        if(uploadIndex==4) {
            Ammo::DetectorProfile profile;trainingRequest=uploadID;
            if(!profile.decode(uploadBytes,64))trainingResult=1;
            else if(!saveModel(profile,false))trainingResult=4;
            else {trainingMode=0;trainingResult=0;motion.reset();}
            uploadIndex=0;uploadOwner=BLE_CONN_HANDLE_INVALID;publishTraining();
        }
    }
}
bool readIMUBurst(float* values) {
    // CTRL3_C BDU+IF_INC configured below, original Sense internal I2C Wire1/0x6A.
    Wire1.beginTransmission(0x6A);Wire1.write(0x1E);if(Wire1.endTransmission(false))return false;
    if(Wire1.requestFrom(uint8_t(0x6A),uint8_t(1))!=1 || ((Wire1.read()&3)!=3))return false;
    Wire1.beginTransmission(0x6A);Wire1.write(0x22);if(Wire1.endTransmission(false))return false;
    if(Wire1.requestFrom(uint8_t(0x6A),uint8_t(12))!=12)return false;
    uint8_t b[12];for(int i=0;i<12;++i)b[i]=Wire1.read();
    for(int i=0;i<3;++i){values[i+3]=int16_t(Ammo::r16(b+2*i))*.07f;values[i]=int16_t(Ammo::r16(b+6+2*i))*.000244f;}return true;
}
void sampleMotion() {
    if(!imuOK || safety.locked || !safety.temperatureValid || !(trainingMode || detectorEnabled || diagnosticMotion || liveRequested))return;
    float v[6];if(!readIMUBurst(v))return;Ammo::MotionFeature feature;
    if(!motion.push(v[0],v[1],v[2],v[3],v[4],v[5],micros(),modelAvailable && trainingMode==3?detector.onset():.03f,modelAvailable && trainingMode==3?detector.rearm():.015f,modelAvailable && trainingMode==3?detector.refractory():200,feature))return;
    lastMotionPeak=feature.peak;++featureSeen;if(!(feature.flags&14))++featureUsable;if(feature.flags&4)++featureGaps;if(feature.flags&2)++featureClips;featureMaximum=fmaxf(featureMaximum,feature.peak);
    if(trainingMode==1 || trainingMode==2) {
        uint8_t p[20];feature.encode(p,captureID,++featureSequence,trainingMode==2?1:0);trainingDataChar.write(p,20);
        if(Bluefruit.connected(captureOwner) && sessions[captureOwner]==captureSession && queueNotification(trainingDataChar,captureOwner,p,20))++featureSent;else ++featureDropped;
    } else if(detectorEnabled && !detector.audio() && trainingMode==3 && feature.flags==1 && detector.accepts(feature.peak,feature.rms,feature.gyro)) {
        if(!safety.event(engine,saveEngine)){detectorEnabled=false;trainingMode=0;trainingResult=4;publishTraining();}publishState();
    }
}
void beginTraining() {
    loadDetector();if(modelAvailable && !detector.audio() && detectorEnabled){if(!saveModel(detector,false)){detectorEnabled=false;trainingResult=4;}}trainingMode=detectorEnabled?3:0;
    BLECharacteristic* chars[4]={&trainingControlChar,&trainingDataChar,&profileChunkChar,&trainingStatusChar};
    for(int i=0;i<4;++i){bool write=i==0 || i==2;auto c=chars[i];c->setProperties(write?CHR_PROPS_WRITE:CHR_PROPS_READ|CHR_PROPS_NOTIFY);c->setPermission(write?SECMODE_NO_ACCESS:SECMODE_OPEN,write?SECMODE_OPEN:SECMODE_NO_ACCESS);c->setFixedLen(i==0?16:20);if(write)c->setWriteCallback(receiveTraining);c->begin();}
    publishTraining();
}
