# CLAUDE.md — Trading Service Migration Example

Project-scoped guidance for Claude Code sessions working in this directory.
Read this first before making changes.

## What this project is

A teaching artifact for platform engineers: a Python **FastAPI** CRUD service
for trades, backed by **PostgreSQL 16**, with schema managed by **Flyway**.
Everything runs in Docker Compose. It is **not** a production system.

Primary consumer: Bayview Asset Management Platform Engineering.

## Tech stack

- Python 3.12 (slim base image), FastAPI, SQLAlchemy 2.x, Pydantic v2
- PostgreSQL 16 (alpine)
- Flyway 10 (alpine) — one-shot migrator, exits `0` on success
- Docker Compose (Compose v2 syntax)

## Repository layout

```text
example/
├── CLAUDE.md              # this file
├── README.md              # user-facing entry point + curl examples
├── docker-compose.yml     # postgres + flyway + api services
├── .env.example           # copy to .env before boot
├── app/                   # FastAPI service (Dockerfile, requirements, source)
├── db/migrations/         # Flyway SQL, versioned V{N}__{description}.sql
├── scripts/               # helper scripts (test_endpoints.sh, etc.)
└── docs/                  # product-brief, user-stories, migration-strategy
```

## Common commands

```bash
# First-time setup
cp .env.example .env

# Bring the whole stack up (build the API image, run migrations, serve)
docker compose up --build

# Re-run migrations only (after adding a new V file)
docker compose up flyway

# Tail logs
docker compose logs -f api
docker compose logs flyway

# Inspect the migration ledger
docker compose exec postgres \
  psql -U trading_user -d trading -c \
  'SELECT installed_rank, version, description, success FROM flyway_schema_history;'

# psql into the DB
docker compose exec postgres psql -U trading_user -d trading

# Run the endpoint smoke tests
bash scripts/test_endpoints.sh

# Tear down and wipe volume
docker compose down -v
```

Ports: `5432` (Postgres), `8000` (API). Change in `docker-compose.yml` if
either is occupied.

## Migration conventions

- **Naming:** `V{N}__{snake_case_description}.sql` (double underscore).
  Never reuse a version number.
- **Forward-only:** never edit a `V` file after it has been applied.
  Flyway will detect checksum drift and refuse to run. Fix mistakes with a
  new higher-numbered migration, not by editing history.
- **Transactionality:** each file runs inside a Postgres transaction.
  If any statement fails, the whole file rolls back.
- **Backfill in-place:** when adding NOT NULL columns to a populated table,
  first add nullable, backfill, then add the constraint — all in the same
  file (see `V2__enhance_trading_table.sql`).
- **Expand-contract for renames/removals:** never drop a column that live
  code still reads. Split into two migrations: expand (add new, backfill,
  keep old), deploy code, then contract (drop old). See
  `V3__extract_counterparty_table.sql` for the expand half.
- **Header comment:** every migration begins with `-- VN:` and a short
  paragraph explaining what and why.

## Adding a new migration

1. Pick the next version number by looking at `db/migrations/`.
2. Create `db/migrations/V{N}__{description}.sql` with a header comment.
3. Run `docker compose up flyway` to apply it.
4. If the migration adds or renames columns, update `app/models.py`,
   `app/schemas.py`, and `app/crud.py` accordingly.
5. Verify with `docker compose exec postgres psql -U trading_user -d trading -c '\d trades'`
   and re-run the endpoint tests.

## Code standards

### Python

- PEP 8, `from __future__ import annotations` at the top of every module.
- Type hints on every function signature. `Optional[T]` for nullable.
- Use the `logging` module. Never `print()`.
- Route handlers live in `main.py` and stay small — push SQL and business
  logic into `crud.py`.
- Pydantic v2 models with `ConfigDict(from_attributes=True)` for ORM
  serialization.
- Pin all dependencies in `requirements.txt`. No `>=` ranges.

### SQL

- Uppercase keywords (`CREATE TABLE`, `INSERT INTO`).
- `snake_case` for tables, columns, indexes, constraints.
- Index naming: `ix_{table}_{column}`.
- Constraint naming: `chk_{table}_{purpose}`, `fk_{table}_{ref}`.
- Use `IF NOT EXISTS` / `IF EXISTS` for idempotency where it doesn't hide
  intent.

### YAML (docker-compose, CI)

- 2-space indent, no tabs.
- Quote strings that could be misinterpreted (`"yes"`, `"5432"`, versions).
- No hardcoded credentials — everything via `${VAR}` from `.env`.

### Bash (scripts/)

- `set -euo pipefail` at the top.
- Quote every variable: `"${var}"`.
- Functions for reusable steps; `main()` at the bottom.
- Separate stdout (data) from stderr (logs).

## Security guardrails

- Never commit `.env`. `.env.example` holds safe local-only defaults.
- Never hardcode credentials in code, YAML, or SQL. Use env vars.
- The API image runs as a non-root user (see `app/Dockerfile`).
- Postgres port `5432` is exposed for local exploration only. In any
  production adaptation, close it and use the internal network.

## Testing

- `scripts/test_endpoints.sh` — smoke tests against a running stack.
  Exits non-zero on any failure. Idempotent (creates a fresh trade per run
  and deletes it at the end).
- No unit test suite ships with this example. If adding one, use `pytest`
  under `app/tests/`, and mock the database with `sqlalchemy` in-memory or
  a test-scoped session.

## Commit and PR conventions

Follow the user's global rules in `~/.claude/rules/git-conventions.md`:

- Branch name: `PE-{number}`
- Commit format: `PE-{number}: {description}`
- PR title: `PE-{number}: {short description}` (under 70 chars)
- **Never** include AI attribution, `Co-Authored-By: Claude`, or
  "Generated with Claude Code" in commits, PR bodies, or code comments.

## What NOT to do here

- Do not add ORM-managed schema creation (`Base.metadata.create_all`).
  Flyway is the single source of truth for schema.
- Do not edit `V1` or `V2` after they've been applied to any environment.
- Do not add framework switching (SQLModel, Tortoise, etc.). This example
  intentionally uses vanilla SQLAlchemy for clarity.
- Do not add authentication, rate limiting, or observability wiring. Scope
  is intentionally narrow — see `docs/product-brief.md` non-goals.
