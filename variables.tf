variable "resource_group_name" {
    type = string
    default = "cka-rg"
}

variable "location" {
    type = string
    default = "West US 3"
}

variable "vnet_name" {
    type = string
    default = "cka-vnet"
}

variable "vnet_cidr" {
    type = string
    default = "10.10.0.0/16"
}

variable "vm_size" {
    type = string
    default = "Standard_B2ms"
}

variable "admin_username" {
    type = string
    default = "heather"
}


