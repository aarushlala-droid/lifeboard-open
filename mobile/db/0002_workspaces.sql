-- Run after 0001, in a maintenance window with a verified database backup.
-- Additive migration: original owner document and revision remain unchanged.
DO $migration$
DECLARE owner_existed boolean;
BEGIN
-- Drain old writers and hold the lock through verification and trigger install.
LOCK TABLE life_board_snapshot IN ACCESS EXCLUSIVE MODE;
CREATE TABLE IF NOT EXISTS life_board_workspaces (
 id text PRIMARY KEY, revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 document jsonb, updated_at timestamptz NOT NULL DEFAULT now()
);
SELECT EXISTS(SELECT 1 FROM life_board_workspaces WHERE id='owner') INTO owner_existed;
INSERT INTO life_board_workspaces(id,revision,document,updated_at)
 SELECT 'owner',revision,document,updated_at FROM life_board_snapshot WHERE id=1
 ON CONFLICT(id) DO NOTHING;
INSERT INTO life_board_workspaces(id) VALUES('owner') ON CONFLICT(id) DO NOTHING;
IF NOT owner_existed AND EXISTS(SELECT 1 FROM life_board_snapshot WHERE id=1) AND
   NOT EXISTS(SELECT 1 FROM life_board_workspaces w JOIN life_board_snapshot s ON s.id=1
      WHERE w.id='owner' AND w.revision=s.revision AND w.document IS NOT DISTINCT FROM s.document) THEN
 RAISE EXCEPTION 'Owner snapshot preservation verification failed';
END IF;
CREATE TABLE IF NOT EXISTS life_board_sessions (
 id uuid PRIMARY KEY,workspace_id text NOT NULL REFERENCES life_board_workspaces(id),
 token_hash text UNIQUE NOT NULL,device_name text NOT NULL,manages_devices boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL,revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS life_board_sessions_workspace ON life_board_sessions(workspace_id);
CREATE TABLE IF NOT EXISTS life_board_challenges (
 code_hash text PRIMARY KEY,workspace_id text NOT NULL REFERENCES life_board_workspaces(id),
 device_name text NOT NULL,expires_at timestamptz NOT NULL,consumed_at timestamptz
);
CREATE TABLE IF NOT EXISTS life_board_pairing_limits (
 bucket text PRIMARY KEY,attempts integer NOT NULL,window_start timestamptz NOT NULL
);
-- Freeze the retained legacy table: an old deployment must fail closed, rather
-- than accepting writes into a disconnected copy of the owner's workspace.
CREATE OR REPLACE FUNCTION life_board_legacy_read_only() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
 RAISE EXCEPTION 'LifeBoard workspace migrated; legacy writes disabled';
END $$;
DROP TRIGGER IF EXISTS life_board_legacy_read_only ON life_board_snapshot;
CREATE TRIGGER life_board_legacy_read_only BEFORE INSERT OR UPDATE OR DELETE
 ON life_board_snapshot FOR EACH STATEMENT EXECUTE FUNCTION life_board_legacy_read_only();
END $migration$;
-- Retain life_board_snapshot as migration recovery; old API must not run concurrently.
-- Retention: periodically delete expired challenges and rate buckets older than 1 day.
