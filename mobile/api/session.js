import { managedHandler } from '../lib/management.js';
export const sessionAction=async(request,response,_store,identity)=>request.method==='GET'?response.status(200).json({workspaceID:identity.workspaceID,sessionID:identity.id,deviceName:identity.name||'Mac',ownerLegacy:identity.workspaceID==='owner'}):response.status(405).json({error:'Method not allowed'});
export default managedHandler(sessionAction);
