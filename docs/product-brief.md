# Product Brief: Flyway-Managed Trading Service (Teaching Example)

## Problem
Platform engineers at Bayview support multiple business lines (retail lending,
loan servicing, MSR analytics, MBS analytics) that each own PostgreSQL
databases. Schema changes today are inconsistent: some teams run ad-hoc SQL
in production, others hand-write change tickets, and there is no unified
story for how migrations are versioned, applied, or rolled back. New
engineers joining the platform team need a hands-on artifact that shows the
end-to-end pattern in under fifteen minutes.

## Users
- **Primary:** Principal and staff platform engineers evaluating Flyway as a
  standard for schema migration across the firm.
- **Secondary:** Application engineers who want to see how a service should
  cooperate with a migrator (dependency ordering, environment configuration,
  schema evolution).
- **Tertiary:** New hires onboarding to the platform team.

## Goals
1. Demonstrate a fully working `docker compose up` stack that provisions
   PostgreSQL, runs Flyway migrations, and starts a FastAPI CRUD service.
2. Teach the mechanics of Flyway versioned migrations (`V1__`, `V2__`), the
   `flyway_schema_history` table, and safe schema evolution.
3. Show three realistic schema evolutions, one per git branch, on a domain
   the audience understands (trading):
   - **V1** — the initial `trades` table (baseline).
   - **V2** — enhance a populated table (add columns + indexes + backfill).
   - **V3** — extract a normalized `counterparties` table using the
     expand-contract pattern for zero-downtime deploys.
4. Provide clear, copy-pasteable curl commands for every CRUD endpoint.
5. Show, per branch, how application code (FastAPI models, schemas, CRUD)
   evolves alongside the schema.

## Non-Goals
- Production hardening (HA Postgres, backups, connection pooling at scale).
- Authentication or authorization on the API.
- Real market data or integration with any brokerage.
- Complex trade lifecycle modelling (allocations, corrections, breaks).

## Success Criteria
- A first-time reader can clone the folder, run `docker compose up --build`,
  and hit `GET /trades` successfully in under 10 minutes.
- The reader can add a new migration file (`V3__...sql`) and observe Flyway
  applying it on the next `docker compose up`.
- The reader can articulate how `flyway_schema_history` prevents duplicate
  application of migrations and detects checksum drift.
- The reader understands the difference between Flyway Community rollback
  behavior (forward-only + repair) and Flyway Teams undo migrations.

## Out-of-Scope
- Kubernetes deployment manifests (a follow-up artifact will translate this
  to a Helm chart with an ArgoCD `PreSync` migration job).
- Multi-tenant schema management.
- Migration performance tuning for tables above 100 million rows.

## Risks and Mitigations
| Risk | Mitigation |
| --- | --- |
| Reader edits V1 after V2 has run | README calls out checksum drift explicitly and points at `flyway repair`. |
| Postgres port conflict on 5432 | `.env.example` documents how to remap; compose exposes the port only for host convenience. |
| Reader assumes this is production-ready | Repeatedly labeled "teaching example" and lists non-goals. |
