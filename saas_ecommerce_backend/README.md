# Advanced Multi-Tenant SaaS E-Commerce API

FastAPI scaffold using async SQLAlchemy, SQLite, and Pydantic v2.

## Local development

Supported Python versions are 3.11-3.13, on Windows, macOS, and Linux. The
backend supports SQLite 3.35 or newer (including the SQLite library bundled
with the supported Python releases). CI checks this Python matrix and the SQLite
version available in each runner.

From this directory, create and activate a virtual environment and install the
reproducibly locked development dependencies:

```powershell
py -m venv .venv
.\.venv\Scripts\Activate.ps1
python -m pip install -r requirements-dev.lock
Copy-Item .env.example .env
```

`requirements.txt` declares production dependency ranges.
`requirements-dev.in` adds the development tools; `requirements.lock` and
`requirements-dev.lock` are generated with pip-tools and pin exact versions.
The lock files intentionally omit artifact hashes because they are generated
across supported platforms; installation still uses exact transitive versions.
When changing dependency declarations, regenerate both locks using the
documented commands below, inspect the diff, run `pip-audit`, and run the full
checks.

`DATABASE_URL` is the SQLite-only database location setting. Relative SQLite
paths resolve from this backend directory, not the process working directory;
an absolute SQLite path can be supplied through the same environment variable
for local or deployment-specific storage.

`.env` is local-only and is ignored by version control and Docker build contexts.
The example key is a placeholder for development only; never use it in
production. Keep real credentials out of source files, command output, logs, and
distributable archives.

## SQLite schema and migrations

The application uses SQLAlchemy's async SQLite driver (`aiosqlite`). The
database engine enables foreign keys and a 30-second busy timeout on every
connection, creates the parent directory for file-backed databases, and uses
WAL mode for file-backed databases. WAL improves reader/writer coexistence but
does not make SQLite a multi-writer database; keep the database on local
persistent storage and use a single application host/process topology suitable
for SQLite. Do not place a WAL database on a network filesystem without
validating its locking and shared-memory semantics.

Application startup does not create, drop, or migrate tables. Apply the
versioned migrations explicitly from this directory:

```powershell
python -m alembic upgrade head
python -m alembic current
python -m alembic check
```

The initial migration (`0001_initial_schema`) reproduces the schema that
existed before Alembic was introduced. The next migration adds product price
and stock checks and tenant lookup indexes. The authentication migration adds
the database-backed rate-limit buckets. Price remains the existing
floating-point representation to avoid silently selecting a currency scale or
rounding existing values; exact monetary storage needs a separately approved
currency/precision and data-migration policy.

### Existing SQLite database without Alembic history

Do **not** run `alembic upgrade head` directly against a database that already
has application tables but no `alembic_version` table. Do not stamp it merely
because the table names appear familiar.

1. Stop application writers and take a verified SQLite backup. From this
   directory, the SQLite backup API can create a consistent backup without
   exposing row contents:

   ```powershell
   python -c "import sqlite3; source=sqlite3.connect('file:saas_ecommerce.db?mode=ro', uri=True); backup=sqlite3.connect('saas_ecommerce.pre-migration.backup.db'); source.backup(backup); backup.close(); source.close()"
   ```

   If `DATABASE_URL` points elsewhere, use that database and a separate backup
   destination instead. Copying only the `.db` file while WAL is active may omit
   committed WAL contents.
2. Run read-only checks on the target and backup: `PRAGMA integrity_check`,
   `PRAGMA foreign_key_check`, and inspect `sqlite_master` plus
   `PRAGMA table_info`, `PRAGMA index_list`, and `PRAGMA foreign_key_list` for
   every table. Compare the result to `migrations/versions/0001_initial_schema.py`.
   Check for duplicate tenant slugs/emails and invalid product stock/prices
   before adopting the later constraints. These checks must not print row data.
3. Perform the proposed `alembic stamp 0001_initial_schema` and
   `alembic upgrade head` against a separate backup copy first. Verify
   `PRAGMA integrity_check`, foreign-key checks, expected indexes/constraints,
   and representative application behavior on that copy.
4. Only after schema and backup verification, stamp the real database at
   `0001_initial_schema`, then run `alembic upgrade head`. Keep the backup until
   post-migration checks and application smoke tests succeed.

The database inspected when this migration was authored contained the three
expected tables and no rows; this does not establish that another environment's
database is empty or identical. The initial migration is a baseline, not a
data export or a command to recreate an existing database.

## Production configuration

Supply settings through the deployment platform's environment variables or
secret manager. Required settings are `APP_NAME`, `ENVIRONMENT`,
`DATABASE_URL`, `SECRET_KEY`, `JWT_ALGORITHM`,
`ACCESS_TOKEN_EXPIRE_MINUTES`, and `CORS_ORIGINS`. Set `ENVIRONMENT` to
`production`, use an independently generated secret with at least 32 bytes for
HS256, 48 bytes for HS384, or 64 bytes for HS512, configure the async SQLite URL,
and provide explicit HTTPS CORS origins. Production startup rejects missing
settings, weak/default keys, unsupported JWT algorithms, invalid database URLs,
and insecure CORS origins.

### Authentication and authorization

Passwords are hashed with the Argon2 implementation selected by `pwdlib`.
Tenant registration requires 12-1024 characters; password values are never
truncated. The OAuth2 password-form login endpoint is unchanged. Access tokens
are signed with the configured HMAC algorithm and require valid `sub` and `exp`
claims. Role and tenant claims remain present for compatibility, but are never
used for authorization; current roles, tenant membership, and account status
come from the database.

Existing product permissions are explicit: TenantAdmins can create, list, and
delete products in their own tenant; Customers can list products in their own
tenant; SuperAdmins can list products only when associated with a tenant and
can deactivate users. Product IDs remain tenant-scoped. Tenant registration
remains public for onboarding. A SuperAdmin account must be provisioned by an
operator; there is no public role-promotion endpoint.

`POST /auth/users/{user_id}/deactivate` is a new SuperAdmin-only endpoint.
Deactivation invalidates all of that user's access tokens on the next request
because each request reloads the account from the database. Tokens for active
accounts remain valid until their configured expiry; this is the revocation
strategy, and there is no separate per-token logout/revocation list.

Login and registration use configurable fixed-window limits:
`LOGIN_RATE_LIMIT_PER_WINDOW` (default 10) and
`LOGIN_RATE_LIMIT_WINDOW_SECONDS` (default 900), plus
`REGISTRATION_RATE_LIMIT_PER_WINDOW` (default 5) and
`REGISTRATION_RATE_LIMIT_WINDOW_SECONDS` (default 3600). Counts are persisted
in SQLite, shared by application workers using the same database, and keyed by
a keyed hash of the direct client address. Forwarded-IP headers are not trusted;
deployments behind a proxy must configure the ASGI server/proxy trust boundary
so the direct client address is trustworthy. Configure these limits for the
expected client population and deployment topology.

The only intentional request/response contract changes are the stronger
registration password bounds and a generic duplicate-registration error detail
to avoid revealing whether an email or tenant slug already exists. The
deactivation endpoint and rate-limit `429` responses are additive. Existing
tokens with valid subject and expiry claims remain acceptable during their
remaining lifetime; role and tenant claim tampering cannot change permissions.

### Product API

Product routes are tenant-scoped using the authenticated user's database
membership; request bodies cannot set `tenant_id`. TenantAdmins can create,
partially update, and delete products. TenantAdmins, Customers, and
tenant-associated SuperAdmins can list and retrieve products. Foreign-tenant
product IDs return `404`. The routes are `POST/GET /products/`,
`GET/PATCH/DELETE /products/{product_id}`.

Tenant currency is an ISO 4217 code. New tenants default to `PKR`; registration
may specify a supported `default_currency`. Products inherit that tenant's
default when `currency` is omitted; an explicit supported product currency is
accepted. Currency values are normalized to uppercase. No currency conversion
is performed. Product prices use `Decimal` validation and `NUMERIC(15, 4)` with
positive values, at most 15 total digits and 4 fractional digits. Responses
serialize `price` as a decimal string to preserve its decimal representation;
clients that previously expected a JSON number must parse this field as a
decimal string. Names are trimmed, required, and limited to 255 characters;
descriptions are optional, may be cleared with explicit `null` on PATCH, and
are limited to 5000 characters. PATCH leaves omitted fields unchanged; explicit
`null` is accepted only for `description`. Empty PATCH requests are rejected.

List ordering is stable by product ID. `skip` is limited to 0-1,000,000,
`limit` to 1-100; optional filters are `search` (1-100 nonblank characters),
`currency`, `min_price`, and `max_price`. Invalid filters and inverted price
bounds return `422`. PATCH requires `expected_version`, returned as `version`
on the product. Updates atomically advance the version; a stale version
returns `409` rather than silently overwriting another update. Product names
are not unique; duplicate names remain allowed for compatibility.

Migration `0004_product_currency_decimal` assigns `PKR` to tenants missing a
currency, assigns each existing product its tenant's default currency only if
the product currency is missing, and changes the price column from `Float` to
`NUMERIC(15, 4)` without currency conversion. Before altering the schema it
checks existing prices and text fields; it aborts without applying the product
schema changes if a price cannot fit the new precision/scale or a name or
description is outside the API limits. Review the existing data and take a
verified backup before applying migrations. Do not edit or bulk-round legacy
prices merely to force this migration through; resolve any preflight failure
with an approved data policy first. SQLite uses dynamic numeric storage, so
keep monetary values within the documented precision and do not treat this
SQLite-backed API as a substitute for validating a production database and
deployment topology.

For example, configure these values using the environment-variable or secret
injection feature provided by your deployment platform. Do not put secret
values in Dockerfiles, source control, build arguments, or logs. For local
development, use `.env.example` as a template and replace its placeholder with
a local-only key.

If a real secret may have been exposed, rotate it in the secret manager and
redeploy affected services. Ignoring or deleting a file in the latest working
tree does **not** remove it from Git history; if it was committed, follow the
hosting provider's guidance to purge repository history as well.

The `.dockerignore` protects Docker build contexts. This project does not define
a general-purpose archive/package workflow; create any other distributable from
an explicit source allowlist rather than archiving the working directory.
Git-generated source archives also exclude sensitive/local files through
`.gitattributes`; `.env.example` remains available as a safe template.

## Verification

From this directory, run the complete test suite:

```powershell
$env:PYTHONDONTWRITEBYTECODE = '1'
python -m pytest -q --cov --cov-report=term-missing
ruff check app migrations tests
ruff format --check app migrations tests
mypy
pip-audit -r requirements-dev.lock
```

Recompile lock files after changing a dependency declaration:

```powershell
python -m pip install "pip-tools>=7.4,<8.0"
python -m piptools compile --resolver=backtracking --output-file requirements.lock requirements.txt
python -m piptools compile --resolver=backtracking --output-file requirements-dev.lock requirements-dev.in
```

Run a specific test module with:

```powershell
python -m pytest tests/test_config.py tests/test_api.py -q
```

API tests use FastAPI's `TestClient`, override the production database
dependency, and create a fresh SQLite database under pytest's temporary
directory for each test. Migration tests also use disposable temporary
databases. They do not run production migrations or connect to the configured
development database. CI supplies only a CI-only signing key and validates
migrations in a temporary directory; it has no production secrets or customer
data. Lint, format, type, audit, migration, and test failures all fail the CI
job, and the stable `Required CI gate` check fails if any Python matrix job
fails. Configure `Required CI gate` as a required status check in the hosting
repository's branch protection or ruleset to prevent merging/releasing a change
with failed checks; that hosting setting cannot be enforced by workflow files
alone. The suite currently measures 79.7% branch-aware coverage of `app`; the
initial coverage floor is 70% to leave room for staged coverage improvements
without weakening tests to hit a target. Increase the floor as meaningful
behavior tests are added.
