const form=document.getElementById("connect-form");
form.addEventListener("submit",async event=>{
  event.preventDefault();
  const button=form.querySelector("button");
  const error=document.getElementById("error");
  button.disabled=true;error.hidden=true;
  try {
    const response=await fetch("/api/connect",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({code:form.elements.namedItem("code").value})});
    const result=await response.json();
    if(!response.ok)throw new Error(result.error||"Could not connect. Try again.");
    // Pin the paired workspace before loading any cached planner or draft.
    // Old scoped caches are retained, but never loaded under the new identity.
    try {
      localStorage.setItem("lifeboard.connected.workspace",result.workspaceID);
      localStorage.removeItem("lifeboard.capture.draft");
    } catch { throw new Error("This browser cannot safely remember a workspace. Enable website storage and reconnect."); }
    if("BroadcastChannel" in window){const channel=new BroadcastChannel("lifeboard-workspace");channel.postMessage({workspaceID:result.workspaceID});channel.close();}
    location.assign("/");
  } catch(cause) {
    error.textContent=cause.message;error.hidden=false;button.disabled=false;
  }
});
