
resource "azurerm_resource_group" "resource_group" {
  name     = "fiap-tech-challenge-costumer-group"
  location = var.main_resource_group_location

  tags = {
    environment = var.environment
  }
}

resource "random_password" "sqlserver_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "random_uuid" "sqlserver_user" {
}

resource "random_uuid" "auth_secret_key" {
}

resource "azurerm_mssql_server" "sqlserver" {
  name                         = "sanduba-costumer-sqlserver"
  resource_group_name          = azurerm_resource_group.resource_group.name
  location                     = azurerm_resource_group.resource_group.location
  version                      = "12.0"
  administrator_login          = random_uuid.sqlserver_user.result
  administrator_login_password = random_password.sqlserver_password.result

  tags = {
    environment = azurerm_resource_group.resource_group.tags["environment"]
  }
}

resource "azurerm_mssql_firewall_rule" "sqlserver_allow_azure_services_rule" {
  name             = "Allow access to Azure services"
  server_id        = azurerm_mssql_server.sqlserver.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

resource "azurerm_mssql_database" "sanduba_costumer_database" {
  name                 = "sanduba-costumer-database"
  server_id            = azurerm_mssql_server.sqlserver.id
  collation            = "SQL_Latin1_General_CP1_CI_AS"
  sku_name             = "Basic"
  max_size_gb          = 2
  read_scale           = false
  zone_redundant       = false
  geo_backup_enabled   = false
  create_mode          = "Default"
  storage_account_type = "Local"

  tags = {
    environment = azurerm_resource_group.resource_group.tags["environment"]
  }
}

resource "azurerm_service_plan" "costumer_plan" {
  name                = "costumer-app-service-plan"
  resource_group_name = azurerm_resource_group.resource_group.name
  location            = azurerm_resource_group.resource_group.location
  os_type             = "Linux"
  sku_name            = "B1"

  tags = {
    environment = azurerm_resource_group.resource_group.tags["environment"]
  }
}

data "azurerm_storage_account" "storage_account_terraform" {
  name                = "sandubaterraform"
  resource_group_name = var.main_resource_group
}

data "azurerm_virtual_network" "virtual_network" {
  name                = "fiap-tech-challenge-network"
  resource_group_name = var.main_resource_group
}

data "azurerm_subnet" "api_subnet" {
  name                 = "fiap-tech-challenge-costumer-subnet"
  virtual_network_name = data.azurerm_virtual_network.virtual_network.name
  resource_group_name  = data.azurerm_virtual_network.virtual_network.resource_group_name
}

resource "azurerm_linux_function_app" "linux_function" {
  name                        = "sanduba-costumer-function"
  resource_group_name         = azurerm_resource_group.resource_group.name
  location                    = azurerm_resource_group.resource_group.location
  storage_account_name        = data.azurerm_storage_account.storage_account_terraform.name
  storage_account_access_key  = data.azurerm_storage_account.storage_account_terraform.primary_access_key
  service_plan_id             = azurerm_service_plan.costumer_plan.id
  https_only                  = true
  functions_extension_version = "~4"

  app_settings = {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE   = false
    FUNCTIONS_EXTENSION_VERSION           = "~4"
    "SqlServerSettings__ConnectionString" = "Server=tcp:${azurerm_mssql_server.sqlserver.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.sanduba_costumer_database.name};Persist Security Info=False;User ID=${random_uuid.sqlserver_user.result};Password=${random_password.sqlserver_password.result};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
    AUTH_SECRET_KEY                       = random_uuid.auth_secret_key.result
    AUTH_ISSUER                           = "Sanduba.Auth"
    AUTH_AUDIENCE                         = "Users"
  }

  site_config {
    always_on = true
    application_stack {
      docker {
        registry_url = "https://index.docker.io"
        image_name   = "cangelosilima/sanduba-costumer-api"
        image_tag    = "latest"
      }
    }
  }

  virtual_network_subnet_id = data.azurerm_subnet.api_subnet.id

  tags = {
    environment = azurerm_resource_group.resource_group.tags["environment"]
  }
}

data "azurerm_storage_account" "log_storage_account" {
  name                = "sandubalog"
  resource_group_name = var.main_resource_group
}

data "azurerm_log_analytics_workspace" "log_workspace" {
  name                = "fiap-tech-challenge-observability-workspace"
  resource_group_name = data.azurerm_storage_account.log_storage_account.resource_group_name
}

resource "azurerm_monitor_diagnostic_setting" "function_monitor" {
  name                       = "fiap-tech-challenge-costumer-monitor"
  target_resource_id         = azurerm_linux_function_app.linux_function.id
  storage_account_id         = data.azurerm_storage_account.log_storage_account.id
  log_analytics_workspace_id = data.azurerm_log_analytics_workspace.log_workspace.id

  enabled_log {
    category = "FunctionAppLogs"
  }

  metric {
    category = "AllMetrics"
  }
}

output "sanduba_costumer_database_connection_string" {
  sensitive = true
  value     = "Server=tcp:${azurerm_mssql_server.sqlserver.fully_qualified_domain_name},1433;Initial Catalog=${azurerm_mssql_database.sanduba_costumer_database.name};Persist Security Info=False;User ID=${random_uuid.sqlserver_user.result};Password=${random_password.sqlserver_password.result};MultipleActiveResultSets=False;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30;"
}

output "sanduba_costumer_auth_key" {
  sensitive = true
  value     = random_uuid.auth_secret_key.result
}

output "sanduba_costumer_url" {
  sensitive = false
  value     = "https://${azurerm_linux_function_app.linux_function.default_hostname}/api"
}