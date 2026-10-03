# ADR: Platform-owned promotion topology

## Status

Accepted for v6.0.0 candidate (tag not created yet).

## Decision

- Consumer selects `platformArea` (or `none` for CI-only).
- Platform area owns environment topology via `platform.promotion`.
- Azure DevOps Variable Groups are removed from the deployment path.
- Runtime ECR pull is infrastructure-owned (node/kubelet + shared repository policy); the pipeline does not create `imagePullSecrets`.
- ScheduledJob post-deploy smoke is platform policy: `tiers.<tier>.scheduledJobSmoke.enabled` (default `false`). Not consumer-owned; not implied by former `smokeAllowed`.

## Consequences

- Breaking public API vs v5.3.2 (`deployEnvironments` removed — no silent ignore).
- Application desired state remains per-tier in `deploy/config/<tier>.yaml`.
- Charts / Helm recovery / target identity / capability preflight unchanged.
- Migrating to v6 does **not** auto-execute CronJobs after deploy unless a tier explicitly sets `scheduledJobSmoke.enabled: true`.
