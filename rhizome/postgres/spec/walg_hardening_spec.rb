# frozen_string_literal: true

require_relative "../lib/walg_hardening"

RSpec.describe WalgHardening do
  describe ".apply" do
    it "writes the drop-in, reloads systemd, and try-restarts wal-g when the drop-in is not yet loaded" do
      expect(described_class).to receive(:_run_command).with("systemctl show wal-g.service -p DropInPaths --value").and_return("/etc/systemd/system/wal-g.service.d/override.conf\n")
      expect(described_class).to receive(:safe_write_to_file).with(WalgHardening::DROP_IN_PATH, WalgHardening::CONFIG)
      expect(described_class).to receive(:_run_command).with("systemctl daemon-reload")
      expect(described_class).to receive(:_run_command).with("systemctl try-restart wal-g.service")

      described_class.apply
    end

    it "no-ops when systemd has already loaded our drop-in" do
      expect(described_class).to receive(:_run_command).with("systemctl show wal-g.service -p DropInPaths --value").and_return("/etc/systemd/system/wal-g.service.d/override.conf #{WalgHardening::DROP_IN_PATH}\n")
      expect(described_class).not_to receive(:safe_write_to_file)

      described_class.apply
    end
  end
end
