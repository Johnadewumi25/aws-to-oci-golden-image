packer {
  required_version = ">= 1.14, < 2.0"
  required_plugins {
    amazon = { source = "github.com/hashicorp/amazon", version = "= 1.8.3" }
  }
}
variable "region" { type = string }
variable "source_ami_id" { type = string }
variable "subnet_id" { type = string }
variable "security_group_id" { type = string }
variable "build_version" { type = string }
source "amazon-ebs" "portable" {
  region                      = var.region
  source_ami                  = var.source_ami_id
  instance_type               = "t2.small"
  subnet_id                   = var.subnet_id
  security_group_id           = var.security_group_id
  associate_public_ip_address = true
  ssh_interface               = "public_ip"
  ssh_username                = "ubuntu"
  ssh_timeout                 = "15m"
  ami_name                    = "aws-oci-full-image-${var.build_version}"
  encrypt_boot                = false
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 16
    volume_type           = "gp3"
    encrypted             = false
    delete_on_termination = true
  }
  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }
  tags     = { Project = "aws-oci-full-image", BuildVersion = var.build_version, OriginCloud = "AWS" }
  run_tags = { Project = "aws-oci-full-image", Name = "aws-portable-image-builder" }
}
build {
  sources = ["source.amazon-ebs.portable"]
  provisioner "shell" {
    script           = "${path.root}/../../scripts/full-image/prepare.sh"
    environment_vars = ["BUILD_VERSION=${var.build_version}"]
  }
  provisioner "shell" {
    inline            = ["sudo reboot"]
    expect_disconnect = true
  }
  provisioner "shell" {
    pause_before = "30s"
    script       = "${path.root}/../../scripts/full-image/verify-source.sh"
  }
  provisioner "file" {
    direction   = "download"
    source      = "/opt/migration-proof/source-report.json"
    destination = "${path.root}/../../.artifacts/full-image-source-report.json"
  }
  provisioner "shell" {
    script = "${path.root}/../../scripts/clean-image.sh"
  }
  post-processor "manifest" {
    output      = "${path.root}/../../.artifacts/full-image-aws-manifest.json"
    strip_path  = true
    custom_data = { version = var.build_version, source = "AWS", purpose = "export-same-disk-to-OCI" }
  }
}
