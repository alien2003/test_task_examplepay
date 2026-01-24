# Database Migration Strategy

## Expand/Contract Pattern

ExamplePay uses the expand/contract pattern (also known as parallel change) for all production schema migrations. This approach ensures zero-downtime deployments by making schema changes backward compatible at every step, which aligns with our Argo Rollouts blue/green deployment strategy where two application versions run simultaneously.

## Phase 1: Expand

**Goal**: Add new schema elements without breaking the current application version.

### Rules

- Add new columns with `DEFAULT` values or `NULL` constraints. Never add `NOT NULL` columns without defaults.
- Add new tables freely.
- Add new indexes (use `CREATE INDEX CONCURRENTLY` on PostgreSQL to avoid locking).
- Never rename or drop columns, tables, or constraints in this phase.

### Example

Suppose we are renaming `users.full_name` to split into `first_name` and `last_name`:

```sql
-- Migration V003__expand_user_name_fields.sql
ALTER TABLE users ADD COLUMN first_name VARCHAR(255);
ALTER TABLE users ADD COLUMN last_name VARCHAR(255);

-- Backfill trigger: keep new columns in sync during transition
CREATE OR REPLACE FUNCTION sync_user_name_fields()
RETURNS TRIGGER AS $$
BEGIN
  IF NEW.first_name IS NULL AND NEW.full_name IS NOT NULL THEN
    NEW.first_name := split_part(NEW.full_name, ' ', 1);
    NEW.last_name := substring(NEW.full_name from position(' ' in NEW.full_name) + 1);
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_sync_user_name
BEFORE INSERT OR UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION sync_user_name_fields();
```

### Deployment

- Apply the expand migration.
- Deploy application version N (current) -- it continues using `full_name` and ignores the new columns.
- The trigger ensures new columns are populated for any writes made by version N.

## Phase 2: Migrate

**Goal**: Backfill historical data and transition the application to use new columns.

### Steps

1. **Backfill data**: Run a background job to populate `first_name` and `last_name` for all existing rows:

   ```sql
   -- Migration V004__backfill_user_name_fields.sql
   UPDATE users
   SET first_name = split_part(full_name, ' ', 1),
       last_name = substring(full_name from position(' ' in full_name) + 1)
   WHERE first_name IS NULL AND full_name IS NOT NULL;
   ```

   For large tables, batch the update to avoid long-running transactions:

   ```sql
   -- Run in batches of 10,000
   UPDATE users
   SET first_name = split_part(full_name, ' ', 1),
       last_name = substring(full_name from position(' ' in full_name) + 1)
   WHERE id IN (
     SELECT id FROM users
     WHERE first_name IS NULL AND full_name IS NOT NULL
     LIMIT 10000
   );
   ```

2. **Dual-write in application code**: Deploy application version N+1, which writes to both `full_name` and `first_name`/`last_name`. Reads start preferring the new columns but fall back to `full_name`.

3. **Verify consistency**: Run a data reconciliation query to confirm all rows have consistent data across old and new columns.

### Integration with Argo Rollouts Blue/Green

During the Phase 2 deployment:

```
                    +-------------------+
                    |  Aurora PostgreSQL |
                    |                   |
                    | full_name (old)   |
                    | first_name (new)  |
                    | last_name (new)   |
                    | sync trigger      |
                    +--------+----------+
                             |
              +--------------+--------------+
              |                             |
    +---------v----------+       +----------v---------+
    | Active (version N) |       | Preview (version N+1)|
    | reads: full_name   |       | reads: first_name,  |
    | writes: full_name  |       |        last_name    |
    | (trigger fills new)|       | writes: both        |
    +--------------------+       +---------------------+
```

Both versions can safely operate against the same database simultaneously because:
- Version N writes to `full_name`; the trigger fills `first_name`/`last_name`
- Version N+1 writes to all three columns
- No data inconsistency regardless of which version handles a request

## Phase 3: Contract

**Goal**: Remove old schema elements after all application versions have migrated.

### Prerequisites

- All running application instances are version N+1 or later
- The Argo Rollout has been fully promoted (no blue/green preview running old version)
- At least one full deployment cycle has completed (scaleDownDelaySeconds has elapsed)
- Data reconciliation confirms 100% consistency

### Steps

```sql
-- Migration V005__contract_user_name_fields.sql

-- Remove the sync trigger (no longer needed)
DROP TRIGGER IF EXISTS trg_sync_user_name ON users;
DROP FUNCTION IF EXISTS sync_user_name_fields();

-- Add NOT NULL constraints to new columns
ALTER TABLE users ALTER COLUMN first_name SET NOT NULL;
ALTER TABLE users ALTER COLUMN last_name SET NOT NULL;

-- Drop the old column
ALTER TABLE users DROP COLUMN full_name;
```

### Timing

The contract migration should be applied in a **separate deployment from the application change that stops using the old column**. This provides a safety buffer:

1. Deploy version N+2 (reads/writes only `first_name`/`last_name`, ignores `full_name`)
2. Wait at least 24 hours with version N+2 stable in production
3. Apply contract migration V005

If version N+2 has issues and needs rollback to N+1, the old column is still present and the dual-write code in N+1 works fine.

## Rollback Considerations

| Phase | Rollback Path | Data Impact |
|-------|--------------|-------------|
| Expand | Drop new columns + trigger | None (no application uses new columns yet) |
| Migrate (backfill) | No rollback needed; backfill is idempotent | None |
| Migrate (app N+1) | Roll back to N via Argo Rollouts | Trigger continues syncing; no data loss |
| Contract | Restore column from backup or re-add + backfill | Potential data loss if column was dropped; this is why we wait 24h |

### Critical Rule

**Never apply a contract migration in the same release as an application change.** The contract migration is irreversible (column drop). If the application change needs rollback, the old schema must still be available.

## Tooling

ExamplePay uses **Flyway** for schema migration management.

### Configuration

```properties
# flyway.conf
flyway.url=jdbc:postgresql://${DB_HOST}:5432/examplepay
flyway.user=${DB_MIGRATION_USER}
flyway.password=${DB_MIGRATION_PASSWORD}
flyway.schemas=public
flyway.locations=filesystem:migrations/
flyway.validateMigrationNaming=true
flyway.baselineOnMigrate=true
```

### Migration Naming

```
V001__create_users_table.sql
V002__add_payment_methods.sql
V003__expand_user_name_fields.sql
V004__backfill_user_name_fields.sql
V005__contract_user_name_fields.sql
```

### CI Integration

Flyway migrations are validated in the CI pipeline:

1. `flyway validate` -- checks pending migrations are syntactically valid
2. `flyway migrate` against a disposable PostgreSQL container -- verifies migrations apply cleanly
3. Application integration tests run against the migrated schema

Migrations that fail validation block the pipeline. The database migration user has restricted permissions (DDL + DML on the application schema only, no `DROP DATABASE` or superuser access).
