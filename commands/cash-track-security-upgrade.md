---
description: Find and fix dependency security vulnerabilities in one Cash-Track repo, then raise a remediation PR
argument-hint: <repo>
---

Run the security upgrade workflow for the Cash-Track repository `$1`.

Valid values for `$1`: `api`, `frontend`, `website`, `infra`, `gateway`, `mysql`, `redis`,
`mysql-backup`, `.github`.

If `$1` is empty, ask which repository before doing anything else.

Invoke the `cash-track-security-upgrade` skill and follow it exactly, using `$1` as the target
repository.
