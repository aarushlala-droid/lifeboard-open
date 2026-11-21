-- Synthetic PostgreSQL acceptance test. It deliberately raises PASS so the
-- entire statement rolls back; no retained objects or production rows change.
DO $staging$
DECLARE changed integer;
BEGIN
 CREATE TEMP TABLE audit_retention_limits(bucket text PRIMARY KEY,attempts integer NOT NULL,window_start timestamptz NOT NULL) ON COMMIT DROP;
 CREATE TEMP TABLE audit_retention_challenges(code_hash text PRIMARY KEY,expires_at timestamptz NOT NULL) ON COMMIT DROP;
 CREATE INDEX ON audit_retention_limits(window_start,bucket);
 CREATE INDEX ON audit_retention_challenges(expires_at,code_hash);
 INSERT INTO audit_retention_limits SELECT 'expired-'||n,1,NOW()-INTERVAL '2 days' FROM generate_series(1,250) n;
 INSERT INTO audit_retention_limits VALUES('live-network',10,NOW()),('recent-network',5,NOW()-INTERVAL '23 hours');
 INSERT INTO audit_retention_challenges SELECT 'expired-'||n,NOW()-INTERVAL '1 minute' FROM generate_series(1,250) n;
 INSERT INTO audit_retention_challenges VALUES('live-challenge',NOW()+INTERVAL '10 minutes');
 WITH candidates AS MATERIALIZED (
    SELECT bucket FROM audit_retention_limits
    WHERE window_start < NOW() - INTERVAL '1 day'
    ORDER BY window_start, bucket LIMIT 100
  ), expired AS (
    SELECT limits.bucket FROM audit_retention_limits limits
    JOIN candidates USING(bucket)
    WHERE limits.window_start < NOW() - INTERVAL '1 day'
    FOR UPDATE OF limits SKIP LOCKED
  ) DELETE FROM audit_retention_limits limits USING expired
    WHERE limits.bucket=expired.bucket AND limits.window_start < NOW() - INTERVAL '1 day';
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>100 OR (SELECT count(*) FROM audit_retention_limits)<>152 THEN RAISE EXCEPTION 'Counter cleanup was not bounded to 100'; END IF;
 IF NOT EXISTS(SELECT 1 FROM audit_retention_limits WHERE bucket='live-network' AND attempts=10) OR NOT EXISTS(SELECT 1 FROM audit_retention_limits WHERE bucket='recent-network') THEN RAISE EXCEPTION 'Active counter changed'; END IF;
 WITH candidates AS MATERIALIZED (
    SELECT code_hash FROM audit_retention_challenges WHERE expires_at < NOW()
    ORDER BY expires_at, code_hash LIMIT 100
  ), expired AS (
    SELECT challenges.code_hash FROM audit_retention_challenges challenges
    JOIN candidates USING(code_hash) WHERE challenges.expires_at < NOW()
    FOR UPDATE OF challenges SKIP LOCKED
  ) DELETE FROM audit_retention_challenges challenges USING expired
    WHERE challenges.code_hash=expired.code_hash AND challenges.expires_at < NOW();
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>100 OR (SELECT count(*) FROM audit_retention_challenges)<>151 THEN RAISE EXCEPTION 'Challenge cleanup was not bounded to 100'; END IF;
 IF NOT EXISTS(SELECT 1 FROM audit_retention_challenges WHERE code_hash='live-challenge') THEN RAISE EXCEPTION 'Active challenge changed'; END IF;
 WITH candidates AS MATERIALIZED (
    SELECT bucket FROM audit_retention_limits
    WHERE window_start < NOW() - INTERVAL '1 day'
    ORDER BY window_start, bucket LIMIT 100
  ), expired AS (
    SELECT limits.bucket FROM audit_retention_limits limits
    JOIN candidates USING(bucket)
    WHERE limits.window_start < NOW() - INTERVAL '1 day'
    FOR UPDATE OF limits SKIP LOCKED
  ) DELETE FROM audit_retention_limits limits USING expired
    WHERE limits.bucket=expired.bucket AND limits.window_start < NOW() - INTERVAL '1 day';
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>100 THEN RAISE EXCEPTION 'Second counter cleanup failed'; END IF;
 WITH candidates AS MATERIALIZED (
    SELECT code_hash FROM audit_retention_challenges WHERE expires_at < NOW()
    ORDER BY expires_at, code_hash LIMIT 100
  ), expired AS (
    SELECT challenges.code_hash FROM audit_retention_challenges challenges
    JOIN candidates USING(code_hash) WHERE challenges.expires_at < NOW()
    FOR UPDATE OF challenges SKIP LOCKED
  ) DELETE FROM audit_retention_challenges challenges USING expired
    WHERE challenges.code_hash=expired.code_hash AND challenges.expires_at < NOW();
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>100 THEN RAISE EXCEPTION 'Second challenge cleanup failed'; END IF;
 -- Deterministically preserve a stale candidate list while renewing its row.
 -- This reproduces the hazardous candidate/lock split without a second session.
 INSERT INTO audit_retention_limits VALUES('renewed-network',10,NOW()-INTERVAL '2 days');
 CREATE TEMP TABLE audit_stale_limit_candidates ON COMMIT DROP AS SELECT bucket FROM audit_retention_limits WHERE bucket='renewed-network';
 UPDATE audit_retention_limits SET window_start=NOW(),attempts=1 WHERE bucket='renewed-network';
 WITH candidates AS MATERIALIZED (SELECT bucket FROM audit_stale_limit_candidates ), expired AS (
    SELECT limits.bucket FROM audit_retention_limits limits
    JOIN candidates USING(bucket)
    WHERE limits.window_start < NOW() - INTERVAL '1 day'
    FOR UPDATE OF limits SKIP LOCKED
  ) DELETE FROM audit_retention_limits limits USING expired
    WHERE limits.bucket=expired.bucket AND limits.window_start < NOW() - INTERVAL '1 day';
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>0 OR NOT EXISTS(SELECT 1 FROM audit_retention_limits WHERE bucket='renewed-network' AND attempts=1 AND window_start=NOW()) THEN RAISE EXCEPTION 'Renewed counter deleted from stale candidate'; END IF;
 INSERT INTO audit_retention_challenges VALUES('renewed-challenge',NOW()-INTERVAL '1 minute');
 CREATE TEMP TABLE audit_stale_challenge_candidates ON COMMIT DROP AS SELECT code_hash FROM audit_retention_challenges WHERE code_hash='renewed-challenge';
 UPDATE audit_retention_challenges SET expires_at=NOW()+INTERVAL '10 minutes' WHERE code_hash='renewed-challenge';
 WITH candidates AS MATERIALIZED (SELECT code_hash FROM audit_stale_challenge_candidates ), expired AS (
    SELECT challenges.code_hash FROM audit_retention_challenges challenges
    JOIN candidates USING(code_hash) WHERE challenges.expires_at < NOW()
    FOR UPDATE OF challenges SKIP LOCKED
  ) DELETE FROM audit_retention_challenges challenges USING expired
    WHERE challenges.code_hash=expired.code_hash AND challenges.expires_at < NOW();
 GET DIAGNOSTICS changed=ROW_COUNT;
 IF changed<>0 OR NOT EXISTS(SELECT 1 FROM audit_retention_challenges WHERE code_hash='renewed-challenge' AND expires_at>NOW()) THEN RAISE EXCEPTION 'Renewed challenge deleted from stale candidate'; END IF;
 RAISE EXCEPTION 'LIFEBOARD_RETENTION_STAGING_PASS: exact100-row batches; active and renewed counters/challenges preserved; rolled back';
END $staging$;
