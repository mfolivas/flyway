# Step 3 — V3: normalize counterparties (expand-contract)

You are on branch **`step-3-add-v3`**. This stage extracts the
`counterparty` free-text column into its own `counterparties` table with a
proper foreign key, using the **expand-contract pattern** so no running
consumer breaks.

**What this teaches:**
1. Expand-contract for zero-downtime schema changes:
   - **Expand (this migration):** add the new structure, backfill, keep
     the old column in place so old code still works.
   - **Deploy code** that writes to both and reads from the new structure.
   - **Contract (a future V4):** drop the old column once no code touches
     it.
2. Backfill logic inside a migration: `INSERT ... SELECT DISTINCT` plus a
   correlated `UPDATE ... FROM`.
3. Get-or-create semantics in the application layer so repeated
   counterparty names collapse to a single row.

Compare against the previous stage:

```bash
git diff step-2-add-v2 step-3-add-v3 -- db/ app/
```

---

## What V3 changes

```sql
CREATE TABLE counterparties (
    id         BIGSERIAL PRIMARY KEY,
    name       VARCHAR(64) NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT uq_counterparties_name UNIQUE (name)
);

INSERT INTO counterparties (name)
SELECT DISTINCT counterparty
FROM trades
WHERE counterparty IS NOT NULL
ON CONFLICT (name) DO NOTHING;

ALTER TABLE trades
    ADD COLUMN IF NOT EXISTS counterparty_id BIGINT
    REFERENCES counterparties (id);

UPDATE trades t
   SET counterparty_id = c.id
  FROM counterparties c
 WHERE t.counterparty = c.name
   AND t.counterparty_id IS NULL;

CREATE INDEX IF NOT EXISTS ix_trades_counterparty_id ON trades (counterparty_id);
```

**Note the old `trades.counterparty` column is intentionally preserved.**
A hypothetical `V4__drop_trades_counterparty_column.sql` would remove it
once every consumer reads from `counterparty_id`.

Application code changes:

- New ORM model: `Counterparty`.
- `Trade.counterparty_id` FK with a lazy relationship.
- `create_trade` writes BOTH the old string column AND the FK.
- New endpoint: `GET /counterparties`.
- `TradeRead` response now includes `counterparty_id`.

> **Note:** the backfill sets `updated_at = executed_at` on V1 rows, but
> new inserts get `updated_at = NOW()` (via the column default and the
> `crud.create_trade` helper). Legacy rows therefore have
> `updated_at == executed_at`, while new rows track "last modified"
> independently. That asymmetry is intentional — we don't want to
> pretend V1 rows were modified at migration time.

---

## How to build

> **Coming from another stage?** Run `docker compose down -v` first to
> wipe the Postgres volume. If the volume was populated by an earlier
> step, the `flyway_schema_history` rows may not match this branch's
> migration files exactly — a clean volume avoids any drift confusion.

```bash
cd ~/Documents/analysis/stories/database-migration/example
cp .env.example .env         # if you haven't already
docker compose build         # rebuild the API image for V3 code
```

## How to start

```bash
docker compose up            # foreground; Ctrl+C to stop
# or
docker compose up -d
docker compose logs -f flyway
docker compose logs -f api
```

On success Flyway logs show:

```text
Successfully applied 3 migrations to schema "public"
```

## How to test

```bash
bash scripts/test_endpoints.sh
```

The V3 test script verifies:

- `GET /counterparties` is reachable and returns a list.
- Posting a trade with `counterparty="JPM"` creates a `counterparties`
  row and populates `trades.counterparty_id`.
- A second trade with the same counterparty **reuses** the existing row
  (no duplicate).
- Trades without a counterparty leave `counterparty_id` null.

Manual examples:

```bash
# Fresh DB: no counterparties yet
curl -s http://localhost:8000/counterparties | jq .

# Post a trade with a counterparty
curl -s -X POST http://localhost:8000/trades \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"NVDA","side":"BUY","quantity":10,"price":950.50,"counterparty":"Goldman"}' | jq .

# Counterparties list now contains Goldman
curl -s http://localhost:8000/counterparties | jq .

# Second trade with the same counterparty reuses the row
curl -s -X POST http://localhost:8000/trades \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"AMD","side":"SELL","quantity":5,"price":170.25,"counterparty":"Goldman"}' | jq .
```

## How to inspect Flyway state

```bash
docker compose exec postgres psql -U trading_user -d trading \
  -c 'SELECT installed_rank, version, description, success
      FROM flyway_schema_history;'
```

Expected:

```text
 installed_rank | version | description                | success
----------------+---------+----------------------------+---------
              1 | 1       | initial trading schema     | t
              2 | 2       | enhance trading table      | t
              3 | 3       | extract counterparty table | t
```

Inspect the joined data:

```bash
docker compose exec postgres psql -U trading_user -d trading -c '
    SELECT t.id, t.symbol, t.side, t.counterparty, c.name AS cp_name, c.id AS cp_id
      FROM trades t
      LEFT JOIN counterparties c ON c.id = t.counterparty_id
     ORDER BY t.id;'
```

## Exercise — trigger and repair checksum drift

Flyway's checksum enforcement is the guardrail against "someone edited a
migration after it ran." Try breaking it on purpose:

```bash
# Bring the stack up and let all three migrations apply.
docker compose up -d
docker compose run --rm flyway info    # Success on V1, V2, V3.

# Edit V1 in a harmless way (add a blank line at the end).
printf '\n' >> db/migrations/V1__initial_trading_schema.sql

# Re-run migrate. Flyway refuses.
docker compose run --rm flyway migrate
#   ERROR: Migration checksum mismatch for migration version 1
#   -> Applied to database : ...
#   -> Resolved locally    : ...

# You have two ways out. Pick one:

# (a) Revert the edit and try again.
git checkout -- db/migrations/V1__initial_trading_schema.sql
docker compose run --rm flyway migrate    # succeeds.

# (b) If the edit was intentional (e.g. a comment cleanup), tell Flyway
#     to accept the new checksum:
docker compose run --rm flyway repair
docker compose run --rm flyway info       # V1 shows the updated checksum.
```

Never resolve drift by hand-editing `flyway_schema_history`. `repair` is
the sanctioned tool.

## Where to go from here

You have finished the workshop.

- Review the full arc:
  `git diff main step-3-add-v3 -- db/ app/`
- Read [`docs/migration-strategy.md`](docs/migration-strategy.md) for the
  full write-up on Flyway state, checksum drift, failure handling, and
  the expand-contract pattern.
- Read [`docs/decisions/ADR-001-adopt-flyway.md`](docs/decisions/ADR-001-adopt-flyway.md)
  for the rationale behind choosing Flyway over Liquibase, Alembic, and
  Sqitch.
- Try adding a `V4__drop_trades_counterparty_column.sql` yourself as an
  exercise. Remember: forward-only. If you break it, `flyway repair`
  clears the failed row from history.

## Troubleshooting

**`FOREIGN KEY constraint violated on counterparty_id`**
Something wrote to `trades.counterparty_id` with an id that does not
exist in `counterparties`. In this example that should not happen — the
app resolves counterparties through `get_or_create_counterparty`. Check
`crud.py` for a recent edit that bypassed it.

**Duplicate counterparty rows appearing**
The `uq_counterparties_name` constraint would prevent that at the DB
layer. If they appear, the application code path is bypassing
`get_or_create_counterparty` — inspect `crud.py`.

**`Migration checksum mismatch`**
Someone edited `V1__`, `V2__`, or `V3__` after it was applied. Revert or
`docker compose run --rm flyway repair`.
