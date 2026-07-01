# Migration Strategy

This document explains how Flyway manages schema state for the trading
service and how to evolve the schema safely.

## Versioning and naming

Flyway looks in `db/migrations` for files that match one of three patterns:

| Prefix | Purpose | Example |
| --- | --- | --- |
| `V` | Versioned migration, applied once, in order. | `V3__add_execution_venue.sql` |
| `R` | Repeatable migration, re-applied whenever the file changes. Runs after all pending `V` migrations. | `R__refresh_reporting_views.sql` |
| `U` | Undo migration (Flyway Teams only). Not used in this example. | `U2__enhance_trading_table.sql` |

Naming rules:

- Two underscores separate the version from the description:
  `V2__enhance_trading_table.sql`.
- Version numbers must be strictly increasing across `V` migrations.
- Descriptions use `snake_case` and describe intent, not mechanism (prefer
  `enhance_trading_table`, not `alter_table_add_columns`).
- Do not reuse a version number, even after a failed migration.

## How Flyway tracks state

On the first run against an empty database Flyway creates the
`flyway_schema_history` table. Each successful migration inserts one row:

```text
installed_rank | version | description                | type | script                            | checksum
1              | 1       | initial trading schema     | SQL  | V1__initial_trading_schema.sql    | -472398471
2              | 2       | enhance trading table      | SQL  | V2__enhance_trading_table.sql     |  198374621
```

On every subsequent run Flyway:

1. Reads `flyway_schema_history`.
2. Lists files in the configured `locations` (here `filesystem:/flyway/sql`).
3. Skips any migration whose version already appears with `success = true`.
4. Recomputes the checksum for every already-applied file and compares it
   with the stored value. A mismatch stops the world: this is checksum
   drift and it means someone edited a file that has already run somewhere.
5. Applies pending migrations in strict version order inside a transaction
   per file (Postgres supports transactional DDL).

## Adding a new migration

1. Create a new file `db/migrations/V<next>__short_description.sql`.
2. Write forward-only SQL. Prefer `IF NOT EXISTS` / `IF EXISTS` guards so a
   partially-applied migration can be retried after a fix.
3. If the change is destructive (drop column, drop table, tightening a
   constraint), split it across two releases: one to stop using the column
   at the application layer, one to drop it after a burn-in period.
4. Run `docker compose up --build`. Flyway will detect the new version and
   apply only it.
5. Verify with:

   ```bash
   docker compose exec postgres \
     psql -U trading_user -d trading -c 'SELECT * FROM flyway_schema_history;'
   ```

## Handling failures

### A migration fails mid-run

Because Postgres wraps DDL in a transaction, a failure in
`V3__...sql` rolls the file back to the pre-migration state. Flyway inserts
a row with `success = false` in `flyway_schema_history`. To recover:

1. Fix the SQL.
2. Run `docker compose run --rm flyway repair`. This removes the failed row
   from `flyway_schema_history` and recomputes checksums.
3. Re-run `docker compose up flyway`.

### Checksum drift

If someone edited an already-applied `V` file, Flyway will refuse to run.
Options:

1. Revert the edit so the checksum matches history. This is almost always
   the right answer.
2. If the edit is safe and the drift is expected (for example, a
   whitespace-only cleanup), run `flyway repair` to update the stored
   checksum.

Never resolve drift by editing `flyway_schema_history` directly.

## Expand-contract for destructive changes

Whenever a migration would break code that is still deployed — dropping a
column, renaming, tightening a nullable column to NOT NULL — split it into
two migrations across two releases:

1. **Expand.** Add the new structure alongside the old one. Backfill.
   Application code writes to both old and new; reads prefer the new. The
   old structure stays in place so the previous application version keeps
   working.
2. **Contract.** Once every running deployment is on the code that reads
   from the new structure, ship a migration that drops the old.

`step-3-add-v3` in this workshop demonstrates only the expand half:
`V3__extract_counterparty_table.sql` creates the `counterparties` table and
adds `trades.counterparty_id`, but intentionally keeps the old
`trades.counterparty` string column. A real production sequence would
follow with a `V4__drop_trades_counterparty_column.sql` after all
consumers have migrated.

## Rollback story

Flyway Community, which we use here, is **forward-only**. There is no
`flyway rollback` command. To revert a change:

1. Write a new migration that reverses the effect: for example, a
   `V4__revert_enhance_trading_table.sql` that drops the columns V2 added.
2. Apply it through the same pipeline as any other change.

Flyway Teams introduces `U__` undo migrations that are the mirror image of
their `V__` counterparts. We do not depend on that feature in this example.

Operationally, real rollbacks in production come from three places, in
order of preference:

1. **Fix-forward** with a new migration (safest, auditable).
2. **Point-in-time recovery** from Postgres WAL backups (used when data is
   corrupted, not just schema).
3. **Restore from snapshot** (last resort; loses recent writes).

## Environment separation

In the real world we run Flyway against each environment with its own
credentials and location list:

```text
flyway -url=$DEV_URL  -locations=filesystem:./db/migrations migrate
flyway -url=$UAT_URL  -locations=filesystem:./db/migrations migrate
flyway -url=$PROD_URL -locations=filesystem:./db/migrations migrate
```

Promotion between environments is a matter of running the same command with
different credentials; the migration files themselves are identical, which
is the whole point.
