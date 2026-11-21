CREATE TABLE IF NOT EXISTS life_board_snapshot (
  id integer PRIMARY KEY CHECK (id = 1),
  revision bigint NOT NULL,
  document jsonb NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);
