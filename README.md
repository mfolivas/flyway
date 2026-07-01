# Step 1 — V1 only: the initial trading schema

You are on branch **`step-1-v1-only`**. This stage introduces the bare
minimum: a `trades` table with a handful of columns and three seed rows.

**What this teaches:** the Flyway baseline. How a single versioned
migration file, discovered by the Flyway container at boot, creates schema
and seeds data — and how the FastAPI service comes up against it.

**What is NOT here yet:** trade lifecycle (status, fees), counterparties,
or any V2/V3 concepts. Those arrive on later branches:

| Next branch          | What it adds                                              |
|----------------------|-----------------------------------------------------------|
| `step-2-add-v2`      | `status`, `fees`, `counterparty`, `updated_at`, indexes.  |
| `step-3-add-v3`      | Normalize `counterparties` into their own table.         |

---

## What V1 gives you

```sql
CREATE TABLE trades (
    id           BIGSERIAL PRIMARY KEY,
    symbol       VARCHAR(16)    NOT NULL,
    side         VARCHAR(4)     NOT NULL,   -- BUY or SELL
    quantity     NUMERIC(20, 4) NOT NULL,
    price        NUMERIC(20, 4) NOT NULL,
    executed_at  TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    CONSTRAINT chk_trades_side           CHECK (side IN ('BUY','SELL')),
    CONSTRAINT chk_trades_quantity_positive CHECK (quantity > 0),
    CONSTRAINT chk_trades_price_positive    CHECK (price > 0)
);
```

Plus three seed rows: an AAPL BUY, an MSFT BUY, an AAPL SELL.

The FastAPI app on this branch mirrors that schema exactly — no extra
fields in the API contract.

---

## How to build

> **Coming from another stage?** Run `docker compose down -v` first to
> wipe the Postgres volume. Flyway records applied versions in
> `flyway_schema_history`; if you start step-1 with a database that
> already has V2/V3 rows, Flyway rejects the mismatch. A clean volume
> means a clean run.

```bash
cd ~/Documents/analysis/stories/database-migration/example
cp .env.example .env         # one-time setup
docker compose build         # build the API image
```

## How to start

```bash
docker compose up            # foreground; Ctrl+C to stop
# or
docker compose up -d         # detached
docker compose logs -f api   # follow API logs
```

On success you will see, in order:

- `trading-postgres  ... database system is ready to accept connections`
- `trading-flyway    ... Successfully applied 1 migration to schema "public"`
- `trading-flyway exited with code 0`
- `trading-api       ... Uvicorn running on http://0.0.0.0:8000`

If Flyway fails, `api` never starts. That is by design.

## How to test

```bash
bash scripts/test_endpoints.sh
```

Or exercise endpoints manually:

```bash
# Health
curl -s http://localhost:8000/health | jq .

# List seed rows
curl -s http://localhost:8000/trades | jq .

# Create a BUY
curl -s -X POST http://localhost:8000/trades \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"NVDA","side":"BUY","quantity":10,"price":950.50}' | jq .

# Filter
curl -s 'http://localhost:8000/trades?symbol=AAPL' | jq .
curl -s 'http://localhost:8000/trades?side=BUY'    | jq .

# Get one
curl -s http://localhost:8000/trades/1 | jq .

# Update
curl -s -X PUT http://localhost:8000/trades/1 \
  -H 'Content-Type: application/json' \
  -d '{"price":195.00}' | jq .

# Delete
curl -s -X DELETE -o /dev/null -w '%{http_code}\n' http://localhost:8000/trades/1
```

Interactive OpenAPI docs live at
[http://localhost:8000/docs](http://localhost:8000/docs).

## How to inspect Flyway state

```bash
docker compose exec postgres psql -U trading_user -d trading \
  -c 'SELECT installed_rank, version, description, success
      FROM flyway_schema_history;'
```

Expected after boot:

```text
 installed_rank | version | description            | success
----------------+---------+------------------------+---------
              1 | 1       | initial trading schema | t
```

## How to move to step 2

```bash
docker compose down -v       # wipe Postgres volume
git checkout step-2-add-v2
docker compose up --build
```

See what step 2 changes before you jump:

```bash
git diff step-1-v1-only step-2-add-v2 -- db/ app/
```

## Troubleshooting

**Flyway container exits with `Migration checksum mismatch`**
Someone edited `V1__initial_trading_schema.sql` after it had already been
applied. Revert the edit, or run `docker compose run --rm flyway repair`.
See [`docs/migration-strategy.md`](docs/migration-strategy.md).

**Port already in use**
Another process holds `5432` or `8000`. Stop it or remap the port in
`docker-compose.yml`.

**API restart loop with `database "trading" does not exist`**
Postgres finished initializing after Flyway timed out. Bring down with
`docker compose down -v` and back up.
