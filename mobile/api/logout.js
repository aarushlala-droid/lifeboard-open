import { expiredCookie } from '../lib/auth.js';
import { managedHandler } from '../lib/management.js';
export const logoutAction=async(request,response,store,identity)=>{if(request.method!=='POST')return response.status(405).json({error:'Method not allowed'});if(identity.id)await store.revoke(identity.workspaceID,identity.id);response.setHeader('Set-Cookie',expiredCookie);return response.status(200).json({signedOut:true});};
export default managedHandler(logoutAction);
