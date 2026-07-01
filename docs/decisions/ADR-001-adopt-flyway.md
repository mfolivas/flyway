# ADR-001: Adopt Flyway as the standard database migration tool

- **Status:** Proposed
- **Date:** 2026-06-30
- **Deciders:** Platform Engineering — Bayview Asset Management
- **Consulted:** Application engineering leads across retail lending, loan
  servicing, MSR, MBS analytics
- **Related artifacts:**
  [`docs/migration-strategy.md`](../migration-strategy.md),
  [`docs/product-brief.md`](../product-brief.md)

## Context

Platform Engineering supports PostgreSQL databases across four business
lines. Today, schema changes are inconsistent across teams:

- Some teams run ad-hoc `psql` in production.
- Some teams write change tickets that a DBA applies by hand.
- Some teams script their own versioning table.

There is no shared story for how migrations are versioned, applied,
inspected, or rolled back. The next hire onboarded to the platform team
needs a hands-on artifact showing the standard we want to adopt firm-wide.

## Decision

We standardize on **Flyway Community** (currently version 10) for schema
migrations across all Platform-Engineering-supported PostgreSQL
databases.

- All schema changes are expressed as versioned SQL files:
  `V{N}__{description}.sql`.
- All migrations are forward-only. To revert a change, we ship a new
  higher-numbered migration that inverses it.
- Flyway runs as a discrete step in the delivery pipeline (Kubernetes
  Job, ArgoCD `PreSync`, or CI/CD stage), never bundled into the runtime
  application container.
- Destructive changes follow the expand-contract pattern (two releases:
  add the new structure with backfill, then drop the old after all
  consumers migrate).

## Alternatives considered

### Liquibase
XML/YAML/JSON changelogs, richer feature set (including built-in rollback
in the community edition). Rejected because:
- Extra domain language (changelogs) that engineers must learn on top of
  SQL.
- The rollback story only works when authors write it, which shifts the
  same discipline back onto humans anyway.
- Verbose changelog files are harder to review than plain SQL.

### Alembic
Python-native, tightly coupled to SQLAlchemy. Rejected because:
- We have Java, .NET, and Go services alongside Python — a
  Python-specific tool would create tooling drift.
- Alembic autogeneration masks the actual DDL, which is exactly what we
  want engineers reading in review.

### Sqitch
Plain-SQL migrations with dependency graphs instead of versions.
Rejected because:
- Team unfamiliarity — much smaller community than Flyway.
- The dependency-graph model is powerful but our schemas are simple
  linear evolutions.

### Hand-written scripts + a `schema_version` table
Cheapest to start, hardest to sustain. Rejected because it reproduces
Flyway with none of the tooling (`info`, `validate`, `repair`).

## Consequences

### Positive
- Single tool across teams; hires learn Flyway once.
- Native support for our exit criteria (`service_completed_successfully`
  in compose, exit-code semantics in Kubernetes Jobs).
- Checksum enforcement blocks the "someone edited a migration after it
  ran" failure mode.
- Plain-SQL migrations are the same language DBAs already speak.

### Negative / trade-offs
- No built-in rollback in the Community edition. Mitigated by requiring
  the expand-contract pattern for destructive changes and point-in-time
  recovery for data-loss incidents.
- No undo migrations (`U__`) without Flyway Teams. If a team hits enough
  friction to justify the license, we revisit.
- New dependency in every pipeline — pinned to a specific major version
  (`flyway/flyway:10-alpine` in this workshop).

### Follow-up work
- Publish a Helm chart that wraps Flyway as a Kubernetes Job with the
  standard ArgoCD `PreSync` annotation. Tracked separately.
- Provide a Bitbucket / GitHub Actions template for CI-driven migrations.
- Add a `flyway validate` step to every application PR pipeline so a bad
  migration is caught before merge.
