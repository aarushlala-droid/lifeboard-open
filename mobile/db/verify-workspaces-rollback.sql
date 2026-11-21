-- Run after 0001, in a maintenance window with a verified database backup.
-- Additive migration: original owner document and revision remain unchanged.
DO $migration$
DECLARE owner_existed boolean; changed integer;
BEGIN
CREATE TEMP TABLE audit_stage_snapshot (id integer PRIMARY KEY, revision bigint, document jsonb, updated_at timestamptz);
INSERT INTO audit_stage_snapshot VALUES(1,71,'{"synthetic":true}'::jsonb,NOW());
-- Drain old writers and hold the lock through verification and trigger install.
LOCK TABLE audit_stage_snapshot IN ACCESS EXCLUSIVE MODE;
CREATE TEMP TABLE IF NOT EXISTS audit_stage_workspaces (
 id text PRIMARY KEY, revision bigint NOT NULL DEFAULT 0 CHECK(revision>=0),
 document jsonb, updated_at timestamptz NOT NULL DEFAULT now()
);
SELECT EXISTS(SELECT 1 FROM audit_stage_workspaces WHERE id='owner') INTO owner_existed;
INSERT INTO audit_stage_workspaces(id,revision,document,updated_at)
 SELECT 'owner',revision,document,updated_at FROM audit_stage_snapshot WHERE id=1
 ON CONFLICT(id) DO NOTHING;
INSERT INTO audit_stage_workspaces(id) VALUES('owner') ON CONFLICT(id) DO NOTHING;
IF NOT owner_existed AND EXISTS(SELECT 1 FROM audit_stage_snapshot WHERE id=1) AND
   NOT EXISTS(SELECT 1 FROM audit_stage_workspaces w JOIN audit_stage_snapshot s ON s.id=1
      WHERE w.id='owner' AND w.revision=s.revision AND w.document IS NOT DISTINCT FROM s.document) THEN
 RAISE EXCEPTION 'Owner snapshot preservation verification failed';
END IF;
CREATE TEMP TABLE IF NOT EXISTS audit_stage_sessions (
 id uuid PRIMARY KEY,workspace_id text NOT NULL REFERENCES audit_stage_workspaces(id),
 token_hash text UNIQUE NOT NULL,device_name text NOT NULL,manages_devices boolean NOT NULL DEFAULT false,
 created_at timestamptz NOT NULL DEFAULT now(),expires_at timestamptz NOT NULL,revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS audit_stage_sessions_workspace ON audit_stage_sessions(workspace_id);
CREATE TEMP TABLE IF NOT EXISTS audit_stage_challenges (
 code_hash text PRIMARY KEY,workspace_id text NOT NULL REFERENCES audit_stage_workspaces(id),
 device_name text NOT NULL,expires_at timestamptz NOT NULL,consumed_at timestamptz
);
CREATE TEMP TABLE IF NOT EXISTS audit_stage_pairing_limits (
 bucket text PRIMARY KEY,attempts integer NOT NULL,window_start timestamptz NOT NULL
);
-- Freeze the retained legacy table: an old deployment must fail closed, rather
-- than accepting writes into a disconnected copy of the owner's workspace.
CREATE OR REPLACE FUNCTION audit_stage_legacy_read_only() RETURNS trigger
LANGUAGE plpgsql AS $$ BEGIN
 RAISE EXCEPTION 'LifeBoard workspace migrated; legacy writes disabled';
END $$;
DROP TRIGGER IF EXISTS audit_stage_legacy_read_only ON audit_stage_snapshot;
CREATE TRIGGER audit_stage_legacy_read_only BEFORE INSERT OR UPDATE OR DELETE
 ON audit_stage_snapshot FOR EACH STATEMENT EXECUTE FUNCTION audit_stage_legacy_read_only();

-- Freeze rejects legacy writes without changing its original row.
BEGIN
 UPDATE audit_stage_snapshot SET revision=72 WHERE id=1;
 RAISE EXCEPTION 'Stage legacy writer was not blocked';
EXCEPTION WHEN raise_exception THEN
 IF SQLERRM <> 'LifeBoard workspace migrated; legacy writes disabled' THEN RAISE; END IF;
END;
UPDATE audit_stage_workspaces SET revision=revision+1 WHERE id='owner' AND revision=71;
GET DIAGNOSTICS changed = ROW_COUNT;
IF changed<>1 THEN RAISE EXCEPTION 'CAS first write failed'; END IF;
UPDATE audit_stage_workspaces SET revision=revision+1 WHERE id='owner' AND revision=71;
GET DIAGNOSTICS changed = ROW_COUNT;
IF changed<>0 THEN RAISE EXCEPTION 'Stale CAS accepted'; END IF;
INSERT INTO audit_stage_sessions(id,workspace_id,token_hash,device_name,expires_at) VALUES('00000000-0000-4000-8000-000000000001','owner','synthetic-hash','Synthetic',NOW()+INTERVAL '1 hour');
BEGIN
 INSERT INTO audit_stage_sessions(id,workspace_id,token_hash,device_name,expires_at) VALUES('00000000-0000-4000-8000-000000000002','owner','synthetic-hash','Synthetic',NOW()+INTERVAL '1 hour');
 RAISE EXCEPTION 'Token uniqueness failed';
EXCEPTION WHEN unique_violation THEN NULL;
END;
BEGIN
 INSERT INTO audit_stage_sessions(id,workspace_id,token_hash,device_name,expires_at) VALUES('00000000-0000-4000-8000-000000000003','missing-workspace','synthetic-other','Synthetic',NOW()+INTERVAL '1 hour');
 RAISE EXCEPTION 'Workspace FK failed';
EXCEPTION WHEN foreign_key_violation THEN NULL;
END;
INSERT INTO audit_stage_challenges(code_hash,workspace_id,device_name,expires_at) VALUES('synthetic-challenge','owner','Synthetic',NOW()+INTERVAL '10 minutes');
UPDATE audit_stage_challenges SET consumed_at=NOW() WHERE code_hash='synthetic-challenge' AND consumed_at IS NULL AND expires_at>NOW();
GET DIAGNOSTICS changed = ROW_COUNT;
IF changed<>1 THEN RAISE EXCEPTION 'First redemption failed'; END IF;
UPDATE audit_stage_challenges SET consumed_at=NOW() WHERE code_hash='synthetic-challenge' AND consumed_at IS NULL AND expires_at>NOW();
GET DIAGNOSTICS changed = ROW_COUNT;
IF changed<>0 THEN RAISE EXCEPTION 'Challenge reused'; END IF;
INSERT INTO audit_stage_pairing_limits VALUES('synthetic-bucket',1,NOW());
INSERT INTO audit_stage_pairing_limits VALUES('synthetic-bucket',1,NOW()) ON CONFLICT(bucket) DO UPDATE SET attempts=audit_stage_pairing_limits.attempts+1;
IF NOT EXISTS(SELECT 1 FROM audit_stage_pairing_limits WHERE attempts=2) THEN RAISE EXCEPTION 'Rate persistence failed'; END IF;
RAISE EXCEPTION 'LIFEBOARD_STAGING_PASS: owner copy, legacy freeze, CAS, uniqueness, workspace FK, one-use challenge, persistent bucket; all staging changes rolled back';

END $migration$;
-- Retain audit_stage_snapshot as migration recovery; old API must not run concurrently.
-- Retention: periodically delete expired challenges and rate buckets older than 1 day.
