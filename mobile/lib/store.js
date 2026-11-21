import { neon } from '@neondatabase/serverless';
// Apply 0003_pairing_retention.sql before deployment. The expiry indexes and
// materialised candidate limit bound lookup/deletion work, including when
// another cleanup transaction holds locks on the oldest rows.
// Recheck expiry while locking and deleting: READ COMMITTED may find an
// updated live row after the earlier candidate snapshot selected its key.
export const PAIRING_RETENTION_QUERIES = Object.freeze([
  `WITH candidates AS MATERIALIZED (
    SELECT bucket FROM life_board_pairing_limits
    WHERE window_start < NOW() - INTERVAL '1 day'
    ORDER BY window_start, bucket LIMIT 100
  ), expired AS (
    SELECT limits.bucket FROM life_board_pairing_limits limits
    JOIN candidates USING(bucket)
    WHERE limits.window_start < NOW() - INTERVAL '1 day'
    FOR UPDATE OF limits SKIP LOCKED
  ) DELETE FROM life_board_pairing_limits limits USING expired
    WHERE limits.bucket=expired.bucket AND limits.window_start < NOW() - INTERVAL '1 day'`,
  `WITH candidates AS MATERIALIZED (
    SELECT code_hash FROM life_board_challenges WHERE expires_at < NOW()
    ORDER BY expires_at, code_hash LIMIT 100
  ), expired AS (
    SELECT challenges.code_hash FROM life_board_challenges challenges
    JOIN candidates USING(code_hash) WHERE challenges.expires_at < NOW()
    FOR UPDATE OF challenges SKIP LOCKED
  ) DELETE FROM life_board_challenges challenges USING expired
    WHERE challenges.code_hash=expired.code_hash AND challenges.expires_at < NOW()`,
]);
export function databaseStore(env=process.env){
  if(!env.DATABASE_URL)throw new Error('Database unavailable');
  const sql=neon(env.DATABASE_URL);
  return {
    async findSession(hash){const rows=await sql`SELECT id, workspace_id AS "workspaceID", device_name AS name,manages_devices AS owner FROM life_board_sessions WHERE token_hash=${hash} AND revoked_at IS NULL AND expires_at>NOW()`;return rows[0]||null;},
    async getSnapshot(workspace){const rows=await sql`SELECT revision,document,updated_at FROM life_board_workspaces WHERE id=${workspace}`;const row=rows[0];return row?{revision:Number(row.revision),data:row.document,updatedAt:row.updated_at}:{revision:0,data:null};},
    async putSnapshot(workspace,base,data){const rows=await sql`UPDATE life_board_workspaces SET revision=revision+1,document=${JSON.stringify(data)}::jsonb,updated_at=NOW() WHERE id=${workspace} AND revision=${base} RETURNING revision,updated_at`;return rows[0]?{revision:Number(rows[0].revision),updatedAt:rows[0].updated_at}:null;},
    async migrateLegacy(hash,expiry){await sql`INSERT INTO life_board_sessions(id,workspace_id,token_hash,device_name,expires_at) VALUES(gen_random_uuid(),'owner',${hash},'Existing owner phone',${expiry}::timestamptz) ON CONFLICT(token_hash) DO NOTHING`;},
    async createWorkspace(id){await sql`INSERT INTO life_board_workspaces(id) VALUES(${id})`;},
    async createSession(id,workspace,hash,name,seconds,manages=false){await sql`INSERT INTO life_board_sessions(id,workspace_id,token_hash,device_name,expires_at,manages_devices) VALUES(${id},${workspace},${hash},${name},NOW()+${seconds}*INTERVAL '1 second',${manages})`;},
    async devices(workspace){return sql`SELECT id,device_name AS name,created_at AS "createdAt",expires_at AS "expiresAt",manages_devices AS "managesDevices" FROM life_board_sessions WHERE workspace_id=${workspace} AND revoked_at IS NULL AND expires_at>NOW() ORDER BY created_at DESC`;},
    async revoke(workspace,id){await sql`UPDATE life_board_sessions SET revoked_at=NOW() WHERE workspace_id=${workspace} AND id=${id}`;},
    async challenge(hash,workspace,name){await sql`INSERT INTO life_board_challenges(code_hash,workspace_id,device_name,expires_at) VALUES(${hash},${workspace},${name},NOW()+INTERVAL '10 minutes')`;},
    async consumeChallenge(hash){const rows=await sql`UPDATE life_board_challenges SET consumed_at=NOW() WHERE code_hash=${hash} AND consumed_at IS NULL AND expires_at>NOW() RETURNING workspace_id AS "workspaceID",device_name AS name`;return rows[0]||null;},
    async pruneExpiredPairing(){await sql.transaction(PAIRING_RETENTION_QUERIES.map(query=>sql.query(query)));},
    async throttle(key,limit=10){const rows=await sql`INSERT INTO life_board_pairing_limits(bucket,attempts,window_start) VALUES(${key},1,NOW()) ON CONFLICT(bucket) DO UPDATE SET attempts=CASE WHEN life_board_pairing_limits.window_start<NOW()-INTERVAL '15 minutes' THEN 1 ELSE life_board_pairing_limits.attempts+1 END, window_start=CASE WHEN life_board_pairing_limits.window_start<NOW()-INTERVAL '15 minutes' THEN NOW() ELSE life_board_pairing_limits.window_start END RETURNING attempts`;return rows[0].attempts<=limit;},
  };
}
