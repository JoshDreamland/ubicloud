# frozen_string_literal: true

class Prog::Postgres::PostgresTimelineNexus
  module PrependMethods
    # The base #take_backup now guards `hop_wait unless postgres_timeline.leader`,
    # so the nil.vm crash this override originally prevented is handled upstream.
    # We still clear the on-demand backup signal here: in the billing-deactivate
    # flow the leader can vanish between the wal-g sentinel landing and our next
    # wake-up (billing_deactivate_wait_backup polls the same sentinel and hops
    # into destroy as soon as it appears, which destroys the servers). The base
    # guard hops to #wait WITHOUT decrementing take_backup_for_converge, so
    # without this decr ConvergePostgresResource#start would nap on
    # take_backup_for_converge_set? until its maintenance-window deadline fires.
    # Clear it, then let the base guard perform the hop.
    def take_backup
      decr_take_backup_for_converge if postgres_timeline.leader.nil?

      super
    end
  end
end
