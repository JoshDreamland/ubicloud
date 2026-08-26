# frozen_string_literal: true

# Publishes the control plane's Postgres observations (currently pg_cp_up)
# from postgres_int_metric_monitor to the regional OTLP collectors. A single strand
# fleet-wide: leader election and crash takeover come from the strand lease.
class Prog::PostgresCpMetricsExport < Prog::Base
  label def wait
    nap 60 unless Config.postgres_cp_metrics_export_enabled

    PostgresCpMetricsExporter.export

    nap Config.postgres_cp_metrics_export_nap_seconds
  end
end
