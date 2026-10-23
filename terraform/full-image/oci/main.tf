terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    oci = { source = "oracle/oci", version = "~> 7.0" }
  }
}
provider "oci" {
  region              = var.region
  config_file_profile = "DEFAULT"
}
variable "region" { type = string }
variable "compartment_ocid" { type = string }
variable "availability_domain" { type = string }
variable "admin_cidr" { type = string }
variable "ssh_public_key" { type = string }
variable "object_name" {
  type    = string
  default = ""
}
variable "build_version" { type = string }
variable "launch_instance" {
  type    = bool
  default = false
}
locals { tags = { Project = "aws-oci-full-image" } }
data "oci_objectstorage_namespace" "current" { compartment_id = var.compartment_ocid }
resource "oci_objectstorage_bucket" "images" {
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.current.namespace
  name           = "aws-full-image-${var.build_version}"
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  freeform_tags  = local.tags
}
module "network" {
  source              = "../../oci"
  region              = var.region
  compartment_ocid    = var.compartment_ocid
  availability_domain = var.availability_domain
  admin_cidr          = var.admin_cidr
}
resource "oci_core_image" "imported" {
  count          = var.object_name == "" ? 0 : 1
  compartment_id = var.compartment_ocid
  display_name   = "aws-exported-ubuntu-${var.build_version}"
  launch_mode    = "PARAVIRTUALIZED"
  image_source_details {
    source_type              = "objectStorageTuple"
    namespace_name           = data.oci_objectstorage_namespace.current.namespace
    bucket_name              = oci_objectstorage_bucket.images.name
    object_name              = var.object_name
    source_image_type        = "VMDK"
    operating_system         = "Ubuntu"
    operating_system_version = "24.04"
  }
  freeform_tags = merge(local.tags, { OriginCloud = "AWS" })
  timeouts { create = "90m" }
}
resource "oci_core_shape_management" "e5" {
  count          = var.object_name == "" ? 0 : 1
  compartment_id = var.compartment_ocid
  image_id       = oci_core_image.imported[0].id
  shape_name     = "VM.Standard.E5.Flex"
}
resource "oci_core_instance" "target" {
  count               = var.launch_instance ? 1 : 0
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = "aws-disk-imported-to-oci"
  shape               = "VM.Standard.E5.Flex"
  shape_config {
    ocpus         = 1
    memory_in_gbs = 4
  }
  source_details {
    source_type             = "image"
    source_id               = oci_core_image.imported[0].id
    boot_volume_size_in_gbs = 50
  }
  create_vnic_details {
    subnet_id        = module.network.packer_network.subnet_ocid
    assign_public_ip = true
    hostname_label   = "imported"
  }
  metadata = { ssh_authorized_keys = var.ssh_public_key }
  instance_options { are_legacy_imds_endpoints_disabled = true }
  preserve_boot_volume = false
  freeform_tags        = local.tags
  depends_on           = [oci_core_shape_management.e5]
}
output "bucket" { value = oci_objectstorage_bucket.images.name }
output "namespace" { value = data.oci_objectstorage_namespace.current.namespace }
output "image_id" { value = try(oci_core_image.imported[0].id, null) }
output "public_ip" { value = try(oci_core_instance.target[0].public_ip, null) }
output "instance_id" { value = try(oci_core_instance.target[0].id, null) }
