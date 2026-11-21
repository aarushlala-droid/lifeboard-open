import test from 'node:test';
import assert from 'node:assert/strict';
import {LifeBoardSync,emptyDocument,DocumentStorage,mergeSnapshots} from '../web/sync.js';
const task=(id,title)=>({id,title,notes:'Original',isCompleted:false});
function environment(){
 const old={fetch:globalThis.fetch,navigator:Object.getOwnPropertyDescriptor(globalThis,'navigator'),localStorage:Object.getOwnPropertyDescriptor(globalThis,'localStorage')};const values=new Map();
 Object.defineProperty(globalThis,'navigator',{configurable:true,value:{onLine:true}});
 Object.defineProperty(globalThis,'localStorage',{configurable:true,value:{getItem:k=>values.get(k)??null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)}});
 return {values,restore(){globalThis.fetch=old.fetch;for(const k of ['navigator','localStorage']){if(old[k])Object.defineProperty(globalThis,k,old[k]);else delete globalThis[k];}}};
}
test('upload acknowledgement rebases concurrent local edit over a newly remote task',async()=>{
 const env=environment();let sync;let release,started;const began=new Promise(r=>started=r),hold=new Promise(r=>release=r);
 let server=emptyDocument();server.tasks=[task('a','A')];let revision=1,uploads=0;
 globalThis.fetch=async(_url,options={})=>{
  if(!options.method)return {ok:true,json:async()=>({data:structuredClone(server),revision})};
  uploads++;if(uploads===1){started();await hold;}server=JSON.parse(options.body);revision++;return {ok:true,status:200,json:async()=>({revision})};
 };
 try{
  sync=new LifeBoardSync();await sync.ready;sync.data=structuredClone(server);sync.base=structuredClone(server);server.tasks.push(task('b','Remote B'));
  sync.mutate(d=>d.tasks[0].title='Local first');const run=sync.sync();await began;
  sync.mutate(d=>d.tasks[0].notes='Local during upload');release();await run;
  for(let i=0;i<100&&(uploads<2||sync.busy);i++)await new Promise(r=>setTimeout(r,5));
  assert.equal(server.tasks.find(t=>t.id==='b').title,'Remote B');assert.equal(server.tasks[0].notes,'Local during upload');assert.equal(sync.data.tasks.length,2);
 }finally{clearTimeout(sync?.timer);env.restore();}
});
test('fallback durable states are scoped and new beta never loads legacy owner data',async()=>{
 const env=environment();try{
  const owner=new DocumentStorage();owner.workspaceID='owner';const doc=emptyDocument();doc.tasks=[task('private','Owner')];await owner.save({data:doc,base:doc,revision:3});
  const beta=new DocumentStorage();beta.workspaceID='beta';assert.equal(await beta.load(),null);const betaDoc=emptyDocument();await beta.save({data:betaDoc,base:null,revision:0});
  assert.equal((await owner.load()).data.tasks[0].title,'Owner');assert.equal((await beta.load()).data.tasks.length,0);
  env.values.set('lifeboard.mobile.document.v1',JSON.stringify(doc));env.values.set('lifeboard.connected.workspace','beta-new');const sync=new LifeBoardSync();await sync.ready;assert.equal(sync.data.tasks.length,0);
 }finally{env.restore();}
});
test('logout prevents an in-flight download resurrecting cleared data',async()=>{
 const env=environment();let sync,release,started;const began=new Promise(r=>started=r),hold=new Promise(r=>release=r);const doc=emptyDocument();doc.tasks=[task('a','Private')];
 globalThis.fetch=async()=>{started();await hold;return {ok:true,json:async()=>({data:doc,revision:1})};};
 try{
  sync=new LifeBoardSync();await sync.ready;const run=sync.sync();await began;await sync.clearLocal();release();await run;
  assert.equal(sync.data.tasks.length,0);assert.equal(sync.closed,true);assert.equal(env.values.has('lifeboard.mobile.state.v2'),false);
 }finally{clearTimeout(sync?.timer);env.restore();}
});
test('Mac UUID capitalisation does not duplicate or delete mobile records',()=>{
 const id='a1234567-1234-4123-8123-a123456789ab';const base=emptyDocument();base.tasks=[task(id,'A')];const local=structuredClone(base),remote=structuredClone(base);local.tasks[0].notes='Local';remote.tasks[0].id=id.toUpperCase();remote.tasks[0].title='Remote';
 const result=mergeSnapshots(base,local,remote);assert.deepEqual(result.conflicts,[]);assert.equal(result.data.tasks.length,1);assert.equal(result.data.tasks[0].notes,'Local');assert.equal(result.data.tasks[0].title,'Remote');
});
