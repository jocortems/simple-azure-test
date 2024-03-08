terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.0"
    }

    http = {
      source = "hashicorp/http"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {
    resource_group {
        prevent_deletion_if_contains_resources = false
    }
  }
}

provider "http" {}

data "http" "my_ip" {
  url = "http://ipv4.icanhazip.com"
}

resource "random_string" "prefix" {
  length  = 6
  special = false
  upper   = false
  numeric = false
}

resource "azurerm_resource_group" "rg_name" {
  name = var.resource_group_name
  location = var.location
}

resource "azurerm_virtual_network" "vnet" {
  name                = var.vnet_name
  location            = azurerm_resource_group.rg_name.location
  resource_group_name = azurerm_resource_group.rg_name.name
  address_space       = [var.vnet_cidr]
}

resource "azurerm_subnet" "cka" {
    resource_group_name     = azurerm_resource_group.rg_name.name
    name                    = "k8s-cluster"
    virtual_network_name    = azurerm_virtual_network.vnet.name
    address_prefixes        = [cidrsubnet(azurerm_virtual_network.vnet.address_space[0],8, 1)]
}

resource "azurerm_subnet" "public_vm" {
    resource_group_name     = azurerm_resource_group.rg_name.name
    name                    = "jumpbox"
    virtual_network_name    = azurerm_virtual_network.vnet.name
    address_prefixes        = [cidrsubnet(azurerm_virtual_network.vnet.address_space[0],8, 0)]
}

resource "azurerm_network_security_group" "public_nsg" {
  name                = "public-nsg"
  location            = azurerm_resource_group.rg_name.location
  resource_group_name = azurerm_resource_group.rg_name.name
}

resource "azurerm_network_security_rule" "public_nsg_rule" {
  name                          = "Allow-home"
  priority                      = 100
  direction                     = "Inbound"
  access                        = "Allow"
  protocol                      = "*"
  source_port_range             = "*"
  destination_port_range        = "*"
  source_address_prefixes       = [replace(data.http.my_ip.response_body,"\n","")]  
  destination_address_prefix    = "*"
  resource_group_name           = azurerm_resource_group.rg_name.name
  network_security_group_name   = azurerm_network_security_group.public_nsg.name
}

resource "azurerm_subnet_network_security_group_association" "nsg_public_subnet_attach" {
  subnet_id                 = azurerm_subnet.public_vm.id
  network_security_group_id = azurerm_network_security_group.public_nsg.id
}

resource "azurerm_public_ip" "public_vm_pip" {
  name                      = "jumpboxVM-pip"
  location                  = azurerm_resource_group.rg_name.location
  resource_group_name       = azurerm_resource_group.rg_name.name
  allocation_method         = "Static"
  sku                       = "Standard"
}

resource "azurerm_network_interface" "public_vm_nic" { 
  name                    = "jumpboxVM-nic"
  location                  = azurerm_resource_group.rg_name.location
  resource_group_name       = azurerm_resource_group.rg_name.name
  
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.public_vm.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(azurerm_subnet.public_vm.address_prefixes[0], 10)
    public_ip_address_id          = azurerm_public_ip.public_vm_pip.id
  }
}

resource "azurerm_linux_virtual_machine" "jumpbox_vm" {
  name                      = "jumpboxVM"
  location                  = azurerm_resource_group.rg_name.location
  resource_group_name       = azurerm_resource_group.rg_name.name
  size                      = var.vm_size
  admin_username            = var.admin_username
  network_interface_ids     = [
    azurerm_network_interface.public_vm_nic.id
  ]

  custom_data = base64encode(file("cloud-init.sh"))
  
  disable_password_authentication = true
  admin_ssh_key {
        public_key = file("${path.module}/ssh-key.pub")
        username = var.admin_username
    }
  
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}

resource "azurerm_network_interface" "nic" { 
  count                   = 3
  name                    = format("k8s-nic-%s", count.index)
  location                = azurerm_resource_group.rg_name.location
  resource_group_name     = azurerm_resource_group.rg_name.name  
  enable_ip_forwarding          = true

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.cka.id
    private_ip_address_allocation = "Static"
    private_ip_address            = cidrhost(azurerm_subnet.cka.address_prefixes[0], 10 + count.index)
  }
}

resource "azurerm_linux_virtual_machine" "k8s" {
  count                   = 3
  name                    = count.index == 0 ? "k8s-master" : format("k8s-worker-%s", count.index)
  location                = azurerm_resource_group.rg_name.location
  resource_group_name     = azurerm_resource_group.rg_name.name
  size                    = var.vm_size
  admin_username          = var.admin_username
  network_interface_ids   = [
    azurerm_network_interface.nic[count.index].id
  ]

  disable_password_authentication = true
  admin_ssh_key {
        public_key = file("${path.module}/ssh-key.pub")
        username = var.admin_username
    }
  
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-focal"
    sku       = "20_04-lts-gen2"
    version   = "latest"
  }
}


resource "azurerm_route_table" "pod_cidr" {
  name                    = "k8s-rt"
  location                = azurerm_resource_group.rg_name.location
  resource_group_name     = azurerm_resource_group.rg_name.name

  lifecycle {
    ignore_changes = [route]
  }

  route {
    name                    = "master-node"
    address_prefix          = "172.19.0.0/24"
    next_hop_type           = "VirtualAppliance"
    next_hop_in_ip_address  = azurerm_network_interface.nic[0].ip_configuration[0].private_ip_address
  }

  route {
    name                    = "worker-node-0"
    address_prefix          = "172.19.1.0/24"
    next_hop_type           = "VirtualAppliance"
    next_hop_in_ip_address  = azurerm_network_interface.nic[1].ip_configuration[0].private_ip_address
  }

  route {
    name                    = "worker-node-1"
    address_prefix          = "172.19.2.0/24"
    next_hop_type           = "VirtualAppliance"
    next_hop_in_ip_address  = azurerm_network_interface.nic[2].ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "k8s_rt" {
  subnet_id               = azurerm_subnet.cka.id
  route_table_id          = azurerm_route_table.pod_cidr.id
}

resource "azurerm_subnet_route_table_association" "linuxvm" {
  subnet_id               = azurerm_subnet.public_vm.id
  route_table_id          = azurerm_route_table.pod_cidr.id
}

resource "azurerm_network_security_group" "nsg" {
  name                = "k8s-nsg"
  location                = azurerm_resource_group.rg_name.location
  resource_group_name     = azurerm_resource_group.rg_name.name
}

resource "azurerm_network_security_rule" "nsg_rule" {
  name                        = "Allow-RFC1918"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "*"
  source_port_range           = "*"
  destination_port_range      = "*"
  source_address_prefixes     = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  destination_address_prefixes  = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  resource_group_name         = azurerm_resource_group.rg_name.name
  network_security_group_name = azurerm_network_security_group.nsg.name
}

resource "azurerm_subnet_network_security_group_association" "nsg_k8s_subnet_attach" {
  subnet_id                 = azurerm_subnet.cka.id
  network_security_group_id = azurerm_network_security_group.nsg.id
}

resource "azurerm_storage_account" "flow_logs" {
  name                      	 = format("flowlogs%s", random_string.prefix.result)
  resource_group_name       	 = azurerm_resource_group.rg_name.name
  location                  	 = azurerm_resource_group.rg_name.location
  account_tier              	 = "Standard"
  public_network_access_enabled  = true
  account_replication_type  	 = "LRS"
  min_tls_version           	 = "TLS1_2"
  enable_https_traffic_only 	 = true
}

resource "azurerm_network_watcher_flow_log" "flow_logs" {
  network_watcher_name = format("NetworkWatcher_%s", azurerm_resource_group.rg_name.location)
  resource_group_name  = "NetworkWatcherRG"
  name                 = "cka-log"

  network_security_group_id = azurerm_network_security_group.nsg.id
  storage_account_id        = azurerm_storage_account.flow_logs.id
  enabled                   = true

  retention_policy {
    enabled = true
    days    = 1
  }
}