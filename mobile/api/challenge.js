import { randomBytes } from 'node:crypto';
import { digest } from '../lib/auth.js';
import { managedHandler } from '../lib/management.js';
export const challengeAction=async(request,response,store,identity)=>{
 if(request.method!=='POST')return response.status(405).json({error:'Method not allowed'});
 if(!identity.owner)return response.status(403).json({error:'Request a pairing code from your Mac.'});
 const name=request.body?.deviceName||'Phone';if(typeof name!=='string'||!name.trim()||name.length>80)return response.status(400).json({error:'Device name must be 1–80 characters.'});
 if(!await store.throttle('issue:'+identity.workspaceID,20))return response.status(429).json({error:'Wait 15 minutes before requesting more pairing codes.'});
 const code=randomBytes(12).toString('hex').toUpperCase();await store.challenge(digest(code),identity.workspaceID,name.trim());return response.status(200).json({code,expiresAt:new Date(Date.now()+600000).toISOString()});
};
export default managedHandler(challengeAction);
