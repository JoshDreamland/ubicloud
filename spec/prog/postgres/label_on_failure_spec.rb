# frozen_string_literal: true

require_relative "spec_helper"

POSTGRES_PROGS_WITH_ON_FAILURE = [
  Prog::Postgres::PostgresServerNexus,
  Prog::Postgres::PostgresTimelineNexus,
  Prog::Postgres::ConvergePostgresResource
].freeze

RSpec.describe "Postgres Prog on_failure messages" do
  POSTGRES_PROGS_WITH_ON_FAILURE.each do |klass|
    describe klass do
      klass.labels.each do |label|
        it "has an on_failure message for ##{label}" do
          message = klass.label_alert_for(label)
          expect(message).not_to be_nil,
            "#{klass}##{label} is missing an on_failure message. " \
            "Add `on_failure :#{label}, \"What went wrong for an oncaller.\"` to #{klass}."
          expect(message).not_to be_empty
        end
      end
    end
  end
end
