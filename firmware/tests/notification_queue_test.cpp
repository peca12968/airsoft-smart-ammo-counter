#include "../AmmoSensor/NotificationQueue.h"
#include <assert.h>
int main(){
 Ammo::NotificationQueue<3> q;uint8_t a[20]={1},b[20]={2};
 assert(!q.push(1,1,1,a,21,false));assert(!q.front());
 assert(q.push(1,7,10,a,20,false));assert(q.push(1,7,11,a,20,true));
 assert(q.push(1,7,11,b,20,true));assert(q.size()==2); // Live values coalesce only within a session.
 assert(q.push(1,7,10,b,20,false));assert(!q.push(1,7,12,a,20,false));
 assert(q.front()->attribute==10 && q.front()->data[0]==1);q.pop();
 assert(q.front()->attribute==11 && q.front()->data[0]==2);q.pop();
 assert(q.front()->attribute==10 && q.front()->data[0]==2);q.pop();
 // Capture completion is queued after all its frames, never ahead of them.
 assert(q.push(1,7,10,a,20,false));assert(q.push(1,7,12,a,20,false));
 assert(q.front()->attribute==10);q.pop();assert(q.front()->attribute==12);q.pop();
 assert(q.push(1,8,11,a,20,true));assert(q.push(1,9,11,b,20,true));assert(q.size()==2);
 q.clear();assert(!q.front() && q.size()==0);q.pop();
}
