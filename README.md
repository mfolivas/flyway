# Step 4 — V4: forward-only rollback of V3

You are on branch **`step-4-rollback-v3`**. This stage teaches how to
reverse an applied migration in Flyway Community: you ship a **new
higher-numbered migration** that inverses the effect. There is no
`flyway rollback` command in the Community edition — this pattern is
the sanctioned answer.

**What this teaches:**
1. **Forward-only rollback.** V3 shipped counterparty normalization. We
   decided that was the wrong call. V4 drops the FK column, drops the
   `counterparties` table, and keeps the pre-V3 string column intact.
2. **Never edit or delete an applied V file.** Flyway's checksum
   enforcement would refuse to run against any environment where V3
   already succeeded. The only safe move is a new V file.
3. **Coordinated schema + code rollback.** The migration is one half of
   the story — the app code that referenced `counterparty_id` and
   `/counterparties` also has to be walked back to the pre-V3 shape.
4. **When `flyway repair` is the right tool** (a *different* scenario)
   and why `U__` undo migrations are not part of Flyway Community.

Compare against the previous stage:

```bash
git diff step-3-add-v3 step-4-rollback-v3 -- db/ app/
```

---

## What V4 changes

```sql
DROP INDEX IF EXISTS ix_trades_counterparty_id;

ALTER TABLE trades
    DROP COLUMN IF EXISTS counterparty_id;

DROP TABLE IF EXISTS counterparties;
```

Three statements, executed in reverse dependency order:
1. Drop the index first (has to go before the column it covers).
2. Drop the FK column (has to go before the table it references).
3. Drop the `counterparties` table.

`trades.counterparty` — the original V2 string column — stays untouched.
That is why V3 was pedagogically designed as the **expand** half of
expand-contract: the old column was preserved, so V4 can walk V3 back
without losing any data that was only in the FK.

Application code changes on this branch:

- `models.py` — no `Counterparty` model, no `counterparty_id` FK.
- `schemas.py` — no `CounterpartyRead`, no `counterparty_id` on
  `TradeRead`.
- `crud.py` — no `get_or_create_counterparty`, no dual-writes.
  `create_trade` writes only the string column, like it did in V2.
- `main.py` — no `GET /counterparties` endpoint. `version = "4.0.0"`.

## Why not just delete `V3__extract_counterparty_table.sql`?

Two reasons, both hard blockers:

1. **Checksum enforcement.** On any environment where V3 already ran,
   Flyway records its checksum in `flyway_schema_history`. On the next
   startup Flyway recomputes the checksum from disk and compares — if
   the file is gone, or its content differs, Flyway refuses to run. You
   cannot silently rewrite history.
2. **Fresh environments must traverse the same history.** A new dev laptop
   needs to reach the same schema as prod. If you deleted V3, fresh envs
   would skip it, but prod already has it. History would fork. Flyway is
   built to prevent exactly that.

The one-word summary: **the schema history is a ledger, not a scratchpad**.

## The three related things people confuse

### 1. Forward-only rollback (this migration, V4)

Used when an applied migration was **successful** but you don't want
its effect anymore. Ship an inverse migration. Same pipeline, same
review process, same gates as any other change.

### 2. `flyway repair`

Used when an applied migration **failed** mid-run and left a
`success = false` row in `flyway_schema_history`, or when someone
edited an already-applied V file and you want Flyway to accept the new
checksum (rare, only after a review). `repair` clears failed rows and
recomputes checksums. It does NOT reverse a successful migration.
Different tool, different problem.

### 3. Flyway Teams `U__` undo migrations

Flyway Teams (paid) supports `U{N}__.sql` files that mirror
`V{N}__.sql`. `flyway undo` runs the U file, reverses the effect, and
removes the row from `flyway_schema_history`. We do NOT use this in
Community. If we ever did, ADR-001 would need an update — right now the
platform standard is Community + forward-only + expand-contract.

## Real-world rollback priorities

When a schema change goes wrong in production, ops teams reach for
these in order:

1. **Fix-forward** with a new migration (safest, audit trail intact).
   This is the pattern V4 demonstrates.
2. **Point-in-time recovery** from Postgres WAL backups (used when data
   was corrupted, not just schema). Loses writes after the recovery
   point.
3. **Restore from snapshot** (last resort — loses everything after the
   snapshot).

The whole point of Flyway + expand-contract is to keep fix-forward
viable so you almost never need levels 2 or 3.

---

## How to build

> **Coming from another stage?** Run `docker compose down -v` first to
> wipe the Postgres volume. If the volume was populated by an earlier
> step, the `flyway_schema_history` rows may not match this branch's
> migration files exactly — a clean volume avoids any drift confusion.

```bash
cd flyway            # wherever you cloned this repo
cp .env.example .env # if you haven't already
docker compose build # rebuild the API image for V4 code
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
Successfully applied 4 migrations to schema "public"
```

Fresh environments apply V1 → V2 → V3 → V4 in order. V3 briefly
materialises the `counterparties` table; V4 immediately drops it. That
is the correct behavior — the ledger records what actually happened, in
order, on every environment.

## How to test

```bash
bash scripts/test_endpoints.sh
```

The V4 test script verifies:

- `GET /counterparties` returns **404** (endpoint gone).
- Trade responses no longer include a `counterparty_id` field.
- Posting a trade with `counterparty="JPM"` still writes the string
  column and echoes it back.
- V1 seed rows are still `SETTLED` (V2 backfill preserved through the
  V4 rollback — as it should be, since V4 didn't touch V2's columns).

## How to inspect Flyway state

```bash
docker compose exec postgres psql -U trading_user -d trading \
  -c 'SELECT installed_rank, version, description, success
      FROM flyway_schema_history;'
```

Expected:

```text
 installed_rank | version | description                        | success
----------------+---------+------------------------------------+---------
              1 | 1       | initial trading schema             | t
              2 | 2       | enhance trading table              | t
              3 | 3       | extract counterparty table         | t
              4 | 4       | revert v3 counterparty extraction  | t
```

Confirm the counterparties table is gone:

```bash
docker compose exec postgres psql -U trading_user -d trading \
  -c "SELECT to_regclass('public.counterparties');"
# Expected: NULL
```

And that `trades.counterparty_id` is gone:

```bash
docker compose exec postgres psql -U trading_user -d trading -c '\d trades'
# Expected: no counterparty_id column
```

## Exercise — check what a fresh dev laptop sees

Simulating a brand-new environment:

```bash
docker compose down -v
docker compose up -d
docker compose logs flyway | grep 'Migrating\|Successfully'
```

You should see all four migrations apply, in order, ending with:

```text
Successfully applied 4 migrations to schema "public", now at version v4
```

The V3 changes appear briefly during migration and are gone by the time
Flyway exits. The final state matches what production sees.

## Where to go from here

You have completed the workshop.

- Review the full arc:
  `git diff main step-4-rollback-v3 -- db/ app/`
- Read [`docs/migration-strategy.md`](docs/migration-strategy.md) for
  the full write-up on Flyway state, checksum drift, failure handling,
  and the expand-contract pattern.
- Read [`docs/decisions/ADR-001-adopt-flyway.md`](docs/decisions/ADR-001-adopt-flyway.md)
  for the rationale behind choosing Flyway over Liquibase, Alembic,
  and Sqitch.
- Try adding a `V5__…sql` yourself. Some options:
  - Add a real feature (e.g. an `executions` table for partial fills).
  - Re-introduce counterparties, this time with a plan for the contract
    half.
  - Add a `R__refresh_reporting_views.sql` repeatable migration and
    observe how it re-runs whenever the file changes.

## Troubleshooting

**`Migration checksum mismatch`**
Someone edited `V1`, `V2`, `V3`, or `V4` after it was applied. Revert
the edit or run `docker compose run --rm flyway repair` if the edit was
intentional.

**`relation "counterparties" does not exist` in application logs**
The app code was reverted to the V2 shape and does not reference
`counterparties` any more. If you see this error you are running older
V3 code against the V4 schema — rebuild the API image with
`docker compose build --no-cache api`.

**`Successfully applied 0 migrations`**
Your Postgres volume still has the V1–V3 state from step-3 without V4.
Run `docker compose down -v` and re-`docker compose up`.
