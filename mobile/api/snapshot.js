import { authorise,sameOrigin,validDeviceToken } from '../lib/auth.js';
import { databaseStore } from '../lib/store.js';
import { validateDocument } from '../lib/validation.js';
export function createSnapshotHandler(storeFactory=databaseStore,env=process.env){return async function(request,response){
 response.setHeader('Cache-Control','no-store');response.setHeader('X-Content-Type-Options','nosniff');
 if(!['GET','PUT'].includes(request.method))return response.status(405).json({error:'Method not allowed'});
 if(!sameOrigin(request))return response.status(403).json({error:'This request must come from LifeBoard.'});
 try{const store=storeFactory(env),identity=await authorise(request,store,env);if(!identity)return response.status(401).json({error:'Connect this device to LifeBoard first.'});
 const expected=request.headers['x-lifeboard-workspace'];
 const bearer=validDeviceToken(request.headers.authorization,env.LIFEBOARD_DEVICE_TOKEN)||/^Bearer [A-Za-z0-9_-]{43}$/.test(request.headers.authorization||'');
 // A browser cookie can change in another tab after its identity preflight.
 // Binding each request to its expected workspace closes that race atomically.
 if((!bearer&&typeof expected!=='string')||(expected!==undefined&&expected!==identity.workspaceID))
   return response.status(403).json({error:'Workspace changed. Reload LifeBoard before syncing.',code:'workspace_mismatch'});

 if(request.method==='GET')return response.status(200).json(await store.getSnapshot(identity.workspaceID));
 const raw=request.headers['if-match'];const base=typeof raw==='string'&&/^\d+$/.test(raw)?Number(raw):NaN;
 if(!Number.isSafeInteger(base)||base<0)return response.status(428).json({error:'A sync version is required.'});
 const data=request.body;const errors=validateDocument(data);if(errors.length||Buffer.byteLength(JSON.stringify(data)??'')>2000000)return response.status(400).json({error:'That change is incomplete or too large to sync.',fields:errors});
 const receipt=await store.putSnapshot(identity.workspaceID,base,data);if(!receipt)return response.status(409).json({error:'A newer change is available. Sync again to merge it.'});return response.status(200).json(receipt);
 }catch{return response.status(503).json({error:"LifeBoard couldn't sync right now. Retry when the connection is available."});}
};}
export default createSnapshotHandler();
