# frozen_string_literal: true

# Verifies that every label in every Postgres Prog class has a human-readable
# purpose description. Descriptions are shown in deadline pages fired by
# strand.rb when a strand fails to reach its target label on time, giving
# oncall engineers immediate context without having to read source code.
#
# To add a description, change:
#   label def my_label
# to:
#   label "What this label is doing.", def my_label

POSTGRES_PROGS = [
  Prog::Postgres::PostgresServerNexus,
  Prog::Postgres::PostgresTimelineNexus,
  Prog::Postgres::ConvergePostgresResource,
].freeze

RSpec.describe "Postgres Prog label descriptions" do
  POSTGRES_PROGS.each do |klass|
    describe klass do
      klass.labels.each do |label|
        it "has a description for ##{label}" do
          description = klass.label_description_for(label)
          expect(description).not_to be_nil, "#{klass}##{label} has no description. " \
            "Add one by changing `label def #{label}` to `label \"What this label does.\", def #{label}`"
          expect(description).not_to be_empty
        end
      end
    end
  end
end
