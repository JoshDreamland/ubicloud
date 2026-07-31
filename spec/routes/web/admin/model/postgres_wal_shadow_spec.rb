# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresWalShadow" do
  include AdminModelSpecHelper

  before do
    postgres_resource = create_postgres_resource(project: Project.create(name: "test-project"), location_id: Location::HETZNER_FSN1_ID)
    @instance = Prog::Postgres::PostgresWalShadowNexus.assemble(postgres_resource.id, ch_config: "[ch]\n", boot_image: "ami-0123").subject
    admin_account_setup_and_login
  end

  it "displays the PostgresWalShadow instance page correctly" do
    click_link "PostgresWalShadow"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresWalShadow"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresWalShadow #{@instance.ubid}"
  end
end
