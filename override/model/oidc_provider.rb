# frozen_string_literal: true

require "base64"
require "excon"

class OidcProvider
  module PrependMethods
    # Client-credentials token minting shared by the VM-side OTLP token
    # writer and the control plane's pg_cp_up exporter.
    def client_credentials_token(audience: nil, additional_body_params: {}, timeout: nil)
      body_params = {grant_type: "client_credentials"}
      body_params[:audience] = audience if audience
      body_params.merge!(additional_body_params)

      options = {
        headers: {
          "Content-Type" => "application/x-www-form-urlencoded",
          "Accept" => "application/json",
          "Authorization" => "Basic #{Base64.strict_encode64([CGI.escape(client_id), CGI.escape(client_secret)].join(":"))}",
        },
        body: URI.encode_www_form(body_params),
        expects: [200, 201],
      }
      options[:connect_timeout] = options[:write_timeout] = options[:read_timeout] = timeout if timeout

      response = Excon.post(URI.join(url, token_endpoint).to_s, **options)
      access_token = JSON.parse(response.body)["access_token"]
      raise "OAuth token response missing access_token: #{response.body}" unless access_token

      access_token
    end
  end
end
