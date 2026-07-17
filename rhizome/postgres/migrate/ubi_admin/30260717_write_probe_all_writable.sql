-- Extend the write-availability probe to every writable server: drop the
-- replication-slot requirement from monitor.write_probe_check() (30260616_write_probe.sql)
-- so it applies to any server out of recovery and not read-only.
CREATE OR REPLACE FUNCTION monitor.write_probe_check()
RETURNS TABLE (applicable boolean, xid bigint)
LANGUAGE plpgsql
AS $$
BEGIN
  applicable := NOT pg_is_in_recovery()
    AND NOT current_setting('transaction_read_only')::boolean;
  xid := NULL;

  IF applicable THEN
    INSERT INTO monitor.write_probe (id) VALUES (1)
      ON CONFLICT (id) DO UPDATE SET updated_at = now();
    xid := pg_current_xact_id()::text::bigint;
  END IF;

  RETURN NEXT;
END;
$$;
