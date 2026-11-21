const CACHE_KEY = "lifeboard.mobile.document.v1";
const BASE_KEY = "lifeboard.mobile.base.v1";
const REVISION_KEY = "lifeboard.mobile.revision.v1";
export const COLLECTIONS = ["tasks", "events", "subjects", "projects", "yearMarkers", "activity", "focusSessions", "externalEvents"];

export function emptyDocument() {
  return {
    schemaVersion: 3,
    tasks: [], events: [], subjects: [], projects: [], yearMarkers: [], activity: [], focusSessions: [], externalEvents: [],
    settings: {
      defaultTaskMinutes: 30, eveningStartMinutes: 1020, eveningEndMinutes: 1320,
      maxFocusMinutes: 50, breakMinutes: 10, weekStartsMonday: true,
      academicYearStartMonth: 9, planningHours: [], hasCompletedOnboarding: true,
      automaticICloudBackup: false, notificationsScheduledItems: false,
      notificationsDeadlines: false, notificationsFocus: true, notificationLeadMinutes: 10,
      selectedExternalCalendarIDs: [],
    },
  };
}

function read(key, fallback) {
  try { return JSON.parse(localStorage.getItem(key)) ?? fallback; } catch { return fallback; }
}
const canonicalID = value => typeof value === "string" ? value.toLowerCase() : value;
export const sameID = (a,b) => canonicalID(a) === canonicalID(b);
const stable = value => JSON.stringify(value, (_key, val) => typeof val === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(val) ? val.toLowerCase() : val && !Array.isArray(val) && typeof val === "object"
  ? Object.fromEntries(Object.keys(val).sort().map(key => [key, val[key]])) : val);
const same = (left, right) => stable(left) === stable(right);
const byID = rows => new Map((rows || []).map(row => [canonicalID(row.id), row]));

const recordArray = value => Array.isArray(value) && value.every(row=>row && typeof row==='object' && typeof row.id==='string');
const plain = value => value && typeof value==='object' && !Array.isArray(value);
function mergeValue(before,ours,theirs,path,conflicts){
  if(same(ours,theirs))return ours;
  if(same(ours,before))return theirs;
  if(same(theirs,before))return ours;
  if(['modifiedAt','createdAt','lastActivity','lastICloudBackup','lastExternalCalendarRefresh'].includes(path.at(-1))){const values=[ours,theirs].filter(Boolean).sort((a,b)=>Date.parse(a)-Date.parse(b));return path.at(-1)==='createdAt'?values[0]:values.at(-1);}
  if(plain(ours)&&plain(theirs)&&(plain(before)||before==null)){
    if(path[0]==='focusSessions'&&sameID(ours.id,theirs.id)&&ours.startedAt===theirs.startedAt){const chosen=ours.completedTimer?ours:theirs.completedTimer?theirs:Date.parse(ours.endedAt)>=Date.parse(theirs.endedAt)?ours:theirs;return {...chosen,focusedSeconds:Math.max(ours.focusedSeconds,theirs.focusedSeconds),completedTimer:ours.completedTimer||theirs.completedTimer};}
    const result={};for(const key of new Set([...Object.keys(before||{}),...Object.keys(ours),...Object.keys(theirs)])){const value=mergeValue(before?.[key],ours[key],theirs[key],[...path,key],conflicts);if(value!==undefined)result[key]=value;}return result;
  }
  if(recordArray(ours)&&recordArray(theirs)&&(recordArray(before)||before==null)){
    const a=byID(before),b=byID(ours),c=byID(theirs),result=[];
    for(const id of new Set([...c.keys(),...b.keys(),...a.keys()])){const value=mergeValue(a.get(id),b.get(id),c.get(id),[...path,id],conflicts);if(value!==undefined)result.push(value);}return result;
  }
  conflicts.push(path.join('/'));return ours;
}
export function mergeSnapshots(base,local,remote){
  base=structuredClone(base||emptyDocument());local=structuredClone(local);remote=structuredClone(remote);
  const finished=new Set([...(local.focusSessions||[]),...(remote.focusSessions||[])].map(row=>canonicalID(row.id)));
  for(const doc of [base,local,remote])if(doc.activeFocus&&finished.has(canonicalID(doc.activeFocus.id)))delete doc.activeFocus;
  const conflicts=[],result=mergeValue(base,local,remote,[],conflicts);
  if(result.activeFocus&&result.focusSessions?.some(row=>sameID(row.id,result.activeFocus.id)))delete result.activeFocus;
  return {data:conflicts.length?null:result,conflicts:conflicts.sort()};
}
export function valueAtPath(root,path){
  let value=root;for(const key of path.split('/'))value=Array.isArray(value)?value.find(row=>sameID(row.id,key)):value?.[key];return value;
}
function setPath(root,path,value){
  const parts=path.split('/');let node=root;
  for(const key of parts.slice(0,-1)){node=Array.isArray(node)?node.find(row=>sameID(row.id,key)):node[key];if(!node)throw new Error('The conflicting record changed; sync and review again');}
  const key=parts.at(-1);
  if(Array.isArray(node)){const index=node.findIndex(row=>sameID(row.id,key));if(index>=0)node.splice(index,1);if(value!==undefined)node.push(structuredClone(value));}
  else if(value===undefined)delete node[key];else node[key]=structuredClone(value);
}

function hasContent(document) {
  return COLLECTIONS.some(key => document[key]?.length) || Boolean(document.activeFocus);
}

export class LifeBoardSync extends EventTarget {
  constructor() {
    super();
    this.data = read(CACHE_KEY, emptyDocument());
    this.base = read(BASE_KEY, null);
    this.revision = read(REVISION_KEY, 0);
    this.status = "Connecting…";
    this.lastSyncedAt = null;
    this.busy = false;
    this.timer = null;
    this.mutationVersion = 0;
    this.pendingSync = false;
    this.conflicts = [];
    this.conflictRemote = null;
    this.durable = false;
    this.storage = new DocumentStorage();
    this.epoch = 0;
    this.identityVerified = false;
    this.scopeReady = false;
    this.closed = false;
    this.persistence = Promise.resolve();
    this.persistenceVersion=0;
    this.ready = this.storage.load().then(state => {
      if (state) { this.data = state.data; this.base = state.base; this.revision = state.revision; this.conflicts = state.conflicts || []; this.conflictRemote = state.conflictRemote || null; }
      else if (this.storage.workspaceID) { this.data=emptyDocument();this.base=null;this.revision=0; }
      this.durable = true; this.scopeReady = true;
      this.emit();
    }).catch(() => { this.status = "Storage unavailable · export your pending work before closing"; this.emit(); });
  }

  emit() { this.dispatchEvent(new Event("change")); }
  persist(stateOverride, workspaceID = this.storage.workspaceID) {
    const state = structuredClone(stateOverride || { data: this.data, base: this.base, revision: this.revision, conflicts: this.conflicts, conflictRemote: this.conflictRemote });
    this.durable = false;
    const version=++this.persistenceVersion;
    // Capture the namespace when the operation is queued. A later identity
    // check must never send a queued old-workspace document to a new key.
    this.persistence = this.persistence.catch(() => {}).then(() => this.storage.save(state, workspaceID)).then(() => {
      if(version===this.persistenceVersion){this.durable = true; this.emit();}
    }).catch(() => {
      this.durable = false;
      this.status = "Couldn't save on this device · export pending work before closing";
      this.emit();
    });
    return this.persistence;
  }
  async clearLocal() {
    this.closed = true; this.epoch++; this.pendingSync = false;
    clearTimeout(this.timer); await this.ready; await this.persistence;
    await this.storage.clear();
    for (const key of [CACHE_KEY, BASE_KEY, REVISION_KEY, "lifeboard.capture.draft", "lifeboard.mobile.state.v2", "lifeboard.connected.workspace", "lifeboard.mobile.lastWorkspace"]) { try { localStorage.removeItem(key); } catch {} }
    this.data = emptyDocument(); this.base = null; this.revision = 0; this.conflicts = []; this.conflictRemote = null; this.emit();
  }
  async verifyIdentity() {
    if (!globalThis.window) { this.identityVerified = true; return; } // Test runners inject snapshot transport; browsers always verify scope.
    const epoch = this.epoch;
    const checkVersion = this.identityCheckVersion = (this.identityCheckVersion || 0) + 1;
    const checkCurrent = () => {
      if (this.closed || epoch !== this.epoch || checkVersion !== this.identityCheckVersion) throw new Error("signedout");
    };
    const response = await fetch('/api/session', {cache:'no-store'});
    if (response.status===401) { this.identityVerified=false; throw new Error('unauthorised'); }
    if (!response.ok) throw new Error('identity');
    const identity = await response.json();
    checkCurrent();
    if (!identity.workspaceID) throw new Error('identity');
    if (this.storage.workspaceID !== identity.workspaceID) {
      const migrateLegacy = !this.storage.workspaceID && identity.ownerLegacy === true;
      this.identityVerified = false; this.scopeReady = false;
      clearTimeout(this.timer); this.emit();
      // Keep the previous identity and document intact for recovery until the
      // new scope is durably ready. Loading is explicit and does not repin it.
      await this.persistence; checkCurrent();
      if (!this.durable) throw new Error('storage');
      const state = await this.storage.load(identity.workspaceID); checkCurrent();
      const next = state || (migrateLegacy
        ? {data:this.data,base:this.base,revision:this.revision,conflicts:this.conflicts,conflictRemote:this.conflictRemote}
        : {data:emptyDocument(),base:null,revision:0,conflicts:[],conflictRemote:null});
      await this.persist(next, identity.workspaceID); checkCurrent();
      if (!this.durable) {
        // Only the staged new-scope save failed. The drained old-scope copy
        // remains durable and can be exported or used for a safe retry.
        this.durable = true;
        this.status = "Workspace connection not verified · previous work remains on this device";
        this.emit(); throw new Error('storage');
      }
      this.storage.workspaceID = identity.workspaceID;
      this.data=structuredClone(next.data);this.base=structuredClone(next.base);this.revision=next.revision;
      this.conflicts=structuredClone(next.conflicts||[]);this.conflictRemote=structuredClone(next.conflictRemote||null);
    }
    checkCurrent();
    this.scopeReady = true; this.identityVerified = true; this.emit();
  }
  resolveConflicts(choices) {
    if(globalThis.window&&(!this.scopeReady||this.closed||(navigator.onLine&&!this.identityVerified)))throw new Error("Reconnect and verify this workspace before editing");
    if (!this.conflictRemote) throw new Error("Sync again to load conflicting versions");
    const nextBase = structuredClone(this.base || emptyDocument());
    const next = structuredClone(this.data);
    for(const path of this.conflicts){
      const choice=choices[path];if(!['local','remote'].includes(choice))throw new Error('Choose a version for every conflict');
      const theirs=valueAtPath(this.conflictRemote,path);
      setPath(nextBase,path,theirs);
      if(choice==='remote')setPath(next,path,theirs);
    }
    const resolved=mergeSnapshots(nextBase,next,this.conflictRemote);
    if(resolved.conflicts.length)throw new Error('Other fields changed; sync and review again');
    this.base=structuredClone(this.conflictRemote);this.conflicts=[];this.conflictRemote=null;
    this.replace(resolved.data);
  }

  mutate(change) {
    if(globalThis.window&&(!this.scopeReady||this.closed||(navigator.onLine&&!this.identityVerified)))throw new Error("Reconnect and verify this workspace before editing");
    const next = structuredClone(this.data);
    change(next);
    this.data = next;
    this.markChanged();
  }
  replace(next) {
    if(globalThis.window&&(!this.scopeReady||this.closed||(navigator.onLine&&!this.identityVerified)))throw new Error("Reconnect and verify this workspace before editing");
    this.data = structuredClone(next);
    this.markChanged();
  }
  markChanged() {
    this.mutationVersion++;
    this.status = navigator.onLine ? "Changes waiting" : "Offline · changes waiting";
    this.persist();
    clearTimeout(this.timer);
    if (this.busy) this.pendingSync = true;
    else this.timer = setTimeout(() => this.sync(), 400);
  }

  async sync() {
    if (this.closed) return;
    const epoch = this.epoch;
    await this.ready;
    await this.persistence;
    if (!this.durable) { this.status = "Storage unavailable · export pending work"; this.emit(); return; }
    if (this.busy) { this.pendingSync = true; return; }
    if (!navigator.onLine) {
      if (!navigator.onLine) { this.status = "Offline · changes waiting"; this.emit(); }
      return;
    }
    if (this.closed || epoch !== this.epoch) return;
    this.busy = true;
    this.status = "Syncing…";
    this.emit();
    try {
      await this.verifyIdentity();
      if (this.closed || epoch !== this.epoch) return;
      if (!this.durable) return;
      for (let attempt = 0; attempt < 3; attempt++) {
        const response = await fetch("/api/snapshot", { cache: "no-store", headers: this.storage.workspaceID ? {"X-LifeBoard-Workspace":this.storage.workspaceID} : {} });
        if (response.status === 403) { this.identityVerified=false;this.status="Workspace connection changed · reconnect";this.emit();return; }
        if (response.status === 401) { this.status = "Connection expired · reconnect this device"; this.emit(); return; }
        if (!response.ok) throw new Error("fetch");
        const latest = await response.json();
        if (this.closed || epoch !== this.epoch) return;
        if (latest.data && latest.data.schemaVersion !== 3) throw new Error("schema");
        const local = structuredClone(this.data);
        const localVersion = this.mutationVersion;
        let merged;
        if (!latest.data) {
          merged = local;
        } else if (!this.base) {
          if (!hasContent(local)) merged = latest.data;
          else {
            const seeded = emptyDocument();
            seeded.settings = local.settings;
            const candidate = mergeSnapshots(seeded, local, latest.data);
            if(candidate.conflicts.length){this.base=seeded;this.conflicts=candidate.conflicts;this.conflictRemote=structuredClone(latest.data);this.status="Sync needs review · open Sync Centre";await this.persist();return;}
            merged = candidate.data;
            if (merged) merged.settings = latest.data.settings;
          }
        } else {
          const candidate = mergeSnapshots(this.base, local, latest.data);
          if (candidate.conflicts.length) {
            this.conflicts = candidate.conflicts;
            this.conflictRemote = structuredClone(latest.data);
            this.status = "Sync needs review · open Sync Centre";
            await this.persist();
            return;
          }
          merged = candidate.data;
        }
        if (!merged) throw new Error("merge");
        if (latest.data && same(merged, latest.data)) {
          if (this.mutationVersion === localVersion) this.data = merged;
          else this.pendingSync = true;
          this.base = structuredClone(merged);
          this.revision = latest.revision;
          this.lastSyncedAt = new Date();
          this.status = this.pendingSync ? "Changes waiting" : "Synced just now";
          await this.persist();
          return;
        }
        const saved = await fetch("/api/snapshot", {
          method: "PUT", headers: { "Content-Type": "application/json", "If-Match": String(latest.revision), ...(this.storage.workspaceID?{"X-LifeBoard-Workspace":this.storage.workspaceID}:{}) },
          body: JSON.stringify(merged),
        });
        if(saved.status===403){this.identityVerified=false;this.status="Workspace connection changed · reconnect";this.emit();return;}
        if (saved.status === 409) continue;
        if (!saved.ok) throw new Error("save");
        const result = await saved.json();
        if (this.closed || epoch !== this.epoch) return;
        if (this.mutationVersion === localVersion) this.data = merged;
        else {
          const rebased = mergeSnapshots(local, this.data, merged);
          if (rebased.conflicts.length) {
            this.base = local; this.conflicts = rebased.conflicts; this.conflictRemote = structuredClone(merged);
            this.status = "Sync needs review · open Sync Centre"; await this.persist(); return;
          }
          this.data = rebased.data; this.pendingSync = true;
        }
        this.base = structuredClone(merged);
        this.revision = result.revision;
        this.lastSyncedAt = new Date();
        this.status = this.pendingSync ? "Changes waiting" : "Synced just now";
        await this.persist();
        return;
      }
      this.status = "Changes waiting · retrying";
      this.emit();
    } catch (error) {
      if (error.message === "unauthorised") { this.status = "Connection expired · reconnect this device"; this.emit(); return; }
      this.status = this.durable ? "Couldn't sync · saved on this device" : "Couldn't save · export pending work";
      this.emit();
    } finally {
      this.busy = false;
      if (this.pendingSync && !this.closed && epoch === this.epoch) {
        this.pendingSync = false;
        clearTimeout(this.timer);
        this.timer = setTimeout(() => this.sync(), 0);
      }
    }
  }
}

// One transaction contains the document, baseline, revision and unresolved queue.
export class DocumentStorage {
  constructor() {
    this.db = null; this.workspaceID = null;
    try { this.workspaceID=localStorage.getItem("lifeboard.connected.workspace"); } catch {}
  }
  fallbackKey(workspaceID = this.workspaceID) { return workspaceID ? `lifeboard.mobile.state.v2:${workspaceID}` : "lifeboard.mobile.state.v2"; }
  async open() {
    if (!globalThis.indexedDB) return null;
    if (this.db) return this.db;
    this.db = await new Promise((resolve, reject) => {
      const request = indexedDB.open("lifeboard-private-v2", 1);
      request.onupgradeneeded = () => request.result.createObjectStore("state");
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error);
      request.onblocked = () => reject(new Error("Storage is in use; close other LifeBoard tabs"));
    });
    return this.db;
  }
  async load(workspaceID = this.workspaceID) {
    const discover = arguments.length === 0;
    const db = await this.open();
    if (!db) {
      if (discover && !workspaceID) { try { workspaceID = localStorage.getItem("lifeboard.mobile.lastWorkspace"); } catch {} }
      if (discover) this.workspaceID = workspaceID;
      return read(this.fallbackKey(workspaceID), null);
    }
    if (discover && !workspaceID) { workspaceID = await new Promise((resolve,reject)=>{ const tx=db.transaction("state","readonly"),request=tx.objectStore("state").get("lastWorkspace");request.onsuccess=()=>resolve(request.result||null);request.onerror=()=>reject(request.error); }); }
    if (discover) this.workspaceID = workspaceID;
    return new Promise((resolve, reject) => {
      const tx = db.transaction("state", "readonly"); let value;
      const request = tx.objectStore("state").get(workspaceID ? `workspace:${workspaceID}` : "workspace");
      request.onsuccess = () => { value = request.result; };
      tx.oncomplete = () => resolve(value || null);
      tx.onerror = tx.onabort = () => reject(tx.error || new Error("Storage denied"));
    });
  }
  async save(state, workspaceID = this.workspaceID) {
    const db = await this.open();
    if (!db) {
      localStorage.setItem(this.fallbackKey(workspaceID), JSON.stringify({...state,workspaceID}));
      // Pointer failure cannot invalidate the already atomic workspace envelope.
      if (workspaceID) { try { localStorage.setItem("lifeboard.mobile.lastWorkspace",workspaceID); } catch {} }
      return;
    }
    await new Promise((resolve, reject) => {
      const tx = db.transaction("state", "readwrite");
      try {
        tx.objectStore("state").put({...state,workspaceID}, workspaceID ? `workspace:${workspaceID}` : "workspace");
        if (workspaceID) tx.objectStore("state").put(workspaceID,"lastWorkspace");
      } catch(error){tx.abort();reject(error);return;}
      tx.oncomplete = resolve;
      tx.onerror = tx.onabort = () => reject(tx.error || new Error("Storage is full or denied"));
    });
  }
  async clear() {
    const db = await this.open();
    if (!db) { localStorage.removeItem(this.fallbackKey()); localStorage.removeItem("lifeboard.mobile.state.v2"); return; }
    await new Promise((resolve, reject) => {
      const tx = db.transaction("state", "readwrite"); tx.objectStore("state").clear();
      tx.oncomplete = resolve; tx.onerror = tx.onabort = () => reject(tx.error);
    });
  }
}

export function inverseOperation(before, after) {
  const changes = [];
  for (const collection of COLLECTIONS) {
    const a = byID(before[collection]), b = byID(after[collection]);
    for (const id of new Set([...a.keys(), ...b.keys()])) {
      const old = a.get(id), next = b.get(id);
      if (same(old, next)) continue;
      if (!old || !next) { changes.push(structuredClone({ collection, id, old, next })); continue; }
      const fields = Object.keys({ ...old, ...next }).filter(key => !same(old[key], next[key]));
      changes.push(structuredClone({ collection, id, old, next, fields }));
    }
  }
  return changes;
}
export function applyInverse(data, changes) {
  const conflicts = [];
  for (const change of changes) {
    const rows = data[change.collection], index = rows.findIndex(row => sameID(row.id,change.id)), current = rows[index];
    if (!change.fields) {
      if (!same(current, change.next)) { conflicts.push(change.id); continue; }
      if (index >= 0) rows.splice(index, 1);
      if (change.old) rows.push(structuredClone(change.old));
    } else {
      if (!current) { conflicts.push(change.id); continue; }
      for (const field of change.fields) {
        if (field === "modifiedAt") continue;
        if (!same(current[field], change.next[field])) { conflicts.push(`${change.id}/${field}`); continue; }
        if (change.old[field] === undefined) delete current[field]; else current[field] = structuredClone(change.old[field]);
      }
    }
  }
  return conflicts;
}
export function patchDraft(original, draft, current) {
  const target = structuredClone(current), conflicts = [];
  for (const field of Object.keys({ ...original, ...draft })) {
    if (same(original[field], draft[field])) continue;
    if (!same(current[field], original[field]) && !same(current[field], draft[field])) { conflicts.push(field); continue; }
    if (draft[field] === undefined) delete target[field]; else target[field] = draft[field];
  }
  return { data: conflicts.length ? null : target, conflicts };
}
