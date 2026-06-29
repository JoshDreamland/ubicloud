# frozen_string_literal: true

# Testing helper prog. Re-triggers a set of server semaphores across the target
# servers of a Postgres resource in rolling order: every targeted standby first,
# then the targeted primary, waiting for each stage to converge (server strand
# back in `wait` with the triggered semaphores consumed) before moving on.
class Prog::Postgres::TriggerServerUpgrade < Prog::Base
  subject_is :postgres_resource

  def semaphores
    @semaphores ||= frame.fetch("semaphores")
  end

  def target_server_ids
    @target_server_ids ||= frame.fetch("server_ids")
  end

  def target_servers
    postgres_resource.servers.select { target_server_ids.include?(it.id) }
  end

  def target_standbys
    target_servers.reject(&:is_representative)
  end

  def target_primary
    target_servers.find(&:is_representative)
  end

  label def start
    register_deadline(nil, 30 * 60)
    target_standbys.each { trigger(it) }
    hop_wait_standbys
  end

  label def wait_standbys
    nap 5 unless target_standbys.all? { converged?(it) }

    trigger(target_primary) if target_primary
    hop_wait_primary
  end

  label def wait_primary
    nap 5 if target_primary && !converged?(target_primary)

    pop "triggered #{semaphores.join(", ")} standby-first on #{target_server_ids.count} server(s)"
  end

  def trigger(server)
    semaphores.each { Semaphore.incr(server.id, it) }
  end

  # A server is converged once its strand is back in `wait` with none of the
  # triggered semaphores still pending.
  def converged?(server)
    st = server.strand&.reload
    st.nil? || (st.label == "wait" && DB[:semaphore].where(strand_id: server.id, name: semaphores).empty?)
  end
end
