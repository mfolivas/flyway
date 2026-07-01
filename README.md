# Step 2 — V2: enhance the trades table

You are on branch **`step-2-add-v2`**. This stage adds lifecycle metadata
to the `trades` table without breaking existing data or the API contract.

**What this teaches:** how to add non-nullable columns to a populated
table safely. The canonical sequence — add nullable → backfill → set
defaults → tighten to NOT NULL → add constraint — all inside a single
transactional migration.

Compare against the previous stage:

```bash
git diff step-1-v1-only step-2-add-v2 -- db/ app/
```

You will see:

- One new migration file: `db/migrations/V2__enhance_trading_table.sql`.
- ORM model gains four columns.
- API contract gains `status`, `fees`, `counterparty`, `updated_at`.
- New query param: `GET /trades?status=SETTLED`.
- `PUT /trades/{id}` can now mark a trade `SETTLED`.

---

## What V2 changes

```sql
ALTER TABLE trades
    ADD COLUMN IF NOT EXISTS status       VARCHAR(16),
    ADD COLUMN IF NOT EXISTS fees         NUMERIC(20, 4),
    ADD COLUMN IF NOT EXISTS counterparty VARCHAR(64),
    ADD COLUMN IF NOT EXISTS updated_at   TIMESTAMPTZ;

UPDATE trades
   SET status='SETTLED', fees=0, updated_at=executed_at
 WHERE status IS NULL;

ALTER TABLE trades
    ALTER COLUMN status     SET DEFAULT 'PENDING', ALTER COLUMN status     SET NOT NULL,
    ALTER COLUMN fees       SET DEFAULT 0,         ALTER COLUMN fees       SET NOT NULL,
    ALTER COLUMN updated_at SET DEFAULT NOW(),     ALTER COLUMN updated_at SET NOT NULL;

ALTER TABLE trades
    ADD CONSTRAINT chk_trades_status CHECK (status IN ('PENDING','SETTLED','CANCELLED'));

CREATE INDEX IF NOT EXISTS ix_trades_symbol ON trades (symbol);
CREATE INDEX IF NOT EXISTS ix_trades_status ON trades (status);
```

The three V1 seed rows are backfilled to `status='SETTLED'`. New trades
default to `status='PENDING'`.

> **Note:** the backfill sets `updated_at = executed_at` on V1 rows, but
> new inserts get `updated_at = NOW()` (via the column default and the
> `crud.create_trade` helper). Legacy rows therefore have
> `updated_at == executed_at`, while new rows track "last modified"
> independently. That asymmetry is intentional — we don't want to
> pretend V1 rows were modified at migration time.

---

## How to build

> **Coming from another stage?** Run `docker compose down -v` first to
> wipe the Postgres volume. Flyway records applied versions in
> `flyway_schema_history`; if you switch to step-2 with a database that
> already has V3 rows (or any version this branch doesn't ship), Flyway
> rejects the mismatch. A clean volume means a clean run.

```bash
cd ~/Documents/analysis/stories/database-migration/example
cp .env.example .env         # if you haven't already
docker compose build         # rebuild the API image for the V2 code
```

## How to start

```bash
docker compose up            # foreground; Ctrl+C to stop
# or
docker compose up -d
docker compose logs -f flyway
docker compose logs -f api
```

On success, Flyway logs show:

```text
Successfully applied 2 migrations to schema "public"
```

## How to test

```bash
bash scripts/test_endpoints.sh
```

The V2 test script exercises the new fields, verifies V1 seed data was
backfilled, and rejects invalid `status` values.

Manual examples:

```bash
# List trades filtered by status
curl -s 'http://localhost:8000/trades?status=SETTLED' | jq .
curl -s 'http://localhost:8000/trades?status=PENDING' | jq .

# Create with counterparty
curl -s -X POST http://localhost:8000/trades \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"NVDA","side":"BUY","quantity":10,"price":950.50,"counterparty":"JPM"}' | jq .

# Mark a trade SETTLED
curl -s -X PUT http://localhost:8000/trades/4 \
  -H 'Content-Type: application/json' \
  -d '{"status":"SETTLED","fees":1.25}' | jq .
```

## How to inspect Flyway state

```bash
docker compose exec postgres psql -U trading_user -d trading \
  -c 'SELECT installed_rank, version, description, success
      FROM flyway_schema_history;'
```

Expected:

```text
 installed_rank | version | description            | success
----------------+---------+------------------------+---------
              1 | 1       | initial trading schema | t
              2 | 2       | enhance trading table  | t
```

## How to move to step 3

```bash
docker compose down -v
git checkout step-3-add-v3
docker compose up --build
```

Preview the diff:

```bash
git diff step-2-add-v2 step-3-add-v3 -- db/ app/
```

## Troubleshooting

**`ERROR: check constraint "chk_trades_status" is violated by some row`**
V1 rows were not backfilled before the constraint was added. In this
example the migration does the backfill in the same transaction so this
should not happen; if you see it, inspect the migration for a bad SQL edit
that skipped the `UPDATE`.

**`Migration checksum mismatch`**
Someone edited `V1__` or `V2__` after it had been applied. Revert the
edit or run `docker compose run --rm flyway repair`.
See [`docs/migration-strategy.md`](docs/migration-strategy.md).
