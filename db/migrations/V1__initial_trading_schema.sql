-- V1: Initial trading schema.
--
-- Creates the trades table that records buy and sell transactions for a
-- security, plus three seed rows so the API has data to serve immediately
-- after `docker compose up`.
--
-- This is the baseline version. Every future migration builds on this one
-- and must not modify the statements inside V1 - Flyway detects checksum
-- drift and will refuse to run.

CREATE TABLE IF NOT EXISTS trades (
    id           BIGSERIAL PRIMARY KEY,
    symbol       VARCHAR(16)    NOT NULL,
    side         VARCHAR(4)     NOT NULL,
    quantity     NUMERIC(20, 4) NOT NULL,
    price        NUMERIC(20, 4) NOT NULL,
    executed_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_trades_side CHECK (side IN ('BUY', 'SELL')),
    CONSTRAINT chk_trades_quantity_positive CHECK (quantity > 0),
    CONSTRAINT chk_trades_price_positive CHECK (price > 0)
);

-- Seed data so the API returns something useful on first boot.
INSERT INTO trades (symbol, side, quantity, price, executed_at) VALUES
    ('AAPL', 'BUY',  100.0000, 189.4500, NOW() - INTERVAL '2 days'),
    ('MSFT', 'BUY',   50.0000, 415.2000, NOW() - INTERVAL '1 day'),
    ('AAPL', 'SELL',  25.0000, 192.1000, NOW() - INTERVAL '6 hours');
