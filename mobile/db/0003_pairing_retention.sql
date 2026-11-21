-- Additive, idempotent expiry indexes. Run before deploying bounded cleanup.
-- The single atomic statement is compatible with Vercel's Query editor.
-- No workspace, snapshot, session or credential rows are changed.
DO $retention_indexes$
BEGIN
 CREATE INDEX IF NOT EXISTS life_board_pairing_limits_retention
  ON life_board_pairing_limits(window_start,bucket);
 CREATE INDEX IF NOT EXISTS life_board_challenges_retention
  ON life_board_challenges(expires_at,code_hash);
END $retention_indexes$;
