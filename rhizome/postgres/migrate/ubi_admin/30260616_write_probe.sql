-- Heartbeat table + probe function for the write-availability probe.
CREATE SCHEMA IF NOT EXISTS monitor;

CREATE TABLE IF NOT EXISTS monitor.write_probe (
  id         smallint    PRIMARY KEY,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Gates and writes the heartbeat in one round-trip, returning (applicable, xid).
-- Invoker rights: the caller (ubi_monitoring) needs the privileges granted below.
CREATE OR REPLACE FUNCTION monitor.write_probe_check()
RETURNS TABLE (applicable boolean, xid bigint)
LANGUAGE plpgsql
AS $$
BEGIN
  applicable := NOT pg_is_in_recovery()
    AND NOT current_setting('transaction_read_only')::boolean
    AND EXISTS (SELECT 1 FROM pg_replication_slots);
  xid := NULL;

  IF applicable THEN
    INSERT INTO monitor.write_probe (id) VALUES (1)
      ON CONFLICT (id) DO UPDATE SET updated_at = now();
    xid := pg_current_xact_id()::text::bigint;
  END IF;

  RETURN NEXT;
END;
$$;

-- Minimum privileges for ubi_monitoring to run the probe. The upsert needs all of
-- SELECT, INSERT, UPDATE (SELECT to read the conflicting row).
GRANT USAGE ON SCHEMA monitor TO ubi_monitoring;
GRANT SELECT, INSERT, UPDATE ON monitor.write_probe TO ubi_monitoring;
REVOKE EXECUTE ON FUNCTION monitor.write_probe_check() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION monitor.write_probe_check() TO ubi_monitoring;
