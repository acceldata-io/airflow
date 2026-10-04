# odp-airflow-ranger-auth-manager

## Read this first

```bash
D=~/work_files/ranger-airflow-plugin/docs/INDEX.md
grep -A8 "^## RangerAuthzClient.filter_keys" $D
grep -A6 "^## RangerAuthManager.is_authorized_dag" $D
grep -A5 "^GAP-02" $D
```

Narrative walkthrough:
`~/work_files/ranger-airflow-plugin/docs/02-python-auth-manager.md`

## Two overrides of the repo-root CLAUDE.md

The Airflow repo root `CLAUDE.md` is **upstream Airflow's** and mostly applies.
Two rules do not, for this directory only:

**1. Tests run in a plain venv, not breeze.** The root says *"never run pytest
directly on the host"*. That rule exists for Airflow's own suite, which needs a
database and containers. This package stubs Airflow via `sys.modules` injection
in `tests/test_ranger_auth_manager.py` and needs neither:

```bash
/tmp/rangervenv/bin/python -m pytest tests/ -q     # ~15s, 46 tests
```

If that venv is gone: `python3 -m venv /tmp/rangervenv && /tmp/rangervenv/bin/pip
install pytest urllib3 packaging ruff`.

**2. `uv run ruff` does not work here** — uv resolves the workspace and then
cannot find ruff. Use `/tmp/rangervenv/bin/ruff` instead. The root's *rule*
still applies: format and check every Python file immediately after editing it.

```bash
/tmp/rangervenv/bin/ruff format <file>
/tmp/rangervenv/bin/ruff check --output-format=concise <file>
```

This package has no `[tool.ruff]` config, so bare ruff applies a stricter
default than the repo enforces. Fix findings in **lines you touched**; several
pre-existing ones (`D101` missing docstrings, `TC001`, `D213`) are not yours.

Everything else from the root applies, notably: write **Dag** in title case in
prose, and never add `Co-Authored-By` naming an agent.

## What this module is

The **policy enforcement point**. `RangerAuthManager(FabAuthManager)` —
authentication fully inherited from FAB, authorization routed to the colocated
JVM agent over `127.0.0.1:9183`.

It decides nothing itself. It asks, and turns the answer into a boolean that
Airflow's route dependencies convert to a 403.

## The cardinal rule

**This client speaks Airflow's vocabulary and must never learn Ranger's.** It
sends `resource_type: "dag"`, `method: "POST"`, `access_entity: "RUN"`. It does
not know these become the Ranger access type `trigger`.

That mapping lives only in the agent's `AccessMapper` (`DEC-03`), so changing
the taxonomy is a jar rebuild tracking Ranger's release rather than a wheel
rebuild per Airflow minor × Python version. If you find yourself importing a
Ranger access-type name into this package, something has gone wrong.

## Fail-closed is the invariant

Every path returns deny. No exceptions, and **no retries** — a retry storm
against a struggling agent turns a slow page into an outage.

| Situation | Result |
|---|---|
| client not initialised | `False` |
| transport error, timeout, connection refused | `False` |
| any non-200 (401/422/500/503) | `False` |
| malformed body, length mismatch, id mismatch | `False` |
| filter: any chunk fails | `frozenset()` — the whole call |
| filter: response not a subset of the request | `frozenset()` |

When adding a method, the fail-closed paths are the part to hand-review.

## Settled — do not re-propose

- **DEC-01** Subclass `FabAuthManager`, not `BaseAuthManager` or
  `KeycloakAuthManager` (the latter is alpha, "subject to change without
  warning"). LDAP and Kerberos-via-SPNEGO come free.
- **DEC-07** `_parse_decisions` zips by index **and** asserts the echoed id. An
  earlier dict-keyed version collapsed duplicate ids and could silently
  **grant**. Do not reintroduce id-keyed lookup.
- **DEC-12** Send the principal, never groups. A Kerberos ticket carries no
  groups, and Ranger's usersync must be the single source of truth.

## Open in this module

- **GAP-02** *(top of the queue)* Only `is_authorized_dag` is overridden, so
  `/api/v2/dags` passes one class-level "any" check and returns every row
  unfiltered. Invisible under `dag=*`; with `dag=etl_*` a user still sees all
  999. **Correctness, not performance.**
- **GAP-03** Keyless-check handling. A denied "any" must not become a 403 on a
  list page — under `SELF_OR_DESCENDANTS` one deny policy poisons the
  class-level question. But the same keyless check is issued by non-list routes
  where permissive would be wrong, so it is per-call-site. Research first: grep
  `requires_access_dag` under `airflow-core/src/airflow/api_fastapi/core_api/routes/`.
- **GAP-12** `_load_trusted_proxies()` re-reads conf on every authz check;
  resolve once in `RequestContextMiddleware.__init__`.
- **GAP-13** `current_request_context` warns once, so a permanently missing
  middleware is invisible after the first line.
- **GAP-14** No break-glass — a dead agent denies every Dag operation with no
  documented flip back to FAB.

## Deployment coupling

`REQUIRED_CAPABILITIES = ("authorize", "filter")` means this wheel refuses to
start against an agent that lacks either. **The agent must be upgraded before
the wheel.** That belongs in the admin guide's upgrade section.

## The boundary

This governs **who may operate Airflow**, not **what Airflow's tasks may do**.
Task execution carries a task-instance JWT with no user, so
`is_authorized_connection` is never called and `BaseHook.get_connection` always
succeeds. That is Airflow's documented security model, not a gap here — but it
must appear in the release notes, and it is the thing most likely to be
misunderstood by someone reading only this package.

## Conventions

`ODP-XXXX: short subject`. Branch `ODP-8150` in this fork. Do **not** name the
wheel `apache-airflow-providers-apache-ranger` — that is the upstream provider
namespace and must stay free.
