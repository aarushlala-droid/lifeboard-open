import { managedHandler } from '../lib/management.js';
export const deviceAction=async(request,response,store,identity)=>{
 if(!identity.owner)return response.status(403).json({error:'Manage devices from your Mac.'});
 if(request.method==='GET')return response.status(200).json({devices:await store.devices(identity.workspaceID)});
 if(request.method==='DELETE'){const id=request.body?.id;if(typeof id!=='string'||!/^[0-9a-f-]{36}$/i.test(id))return response.status(400).json({error:'Choose a valid device.'});await store.revoke(identity.workspaceID,id);return response.status(200).json({revoked:true});}
 return response.status(405).json({error:'Method not allowed'});
};
export default managedHandler(deviceAction);
