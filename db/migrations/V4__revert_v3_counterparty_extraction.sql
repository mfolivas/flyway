-- V4: Forward-only rollback of V3.
--
-- Scenario: V3 shipped the expand phase of counterparty normalization
-- (new counterparties table + trades.counterparty_id FK). We have since
-- decided that normalization was the wrong call for this workload and
-- need to walk it back BEFORE any consumer starts depending on the FK.
--
-- Flyway Community is forward-only. There is no `flyway rollback`. The
-- only sanctioned way to undo an applied migration is to ship a NEW
-- higher-numbered migration that inverses the effect. Editing or
-- deleting V3 would break checksums on every environment where it
-- already ran.
--
-- V4 undoes V3 in reverse dependency order:
--   1. drop the index on trades.counterparty_id
--   2. drop the FK column trades.counterparty_id
--   3. drop the counterparties table
--
-- The old trades.counterparty string column stays in place — V3 added
-- the FK alongside it (expand-contract) so removing the FK restores the
-- pre-V3 shape without data loss.
--
-- Fresh environments will apply V1 -> V2 -> V3 -> V4 in order, briefly
-- materialising the V3 state before this migration removes it. That is
-- the correct behavior: a fresh DB must traverse the same history as
-- production so the schema_history ledger stays honest.

DROP INDEX IF EXISTS ix_trades_counterparty_id;

ALTER TABLE trades
    DROP COLUMN IF EXISTS counterparty_id;

DROP TABLE IF EXISTS counterparties;
