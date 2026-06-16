# frozen_string_literal: true

# Companion to cleanup-all-resources.sh — run with:
#   bundle exec ruby -r ./loader .devcontainer/scripts/cleanup-all-resources.rb
#
# Drains all Postgres resources/servers, force-destroys the timelines left
# behind, and confirms every Postgres record (resource, servers, timeline, and
# associated metadata + strands) reached a terminal (destroyed) state. Exits
# non-zero if anything is still present after the timeout.
#
# Only Ubicloud state is checked here — AWS buckets/policies are out of scope.

timeout = Integer(ENV.fetch("CLEANUP_TIMEOUT", "900")) # seconds per drain phase

def wait_until(label, timeout)
  waited = 0
  loop do
    remaining = yield
    if remaining.zero?
      puts "  #{label}: drained"
      return true
    end
    if waited >= timeout
      puts "  #{label}: TIMEOUT — #{remaining} still present after #{waited}s (is foreman/respirate running?)"
      return false
    end
    puts "  #{label}: #{remaining} remaining (#{waited}s elapsed)"
    sleep 10
    waited += 10
  end
end

# 1. Safety net: signal destroy on any resource the API delete did not cover
#    (e.g. other locations). incr_destroy is exactly what the API DELETE triggers
#    and is idempotent for resources already tearing down.
pending = PostgresResource.all
pending.each(&:incr_destroy)
puts "Signalled destroy on #{pending.count} remaining Postgres resource(s)"

# 2. Wait for resources and their servers to drain. Servers must be gone before
#    timelines can be destroyed (postgres_server.timeline_id FK).
wait_until("PostgresResource", timeout) { PostgresResource.count }
wait_until("PostgresServer", timeout) { PostgresServer.count }

# 3. Force-destroy the timelines that the resource drop intentionally left behind.
timelines = PostgresTimeline.all
timelines.each(&:incr_destroy)
puts "Signalled destroy on #{timelines.count} retained timeline(s)"
wait_until("PostgresTimeline", timeout) { PostgresTimeline.count }

# 4. Confirm terminal state of every Postgres record and its strands.
puts "=== Confirmation: Ubicloud Postgres records in terminal state ==="
checks = {
  "PostgresResource" => PostgresResource.count,
  "PostgresServer" => PostgresServer.count,
  "PostgresTimeline" => PostgresTimeline.count,
  "PostgresMetricDestination" => PostgresMetricDestination.count,
  "PostgresLogDestination" => PostgresLogDestination.count,
  "PostgresInitScript" => PostgresInitScript.count,
  "Postgres::* strands" => Strand.where(Sequel.like(:prog, "Postgres::%")).count,
}

clean = checks.values.all?(&:zero?)
checks.each { |name, n| puts format("  %-28s %s", name, n.zero? ? "OK (0)" : "NOT TERMINAL (#{n})") }

if clean
  puts "=== CLEAN: all Postgres resources, timelines, and metadata destroyed ==="
  exit 0
else
  puts "=== INCOMPLETE: some records did not reach terminal state (see above) ==="
  exit 1
end
