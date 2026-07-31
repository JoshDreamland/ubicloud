# frozen_string_literal: true

require_relative "../../common/lib/util"

class WalshadowInstall
  WRAPPER = File.expand_path("../bin/walshadow-run", __dir__)

  def initialize(pg_version)
    @pg_version = pg_version
  end

  # runs as root; build/ tree is root-owned from the build daemonizer unit
  def run
    pg_config = "PG_CONFIG=/usr/lib/postgresql/#{@pg_version}/bin/pg_config"
    r "make", "-C", "walshadow-src/pgext", "with_llvm=no", pg_config
    r "make", "-C", "walshadow-src/pgext", "with_llvm=no", pg_config, "install"
    r "install", "-m", "755", "walshadow-src/target/release/walshadow-stream", "/usr/local/bin/walshadow-stream"
    r "install", "-m", "755", WRAPPER, "/usr/local/bin/walshadow-run"
  end
end
