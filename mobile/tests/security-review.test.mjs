import test from 'node:test';
import assert from 'node:assert/strict';
import { LifeBoardSync,emptyDocument,DocumentStorage,mergeSnapshots } from '../web/sync.js';
function environment(){const saved={navigator:Object.getOwnPropertyDescriptor(globalThis,'navigator'),localStorage:Object.getOwnPropertyDescriptor(globalThis,'localStorage'),window:Object.getOwnPropertyDescriptor(globalThis,'window'),fetch:globalThis.fetch};const values=new Map();Object.defineProperty(globalThis,'navigator',{configurable:true,value:{onLine:true}});Object.defineProperty(globalThis,'localStorage',{configurable:true,value:{getItem:k=>values.get(k)||null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)}});return ()=>{globalThis.fetch=saved.fetch;for(const k of ['navigator','localStorage','window'])if(saved[k])Object.defineProperty(globalThis,k,saved[k]);else delete globalThis[k];};}
test('a second local edit during upload preserves an independent remote task edit',async()=>{const restore=environment();let sync;try{const base=emptyDocument();base.tasks=[{id:'A',title:'old A'},{id:'B',title:'old B'}];let server=structuredClone(base);server.tasks[1].title='remote B';let revision=2,uploads=0,start,release;const started=new Promise(r=>start=r),released=new Promise(r=>release=r);globalThis.fetch=async(_url,options={})=>{if(!options.method)return{ok:true,json:async()=>({revision,data:structuredClone(server)})};uploads++;if(uploads===1){start();await released;}server=JSON.parse(options.body);revision++;return{ok:true,status:200,json:async()=>({revision})};};sync=new LifeBoardSync();await sync.ready;sync.data=structuredClone(base);sync.base=structuredClone(base);sync.revision=1;sync.mutate(d=>d.tasks[0].title='first local A');const running=sync.sync();await started;sync.mutate(d=>d.tasks[0].title='later local A');release();await running;for(let i=0;i<100&&(uploads<2||sync.busy);i++)await new Promise(r=>setTimeout(r,10));assert.equal(uploads,2);assert.equal(server.tasks[0].title,'later local A');assert.equal(server.tasks[1].title,'remote B');}finally{clearTimeout(sync?.timer);restore();}});
test('storage fallback is scoped to workspace identity',async()=>{const restore=environment();try{const storage=new DocumentStorage();storage.workspaceID='owner';const owner=emptyDocument();owner.tasks=[{id:'private',title:'Owner private work'}];await storage.save({data:owner,base:owner,revision:1});storage.workspaceID='beta';assert.equal(await storage.load(),null);const beta=emptyDocument();beta.tasks=[{id:'tester',title:'Tester work'}];await storage.save({data:beta,base:beta,revision:2});storage.workspaceID='owner';assert.equal((await storage.load()).data.tasks[0].title,'Owner private work');}finally{restore();}});
test('signing out invalidates a delayed snapshot and cannot recreate private cache',async()=>{const restore=environment();let sync;try{const owner=emptyDocument();owner.tasks=[{id:'private',title:'Private cached work'}];let started,release;const readStarted=new Promise(r=>started=r),readReleased=new Promise(r=>release=r);globalThis.fetch=async()=>{started();await readReleased;return{ok:true,json:async()=>({revision:3,data:owner})};};sync=new LifeBoardSync();await sync.ready;const running=sync.sync();await readStarted;await sync.clearLocal();release();await running;assert.equal(sync.data.tasks.length,0);assert.equal(await sync.storage.load(),null);}finally{clearTimeout(sync?.timer);restore();}});

test('field conflict choices preserve independent edits from both devices',async()=>{const restore=environment();let sync;try{const base=emptyDocument();base.tasks=[{id:'shared',title:'Original',notes:'Old notes',estimatedMinutes:30}];const local=structuredClone(base),remote=structuredClone(base);local.tasks[0].title='Local title';local.tasks[0].estimatedMinutes=60;remote.tasks[0].title='Remote title';remote.tasks[0].notes='Remote independent notes';const candidate=mergeSnapshots(base,local,remote);assert.deepEqual(candidate.conflicts,['tasks/shared/title']);sync=new LifeBoardSync();await sync.ready;sync.data=local;sync.base=base;sync.conflicts=candidate.conflicts;sync.conflictRemote=remote;sync.resolveConflicts({'tasks/shared/title':'local'});assert.equal(sync.data.tasks[0].title,'Local title');assert.equal(sync.data.tasks[0].notes,'Remote independent notes');assert.equal(sync.data.tasks[0].estimatedMinutes,60);clearTimeout(sync.timer);sync.data=structuredClone(local);sync.base=structuredClone(base);sync.conflicts=candidate.conflicts;sync.conflictRemote=structuredClone(remote);sync.resolveConflicts({'tasks/shared/title':'remote'});assert.equal(sync.data.tasks[0].title,'Remote title');assert.equal(sync.data.tasks[0].notes,'Remote independent notes');assert.equal(sync.data.tasks[0].estimatedMinutes,60);}finally{clearTimeout(sync?.timer);restore();}});

async function cachedOwner() {
  localStorage.setItem('lifeboard.connected.workspace','owner');
  const storage=new DocumentStorage(),data=emptyDocument();
  data.tasks=[{id:'synthetic-owner',title:'Private synthetic owner marker'}];
  await storage.save({data,base:structuredClone(data),revision:7,conflicts:[],conflictRemote:null});
  const sync=new LifeBoardSync();await sync.ready;
  Object.defineProperty(globalThis,'window',{configurable:true,value:{}});
  sync.identityVerified=true;return sync;
}
function betaTransport(uploads=[]) {
  globalThis.fetch=async(url,options={})=>{
    if(url==='/api/session')return{ok:true,status:200,json:async()=>({workspaceID:'beta',ownerLegacy:false})};
    assert.equal(options.headers['X-LifeBoard-Workspace'],'beta');
    if(options.method==='PUT'){uploads.push(JSON.parse(options.body));return{ok:true,status:200,json:async()=>({revision:1})};}
    return{ok:true,status:200,json:async()=>({revision:0,data:null})};
  };
}
test('a failed new workspace load keeps the old document recoverable and retry never uploads it',async()=>{
  const restore=environment();let sync;
  try {
    sync=await cachedOwner();const uploads=[];betaTransport(uploads);
    const load=sync.storage.load.bind(sync.storage);let failed=false;
    sync.storage.load=async workspace=>{if(workspace==='beta'&&!failed){failed=true;throw new Error('IDB transaction aborted');}return load(workspace);};
    await assert.rejects(sync.verifyIdentity(),/IDB transaction aborted/);
    assert.equal(sync.storage.workspaceID,'owner');assert.equal(sync.identityVerified,false);assert.equal(sync.scopeReady,false);
    assert.equal(JSON.parse(JSON.stringify(sync.data)).tasks[0].title,'Private synthetic owner marker');
    assert.throws(()=>sync.mutate(d=>d.tasks.push({id:'unsafe'})),/Reconnect/);
    assert.throws(()=>sync.replace(emptyDocument()),/Reconnect/);
    await sync.sync();assert.equal(sync.storage.workspaceID,'beta');assert.equal(sync.identityVerified,true);
    assert.equal(uploads.length,1);assert.deepEqual(uploads[0].tasks,[]);
    assert.equal((await load('owner')).data.tasks[0].title,'Private synthetic owner marker');
    assert.deepEqual((await load('beta')).data.tasks,[]);
  }finally{clearTimeout(sync?.timer);restore();}
});
test('queued owner persistence drains into its original namespace before a workspace switch',async()=>{
  const restore=environment();let sync,release;
  try {
    sync=await cachedOwner();betaTransport();
    const opening=new Promise(resolve=>release=resolve),open=sync.storage.open.bind(sync.storage);
    let delayed=true;sync.storage.open=async()=>{if(delayed){delayed=false;await opening;}return open();};
    sync.mutate(d=>d.tasks[0].title='Queued owner edit');
    const switching=sync.verifyIdentity();await new Promise(resolve=>setImmediate(resolve));
    assert.equal(sync.storage.workspaceID,'owner');assert.equal(sync.identityVerified,false);assert.equal(sync.scopeReady,false);
    release();await switching;
    const owner=await sync.storage.load('owner'),beta=await sync.storage.load('beta');
    assert.equal(owner.data.tasks[0].title,'Queued owner edit');assert.deepEqual(beta.data.tasks,[]);
    assert.equal(sync.storage.workspaceID,'beta');assert.deepEqual(sync.data.tasks,[]);
  }finally{release?.();clearTimeout(sync?.timer);restore();}
});
test('sign-out epoch invalidates a delayed new workspace load before pinning or saving it',async()=>{
  const restore=environment();let sync,release;
  try {
    sync=await cachedOwner();betaTransport();
    const loaded=new Promise(resolve=>release=resolve),load=sync.storage.load.bind(sync.storage);let started;
    const loading=new Promise(resolve=>started=resolve);
    sync.storage.load=async workspace=>{if(workspace==='beta'){started();await loaded;}return load(workspace);};
    const switching=sync.verifyIdentity();await loading;await sync.clearLocal();release();
    await assert.rejects(switching,/signedout/);assert.equal(sync.closed,true);assert.equal(sync.storage.workspaceID,'owner');
    assert.deepEqual(sync.data.tasks,[]);assert.equal(await load('beta'),null);assert.equal(await load('owner'),null);
  }finally{release?.();clearTimeout(sync?.timer);restore();}
});
test('failed new workspace persistence leaves old identity intact and retry stays isolated',async()=>{
  const restore=environment();let sync;
  try {
    sync=await cachedOwner();betaTransport();const save=sync.storage.save.bind(sync.storage);let failed=false;
    sync.storage.save=async(state,workspace)=>{if(workspace==='beta'&&!failed){failed=true;throw new Error('quota exceeded');}return save(state,workspace);};
    await assert.rejects(sync.verifyIdentity(),/storage/);assert.equal(sync.storage.workspaceID,'owner');
    assert.equal(sync.identityVerified,false);assert.equal(sync.scopeReady,false);assert.equal(sync.data.tasks.length,1);
    assert.equal(sync.durable,true);
    await sync.verifyIdentity();assert.equal(sync.storage.workspaceID,'beta');assert.deepEqual(sync.data.tasks,[]);
    assert.equal((await sync.storage.load('owner')).data.tasks.length,1);
  }finally{clearTimeout(sync?.timer);restore();}
});
