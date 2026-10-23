# Build in AWS, export once, import into OCI

This is the full boot-disk migration workflow requested for the replacement lab.
The previous website-file migration is historical and its resources were removed.
This workflow builds Ubuntu once in AWS. OCI receives the exported AWS disk; it
does not run a second Packer build.

```text
Ubuntu on AWS -> Packer provisions and reboots -> AWS AMI
  -> VM Import/Export creates a VMDK in private S3
  -> download VMDK -> upload to private OCI Object Storage
  -> read back and compare SHA-256
  -> import VMDK as an OCI custom image
  -> add E5 shape compatibility -> launch -> verify OS, packages, config and database
```

The captured disk includes Ubuntu, nginx, packages, system configuration, a SQLite
database and website files. AWS VPCs, IAM, public IP addresses and managed services
are configured separately. This lab uses one boot disk; additional data disks
need their own migration process.

## Prerequisites

Use local AWS and OCI CLI profiles; never upload their secret keys into an image.
Install Terraform and Packer on the operator computer. The image provisioners run
inside the temporary Ubuntu builder, so Windows does not require WSL or Ansible.
The Python orchestration helper uses the cloud CLIs and the standard library.

AWS VM Import/Export requires unencrypted EBS snapshots. This lab creates a fresh,
disposable staging disk with no real credentials or production data. It does not
change account-wide encryption defaults. The export S3 bucket uses SSE-S3 and
blocks public access; transfers use TLS. The OCI bucket is also private and uses
OCI's default encryption at rest.

The Ubuntu builder uses a BIOS-only t2.small instance. Preparation installs a
generic kernel, virtio drivers, BIOS GRUB, DHCP, and Oracle/Ec2 cloud-init discovery.
It removes the alternate EFI boot files only from this newly created lab disk.
It then reboots and verifies the source before capture. There is no partition-table
conversion. The build log and source report record the observed disk layout.

## 1. Create AWS export infrastructure

Set `region` and `admin_cidr` in an ignored variable file under
`terraform/full-image/aws`. The address must be the operator's public IPv4 /32.
Run `terraform init`, `terraform validate`, then create and inspect a saved plan.
Apply that plan. Save `terraform output -json` to
`.artifacts/full-image-aws-outputs.json`.

The module creates a dedicated VPC, subnet, internet route, restricted security
group, private SSE-S3 bucket, and VM Import/Export service role. Its trust policy
uses the documented vmimport external ID, source account and VMIE source ARN.
The role grants bucket access only for this export and EC2 permissions in the
configured region. Caller permissions must also permit ExportImage and PassRole.

## 2. Build one portable image in AWS

Use `packer/full-image/image.pkr.hcl`. Supply `region`, a current Canonical Ubuntu
24.04 x86_64 non-Marketplace source AMI, the created subnet/security group, and a
unique `build_version` through an ignored Packer variable file.

```powershell
packer init packer/full-image
packer validate -var-file=packer/full-image/lab.pkrvars.hcl packer/full-image
packer build -on-error=abort -var-file=packer/full-image/lab.pkrvars.hcl packer/full-image
```

The builder creates proof files in `/opt/migration-proof`,
`/etc/migration-proof`, `/var/lib/migration-proof`, and the web root. The source
report contains hashes, selected installed package versions and database records.
Packer downloads it before cleaning cloud-init identity and SSH keys for capture.
The manifest records the resulting AWS AMI. Reading its ID selects an image;
it does not transfer that image.

With `-on-error=abort`, a failed build can leave the temporary instance and key
pair available for diagnosis. Inspect and remove those resources after repair.

## 3. Export the AMI as VMDK

```powershell
python scripts/full-image/pipeline.py start-export
python scripts/full-image/pipeline.py status
python scripts/full-image/pipeline.py wait-export
```

The helper checks that the AMI is private, belongs to the current account, has no
product codes, and contains exactly one unencrypted EBS disk. It requests VMDK
export into `exports/` in the dedicated S3 bucket and saves the export task ID.
When Packer inherits `uefi-preferred` AMI metadata, the helper registers the same
owned snapshot with explicit `legacy-bios` metadata after checking the source BIOS
boot report. It records both AMI IDs and their shared snapshot. No disk is rebuilt.
Run `status` until AWS reports `completed`. An accepted request alone does not
mean the image is exportable; inspect the final status and error message.
`wait-export` polls every 30 seconds for up to 30 minutes, stops on a terminal
failure, and preserves the task on timeout so it can be inspected and resumed.

## 4. Create the OCI destination and transfer the disk

Set `region`, `compartment_ocid`, `availability_domain`, `admin_cidr`,
`ssh_public_key` and `build_version` under `terraform/full-image/oci`.
Leave `object_name` empty and `launch_instance` false for the first plan/apply.
This creates the private bucket and test network. Save its JSON outputs to
`.artifacts/full-image-oci-outputs.json`.

```powershell
python scripts/full-image/pipeline.py transfer
```

The helper downloads the completed export, checks its size, computes SHA-256,
uploads it with multipart checksum verification, downloads the OCI object again,
and compares full-file SHA-256. The transfer report records both matching digests
and the exact object name. Set AWS_EXE and OCI_EXE to explicit CLI paths if needed.
The helper defaults to `us-west-1` and `us-phoenix-1`; set `AWS_REGION` and
`OCI_CLI_REGION` to match Terraform if using different regions.

## 5. Import the AWS disk and launch it in OCI

Set `object_name` to the transfer report's `oci_object_name` and keep
`launch_instance` false. Plan, inspect and apply. Terraform imports that VMDK as an
Ubuntu 24.04 custom image in paravirtualized mode and adds E5 shape compatibility.
Wait for the custom image to become Available.

Then set `launch_instance` true. Plan and apply again to launch a 1 OCPU, 4 GB
VM.Standard.E5.Flex test VM using the imported image. The public SSH key is supplied
through OCI metadata; the original private key remains on the operator computer.

## 6. Validate the entire migration

Wait for cloud-init to finish. Run `scripts/full-image/verify-target.py` using
Python on the OCI VM. It compares the original file hashes, nginx/SQLite/kernel
package versions and database records; checks BIOS and the generic kernel; reads
OCI's authenticated instance metadata; and checks nginx and HTTP.

Save the JSON output to `.artifacts/full-image-target-report.json`. Validate HTTP
from the operator computer as well, using `http://<new-oci-ip>/`. This lab has no
HTTPS listener or certificate. Do not reuse the old deleted lab's IP addresses.

Only report the migration as passed after the imported instance boots and all
checks pass. Preserve the transfer/source/target reports as evidence.
For example, from PowerShell after supplying your SSH key path:

```powershell
$ociIp = terraform -chdir=terraform/full-image/oci output -raw public_ip
$sshKey = 'path/to/your/private-key'
ssh -i $sshKey "ubuntu@$ociIp" 'sudo cloud-init status --wait'
Get-Content scripts/full-image/verify-target.py -Raw |
  ssh -i $sshKey "ubuntu@$ociIp" 'sudo python3 -' |
  Set-Content .artifacts/full-image-target-report.json -Encoding utf8
python scripts/full-image/finalize.py
```

Run `python scripts/full-image/finalize.py` on the operator computer. It compares
the target evidence with the original AWS report stored outside the VM, confirms
the OCI instance matches Terraform, and checks the public HTTP response against
the original AWS page hash. The final result is `.artifacts/full-image-result.json`.

## Costs and cleanup

The builder, validation VM, public IPv4 address, EBS/OCI boot disks, image storage,
S3/Object Storage requests and outbound transfer can incur charges. There is no
NAT gateway or load balancer in this lab. Delete temporary builders after capture
and remove validation resources and retained artifacts when finished.

Destroy the OCI instance/imported image before its bucket, remove the retained
objects, and destroy both Terraform environments. Deregister the captured AWS
AMI and delete its owned snapshot separately; Packer artifacts are not Terraform
resources. Delete local VMDKs only after confirming the intended paths and whether
the migration evidence should be retained. Never delete a source VM or image
needed for a migration until the destination is verified.

For a longer-lived image factory, add S3 access logging, CloudTrail data events
and CloudWatch metrics, and OCI audit/monitoring appropriate to its retention and
cost requirements.

## References

- [Original OCI distribution approach](https://www.linkedin.com/pulse/build-once-import-everywhere-golden-image-across-oci-regions-adewumi-itfhc/)
- [AWS image export constraints](https://docs.aws.amazon.com/vm-import/latest/userguide/limits-image-export.html)
- [AWS VM Import/Export permissions](https://docs.aws.amazon.com/vm-import/latest/userguide/required-permissions.html)
- [OCI custom Linux image requirements](https://docs.oracle.com/en-us/iaas/Content/Compute/Tasks/importingcustomimagelinux.htm)
