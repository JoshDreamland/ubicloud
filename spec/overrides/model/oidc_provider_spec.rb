# frozen_string_literal: true

require_relative "../../model/spec_helper"

RSpec.describe OidcProvider::PrependMethods do # rubocop:disable RSpec/SpecFilePathFormat
  subject(:oidc_provider) {
    OidcProvider.create(
      display_name: "test-provider", url: "https://auth.example.com",
      authorization_endpoint: "/authorize", token_endpoint: "/oauth/token",
      userinfo_endpoint: "/userinfo", jwks_uri: "https://auth.example.com/jwks",
      client_id: "client", client_secret: "secret",
    )
  }

  describe "#client_credentials_token" do
    it "omits the audience param and uses default timeouts when not given" do
      request_body = nil
      stub_request(:post, "https://auth.example.com/oauth/token")
        .with { |request| request_body = request.body }
        .to_return(status: 200, body: JSON.generate(access_token: "tok"))
      expect(oidc_provider.client_credentials_token).to eq("tok")
      expect(URI.decode_www_form(request_body).to_h).to eq("grant_type" => "client_credentials")
    end
  end
end
