locals {
  cognito_issuer = "https://cognito-idp.${var.region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  google_enabled = var.google_client_id != "" && var.google_client_secret != ""

  # Atributos custom del pool, sin el prefijo custom: que Cognito agrega solo.
  cognito_custom_attributes = ["role", "tenant_id", "user_id", "trabajador_id"]
}

resource "aws_cognito_user_pool" "main" {
  name                     = "${local.name}-user-pool"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF"
  deletion_protection      = "INACTIVE"
  user_pool_tier           = "ESSENTIALS"

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = true
  }

  dynamic "schema" {
    for_each = local.cognito_custom_attributes

    content {
      name                     = schema.value
      attribute_data_type      = "String"
      mutable                  = true
      developer_only_attribute = false

      string_attribute_constraints {
        min_length = 1
        max_length = 256
      }
    }
  }
}

resource "aws_cognito_user_pool_domain" "main" {
  domain                = var.cognito_domain_prefix != "" ? var.cognito_domain_prefix : "${local.name}-${local.account_id}"
  user_pool_id          = aws_cognito_user_pool.main.id
  managed_login_version = 2
}

# El proveedor Google solo existe si hay credenciales.
resource "aws_cognito_identity_provider" "google" {
  count = local.google_enabled ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id        = var.google_client_id
    client_secret    = var.google_client_secret
    authorize_scopes = "email openid profile"
  }

  attribute_mapping = {
    email    = "email"
    username = "sub"
    name     = "name"
  }
}

resource "aws_cognito_user_pool_client" "spa" {
  name         = "${local.name}-spa"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  explicit_auth_flows = ["ALLOW_USER_PASSWORD_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  supported_identity_providers         = local.google_enabled ? ["COGNITO", "Google"] : ["COGNITO"]

  callback_urls = [
    "http://localhost:5173",
    "http://localhost:5173/login",
    local.amplify_url,
    "${local.amplify_url}/login",
  ]
  logout_urls = [
    "http://localhost:5173",
    "http://localhost:5173/login",
    local.amplify_url,
    "${local.amplify_url}/login",
  ]

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 5

  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  enable_token_revocation       = true
  prevent_user_existence_errors = "ENABLED"

  read_attributes = concat([for a in local.cognito_custom_attributes : "custom:${a}"], ["email", "name"])

  # role, tenant_id, user_id y trabajador_id son claims de autorización: solo los escribe el
  # backend con las APIs admin (AdminCreateUser/AdminUpdateUserAttributes), nunca el usuario.
  write_attributes = ["email", "name"]

  depends_on = [aws_cognito_identity_provider.google]
}
