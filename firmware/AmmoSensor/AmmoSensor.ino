// Original Seeed XIAO nRF52840 Sense ONLY. Arduino Seeeduino:nrf52 1.1.13.
#include <Arduino.h>
#include <Adafruit_TinyUSB.h>
#include <bluefruit.h>
#include <Wire.h>
#include <LSM6DS3.h>
#include <InternalFileSystem.h>
#include "CounterEngine.h"
#include "BatteryEstimate.h"
#include "CommandQueue.h"
#include "RunSwitch.h"
#include "SafetyMonitor.h"
#include "NotificationQueue.h"
#if !defined(TARGET_SEEED_XIAO_NRF52840_SENSE) || defined(TARGET_SEEED_XIAO_NRF52840_SENSE_PLUS)
#error "Select original Seeed XIAO nRF52840 Sense, not Plus or mbed"
#endif
static_assert(PIN_LSM6DS3TR_C_POWER == 15, "Unexpected original Sense pin mapping");
using namespace Adafruit_LittleFS_Namespace;
Ammo::Engine engine;
LSM6DS3 imu(I2C_MODE, 0x6A);
BLEService service(GATT::service);
BLECharacteristic identityChar(GATT::identity), stateChar(GATT::state), commandChar(GATT::command), ackChar(GATT::ack);
BLECharacteristic safetyChar(GATT::safety),counterResetChar(GATT::counterReset);
Ammo::SafetyMonitor safety;
bool safetySampled=false;
uint32_t lastSafety=0;
const char* slots[2]={"/ammo0.bin","/ammo1.bin"};
int activeSlot=-1;
bool storageOK=false, imuOK=false, recording=false, bleReady=false;
// Default matches the user's existing battery-positive inline switch: no GPIO wiring.
// Enable only for a separately wired dry-contact D0-to-GND switch.
#ifndef AMMO_ENABLE_RUN_SWITCH
#define AMMO_ENABLE_RUN_SWITCH 0
#endif
constexpr bool useRunSwitch=AMMO_ENABLE_RUN_SWITCH != 0;
constexpr uint8_t runSwitchPin=0; // Original Sense D0/P0.02; never connect battery voltage here.
Ammo::RunSwitch runSwitch;
volatile bool runEnabled=false;
volatile bool advertisingRequested=false;
bool switchRequested=false, wireStarted=false;
constexpr uint8_t maxCentrals=2;
Ammo::CommandQueue<4> commands;
volatile uint32_t sessions[BLE_MAX_CONNECTION]={0};
volatile uint32_t queueDrops=0;
// Bluefruit BLECharacteristic::notify waits on its HVN semaphore. Do not call it
// in the sampling loop. Use a bounded FIFO and the SoftDevice's nonblocking API.
Ammo::NotificationQueue<32> notificationQueue;
uint32_t notificationErrors=0;
bool queueNotification(BLECharacteristic& characteristic,uint16_t handle,const uint8_t* data,uint16_t length,bool coalesce=false) {
    if(handle>=BLE_MAX_CONNECTION || !Bluefruit.connected(handle) || !characteristic.notifyEnabled(handle))return false;
    return notificationQueue.push(handle,sessions[handle],characteristic.handles().value_handle,data,length,coalesce);
}
void flushNotifications() {
    for(uint8_t i=0;i<4;++i) {
        auto p=notificationQueue.front();if(!p)return;
        if(p->connection>=BLE_MAX_CONNECTION || !Bluefruit.connected(p->connection) || sessions[p->connection]!=p->session){notificationQueue.pop();continue;}
        uint16_t length=p->length;ble_gatts_hvx_params_t params={};params.handle=p->attribute;params.type=BLE_GATT_HVX_NOTIFICATION;params.p_len=&length;params.p_data=p->data;
        uint32_t error=sd_ble_gatts_hvx(p->connection,&params);
        if(error==NRF_ERROR_RESOURCES || error==NRF_ERROR_BUSY)return; // Try next loop; IMU always runs.
        if(error!=NRF_SUCCESS)++notificationErrors;
        notificationQueue.pop();
    }
}
// IMU-derived events require an explicitly trained and enabled profile.
struct Sample { uint32_t microsAt, index; float ax,ay,az,gx,gy,gz; uint8_t label; };
constexpr uint16_t sampleBufferCount=64;
Sample samples[sampleBufferCount]; uint16_t head=0, tail=0; uint32_t dropped=0, sampleIndex=0;
uint8_t label=0; uint32_t nextSample=0, lastBattery=0;
uint16_t readRailMillivolts() {
    // P0.14 remains LOW, including during USB charging, per current official FAQ.
    uint32_t sum=0;
    for(int i=0;i<8;++i) sum+=analogRead(PIN_VBAT);
    return uint16_t(Ammo::batteryVoltage(uint16_t(sum/8))*1000.0f+0.5f);
}
uint8_t readBattery() { return Ammo::batteryPercent(float(readRailMillivolts())/1000.0f); }
void startWatchdog() {
    if(!NRF_WDT->RUNSTATUS) {
        NRF_WDT->CONFIG=1; // Run in CPU sleep; pause while halted by a debugger.
        NRF_WDT->CRV=8*32768; NRF_WDT->RREN=1; NRF_WDT->TASKS_START=1;
    }
    NRF_WDT->RR[0]=0x6E524635;
}
void publishSafety() {
    if(!bleReady) return;
    uint8_t data[20]; safety.encode(data,engine.state.boot); safetyChar.write(data,sizeof(data));
    uint16_t handles[maxCentrals]; const uint8_t count=Bluefruit.getConnectedHandles(handles,maxCentrals);
    for(uint8_t i=0;i<count;++i) queueNotification(safetyChar,handles[i],data,sizeof(data),true);
}

bool loadSlot(int slot, Ammo::Engine& result) {
    File file(InternalFS); uint8_t data[Ammo::Engine::journalSize];
    if(!file.open(slots[slot],FILE_O_READ)) return false;
    const size_t size=file.size(); const int count=file.read(data,sizeof(data)); file.close();
    return count==int(size) && result.decodeJournal(data,size);
}
bool saveEngine(Ammo::Engine& next) {
    if(!storageOK || next.generation==UINT64_MAX) return false;
    const int target=activeSlot==0 ? 1:0;
    ++next.generation;
    uint8_t data[Ammo::Engine::journalSize]; next.encodeJournal(data);
    // Keep the active valid slot intact until the alternate slot verifies.
    InternalFS.remove(slots[target]);
    File file(InternalFS);
    if(!file.open(slots[target],FILE_O_WRITE)) return false;
    const size_t count=file.write(data,sizeof(data)); file.close();
    Ammo::Engine verify;
    if(count!=sizeof(data) || !loadSlot(target,verify) || verify.generation!=next.generation) return false;
    activeSlot=target; return true;
}
void publishCounterReset() {
    if(!bleReady)return;
    uint8_t p[20]={1};Ammo::w32(p+4,engine.resetBaseline);Ammo::w32(p+8,engine.resetGeneration);Ammo::w32(p+12,engine.state.boot);
    counterResetChar.write(p,20);uint16_t handles[maxCentrals];uint8_t count=Bluefruit.getConnectedHandles(handles,maxCentrals);
    for(uint8_t i=0;i<count;++i)queueNotification(counterResetChar,handles[i],p,20,true);
}
void publishState() {
    if(!bleReady) return;
    uint8_t data[20]; engine.state.encode(data); stateChar.write(data,sizeof(data));
    uint16_t handles[maxCentrals];
    const uint8_t count=Bluefruit.getConnectedHandles(handles,maxCentrals);
    for(uint8_t i=0;i<count;++i) queueNotification(stateChar,handles[i],data,sizeof(data),true);
}
void connected(uint16_t handle) {
    if(!runEnabled) { Bluefruit.disconnect(handle); return; }
    taskENTER_CRITICAL();
    if(handle<BLE_MAX_CONNECTION) ++sessions[handle];
    taskEXIT_CRITICAL();
    // The loop owns explicit advertising starts, so a queued connect callback
    // cannot restart advertising after the switch has entered standby.
    if(Bluefruit.Periph.connected()<maxCentrals) advertisingRequested=true;
}
void receiveCommand(uint16_t handle, BLECharacteristic*, uint8_t* data, uint16_t length) {
    // BLE callbacks run on another RTOS task: only queue, all flash/state work is in loop().
    if(!runEnabled || length!=16 || handle>=BLE_MAX_CONNECTION) return;
    taskENTER_CRITICAL();
    if(runEnabled && !commands.push(handle,sessions[handle],data,length)) ++queueDrops;
    taskEXIT_CRITICAL();
}
void setRecording(bool value) {
    if(value && safety.locked) { Serial.println("# safety locked: recording refused; charging is NOT disconnected"); return; }
    if(value && !imuOK) { Serial.println("# IMU unavailable"); return; }
    Ammo::Engine next=engine;
    if(next.state.sequence==UINT32_MAX) return;
    next.state.flags = value ? next.state.flags|2 : next.state.flags&~2;
    ++next.state.sequence;
    if(!saveEngine(next)) { Serial.println("# persistence failed"); return; }
    engine=next; recording=value;
    if(value) { head=tail=0; dropped=sampleIndex=0; nextSample=micros(); Serial.println("micros,index,label,ax_g,ay_g,az_g,gx_dps,gy_dps,gz_dps,dropped"); }
    else { Serial.print("# stopped,dropped="); Serial.println(dropped); }
    publishState();
}
bool commitRuntimeFlags(bool available) {
    Ammo::Engine next=engine;
    next.state.flags=(next.state.flags & ~uint8_t(3)) | (available ? 1:0);
    if(next.state.flags==engine.state.flags) return true;
    if(next.state.sequence==UINT32_MAX) return false;
    ++next.state.sequence;
    if(!saveEngine(next)) return false;
    engine=next; return true;
}
void publishState();
void publishTraining();
#include "TrainingService.h"
#include "LiveSignals.h"
void enterStandby() {
    stopLiveAudio();previewOwner=BLE_CONN_HANDLE_INVALID;
    trainingMode=0;detectorEnabled=false;captureOwner=BLE_CONN_HANDLE_INVALID;motion.reset();notificationQueue.clear();
    // This is functional standby, not a physical power cut or guaranteed deep sleep.
    runEnabled=false;
    if(bleReady) {
        Bluefruit.Advertising.restartOnDisconnect(false);
        Bluefruit.Advertising.stop();
        uint16_t handles[maxCentrals];
        const uint8_t count=Bluefruit.getConnectedHandles(handles,maxCentrals);
        for(uint8_t i=0;i<count;++i) Bluefruit.disconnect(handles[i]);
    }
    taskENTER_CRITICAL(); commands.clear(); advertisingRequested=false; taskEXIT_CRITICAL();
    recording=false; head=tail=0;
    digitalWrite(PIN_LSM6DS3TR_C_POWER,LOW); imuOK=false;
    if(!commitRuntimeFlags(false)) Serial.println("# standby flags not persisted; counts remain at last committed state");
    Serial.println("# mode=standby; counting/BLE stopped; USB charging remains hardware-controlled");
}
void enterRun() {
    if(!safety.locked) {
        digitalWrite(PIN_LSM6DS3TR_C_POWER,HIGH); delay(20);
        if(!wireStarted) { Wire1.begin(); wireStarted=true; }
        imuOK=imu.begin()==0;
        if(imuOK) {
            Wire1.setClock(400000);
            Wire1.beginTransmission(0x6A);Wire1.write(0x12);Wire1.write(0x44);imuOK=Wire1.endTransmission()==0; // BDU + auto-increment
            motion.reset();
        }
    }
    if(!commitRuntimeFlags(imuOK)) {
        digitalWrite(PIN_LSM6DS3TR_C_POWER,LOW); imuOK=false;
        Serial.println("# RUN rejected: runtime state could not be committed; toggle OFF/ON after recovery"); return;
    }
    runEnabled=true;
    advertisingRequested=false;
    publishState();
    if(bleReady) {
        Bluefruit.Advertising.restartOnDisconnect(true);
        Bluefruit.Advertising.start(0);
    }
    Serial.println(imuOK ? "# mode=run; IMU ready" : "# mode=run; IMU unavailable");
}
void sampleSafety() {
    int32_t temperature=0;
    uint8_t softdevice=0;
    const bool tempOK=sd_softdevice_is_enabled(&softdevice)==NRF_SUCCESS && softdevice && sd_temp_get(&temperature)==NRF_SUCCESS && temperature>=INT16_MIN && temperature<=INT16_MAX;
    const bool usb=(NRF_POWER->USBREGSTATUS & POWER_USBREGSTATUS_VBUSDETECT_Msk)!=0;
    const bool wasLocked=safety.locked;
    // P0.17 is the original Sense /CHG input. High means inactive/unknown, not "full".
    safety.update(readRailMillivolts(),int16_t(temperature),tempOK,usb,usb ? (nrf_gpio_pin_read(17)==0 ? 1:0):255);
    if(safety.locked && !wasLocked) {
        recording=false; head=tail=0;
        digitalWrite(PIN_LSM6DS3TR_C_POWER,LOW); imuOK=false;
        if(!commitRuntimeFlags(false)) Serial.println("# could not commit safety runtime flags; counting remains blocked");
        publishState();
        Serial.println("# SAFETY LOCK: IMU/events/commands stopped; unplug USB and switch battery OFF; charging has NOT been cut by firmware");
    }
    publishSafety();
}
void setup() {
    if(NRF_POWER->RESETREAS & POWER_RESETREAS_DOG_Msk) safety.latch(Ammo::SafetyReason::watchdog);
    NRF_POWER->RESETREAS=POWER_RESETREAS_DOG_Msk;
    if(useRunSwitch) pinMode(runSwitchPin,INPUT_PULLUP); // Optional dry contact: D0 <-> GND.
    pinMode(VBAT_ENABLE,OUTPUT); digitalWrite(VBAT_ENABLE,LOW);
    pinMode(PIN_VBAT,INPUT); analogReadResolution(12); analogReference(AR_INTERNAL_3_0); delay(5);
    Serial.begin(115200); // No while(!Serial): battery operation must start without USB.
    pinMode(PIN_CHARGING_CURRENT,INPUT); // BSP default low charge current; no fast-charge override.
    nrf_gpio_cfg_input(17,NRF_GPIO_PIN_NOPULL); // /CHG, separate from charge-current selection.
    pinMode(PIN_LSM6DS3TR_C_POWER,OUTPUT); digitalWrite(PIN_LSM6DS3TR_C_POWER,LOW);
    imu.settings.accelSampleRate=416; imu.settings.gyroSampleRate=416;
    imu.settings.accelRange=8;imu.settings.gyroRange=2000;
    storageOK=InternalFS.begin();
    Ammo::Engine a,b; bool okA=storageOK && loadSlot(0,a), okB=storageOK && loadSlot(1,b);
    if(okA || okB) {
        activeSlot=okA && (!okB || a.generation>=b.generation) ? 0:1;
        engine=activeSlot==0 ? a:b;
        if(engine.state.boot==UINT32_MAX) { Serial.println("# boot counter exhausted; service disabled"); while(true) delay(1000); }
        ++engine.state.boot;
    } else {
        // Never silently replace corrupt existing journals with a full magazine.
        if(storageOK && (InternalFS.exists(slots[0]) || InternalFS.exists(slots[1]))) {
            Serial.println("# both journals invalid; recovery required; BLE disabled"); while(true) delay(1000);
        }
        engine.deviceID=uint64_t(NRF_FICR->DEVICEID[0]) | uint64_t(NRF_FICR->DEVICEID[1])<<32;
    }
    engine.state.sequence=0; engine.hasLast=false;
    engine.state.flags=32 | (imuOK ? 1:0) | (engine.state.total==UINT32_MAX ? 8:0);
    engine.state.battery=readBattery(); // Provisional voltage-based percentage, not a fuel gauge.
    if(!saveEngine(engine)) { Serial.println("# cannot commit boot identity; BLE disabled"); while(true) delay(1000); }
    Bluefruit.configPrphConn(23,6,4,1); // MTU 23, 7.5 ms event budget, four nonblocking HVN slots.
    bleReady=Bluefruit.begin(maxCentrals,0);
    if(!bleReady) { Serial.println("# BLE initialization failed"); return; }
    Bluefruit.Periph.setConnectCallback(connected);
    Bluefruit.Periph.setConnInterval(12,24); // Request 15–30 ms; central makes the final choice.
    Bluefruit.setName("XIAO Ammo Estimate"); Bluefruit.setTxPower(0);
    service.begin();
    identityChar.setProperties(CHR_PROPS_READ); identityChar.setPermission(SECMODE_OPEN,SECMODE_NO_ACCESS); identityChar.setFixedLen(9); identityChar.begin();
    uint8_t identity[9]={GATT::version}; Ammo::w64(identity+1,engine.deviceID); identityChar.write(identity,sizeof(identity));
    stateChar.setProperties(CHR_PROPS_READ|CHR_PROPS_NOTIFY); stateChar.setPermission(SECMODE_OPEN,SECMODE_NO_ACCESS); stateChar.setFixedLen(20); stateChar.begin();
    commandChar.setProperties(CHR_PROPS_WRITE); commandChar.setPermission(SECMODE_NO_ACCESS,SECMODE_OPEN); commandChar.setFixedLen(16); commandChar.setWriteCallback(receiveCommand); commandChar.begin();
    ackChar.setProperties(CHR_PROPS_READ|CHR_PROPS_NOTIFY); ackChar.setPermission(SECMODE_OPEN,SECMODE_NO_ACCESS); ackChar.setFixedLen(14); ackChar.begin();
    safetyChar.setProperties(CHR_PROPS_READ|CHR_PROPS_NOTIFY); safetyChar.setPermission(SECMODE_OPEN,SECMODE_NO_ACCESS); safetyChar.setFixedLen(20); safetyChar.begin();
    counterResetChar.setProperties(CHR_PROPS_READ|CHR_PROPS_NOTIFY);counterResetChar.setPermission(SECMODE_OPEN,SECMODE_NO_ACCESS);counterResetChar.setFixedLen(20);counterResetChar.begin();publishCounterReset();
    publishSafety();beginTraining();beginLiveSignals();
    uint8_t emptyAck[14]={GATT::version,2}; ackChar.write(emptyAck,sizeof(emptyAck)); publishState();
    Bluefruit.Advertising.addFlags(BLE_GAP_ADV_FLAGS_LE_ONLY_GENERAL_DISC_MODE);
    Bluefruit.Advertising.addService(service); Bluefruit.ScanResponse.addName();
    Bluefruit.Advertising.restartOnDisconnect(false); Bluefruit.Advertising.setInterval(160,800);
    Serial.println(useRunSwitch ? "# D0-to-GND closed=RUN, open=standby" : "# always RUN while powered; existing inline battery switch; no GPIO switch required");
    Serial.println("# r=record,s=stop,0=stationary,1=movement,2=impact,3=mechanical,e=simulated event,?=status");
    startWatchdog();
}
void loop() {
    if(NRF_WDT->RUNSTATUS) NRF_WDT->RR[0]=0x6E524635;
    if(!safetySampled || uint32_t(millis()-lastSafety)>=2000) {
        lastSafety=millis(); safetySampled=true; sampleSafety();
    }
    const bool requested=useRunSwitch ? runSwitch.update(digitalRead(runSwitchPin)==LOW,millis()) : true;
    if(requested!=switchRequested) {
        switchRequested=requested;
        if(requested) enterRun(); else enterStandby();
    }
    if(!runEnabled) {
        while(Serial.available()) {
            if(Serial.read()=='?') Serial.println("# mode=standby,run=0; close D0-to-GND to run");
        }
        delay(20); return; // USB remains available; no counting, IMU reads or advertising.
    }
    taskENTER_CRITICAL();
    const bool restartAdvertising=advertisingRequested; advertisingRequested=false;
    taskEXIT_CRITICAL();
    if(restartAdvertising && bleReady && Bluefruit.Periph.connected()<maxCentrals)
        Bluefruit.Advertising.start(0);
    if(uint32_t(millis()-lastBattery)>=60000) {
        lastBattery=millis(); const uint8_t battery=readBattery();
        const int delta=int(battery)-int(engine.state.battery);
        if(engine.state.sequence<UINT32_MAX && (delta>=3 || delta<=-3 || ((battery==0 || battery==100) && battery!=engine.state.battery))) {
            Ammo::Engine next=engine; next.state.battery=battery; ++next.state.sequence;
            if(saveEngine(next)) { engine=next; publishState(); }
        }
    }
    processTraining();updateLiveSignals();sampleMotion();if(microphoneActive)processAudioSpectrum();flushNotifications();
    Ammo::QueuedCommand command;
    taskENTER_CRITICAL();
    const bool haveCommand=commands.pop(command);
    const bool currentSession=haveCommand && command.connection<BLE_MAX_CONNECTION && sessions[command.connection]==command.session;
    taskEXIT_CRITICAL();
    if(currentSession && Bluefruit.connected(command.connection)) {
        Ammo::Ack ack=safety.command(engine,command.data,16,saveEngine);
        if(ack.result==0 && command.data[1]==4)publishCounterReset();
        uint8_t data[14]; ack.encode(data); ackChar.write(data,sizeof(data));
        // ACK only its sender; state notifications go to both connected clients.
        if(Bluefruit.connected(command.connection) && sessions[command.connection]==command.session)
            queueNotification(ackChar,command.connection,data,sizeof(data));
        publishState();
    }
    while(Serial.available()) {
        const char c=Serial.read();
        if(c=='r') setRecording(true);
        else if(c=='s') setRecording(false);
        else if(c>='0' && c<='3') label=c-'0';
        else if(c=='e') { if(!safety.event(engine,saveEngine)) Serial.println("# event rejected: safety/storage/sequence guard"); publishState(); }
        else if(c=='d') { if(trainingMode==0 && !recording && safety.ready()) {resetFeatureDiagnostics();motion.reset();diagnosticDeadline=millis()+4000;diagnosticMotion=true;Serial.println("# diagnostic: 4s IMU only; counts unchanged");} else Serial.println("# diagnostic busy"); }
        else if(c=='b') { Serial.print("# battery="); Serial.println(engine.state.battery); }
        else if(c=='?') {
            Serial.print("# status,mode=run,imu="); Serial.print(imuOK); Serial.print(",ble="); Serial.print(bleReady);
            Serial.print(",links="); Serial.print(bleReady ? Bluefruit.Periph.connected() : 0);
            Serial.print(",cap="); Serial.print(engine.state.capacity); Serial.print(",left="); Serial.print(engine.state.remaining);
            Serial.print(",total="); Serial.print(engine.state.total);Serial.print(",reset_baseline=");Serial.print(engine.resetBaseline);Serial.print(",reset_generation=");Serial.print(engine.resetGeneration); Serial.print(",boot="); Serial.print(engine.state.boot);
            Serial.print(",seq="); Serial.print(engine.state.sequence); Serial.print(",queueDrops="); Serial.print(queueDrops);
            Serial.print(",rail_mV="); Serial.print(safety.millivolts); Serial.print(",die_quarter_C="); Serial.print(safety.quarterDegrees);
            Serial.print(",usb="); Serial.print(safety.usb); Serial.print(",charge_pin="); Serial.print(safety.chargeActive);
            Serial.print(",audio_fft_frames=");Serial.print(spectrumFrames);Serial.print(",audio_overruns=");Serial.print(spectrumOverruns);Serial.print(",audio_similarity_permille=");Serial.print(uint16_t(acousticSimilarity*1000));Serial.print(",audio_model=");Serial.print(modelAvailable && detector.audio());
            Serial.print(",audio_samples=");Serial.print(audioTotalSamples);Serial.print(",audio_max_peak=");Serial.print(maximumAudioPeak);Serial.print(",audio_peak=");Serial.print(lastAudioPeak);Serial.print(",audio_rms=");Serial.print(lastAudioRMS);Serial.print(",audio_running=");Serial.print(microphoneActive);
            Serial.print(",feature_seen=");Serial.print(featureSeen);Serial.print(",feature_usable=");Serial.print(featureUsable);Serial.print(",feature_gaps=");Serial.print(featureGaps);Serial.print(",feature_clips=");Serial.print(featureClips);Serial.print(",feature_peak_mg=");Serial.print(uint16_t(featureMaximum*1000));
            Serial.print(",notify_pending=");Serial.print(notificationQueue.size());Serial.print(",notify_errors=");Serial.print(notificationErrors);
            Serial.print(",feature_sent=");Serial.print(featureSent);Serial.print(",feature_dropped=");Serial.print(featureDropped);
            Serial.print(",training_mode=");Serial.print(trainingMode);Serial.print(",model_id=");Serial.print(modelAvailable?detector.id():0);
            Serial.print(",safety_locked="); Serial.print(safety.locked); Serial.print(",safety_reason="); Serial.println(uint8_t(safety.reason));
        }
    }
    if(recording && int32_t(micros()-nextSample)>=0) {
        nextSample=micros()+9615; // approx 104Hz; timestamps are authoritative.
        Sample s{micros(),sampleIndex++,imu.readFloatAccelX(),imu.readFloatAccelY(),imu.readFloatAccelZ(),imu.readFloatGyroX(),imu.readFloatGyroY(),imu.readFloatGyroZ(),label};
        const uint16_t next=(head+1)%sampleBufferCount;
        if(next==tail) ++dropped; else { samples[head]=s; head=next; }
    }
    if(head!=tail && Serial && Serial.availableForWrite()>=128) {
        const Sample& s=samples[tail];
        Serial.print(s.microsAt); Serial.print(','); Serial.print(s.index); Serial.print(','); Serial.print(s.label);
        const float values[6]={s.ax,s.ay,s.az,s.gx,s.gy,s.gz};
        for(float value:values) { Serial.print(','); Serial.print(value,5); }
        Serial.print(','); Serial.println(dropped); tail=(tail+1)%sampleBufferCount;
    }
    delay(1);
}
