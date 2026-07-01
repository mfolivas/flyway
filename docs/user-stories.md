# User Stories

Each story follows the "As a ... I want ... so that ..." format with an
explicit set of acceptance criteria the reader can verify locally.

---

## US-1: Initial schema startup (step-1-v1-only)
**As a** platform engineer new to Flyway
**I want** a single command that brings up Postgres and applies the initial
schema
**So that** I can see a versioned migration workflow end-to-end without
manual steps.

### Acceptance Criteria
- On branch `step-1-v1-only`, running `docker compose up --build` starts
  `postgres`, then `flyway`, then `api` in that order.
- Flyway logs show `Successfully applied 1 migration to schema "public"`
  on the first run (only V1 exists on this branch).
- The `flyway_schema_history` table exists in the `trading` database and
  contains one row per applied migration.
- `GET /health` returns `{"status": "ok", "database": "reachable"}`.

---

## US-2: Record a buy transaction
**As an** application engineer prototyping against the trading service
**I want** to record a BUY transaction via HTTP
**So that** I can verify the CRUD path from FastAPI to Postgres.

### Acceptance Criteria
- `POST /trades` with a valid BUY payload returns HTTP 201 and a JSON body
  containing an `id`, `executed_at`, and default `status="PENDING"`.
- The `side` field is validated: any value other than `BUY` or `SELL` returns
  HTTP 422.
- Negative or zero `quantity` and `price` return HTTP 422.
- The row is visible in Postgres via
  `SELECT * FROM trades WHERE id = <returned id>;`.

---

## US-3: Record a sell transaction
**As an** application engineer
**I want** to record a SELL transaction and optionally provide a
counterparty
**So that** I can capture the full context of the trade.

### Acceptance Criteria
- `POST /trades` with `side="SELL"` and `counterparty="Goldman"` returns
  HTTP 201.
- The `counterparty` value is persisted and echoed back in the response.
- Omitting `counterparty` still succeeds (nullable).

---

## US-4: List and read transactions
**As a** platform engineer
**I want** to list all trades and fetch individual trades by id
**So that** I can validate reads and query filters.

### Acceptance Criteria
- `GET /trades` returns an array of trades ordered by most recent
  `executed_at` first, including the three V1 seed rows.
- `GET /trades?symbol=AAPL` returns only trades for AAPL.
- `GET /trades?side=BUY` returns only BUY trades.
- `GET /trades?status=SETTLED` returns only trades whose status is SETTLED
  (requires V2 to be applied).
- `GET /trades/{id}` returns HTTP 200 with a single trade for a valid id and
  HTTP 404 for an unknown id.

---

## US-5: Enhance the schema via a V2 migration
**As a** platform engineer teaching the pattern
**I want** to add columns, indexes, and constraints in a new migration file
**So that** the reader can see how Flyway evolves a schema safely.

### Acceptance Criteria
- V2 adds `status`, `fees`, `counterparty`, `updated_at` columns.
- V2 backfills existing V1 rows so `status='SETTLED'` and
  `updated_at=executed_at`.
- V2 adds indexes `ix_trades_symbol` and `ix_trades_status` (verifiable with
  `\d trades` in psql).
- V2 adds a check constraint restricting `status` to
  `PENDING`, `SETTLED`, or `CANCELLED`.
- `PUT /trades/{id}` with `{"status": "SETTLED"}` succeeds and the response
  reflects the updated status and a fresh `updated_at`.

---

## US-6: Normalize counterparties via a V3 migration (expand-contract)
**As a** platform engineer
**I want** to extract counterparties into their own table without breaking
existing deployments
**So that** I can teach the expand-contract pattern that underpins every
safe schema change at Bayview.

### Acceptance Criteria
- V3 creates a `counterparties` table with `id`, `name` (unique), and
  `created_at`.
- V3 adds a nullable `counterparty_id` foreign key to `trades`.
- V3 backfills `counterparties` from `DISTINCT trades.counterparty` and
  sets `trades.counterparty_id` accordingly.
- The old `trades.counterparty` text column is intentionally preserved
  (expand phase); a future V4 would drop it.
- `GET /counterparties` returns the list of counterparties.
- `POST /trades` with a new `counterparty` value creates a
  `counterparties` row on the fly and links the trade to it.

---

## US-7: Rollback awareness
**As a** platform engineer preparing to adopt Flyway
**I want** to understand how rollbacks work in the Community edition
**So that** I can plan safe change management.

### Acceptance Criteria
- The reader can locate and read `docs/migration-strategy.md`.
- The documentation states that Flyway Community is forward-only: rolling
  back means writing a new `Vn__revert_...sql` migration.
- The documentation explains when `flyway repair` is appropriate (failed
  migration in history, checksum drift after an accidental V-file edit).
- The documentation mentions Flyway Teams' `U__` undo migrations as the paid
  alternative and notes we do not rely on them.
- The reader can delete the `postgres_data` volume
  (`docker compose down -v`) and re-run `docker compose up` to observe both
  migrations running again from scratch.
