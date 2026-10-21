#include "../AmmoSensor/CounterEngine.h"
#include "../AmmoSensor/VibrationDetector.h"
#include <assert.h>
#include <stdio.h>
int main(){
 Ammo::Engine e;e.deviceID=123;e.state.total=1234;e.state.remaining=91;e.generation=55;
 uint8_t old[75]={0};Ammo::w32(old,0x314f4d41);Ammo::w64(old+4,e.generation);Ammo::w64(old+12,e.deviceID);e.state.encode(old+20);Ammo::w32(old+71,Ammo::crc32(old,71));
 Ammo::Engine migrated;assert(migrated.decodeJournal(old,75));assert(migrated.state.total==1234 && migrated.resetBaseline==0);
 uint8_t journal[Ammo::Engine::journalSize];migrated.encodeJournal(journal);Ammo::Engine restored;assert(restored.decodeJournal(journal,sizeof(journal)));assert(restored.state.total==1234);
 uint8_t command[16]={1,4};Ammo::w16(command+2,21075);Ammo::w32(command+4,99);Ammo::w32(command+8,restored.state.sequence);Ammo::w32(command+12,restored.state.boot);
 auto save=[](Ammo::Engine& n){++n.generation;return true;};
 auto failure=[](Ammo::Engine&){return false;};
 assert(restored.command(command,16,failure).result==3);assert(restored.resetGeneration==0 && restored.state.total==1234);
 auto ack=restored.command(command,16,save);assert(ack.result==0);assert(restored.state.total==1234 && restored.resetBaseline==1234 && restored.resetGeneration==1 && restored.state.remaining==91);
 assert(restored.command(command,16,save).result==0 && restored.resetGeneration==1);
 assert(restored.event(save));assert(restored.state.total==1235 && restored.state.total-restored.resetBaseline==1);
 restored.encodeJournal(journal);Ammo::Engine reboot;assert(reboot.decodeJournal(journal,sizeof(journal)));assert(reboot.resetBaseline==1234 && reboot.state.total==1235);
 journal[71]^=1;assert(!reboot.decodeJournal(journal,sizeof(journal)));
 // Sensitive inference removes amplitude-centroid rejection, while keeping onset/rearm and usable-window gates.
 Ammo::DetectorProfile model;Ammo::w32(model.bytes,0x31444d41);model.bytes[4]=1;model.bytes[5]=3;model.bytes[6]=16;model.bytes[7]=1;Ammo::w32(model.bytes+8,1);model.bytes[12]=1;model.bytes[13]=1;Ammo::w16(model.bytes+14,200);
 auto put=[](uint8_t* p,float x){memcpy(p,&x,4);};put(model.bytes+16,.006f);for(int i=0;i<3;++i){put(model.bytes+20+4*i,.2f);put(model.bytes+32+4*i,.002f);}put(model.bytes+44,9);put(model.bytes+48,.006f);put(model.bytes+52,.003f);Ammo::w32(model.bytes+60,Ammo::crc32(model.bytes,60));
 Ammo::DetectorProfile verify;assert(verify.decode(model.bytes,64));assert(verify.accepts(.012f,.003f,0));assert(!verify.accepts(.002f,.001f,0));
 puts("PASS: legacy journal migration, nonzero lifetime, explicit reset offset, retries, save failure, reboot, CRC and sensitive inference");
}
