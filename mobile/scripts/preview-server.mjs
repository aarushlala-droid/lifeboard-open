// Disposable UI verification server. Never points at the owner's sync database.
import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { emptyDocument } from '../web/sync.js';
let data=emptyDocument(),revision=1;
const stamp='2026-10-03T12:00:00Z';
const subjectID='20000000-0000-4000-8000-000000000001', projectID='30000000-0000-4000-8000-000000000001';
data.subjects=[{id:subjectID,title:'Physics',progress:45,confidence:3,notes:'',colour:'blue',archived:false,topics:[{id:'40000000-0000-4000-8000-000000000001',title:'Waves',confidence:2,progress:30,notes:''}],confidenceHistory:[]}];
data.projects=[{id:projectID,title:'Research project',summary:'A sample project',notes:'',status:'active',progress:0,health:3,colour:'indigo',milestones:[],updates:[],progressHistory:[]}];
for(let i=0;i<8;i++)data.tasks.push({id:`10000000-0000-4000-8000-${String(i+1).padStart(12,'0')}`,title:`Revision task ${i+1}`,notes:'Disposable preview data',createdAt:stamp,modifiedAt:stamp,isCompleted:i===7,isArchived:false,estimatedMinutes:30,priority:'medium',tags:[],sortOrder:i,subjectID,projectID});
const server=createServer(async(request,response)=>{
  const url=new URL(request.url,'http://127.0.0.1');response.setHeader('Cache-Control','no-store');
  if(url.pathname==='/api/session'){response.setHeader('Content-Type','application/json');response.end(JSON.stringify({workspaceID:'preview-workspace',sessionID:'preview',ownerLegacy:false}));return;}
  if(url.pathname==='/api/snapshot'){
    response.setHeader('Content-Type','application/json');
    if(request.method==='PUT'){let body='';for await(const part of request)body+=part;if(Number(request.headers['if-match'])!==revision){response.statusCode=409;response.end('{}');return;}data=JSON.parse(body);revision++;response.end(JSON.stringify({revision}));}
    else response.end(JSON.stringify({data,revision}));return;
  }
  if(url.pathname==='/api/logout'){response.end('{}');return;}
  try{const path=url.pathname==='/'?'/index.html':url.pathname;if(path.includes('..'))throw Error();const file=join(new URL('../web/',import.meta.url).pathname,path);const types={'.js':'text/javascript','.css':'text/css','.html':'text/html','.png':'image/png','.webmanifest':'application/manifest+json'};response.setHeader('Content-Type',types[extname(file)]||'application/octet-stream');response.end(await readFile(file));}catch{response.statusCode=404;response.end('Not found');}
});
server.listen(Number(process.env.PORT||4173),'127.0.0.1',()=>console.log('Disposable LifeBoard UI preview on http://127.0.0.1:4173'));
