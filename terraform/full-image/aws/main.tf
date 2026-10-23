terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}
provider "aws" { region = var.region }
variable "region" { type = string }
variable "admin_cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && can(regex("/32$", var.admin_cidr))
    error_message = "Use your current IPv4 address with /32."
  }
}
data "aws_caller_identity" "current" {}
locals { tags = { Project = "aws-oci-full-image" } }
resource "aws_vpc" "lab" {
  cidr_block           = "10.50.0.0/16"
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "aws-oci-full-image" })
}
resource "aws_subnet" "lab" {
  vpc_id     = aws_vpc.lab.id
  cidr_block = "10.50.1.0/24"
  tags       = local.tags
}
resource "aws_internet_gateway" "lab" {
  vpc_id = aws_vpc.lab.id
  tags   = local.tags
}
resource "aws_route_table" "lab" {
  vpc_id = aws_vpc.lab.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.lab.id
  }
  tags = local.tags
}
resource "aws_route_table_association" "lab" {
  subnet_id      = aws_subnet.lab.id
  route_table_id = aws_route_table.lab.id
}
resource "aws_security_group" "lab" {
  name_prefix = "aws-oci-full-image-"
  vpc_id      = aws_vpc.lab.id
  dynamic "ingress" {
    for_each = toset([22, 80])
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = [var.admin_cidr]
    }
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}
resource "aws_s3_bucket" "export" {
  bucket_prefix = "aws-oci-disk-export-"
  tags          = local.tags
}
resource "aws_s3_bucket_public_access_block" "export" {
  bucket                  = aws_s3_bucket.export.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "export" {
  bucket = aws_s3_bucket.export.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_s3_bucket_policy" "tls" {
  bucket = aws_s3_bucket.export.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect    = "Deny", Principal = "*", Action = "s3:*",
    Resource  = [aws_s3_bucket.export.arn, "${aws_s3_bucket.export.arn}/*"],
    Condition = { Bool = { "aws:SecureTransport" = "false" } }
  }] })
}
resource "aws_iam_role" "vmexport" {
  name_prefix = "aws-oci-vmexport-"
  assume_role_policy = jsonencode({ Version = "2012-10-17", Statement = [{
    Effect = "Allow", Principal = { Service = "vmie.amazonaws.com" }, Action = "sts:AssumeRole",
    Condition = {
      StringEquals = { "sts:Externalid" = "vmimport", "aws:SourceAccount" = data.aws_caller_identity.current.account_id },
      ArnLike      = { "aws:SourceArn" = "arn:aws:vmie:*:${data.aws_caller_identity.current.account_id}:*" }
    }
  }] })
  tags = local.tags
}
resource "aws_iam_role_policy" "vmexport" {
  role = aws_iam_role.vmexport.id
  policy = jsonencode({ Version = "2012-10-17", Statement = [
    { Effect = "Allow", Action = ["s3:GetBucketLocation", "s3:ListBucket", "s3:GetBucketAcl"], Resource = aws_s3_bucket.export.arn },
    # VMIE validates write access using its own probe keys before writing exports/.
    { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = "${aws_s3_bucket.export.arn}/*" },
    { Effect = "Allow", Action = ["ec2:DescribeImages", "ec2:DescribeSnapshots", "ec2:DescribeVolumes", "ec2:DescribeInstances"], Resource = "*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
    { Effect = "Allow", Action = ["ec2:ModifySnapshotAttribute", "ec2:CopySnapshot"], Resource = "arn:aws:ec2:${var.region}::snapshot/*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } },
    { Effect = "Allow", Action = "ec2:RegisterImage", Resource = "arn:aws:ec2:${var.region}::image/*", Condition = { StringEquals = { "aws:RequestedRegion" = var.region } } }
  ] })
}
output "build" {
  value = { region = var.region, subnet_id = aws_subnet.lab.id, security_group_id = aws_security_group.lab.id }
}
output "export_bucket" { value = aws_s3_bucket.export.id }
output "export_role" { value = aws_iam_role.vmexport.name }
