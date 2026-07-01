-- V3: Extract counterparty into its own table (expand phase).
--
-- This demonstrates the expand-contract pattern for zero-downtime schema
-- changes:
--   1. EXPAND (this migration): add the new structure alongside the old,
--      backfill, keep both columns in place. Old application code that
--      only knows about trades.counterparty keeps working.
--   2. Deploy application code that writes to both and reads from the new
--      structure. (This branch does that.)
--   3. CONTRACT (a future V4): once every running deployment reads from
--      counterparty_id, drop the old trades.counterparty column.
--
-- V3 adds:
--   - counterparties table (id, name UNIQUE, created_at)
--   - trades.counterparty_id BIGINT FK -> counterparties(id) (nullable)
--   - index on trades.counterparty_id
--   - backfill: one row per DISTINCT trades.counterparty, then set
--     trades.counterparty_id accordingly.
--
-- The old trades.counterparty column is intentionally preserved.

CREATE TABLE IF NOT EXISTS counterparties (
    id         BIGSERIAL PRIMARY KEY,
    name       VARCHAR(64) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_counterparties_name UNIQUE (name)
);

-- Backfill counterparties from any distinct string values currently in
-- trades.counterparty. If the workshop starts from a fresh DB this is a
-- no-op; if the user has been creating trades on step-2 it captures them.
INSERT INTO counterparties (name)
SELECT DISTINCT counterparty
FROM trades
WHERE counterparty IS NOT NULL
ON CONFLICT (name) DO NOTHING;

ALTER TABLE trades
    ADD COLUMN IF NOT EXISTS counterparty_id BIGINT
    REFERENCES counterparties (id);

-- Link existing trades to the newly-created counterparties rows.
UPDATE trades t
   SET counterparty_id = c.id
  FROM counterparties c
 WHERE t.counterparty = c.name
   AND t.counterparty_id IS NULL;

CREATE INDEX IF NOT EXISTS ix_trades_counterparty_id
    ON trades (counterparty_id);
