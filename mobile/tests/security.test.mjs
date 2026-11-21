import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID,createHmac } from 'node:crypto';
import { createSnapshotHandler } from '../api/snapshot.js';
import { createConnectHandler } from '../api/connect.js';
import { createWorkspaceHandler } from '../api/workspaces.js';
import { managedHandler } from '../lib/management.js';
import { deviceAction } from '../api/devices.js';
import { challengeAction } from '../api/challenge.js';
import { sessionAction } from '../api/session.js';
import { logoutAction } from '../api/logout.js';
import { randomToken,digest,authorise } from '../lib/auth.js';
import { validateDocument } from '../lib/validation.js';
const env={LIFEBOARD_DEVICE_TOKEN:'owner-secret',LIFEBOARD_ADMIN_TOKEN:'admin-secret',LIFEBOARD_COOKIE_SECRET:'cookie-secret'};
function document(){return {schemaVersion:3,tasks:[],subjects:[],projects:[],events:[],yearMarkers:[],activity:[],focusSessions:[],externalEvents:[],settings:{}};}
function task(){return {id:randomUUID(),title:'Synthetic task',notes:'',createdAt:'2026-10-03T10:00:00Z',modifiedAt:'2026-10-03T10:00:00Z',isCompleted:false,isArchived:false,estimatedMinutes:30,priority:'none',tags:[],sortOrder:0};}
function memoryStore(){const workspaces=new Map([['owner',{revision:5,data:document()}]]),sessions=new Map(),challenges=new Map(),rates=new Map();return {workspaces,sessions,challenges,rates,
 async findSession(hash){const s=sessions.get(hash);return s&&!s.revoked?s:null;},
 async migrateLegacy(hash){if(!sessions.has(hash))sessions.set(hash,{id:randomUUID(),workspaceID:'owner',name:'Existing owner phone',owner:false});},
 async getSnapshot(id){return structuredClone(workspaces.get(id)||{revision:0,data:null});},
 async putSnapshot(id,base,data){const old=workspaces.get(id);if(!old||base!==old.revision)return null;workspaces.set(id,{revision:base+1,data:structuredClone(data)});return {revision:base+1};},
 async createWorkspace(id){workspaces.set(id,{revision:0,data:null});},
 async createSession(id,workspaceID,hash,name,_seconds,owner=false){sessions.set(hash,{id,workspaceID,name,owner});},
 async devices(id){return [...sessions.values()].filter(v=>v.workspaceID===id&&!v.revoked);},
 async revoke(workspace,id){for(const s of sessions.values())if(s.workspaceID===workspace&&s.id===id)s.revoked=true;},
 async challenge(hash,workspaceID,name){challenges.set(hash,{workspaceID,name});},
 async consumeChallenge(hash){const c=challenges.get(hash);challenges.delete(hash);return c||null;},
 async pruneExpiredPairing(){},
 async throttle(key,limit=10){const n=(rates.get(key)||0)+1;rates.set(key,n);return n<=limit;},
 };}
async function invoke(handler,method='GET',body,headers={}){const request={method,body,headers:{host:'lifeboard.test',...headers},socket:{remoteAddress:'test-network'}};const response={statusCode:200,headers:{},setHeader(k,v){this.headers[k]=v;},status(n){this.statusCode=n;return this;},json(value){this.body=value;return this;}};await handler(request,response);return response;}
const owner={authorization:'Bearer owner-secret'};
test('authenticated malformed records leave snapshot bytes and revision unchanged',async()=>{
 const store=memoryStore(),api=createSnapshotHandler(()=>store,env);const mutations=[
 d=>{d.tasks=[{...task(),id:'not-a-uuid'}];},d=>{d.tasks=[{...task(),title:123}];},d=>{d.tasks=[{...task(),dueDay:{year:2026,month:2,day:30}}];},
 d=>{d.tasks=[{...task(),estimatedMinutes:-1}];},d=>{d.tasks=[{...task(),priority:'urgent'}];},d=>{d.tasks=[{...task(),subjectID:randomUUID()}];},
 d=>{const t=task();delete t.notes;d.tasks=[t];},d=>{const t=task();d.tasks=[t,{...t,id:t.id.toUpperCase()}];},d=>{d.tasks=[{...task(),sortOrder:Infinity}];},
 d=>{d.settings.planningHours=[{weekday:8,startMinutes:0,endMinutes:0}];},d=>{d.focusSessions=[{id:randomUUID(),kind:'focus',taskTitle:1}];},
 d=>{d.schemaVersion=999;},d=>{d.subjects=[{id:randomUUID(),title:'bad nested topics',notes:'',colour:'blue',archived:false,confidence:3,progress:0,topics:[{}],confidenceHistory:[]}];},
 ];
 for(const mutate of mutations){const before=JSON.stringify(store.workspaces.get('owner'));const d=document();mutate(d);const result=await invoke(api,'PUT',d,{...owner,'if-match':'5'});assert.equal(result.statusCode,400);assert.ok(result.body.fields.length);assert.equal(JSON.stringify(store.workspaces.get('owner')),before);}
 const valid=document();valid.tasks=[task()];assert.equal((await invoke(api,'PUT',valid,{...owner,'if-match':'5'})).statusCode,200);
 assert.equal((await invoke(api,'PUT',document(),{...owner,'if-match':'5'})).statusCode,409);
 assert.equal((await invoke(api,'PUT',document(),{...owner,'if-match':'6junk'})).statusCode,428);
});
test('workspace invitations, snapshot writes and device lists stay isolated',async()=>{
 const store=memoryStore(),provision=createWorkspaceHandler(()=>store,env),api=createSnapshotHandler(()=>store,env);
 assert.equal((await invoke(provision,'POST',{},owner)).statusCode,401);
 const a=(await invoke(provision,'POST',{}, {authorization:'Bearer admin-secret'})).body,b=(await invoke(provision,'POST',{}, {authorization:'Bearer admin-secret'})).body;
 assert.notEqual(a.workspaceID,b.workspaceID);const ha={authorization:`Bearer ${a.deviceToken}`},hb={authorization:`Bearer ${b.deviceToken}`};
 const d=document();d.tasks=[task()];await invoke(api,'PUT',d,{...ha,'if-match':'0'});
 assert.equal((await invoke(api,'GET',null,hb)).body.data,null);assert.equal((await invoke(api,'GET',null,owner)).body.revision,5);
 const devices=managedHandler(deviceAction,()=>store,env);assert.equal((await invoke(devices,'GET',null,ha)).body.devices.length,1);
 const bSession=await authorise({headers:hb},store,env);await invoke(devices,'DELETE',{id:bSession.id},ha);assert.ok(await authorise({headers:hb},store,env));
});
test('one-use workspace challenge creates random independently revocable sessions',async()=>{
 const store=memoryStore(),challenge=managedHandler(challengeAction,()=>store,env),connect=createConnectHandler(()=>store,env);
 const one=(await invoke(challenge,'POST',{deviceName:'First phone'},owner)).body,two=(await invoke(challenge,'POST',{deviceName:'Second phone'},owner)).body;
 assert.notEqual(one.code,two.code);const first=await invoke(connect,'POST',{code:one.code}),second=await invoke(connect,'POST',{code:two.code});
 assert.equal(first.statusCode,200);assert.equal(second.statusCode,200);assert.notEqual(first.headers['Set-Cookie'],second.headers['Set-Cookie']);assert.match(first.headers['Set-Cookie'],/HttpOnly; Secure; SameSite=Lax/);
 assert.equal((await invoke(connect,'POST',{code:one.code})).statusCode,401);
 const cookie=first.headers['Set-Cookie'].split(';')[0],other=second.headers['Set-Cookie'].split(';')[0];const identity=await authorise({headers:{cookie}},store,env);
 await store.revoke('owner',identity.id);assert.equal(await authorise({headers:{cookie}},store,env),null);assert.ok(await authorise({headers:{cookie:other}},store,env));
 const logout=managedHandler(logoutAction,()=>store,env);const out=await invoke(logout,'POST',null,{cookie:other});assert.match(out.headers['Set-Cookie'],/Max-Age=0/);assert.equal(await authorise({headers:{cookie:other}},store,env),null);
});
test('persistent pairing throttles retries and never issues a session on failure',async()=>{const store=memoryStore(),connect=createConnectHandler(()=>store,env);for(let i=0;i<10;i++)assert.equal((await invoke(connect,'POST',{code:'INVALIDCODE'})).statusCode,401);const denied=await invoke(connect,'POST',{code:'INVALIDCODE'});assert.equal(denied.statusCode,429);assert.equal(denied.headers['Retry-After'],'900');assert.equal(store.sessions.size,0);});
test('network rejection cannot allocate fresh code buckets, consume codes or run cleanup',async()=>{
 const store=memoryStore();let cleanups=0,consumes=0;
 store.pruneExpiredPairing=async()=>cleanups++;
 store.consumeChallenge=async()=>{consumes++;return null;};
 const connect=createConnectHandler(()=>store,env);
 for(let i=0;i<10;i++)assert.equal((await invoke(connect,'POST',{code:'UNKNOWN-CODE'})).statusCode,401);
 const before=[...store.rates.keys()],beforeCleanup=cleanups,beforeConsume=consumes;
 for(let i=0;i<100;i++){const out=await invoke(connect,'POST',{code:`FRESH-UNKNOWN-${String(i).padStart(3,'0')}`});assert.equal(out.statusCode,429);assert.equal(out.headers['Retry-After'],'900');}
 assert.deepEqual([...store.rates.keys()],before);assert.equal(cleanups,beforeCleanup);assert.equal(consumes,beforeConsume);assert.equal(store.sessions.size,0);
});
test('malformed pairing input consumes only its network quota and never creates code counters',async()=>{
 const store=memoryStore();let consumes=0,cleanups=0;
 store.pruneExpiredPairing=async()=>cleanups++;
 store.consumeChallenge=async()=>{consumes++;return null;};
 const connect=createConnectHandler(()=>store,env);
 for(const code of [null,123,{},'','short','spaces are invalid','A'.repeat(65),'⚠INVALID-CODE'])assert.equal((await invoke(connect,'POST',{code})).statusCode,401);
 assert.equal(store.rates.size,1);assert.match([...store.rates.keys()][0],/^network:/);
 assert.equal(consumes,0);assert.equal(store.sessions.size,0);assert.equal(cleanups,8);
});
test('failure of expiry cleanup fails closed before challenge redemption or session creation',async()=>{
 const store=memoryStore();store.pruneExpiredPairing=async()=>{throw new Error('database unavailable');};
 await store.challenge(digest('SYNTHETIC-CODE'),'owner','Test phone');
 const out=await invoke(createConnectHandler(()=>store,env),'POST',{code:'SYNTHETIC-CODE'});
 assert.equal(out.statusCode,503);assert.equal(store.challenges.size,1);assert.equal(store.sessions.size,0);assert.equal(out.headers['Set-Cookie'],undefined);
});
test('owner legacy cookie migrates once and remains revocable without restoring access',async()=>{const store=memoryStore();const body=`v1.${Math.floor(Date.now()/1000)+3600}`,cookie='lifeboard_session='+body+'.'+createHmac('sha256',env.LIFEBOARD_COOKIE_SECRET).update(body).digest('hex');const first=await authorise({headers:{cookie}},store,env);assert.equal(first.workspaceID,'owner');await store.revoke('owner',first.id);assert.equal(await authorise({headers:{cookie}},store,env),null);const session=managedHandler(sessionAction,()=>store,env);assert.equal((await invoke(session,'GET',null,owner)).body.ownerLegacy,true);});
test('CSRF and missing auth fail before mutation; beta challenge never grants owner',async()=>{const store=memoryStore(),api=createSnapshotHandler(()=>store,env);assert.equal((await invoke(api,'GET')).statusCode,401);assert.equal((await invoke(api,'PUT',document(),{...owner,origin:'https://evil.test','if-match':'5'})).statusCode,403);const beta=(await invoke(createWorkspaceHandler(()=>store,env),'POST',{}, {authorization:'Bearer admin-secret'})).body;const challenge=(await invoke(managedHandler(challengeAction,()=>store,env),'POST',{}, {authorization:`Bearer ${beta.deviceToken}`})).body;const connection=await invoke(createConnectHandler(()=>store,env),'POST',{code:challenge.code});const identity=await authorise({headers:{cookie:connection.headers['Set-Cookie'].split(';')[0]}},store,env);assert.equal(identity.workspaceID,beta.workspaceID);assert.equal(identity.owner,false);});
test('strict Gregorian and nested schema accepts current complete synthetic records',()=>{const d=document();d.tasks=[{...task(),dueDay:{year:2000,month:2,day:29}}];assert.deepEqual(validateDocument(d),[]);d.tasks[0].dueDay.year=1900;assert.ok(validateDocument(d).length);});
test('unknown schema3 fields are rejected to prevent native lossy rewrites',async()=>{const store=memoryStore(),api=createSnapshotHandler(()=>store,env);const d=document();d.tasks=[{...task(),futureFlag:'preserve me'}];assert.equal((await invoke(api,'PUT',d,{...owner,'if-match':'5'})).statusCode,400);assert.equal(store.workspaces.get('owner').revision,5);});
test('concurrent challenge redemption succeeds once',async()=>{const store=memoryStore(),challenge=managedHandler(challengeAction,()=>store,env),connect=createConnectHandler(()=>store,env);const c=(await invoke(challenge,'POST',{},owner)).body;const responses=await Promise.all([invoke(connect,'POST',{code:c.code}),invoke(connect,'POST',{code:c.code})]);assert.deepEqual(responses.map(x=>x.statusCode).sort(),[200,401]);assert.equal(store.sessions.size,1);});
test('beta bearer takes precedence over a legacy owner cookie',async()=>{const store=memoryStore();const beta=randomToken();await store.createSession(randomUUID(),'beta',digest(beta),'Beta',1,true);const body=`v1.${Math.floor(Date.now()/1000)+3600}`,cookie='lifeboard_session='+body+'.'+createHmac('sha256',env.LIFEBOARD_COOKIE_SECRET).update(body).digest('hex');assert.equal((await authorise({headers:{authorization:`Bearer ${beta}`,cookie}},store,env)).workspaceID,'beta');});
test('admin provisioning cannot reuse the owner sync bearer',async()=>{const store=memoryStore();const result=await invoke(createWorkspaceHandler(()=>store,{...env,LIFEBOARD_ADMIN_TOKEN:env.LIFEBOARD_DEVICE_TOKEN}),'POST',{},owner);assert.equal(result.statusCode,401);assert.equal(store.workspaces.size,1);});

// Shared, fully populated wire fixture exercises every native record type and
// additive schema3 field, including fractional instants and overnight tasks.
const { readFileSync } = await import('node:fs');
const wireFixture=()=>JSON.parse(readFileSync(new URL('../../fixtures/wire-valid.json',import.meta.url),'utf8'));
test('authenticated accepted wire fixture round-trips every native collection and optional field',async()=>{
 const store=memoryStore(),api=createSnapshotHandler(()=>store,env),fixture=wireFixture();
 assert.deepEqual(validateDocument(fixture),[]);
 assert.equal((await invoke(api,'PUT',fixture,{...owner,'if-match':'5'})).statusCode,200);
 const read=await invoke(api,'GET',null,owner);assert.deepEqual(read.body.data,fixture);assert.equal(read.body.revision,6);
});
test('accepted wire fixture passes actual native decode gate', {skip:!process.env.LIFEBOARD_WIRE_VALIDATOR?'Set LIFEBOARD_WIRE_VALIDATOR to the compiled disposable native wire gate':false},async()=>{
 const {execFileSync}=await import('node:child_process');
 const output=execFileSync(process.env.LIFEBOARD_WIRE_VALIDATOR,[new URL('../../fixtures/wire-valid.json',import.meta.url).pathname],{encoding:'utf8'});
 assert.match(output,/VALID wire-valid.json tasks=2/);
});
test('authenticated nested malformed matrix returns400 and preserves byte-identical durable state',async()=>{
 const store=memoryStore(),api=createSnapshotHandler(()=>store,env);
 const corruptions=[
  d=>d.subjects[0].id=123,
  d=>d.projects[0].id=false,
  d=>d.tasks[0].id={},
  d=>d.subjects={invalid:'not a collection'},
  d=>d.projects[0].milestones=123,
  d=>d.subjects[0].topics='invalid',
  d=>d.subjects[0].confidenceHistory[0].value=6,
  d=>d.projects[0].progressHistory[0].value=101,
  d=>d.tasks[0].subtasks[0].title='   ',
  d=>d.tasks[0].recurrence.interval=0,
  d=>d.tasks[0].recurrence.frequency='hourly',
  d=>d.tasks[0].recurrence.nextDay={year:2026,month:2,day:29},
  d=>d.tasks[0].recurrence.futureField=true,
  d=>d.tasks[0].actualMinutes=525601,
  d=>d.tasks[0].tags=Array(101).fill('tag'),
  d=>d.tasks[0].tags=['x'.repeat(501)],
  d=>d.tasks[0].createdAt='2026-02-30T00:00:00Z',
  d=>d.tasks[0].topicID=d.projects[0].milestones[0].id,
  d=>d.tasks[0].milestoneID=d.subjects[0].topics[0].id,
  d=>d.activeFocus.taskTitle='',
  d=>d.activeFocus.pausedAt='2024-02-29T19:59:00Z',
  d=>d.activeFocus.plannedMinutes=241,
  d=>d.externalEvents[0].timeZoneIdentifier='Invalid/Zone',
  d=>delete d.externalEvents[0].endInstant,
  d=>d.settings.maxFocusMinutes=241,
  d=>d.settings.breakMinutes=61,
  d=>d.settings.eveningStartMinutes=1440,
  d=>d.settings.eveningEndMinutes=0,
  d=>{delete d.settings.eveningStartMinutes;d.settings.eveningEndMinutes=1000;},
  d=>d.settings.planningHours[0].endMinutes=0,
  d=>d.settings.selectedExternalCalendarIDs=[''],
  d=>d.tasks=Array(20001).fill(d.tasks[0]),
 ];
 for(const corruption of corruptions){const d=wireFixture();corruption(d);const before=JSON.stringify(store.workspaces.get('owner'));const response=await invoke(api,'PUT',d,{...owner,'if-match':'5'});assert.equal(response.statusCode,400,String(corruption));assert.equal(JSON.stringify(store.workspaces.get('owner')),before);}
});
test('snapshot cookie requests bind expected workspace before reading or changing records',async()=>{
 const store=memoryStore(),api=createSnapshotHandler(()=>store,env),token=randomToken();
 await store.createWorkspace('beta');await store.createSession(randomUUID(),'beta',digest(token),'Beta phone',180,false);
 const cookie={cookie:`lifeboard_session=${token}`};
 for(const method of ['GET','PUT']){
  const before=JSON.stringify([...store.workspaces]);
  for(const headers of [cookie,{...cookie,'x-lifeboard-workspace':'owner'},{...cookie,authorization:'Bearer invalid-short-token'}]){
   const result=await invoke(api,method,document(),{...headers,'if-match':'0'});assert.equal(result.statusCode,403);assert.equal(result.body.code,'workspace_mismatch');assert.equal(result.body.data,undefined);assert.equal(JSON.stringify([...store.workspaces]),before);
  }
 }
 assert.equal((await invoke(api,'GET',null,{...cookie,'x-lifeboard-workspace':'beta'})).statusCode,200);
 assert.equal((await invoke(api,'PUT',document(),{...cookie,'x-lifeboard-workspace':'beta','if-match':'0'})).statusCode,200);
 // Existing native owner/beta bearers remain usable without a new header.
 assert.equal((await invoke(api,'GET',null,owner)).statusCode,200);
 assert.equal((await invoke(api,'GET',null,{authorization:`Bearer ${token}`})).statusCode,200);
 assert.equal((await invoke(api,'GET',null,{authorization:`Bearer ${token}`,'x-lifeboard-workspace':'owner'})).statusCode,403);
});
