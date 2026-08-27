# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe CloverAdmin, "PostgresBranchDisk" do
  include AdminModelSpecHelper

  before do
    @instance = create_postgres_branch_disk
    admin_account_setup_and_login
  end

  it "displays the PostgresBranchDisk instance page correctly" do
    click_link "PostgresBranchDisk"
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresBranchDisk"

    click_link @instance.admin_label
    expect(page.status_code).to eq 200
    expect(page.title).to eq "Ubicloud Admin - PostgresBranchDisk #{@instance.ubid}"
  end
end
