# frozen_string_literal: true

require_relative "../../common/lib/util"

# Drop-in counterpart to the unit-file hardening landed in the AMI at
# https://github.com/ClickHouse/postgres-vm-images/commit/111a4fe3e8a0a6bfc56a3c4ad542bb35591a6115
# Kept here so existing instances pick it up without an AMI rebuild.
class WalgHardening
  DROP_IN_DIR = "/etc/systemd/system/wal-g.service.d"
  DROP_IN_PATH = "#{DROP_IN_DIR}/90-hardening.conf".freeze

  CONFIG = <<~OVERRIDE
    [Unit]
    StartLimitIntervalSec=0

    [Service]
    RestartSec=5
    OOMScoreAdjust=-900
    OOMPolicy=stop
  OVERRIDE

  def self.apply
    return if r("systemctl show wal-g.service -p DropInPaths --value").split.include?(DROP_IN_PATH)
    safe_write_to_file(DROP_IN_PATH, CONFIG)
    r "systemctl daemon-reload"
    r "systemctl try-restart wal-g.service"
  end
end
