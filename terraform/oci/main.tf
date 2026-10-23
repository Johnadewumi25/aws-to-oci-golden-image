terraform {
  required_version = ">= 1.10.0, < 2.0.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.0"
    }
  }
}
provider "oci" {
  region              = var.region
  config_file_profile = var.oci_profile
}
variable "region" { type = string }
variable "admin_cidr" {
  type        = string
  description = "Your build runner's current public IPv4 address with /32."
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && can(regex("/32$", var.admin_cidr))
    error_message = "Specify a single IPv4 address as a /32 CIDR."
  }
}
variable "image_id" {
  type        = string
  default     = ""
  description = "Empty creates only the build network; set a golden image ID to launch the web VM."
}
variable "additional_admin_cidrs" {
  type        = list(string)
  default     = []
  description = "Additional single-host public IPv4 CIDRs for the Linux runner."
  validation {
    condition     = alltrue([for cidr in var.additional_admin_cidrs : can(cidrhost(cidr, 0)) && can(regex("/32$", cidr))])
    error_message = "Each additional address must be a single IPv4 /32 CIDR."
  }
}
variable "ssh_public_key" {
  type        = string
  default     = ""
  description = "Public OpenSSH key for the test VM. Never supply a private key."
}
variable "migration_ssh_public_key" {
  type        = string
  default     = ""
  description = "Optional public SSH key generated on the Linux migration runner."
  validation {
    condition     = var.migration_ssh_public_key == "" || can(regex("^ssh-(ed25519|rsa) ", var.migration_ssh_public_key))
    error_message = "Provide an OpenSSH public key, or leave empty."
  }
}

variable "compartment_ocid" { type = string }
variable "availability_domain" { type = string }
variable "oci_profile" {
  type    = string
  default = "DEFAULT"
}
variable "shape" {
  type    = string
  default = "VM.Standard.E5.Flex"
}
resource "oci_core_vcn" "lab" {
  compartment_id = var.compartment_ocid
  cidr_blocks    = ["10.40.0.0/16"]
  display_name   = "aws-oci-lab"
  dns_label      = "awstocilab"
  freeform_tags  = { Project = "aws-oci-lab" }
}
resource "oci_core_internet_gateway" "lab" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "aws-oci-lab"
  enabled        = true
  freeform_tags  = { Project = "aws-oci-lab" }
}
resource "oci_core_route_table" "lab" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "aws-oci-lab"
  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.lab.id
  }
  freeform_tags = { Project = "aws-oci-lab" }
}
resource "oci_core_security_list" "web" {
  compartment_id = var.compartment_ocid
  vcn_id         = oci_core_vcn.lab.id
  display_name   = "aws-oci-lab"
  dynamic "ingress_security_rules" {
    for_each = { for rule in setproduct(toset(concat([var.admin_cidr], var.additional_admin_cidrs)), toset([22, 80])) : "${rule[0]}:${rule[1]}" => rule }
    content {
      protocol    = "6"
      source      = ingress_security_rules.value[0]
      source_type = "CIDR_BLOCK"
      stateless   = false
      tcp_options {
        min = ingress_security_rules.value[1]
        max = ingress_security_rules.value[1]
      }
    }
  }
  egress_security_rules {
    protocol         = "all"
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    stateless        = false
  }
  freeform_tags = { Project = "aws-oci-lab" }
}
resource "oci_core_subnet" "lab" {
  compartment_id             = var.compartment_ocid
  vcn_id                     = oci_core_vcn.lab.id
  cidr_block                 = "10.40.1.0/24"
  display_name               = "aws-oci-lab"
  dns_label                  = "web"
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_route_table.lab.id
  security_list_ids          = [oci_core_security_list.web.id]
  freeform_tags              = { Project = "aws-oci-lab" }
}
resource "oci_core_instance" "web" {
  count               = var.image_id == "" ? 0 : 1
  availability_domain = var.availability_domain
  compartment_id      = var.compartment_ocid
  display_name        = "oci-target-web"
  shape               = var.shape
  shape_config {
    ocpus         = 1
    memory_in_gbs = 4
  }
  create_vnic_details {
    subnet_id        = oci_core_subnet.lab.id
    assign_public_ip = true
    hostname_label   = "web"
  }
  source_details {
    source_type             = "image"
    source_id               = var.image_id
    boot_volume_size_in_gbs = 50
  }
  metadata = { ssh_authorized_keys = join("\n", compact([var.ssh_public_key, var.migration_ssh_public_key])) }
  instance_options { are_legacy_imds_endpoints_disabled = true }
  preserve_boot_volume = false
  freeform_tags        = { Project = "aws-oci-lab" }
  lifecycle {
    precondition {
      condition     = can(regex("^ssh-(ed25519|rsa) ", var.ssh_public_key))
      error_message = "Provide an OpenSSH public key when image_id is set."
    }
  }
}
output "packer_network" {
  value = {
    region              = var.region
    compartment_ocid    = var.compartment_ocid
    availability_domain = var.availability_domain
    subnet_ocid         = oci_core_subnet.lab.id
  }
}
output "public_ip" { value = try(oci_core_instance.web[0].public_ip, null) }
output "instance_id" { value = try(oci_core_instance.web[0].id, null) }
