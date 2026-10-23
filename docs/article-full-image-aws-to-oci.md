# Build Once in AWS, Import Into OCI: Moving an Ubuntu Server as a Golden Image

**Lab validated October 22, 2026:** AWS build, VMDK export, transfer integrity,
OCI image import, VM boot and application checks all passed.

## Introduction

My earlier image distribution project used a simple idea: build a golden image
once, export it, and import it where it is needed. For this project, I wanted to
extend that approach across cloud providers, using AWS as the source and Oracle
Cloud Infrastructure as the destination.

The aim is to move the server's captured boot disk: Ubuntu, installed software,
application configuration, website files and local database data together. The
workflow does not build a separate OCI version of the server and then copy its
website. OCI launches an image imported from the AWS disk export.

The original [OCI image distribution article](https://www.linkedin.com/pulse/build-once-import-everywhere-golden-image-across-oci-regions-adewumi-itfhc/)
provides the starting pattern. The cross-cloud version adds an AWS export stage
and prepares the operating system for the destination's boot and device requirements.

## Objectives

- Build and test one Ubuntu 24.04 x86_64 golden image in AWS.
- Capture an AMI and export its boot disk as a VMDK.
- Transfer the exported file into private OCI Object Storage.
- Verify the transfer using a complete-file SHA-256 comparison.
- Import the VMDK as an OCI custom image and launch a compute instance.
- Verify the original configuration, installed packages, database records and HTTP service.

The lab uses a single boot disk. VPCs, VCNs, security rules, IAM and public IP
addresses are cloud resources and are created separately. Additional disks and
external managed services require their own migration plans.

## Architecture

```text
Windows operator computer
  | local AWS and OCI CLI profiles
  +-- Packer -> temporary Ubuntu builder in AWS
                 | provision -> reboot -> verify -> capture
                 v
               AWS AMI
                 | AWS VM Import/Export
                 v
               private S3 bucket / exported VMDK
                 | TLS download and upload; SHA-256 readback comparison
                 v
               private OCI Object Storage bucket
                 | import VMDK in paravirtualized mode
                 v
               OCI custom image -> OCI compute VM -> validation
```

Packer runs from Windows and executes shell provisioners inside its temporary
Ubuntu instance. This avoids depending on a working WSL installation. API signing
keys and AWS credentials remain on the operator computer.

## Get the sample code

The complete sample project is available in the
[AWS to OCI golden image repository](https://github.com/Johnadewumi25/aws-to-oci-golden-image).
You can clone it or select **Code → Download ZIP** on GitHub:

```powershell
git clone https://github.com/Johnadewumi25/aws-to-oci-golden-image.git
cd aws-to-oci-golden-image
```

Start with the repository's
[reader setup guide](https://github.com/Johnadewumi25/aws-to-oci-golden-image/blob/main/docs/sample-code.md).
It explains how to create your local variable files, save the Terraform outputs
used by the helper, and follow the build, export, transfer, import and validation
steps. Use your own accounts, SSH key, region settings and resource identifiers.

| Sample code | What it does |
| --- | --- |
| `packer/full-image/image.pkr.hcl` | Builds, reboots and captures the AWS image |
| `scripts/full-image/prepare.sh` | Prepares Ubuntu, drivers, nginx and SQLite |
| `terraform/full-image/aws/main.tf` | Creates AWS networking, export storage and the export role |
| `scripts/full-image/pipeline.py` | Exports the AMI, transfers the VMDK and compares SHA-256 |
| `terraform/full-image/oci/main.tf` | Creates OCI storage/network, imports the image and launches the VM |
| `scripts/full-image/verify-target.py` | Verifies the imported server from inside OCI |
| `scripts/full-image/finalize.py` | Compares the results with the original AWS evidence |

The sample is MIT licensed. It includes example variables and validation tests;
credentials, private keys, Terraform state, deployed resource IDs and the exported
VM disk are excluded. This is a reproducible lab with billable cloud resources.

## Prerequisites

The operator needs working AWS and OCI CLI profiles, Terraform, Packer, Python and
OpenSSH. Cloud permissions must cover the lab's networking, compute, images and
object storage. AWS also needs a VM Import/Export service role and permission for
the caller to pass it to that service.

The source must be eligible for AWS export. AWS cannot export encrypted EBS
snapshots or Marketplace-derived images through this workflow. The fresh lab
therefore uses a plain Ubuntu base and an unencrypted staging boot disk containing
only demonstration data. It leaves account-wide encryption settings unchanged.
The S3 export bucket uses SSE-S3; OCI Object Storage uses encryption at rest. Both
buckets block public access.

AWS also disallows a hybrid BIOS/UEFI GRUB export configuration. OCI's Linux custom
image guidance calls for BIOS boot, a supported boot loader, DHCP and appropriate
paravirtualized drivers. These requirements shape the source preparation.

## Task 1: Create the export and destination infrastructure

The AWS Terraform environment creates an isolated VPC and subnet, an internet
route, a security group and a private S3 bucket. Inbound SSH and HTTP are limited
to the operator's public IPv4 /32.

The export role trusts `vmie.amazonaws.com` using the documented external ID,
source-account and source-ARN conditions. Bucket permissions are restricted to
the dedicated export location. The role policy was checked using AWS IAM Access
Analyzer's policy validator, which returned no findings.

The OCI environment first creates its private Object Storage bucket and test
network. It does not launch a compute instance until an imported image is available.

Terraform plans are inspected before apply. Local variables, state files and API
keys stay outside the source package.

## Task 2: Prepare one portable Ubuntu server in AWS

The Packer template uses a BIOS-only EC2 instance type and a current Canonical
Ubuntu 24.04 AMD64 base. Its provisioner installs nginx, SQLite and a generic
Ubuntu kernel with virtio support.

It configures BIOS GRUB, prepares the initramfs, removes the alternate EFI boot
files from this disposable lab disk, and replaces provider-specific interface
settings with DHCP. Cloud-init is prepared to discover Oracle or EC2 metadata on
the next launch. The partition table is not rewritten.

The server contains four useful migration checks:

- An origin document under `/opt/migration-proof` identifying the AWS build.
- An application configuration file under `/etc/migration-proof`.
- A SQLite database under `/var/lib/migration-proof` with a record created in AWS.
- A web page served by nginx from the web root.

These checks make the distinction between a website copy and a disk migration
visible. Configuration and database files outside the web directory must survive
with the website.

## Task 3: Reboot, verify and capture the AWS image

Before capture, Packer reboots the builder. The source check requires BIOS mode,
a running generic kernel, successful nginx HTTP access and valid application data.
It records package versions, database rows and SHA-256 hashes in a source report.

The tested source ran `6.8.0-147-generic`. Its package report included nginx,
SQLite, cloud-init and the generic-kernel package. Packer downloaded the report,
cleaned cloud-init identity and SSH keys, captured the AMI, and removed its
temporary builder and key pair.

```powershell
packer build -on-error=abort -var-file=packer/full-image/lab.pkrvars.hcl packer/full-image
```

An AMI ID in the manifest identifies the AWS artifact. Reading the ID is not the
transfer step. The disk still needs to be exported and imported.

The Canonical base's `uefi-preferred` registration can be inherited by CreateImage
even after a verified BIOS boot. Where needed, the helper registers the same owned
snapshot with explicit `legacy-bios` metadata. It records both IDs and the shared
snapshot; this creates no second operating-system build.

## Task 4: Export the captured disk into S3

```powershell
python scripts/full-image/pipeline.py start-export
python scripts/full-image/pipeline.py status
```

Before export, the helper checks account ownership, privacy, product codes, disk
count and encryption. The export request uses VMDK and the dedicated role and S3
prefix. AWS performs the conversion asynchronously.

Wait for a final `completed` status. A task ID means AWS accepted the request;
it does not prove that export succeeded. A failed task must be diagnosed before
continuing to transfer or import.

## Task 5: Transfer the exact VMDK into OCI

```powershell
python scripts/full-image/pipeline.py transfer
```

The helper downloads the completed AWS export, verifies its size and calculates
SHA-256. It uploads the file into the private OCI bucket with upload checksum
verification. Then it downloads the OCI object again and compares the entire
file's SHA-256 with the AWS download.

This readback check avoids treating a multipart ETag as a full-file checksum.
The transfer report ties together the AWS image, export task, S3 object, OCI object,
byte count and matching digests.

## Task 6: Import the AWS disk as an OCI image

Set the destination Terraform environment's `object_name` to the verified object's
name. Keep `launch_instance` false during import. Terraform creates a custom image
from that private Object Storage object using VMDK and paravirtualized launch mode.

After the image becomes Available, add the intended AMD shape to its compatibility
list. The lab uses `VM.Standard.E5.Flex`. Set `launch_instance` true, inspect the
next plan and apply it to launch a 1 OCPU, 4 GB validation VM.

The new public SSH key is supplied through OCI metadata. No private key is baked
into the disk. The imported system receives a new cloud identity and IP address.

## Task 7: Prove that the imported server works

Run `scripts/full-image/verify-target.py` on the OCI VM. It requires matching
configuration and application file hashes, matching selected package versions,
and the original SQLite records. It also checks BIOS mode, the generic kernel,
nginx and local HTTP access.

The check reads OCI's authenticated instance metadata to confirm the target is an
OCI instance. The AWS origin document remains unchanged: it records where the
disk was built, while metadata identifies where it is now running.

Finally, test HTTP from the operator computer using the new OCI address. The lab
uses plain HTTP for its smoke test; HTTPS requires a listener and certificate.

The source, transfer and target reports are the evidence for the final result.
The migration is complete only when the imported VM boots and the checks pass.

## Validation results

The imported AWS disk booted successfully on OCI. The destination ran Ubuntu
24.04.5 LTS with the same `6.8.0-147-generic` kernel, and cloud-init identified
`DataSourceOracle` and completed without errors.

| Check | Observed result |
| --- | --- |
| AWS build | Packer completed in 12 minutes 50 seconds |
| Export format | Stream-optimized VMDK, 16 GiB virtual disk |
| Exported file | 11,528,035,840 bytes |
| Transfer integrity | AWS download and OCI readback SHA-256 identical |
| OCI image import | Available; BIOS and paravirtualized devices |
| OCI instance | E5 Flex, 1 OCPU, 4 GB RAM |
| Configuration and application files | All four recorded hashes matched |
| Selected installed packages | cloud-init, linux-generic, nginx and sqlite3 versions matched |
| Database | Original AWS-created SQLite record present and unchanged |
| Website | Local and external HTTP passed; content hash matched AWS |
| Export guard tests | Nine passed |

The complete exported-file digest was:

```text
e4243e108ff8ed83f1a3e0dc7a638ea626f7a9fb511ce27a67b712d9b072f6ab
```

The final check compared the OCI results with the original AWS report stored on
the operator computer. It also matched OCI metadata to the instance created by
Terraform. That preserves a clear evidence chain from the AWS build to the
running OCI server, including files outside the website directory.

## Cleanup and cost control

Temporary compute, public IPv4 addresses, disks, snapshots, image storage, object
requests and outbound transfer can incur charges. Packer removes its successful
temporary builder. Terraform manages the destination instance, imported image,
storage bucket and networks.

The captured AWS AMIs and snapshot require separate cleanup because Packer created
them. If two AMI registrations reference one snapshot, deregister both before
deleting that snapshot. Empty the export buckets before destroying them, and
retain the validation reports separately from large disk files.

For a recurring image factory, add access logging, CloudTrail data events,
CloudWatch metrics and appropriate OCI audit/monitoring and retention policies.

## Further reading

- [AWS image export limitations](https://docs.aws.amazon.com/vm-import/latest/userguide/limits-image-export.html)
- [AWS VM Import/Export service permissions](https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html)
- [AWS export-image command](https://docs.aws.amazon.com/cli/latest/reference/ec2/export-image.html)
- [OCI custom Linux image requirements](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimagelinux.htm)
- [Detailed project walkthrough](full-image-migration.md)
