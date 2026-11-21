import { randomUUID } from 'node:crypto';
import { digest, randomToken, SESSION_SECONDS, sessionCookie, sameOrigin,validPairingCode,OWNER_WORKSPACE } from '../lib/auth.js';
import { databaseStore } from '../lib/store.js';
export function createConnectHandler(storeFactory=databaseStore,env=process.env){return async function(request,response){
 response.setHeader('Cache-Control','no-store');if(request.method!=='POST')return response.status(405).json({error:'Method not allowed'});
 if(!sameOrigin(request))return response.status(403).json({error:'This request must come from LifeBoard.'});
 try{const store=storeFactory(env);const code=typeof request.body?.code==='string'?request.body.code.trim().toUpperCase():'';
 const network=request.headers['x-vercel-forwarded-for']||request.headers['x-forwarded-for']||request.socket?.remoteAddress||'unknown';
 // Both buckets persist across cold starts. Never store IP addresses or submitted secrets.
 const limited=()=>{response.setHeader('Retry-After','900');return response.status(429).json({error:'Too many attempts. Wait 15 minutes and request a new code.'});};
 if(!await store.throttle('network:'+digest(network),10))return limited();
 // Only admitted requests perform bounded expiry cleanup. A denied network
 // cannot create fresh code buckets or amplify database work through cleanup.
 await store.pruneExpiredPairing();
 if(!/^[A-Z0-9-]{8,64}$/.test(code))return response.status(401).json({error:'That code is invalid or expired. Request a new code on your Mac.'});
 if(!await store.throttle('challenge:'+digest(code),10))return limited();
 let challenge=await store.consumeChallenge(digest(code));
 if(!challenge&&env.LIFEBOARD_ALLOW_LEGACY_PAIRING==='true'&&validPairingCode(code,env.LIFEBOARD_PAIRING_CODE))challenge={workspaceID:OWNER_WORKSPACE,name:'Existing owner phone'};
 if(!challenge)return response.status(401).json({error:'That code is invalid or expired. Request a new code on your Mac.'});
 const token=randomToken();await store.createSession(randomUUID(),challenge.workspaceID,digest(token),challenge.name,SESSION_SECONDS);
 response.setHeader('Set-Cookie',sessionCookie(token));return response.status(200).json({connected:true,workspaceID:challenge.workspaceID});
 }catch{return response.status(503).json({error:'Mobile connection is temporarily unavailable. Try again soon.'});}
};}
export default createConnectHandler();
