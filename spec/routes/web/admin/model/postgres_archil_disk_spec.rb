# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresArchilDisk" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_archil_disk
    admin_account_setup_and_login
  end

  it "displays the PostgresArchilDisk instance page correctly" do
    click_link "PostgresArchilDisk"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresArchilDisk"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresArchilDisk #{@instance.ubid}"
  end
end
