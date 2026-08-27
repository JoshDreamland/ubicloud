ENV["POSTGRES_SERVICE_PROJECT_ID"] = "3fa904f0-e4dc-86d2-a919-f8b0a326206f"
ENV["ENABLE_FAILURE_INJECTION"] = "true"
ENV["ALLOW_WEB_SSH"] = "true"
if ENV["RACK_ENV"] != "test"
  ENV["AWS_PROFILE"] = "pg-dev-postgresqladmindev"
  ENV["AWS_POSTGRES_IAM_ACCESS"] = "true"
  ENV["CLOVER_ADMIN_DEVELOPMENT_NO_WEBAUTHN"] = "true"
  # GCP is on unless the environment opts out (ENABLE_GCP=false, set by
  # docker-compose.ci.yml). An opted-out environment registers no GCP location,
  # so these are left at the upstream defaults rather than pointed at our project.
  unless %w[0 false no off].include?(ENV.fetch("ENABLE_GCP", "true").downcase)
    ENV["GCP_POSTGRES_IAM_ACCESS"] = "true"
    ENV["POSTGRES_GCE_IMAGE_GCP_PROJECT_ID"] = "dataplane-deployment"
  end
end
