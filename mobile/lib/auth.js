import { createHash,createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
export const SESSION_SECONDS=180*24*60*60;
export const OWNER_WORKSPACE='owner';
export function randomToken(){return randomBytes(32).toString('base64url');}
export function digest(value){return createHash('sha256').update(String(value)).digest('hex');}
export function equalConstantTime(left,right){if(typeof left!=='string'||typeof right!=='string')return false;const a=Buffer.from(left),b=Buffer.from(right);return a.length===b.length&&timingSafeEqual(a,b);}
export function readCookie(header){return header?.split(';').map(x=>x.trim()).find(x=>x.startsWith('lifeboard_session='))?.slice(18)||null;}
export function validDeviceToken(header,secret){return Boolean(secret)&&equalConstantTime(header||'',`Bearer ${secret}`);}
export function validPairingCode(code,secret){return Boolean(secret)&&equalConstantTime(String(code||'').trim().toUpperCase(),secret.toUpperCase());}
export function sessionCookie(token){return `lifeboard_session=${token}; Max-Age=${SESSION_SECONDS}; Path=/; HttpOnly; Secure; SameSite=Lax`;}
export const expiredCookie='lifeboard_session=; Max-Age=0; Path=/; HttpOnly; Secure; SameSite=Lax';
// Tokens have no self-authorising signature: every use checks server revocation.
export async function authorise(request,store,env=process.env){
  if(validDeviceToken(request.headers.authorization,env.LIFEBOARD_DEVICE_TOKEN))return {workspaceID:OWNER_WORKSPACE,owner:true,id:null};
  const bearer=request.headers.authorization?.match(/^Bearer ([A-Za-z0-9_-]{43})$/)?.[1];
  const cookie=readCookie(request.headers.cookie);
  const token=bearer||cookie;
  if(!bearer&&cookie?.startsWith('v1.')&&env.LIFEBOARD_COOKIE_SECRET){
    const [version,expiry,signature,...extra]=cookie.split('.');
    if(!extra.length&&/^\d+$/.test(expiry)&&Number(expiry)>Date.now()/1000&&equalConstantTime(signature,createHmac('sha256',env.LIFEBOARD_COOKIE_SECRET).update(`${version}.${expiry}`).digest('hex'))){
      await store.migrateLegacy(digest(cookie),new Date(Number(expiry)*1000).toISOString());
      return store.findSession(digest(cookie));
    }
  }
  if(!token||! /^[A-Za-z0-9_-]{43}$/.test(token))return null;
  return store.findSession(digest(token));
}
export function sameOrigin(request){const origin=request.headers.origin;if(!origin)return true;try{return new URL(origin).host===request.headers.host;}catch{return false;}}
