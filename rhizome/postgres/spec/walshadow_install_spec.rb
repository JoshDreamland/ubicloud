# frozen_string_literal: true

require_relative "../lib/walshadow_install"

RSpec.describe WalshadowInstall do
  subject(:install) { described_class.new("17") }

  describe "#run" do
    it "builds the pg extension, installs the binary, and writes the wrapper" do
      expect(install).to receive(:_run_command).with("make", "-C", "walshadow-src/pgext", "with_llvm=no", "PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config")
      expect(install).to receive(:_run_command).with("make", "-C", "walshadow-src/pgext", "with_llvm=no", "PG_CONFIG=/usr/lib/postgresql/17/bin/pg_config", "install")
      expect(install).to receive(:_run_command).with("install", "-m", "755", "walshadow-src/target/release/walshadow-stream", "/usr/local/bin/walshadow-stream")
      expect(install).to receive(:_run_command).with("install", "-m", "755", described_class::WRAPPER, "/usr/local/bin/walshadow-run")
      install.run
    end
  end
end
