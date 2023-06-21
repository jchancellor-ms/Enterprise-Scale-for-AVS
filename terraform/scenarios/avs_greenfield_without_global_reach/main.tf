# Create local variable derived from an input prefix or modify for customer naming
locals {
  #update naming convention with target naming convention if different
  private_cloud_rg_name = "${var.prefix}-PrivateCloud-${random_string.namestring.result}"
  sddc_name             = "${var.prefix}-AVS-SDDC-${random_string.namestring.result}"

  network_rg_name = "${var.prefix}-Network-${random_string.namestring.result}"

  expressroute_authorization_key_name = "${var.prefix}-AVS-ExpressrouteAuthKey-${random_string.namestring.result}"
  express_route_connection_name       = "${var.prefix}-AVS-ExpressrouteConnection-${random_string.namestring.result}"
  expressroute_pip_name               = "${var.prefix}-AVS-expressroute-gw-pip-${random_string.namestring.result}"
  expressroute_gateway_name           = "${var.prefix}-AVS-expressroute-gw-${random_string.namestring.result}"

  virtual_hub_name_transit     = ""
  virtual_hub_pip_name_transit = ""
  route_server_name_transit    = ""



  service_health_alert_name = "${var.prefix}-AVS-service-health-alert-${random_string.namestring.result}"
  action_group_name         = "${var.prefix}-AVS-action-group-${random_string.namestring.result}"
  action_group_shortname    = "avs-sddc-sh"
}


#Create the private cloud resource group
resource "azurerm_resource_group" "greenfield_privatecloud" {
  name     = local.private_cloud_rg_name
  location = var.region
}

#Create the Network objects resource group
resource "azurerm_resource_group" "greenfield_network" {
  name     = local.network_rg_name
  location = var.region
}

#Create the AVS Private Cloud
#deploy a private cloud with a single management cluster and connect to the expressroute gateway
module "avs_private_cloud" {
  source = "../../modules/avs_private_cloud_single_management_cluster_no_internet_conn"

  sddc_name                           = local.sddc_name
  sddc_sku                            = var.sddc_sku
  management_cluster_size             = var.management_cluster_size
  rg_name                             = azurerm_resource_group.greenfield_privatecloud.name
  rg_location                         = azurerm_resource_group.greenfield_privatecloud.location
  avs_network_cidr                    = var.avs_network_cidr
  expressroute_authorization_key_name = local.expressroute_authorization_key_name
  internet_enabled                    = false
  hcx_enabled                         = var.hcx_enabled
  hcx_key_names                       = var.hcx_key_names
  tags                                = var.tags
  module_telemetry_enabled            = false
}

#deploy the AVS transit hub resources
### deploy the Virtual Network with subnets for RouteServer, ExpressRouteGateway, RoutingNVAFront, RoutingNVABack
module "avs_virtual_network" {
  source = "../../modules/avs_vnet_variable_subnets"

  rg_name                  = azurerm_resource_group.greenfield_network.name
  rg_location              = azurerm_resource_group.greenfield_network.location
  vnet_name                = local.vnet_name_transit_hub
  vnet_address_space       = var.vnet_address_space_transit_hub
  subnets                  = var.subnets_transit_hub
  tags                     = var.tags
  module_telemetry_enabled = false
}

### deploy the user defined routes and routing entries
#create routing NVA fw-facing route table
#bgp route propogation disabled
#Routes for each firewall subnet next-hop to firewall
resource "azurerm_route_table" "nva_fw_facing_subnet" {
  name                          = "avs_hub_nva_fwd_route_table"
  location                      = module.avs.network_rg_location
  resource_group_name           = module.avs.network_rg_name
  disable_bgp_route_propagation = true
  tags                          = local.cloud_tags
}

#add firewall hub routes to the route table directing traffic to the firewall (with the exception of the route server)
resource "azurerm_route" "nva_fw_facing_subnet_routes" {
  for_each               = { for subnet in var.subnets_transit_hub : subnet.name => subnet if subnet.name != "RouteServerSubnet" }
  name                   = each.value.name
  resource_group_name    = azurerm_resource_group.greenfield_network.name
  route_table_name       = azurerm_resource_group.greenfield_network.location
  address_prefix         = each.value.address_prefix[0]
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.firewall_internal_vip
}
#add a default route directing traffic to the firweall
resource "azurerm_route" "nva_fw_facing_subnet_default_route" {
  name                   = "default"
  resource_group_name    = azurerm_resource_group.greenfield_network.name
  route_table_name       = azurerm_route_table.nva_fw_facing_subnet.name
  address_prefix         = "0.0.0.0/0"
  next_hop_type          = "VirtualAppliance"
  next_hop_in_ip_address = var.firewall_internal_vip
}

resource "azurerm_subnet_route_table_association" "nva_fw_facing_subnet" {
  subnet_id      = module.avs_virtual_network_transit.subnet_ids["FwFacingSubnet"].id
  route_table_id = azurerm_route_table.nva_fw_facing_subnet.id
}

### deploy the ExpressRoute Gateway
module "avs_expressroute_gateway" {
  source = "../../modules/avs_expressroute_gateway"

  expressroute_pip_name           = local.expressroute_pip_name
  expressroute_gateway_name       = local.expressroute_gateway_name
  expressroute_gateway_sku        = var.expressroute_gateway_sku
  rg_name                         = azurerm_resource_group.greenfield_network.name
  rg_location                     = azurerm_resource_group.greenfield_network.location
  gateway_subnet_id               = module.avs_virtual_network_transit.subnet_ids["GatewaySubnet"].id
  express_route_connection_name   = local.express_route_connection_name
  express_route_id                = module.avs_private_cloud.sddc_express_route_id
  express_route_authorization_key = module.avs_private_cloud.sddc_express_route_authorization_key
  module_telemetry_enabled        = false
}
########################################################################################################
### Deploy the two CSR 8000v's
module "create_cisco_csr8000_pair" {
  source = "../../avs-terraform/modules/avs_nva_cisco_1000v"

  rg_name                  = azurerm_resource_group.greenfield_network.name
  rg_location              = azurerm_resource_group.greenfield_network.location
  asn                      = "65111"
  router_id                = "65.1.1.1"
  fw_ars_ips               = module.on-prem.ars_peer_ips
  avs_ars_ips              = module.avs.ars_peer_ips
  csr_fw_facing_subnet_gw  = "172.26.10.81"
  csr_avs_facing_subnet_gw = "172.26.10.65"
  avs_network_subnet       = "172.25.0.0"
  avs_network_mask         = "255.255.252.0"
  node0_name               = "csr-node0"
  node1_name               = "csr-node1"
  fw_facing_subnet_id      = module.avs.subnet_ids["FwFacingSubnet"].id
  avs_facing_subnet_id     = module.avs.subnet_ids["AvsFacingSubnet"].id
  keyvault_id              = module.avs.keyvault_id
  avs_hub_replacement_asn  = "65222"
  fw_hub_replacement_asn   = "65333"
}

#deploy a routeserver to the transit hub vnet
module "avs_routeserver" {
  source = "../../modules/avs_routeserver"

  rg_name                = azurerm_resource_group.greenfield_network.name
  rg_location            = azurerm_resource_group.greenfield_network.location
  virtual_hub_name       = local.virtual_hub_name_transit
  virtual_hub_pip_name   = local.virtual_hub_pip_name_transit
  route_server_name      = local.route_server_name_transit
  route_server_subnet_id = module.avs_virtual_network_transit.subnet_ids["RouteServerSubnet"].id
}

#create bgp connections to the Cisco routing NVA's
resource "azurerm_virtual_hub_bgp_connection" "avs_hub_csr_rs_conn_0" {
  name           = "avs-rs-csr-bgp-connection-0"
  virtual_hub_id = module.avs.virtual_hub_id
  peer_asn       = module.create_cisco_csr8000_pair.asn
  peer_ip        = module.create_cisco_csr8000_pair.csr0_avs_facing_ip
}

resource "azurerm_virtual_hub_bgp_connection" "avs_hub_csr_rs_conn_1" {
  name           = "avs-rs-csr-bgp-connection-1"
  virtual_hub_id = module.avs.virtual_hub_id
  peer_asn       = module.create_cisco_csr8000_pair.asn
  peer_ip        = module.create_cisco_csr8000_pair.csr1_avs_facing_ip
}

#Create the Primary Vnet Hub for AVS
module "avs_virtual_network" {
  source = "../../modules/avs_vnet_variable_subnets"

  rg_name                  = azurerm_resource_group.greenfield_network.name
  rg_location              = azurerm_resource_group.greenfield_network.location
  vnet_name                = local.vnet_name
  vnet_address_space       = var.vnet_address_space
  subnets                  = var.subnets
  tags                     = var.tags
  module_telemetry_enabled = false
}

#Create a route server in the hub/spoke
module "avs_routeserver" {
  source = "../../modules/avs_routeserver"

  rg_name                = azurerm_resource_group.greenfield_network.name
  rg_location            = azurerm_resource_group.greenfield_network.location
  virtual_hub_name       = local.virtual_hub_name
  virtual_hub_pip_name   = local.virtual_hub_pip_name
  route_server_name      = local.route_server_name
  route_server_subnet_id = module.avs_hub_virtual_network.subnet_ids["RouteServerSubnet"].id
}

#create BGP peerings from firewall hub route server to CSR 
#create routeserver peering
resource "azurerm_virtual_hub_bgp_connection" "fw_hub_csr_rs_conn_0" {
  name           = "firewall-rs-csr-bgp-connection-0"
  virtual_hub_id = module.on-prem.virtual_hub_id
  peer_asn       = module.create_cisco_csr8000_pair.asn
  peer_ip        = module.create_cisco_csr8000_pair.csr0_fw_facing_ip
}

resource "azurerm_virtual_hub_bgp_connection" "fw_hub_csr_rs_conn_1" {
  name           = "firewall-rs-csr-bgp-connection-1"
  virtual_hub_id = module.on-prem.virtual_hub_id
  peer_asn       = module.create_cisco_csr8000_pair.asn
  peer_ip        = module.create_cisco_csr8000_pair.csr1_fw_facing_ip
}

resource "azurerm_route_table" "firewall_hub_gateway" {
  name                          = "firewall_hub_route_table"
  location                      = module.on-prem.network_rg_location
  resource_group_name           = module.on-prem.network_rg_name
  disable_bgp_route_propagation = false

  route {
    name           = "avs-route"
    address_prefix = module.avs.avs_network_cidr
    next_hop_type  = "VirtualAppliance"
    #next_hop_in_ip_address = module.deploy_firewall.firewall_private_ip_address
    next_hop_in_ip_address = module.avs_azure_firewall.firewall_private_ip_address
  }

  tags = local.cloud_tags
}
