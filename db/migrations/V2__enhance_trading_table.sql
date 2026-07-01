-- V2: Enhance the trades table with lifecycle and settlement metadata.
--
-- Adds columns needed to track a trade through its full lifecycle:
--   status        - PENDING / SETTLED / CANCELLED
--   fees          - transaction cost paid to the venue or clearer
--   counterparty  - the other side of the trade (nullable)
--   updated_at    - last modification timestamp
--
-- Also adds two indexes commonly used by the API:
--   ix_trades_symbol - filter trades for a given ticker
--   ix_trades_status - dashboards that group by lifecycle state
--
-- Finally, backfills existing V1 rows so seed data is queryable under the
-- new contract without any application-side handling.

ALTER TABLE trades
    ADD COLUMN IF NOT EXISTS status       VARCHAR(16),
    ADD COLUMN IF NOT EXISTS fees         NUMERIC(20, 4),
    ADD COLUMN IF NOT EXISTS counterparty VARCHAR(64),
    ADD COLUMN IF NOT EXISTS updated_at   TIMESTAMPTZ;

-- Backfill legacy V1 rows before we enforce NOT NULL and defaults.
UPDATE trades
SET status     = 'SETTLED',
    fees       = 0,
    updated_at = executed_at
WHERE status IS NULL;

-- Apply defaults and the status check constraint now that data is clean.
ALTER TABLE trades
    ALTER COLUMN status SET DEFAULT 'PENDING',
    ALTER COLUMN status SET NOT NULL,
    ALTER COLUMN fees SET DEFAULT 0,
    ALTER COLUMN fees SET NOT NULL,
    ALTER COLUMN updated_at SET DEFAULT NOW(),
    ALTER COLUMN updated_at SET NOT NULL;

ALTER TABLE trades
    ADD CONSTRAINT chk_trades_status
    CHECK (status IN ('PENDING', 'SETTLED', 'CANCELLED'));

CREATE INDEX IF NOT EXISTS ix_trades_symbol ON trades (symbol);
CREATE INDEX IF NOT EXISTS ix_trades_status ON trades (status);
