# Use the article's sample code

This project reproduces the AWS-built Ubuntu boot-disk migration described in
the [article](article-full-image-aws-to-oci.md). It builds one fresh image in AWS,
exports it as VMDK, transfers and imports that disk into OCI, and verifies the
running server. It does not perform a second OS build in OCI.

## Download and prerequisites

Clone `https://github.com/Johnadewumi25/aws-to-oci-golden-image.git`, or select
**Code → Download ZIP** on the GitHub repository and extract it. Run the following
PowerShell commands from the extracted project's root directory.

Install Git if cloning, AWS CLI v2, OCI CLI, Terraform 1.10 or later but below 2.0,
Packer 1.14 or later but below 2.0, Python 3.10 or later, and OpenSSH. Packer's
Ubuntu provisioners run inside EC2; WSL is not required. Python helpers use the
standard library and authenticated cloud CLIs. Allow at least 30 GB of local free
space for the exported VMDK and its verification download.

Use your own AWS `default` and OCI `DEFAULT` profiles. The helper selects those
profile names explicitly. Keep credentials in your local CLI configuration, and
check access before provisioning:

```powershell
aws sts get-caller-identity --profile default
oci os ns get --profile DEFAULT --region us-phoenix-1
```

The examples use AWS `us-west-1` and OCI `us-phoenix-1`. To change them, update the
variable files and set `AWS_REGION` and `OCI_CLI_REGION` to the same regions.
The account needs permissions for the resources in the Terraform modules and
Packer build, including AWS VM Import/Export and passing its service role.
Cloud resources, image storage and transfers can incur charges.

## Create your local inputs

```powershell
New-Item -ItemType Directory -Force .artifacts/ssh | Out-Null
Copy-Item terraform/full-image/aws/lab.tfvars.example terraform/full-image/aws/lab.auto.tfvars
Copy-Item terraform/full-image/oci/lab.tfvars.example terraform/full-image/oci/lab.auto.tfvars
Copy-Item packer/full-image/lab.example.pkrvars.hcl packer/full-image/lab.pkrvars.hcl
```

Edit the copies; do not run the examples with the placeholder values:

| File | Values to supply |
| --- | --- |
| AWS `lab.auto.tfvars` | Region and your current public IPv4 with `/32` |
| OCI `lab.auto.tfvars` | Region, your compartment OCID, availability domain, the same IPv4 `/32`, your SSH **public** key, and a unique build version |
| Packer `lab.pkrvars.hcl` | AWS region, a current Canonical Ubuntu 24.04 AMD64 non-Marketplace AMI, AWS subnet/security group IDs from the next step, and the same build version |

Leave OCI `object_name = ""` and `launch_instance = false` initially. Terraform
automatically loads the `lab.auto.tfvars` files. The Packer commands pass its
variable file explicitly. These local files and `.artifacts` are ignored by Git.
Keep your SSH private key on your computer and use its path in the validation
commands. Share only the public key through OCI's `ssh_public_key` variable.

The staging EBS disk must be unencrypted for AWS export. Use demonstration data
on this new builder and read the [walkthrough's prerequisites](full-image-migration.md#prerequisites).

## Create AWS infrastructure

```powershell
$env:AWS_PROFILE = 'default'
terraform -chdir=terraform/full-image/aws init
terraform -chdir=terraform/full-image/aws validate
terraform -chdir=terraform/full-image/aws plan -out=lab.tfplan
```

Inspect the plan before applying it:

```powershell
terraform -chdir=terraform/full-image/aws apply lab.tfplan
terraform -chdir=terraform/full-image/aws output -json |
  Set-Content .artifacts/full-image-aws-outputs.json -Encoding utf8
terraform -chdir=terraform/full-image/aws output build
```

Copy the returned subnet and security group IDs into your Packer variable file.
Use a source AMI for your selected AWS region, not an ID from another region.

## Build, capture and export

```powershell
packer init packer/full-image
packer validate -var-file=packer/full-image/lab.pkrvars.hcl packer/full-image
packer build -on-error=abort -var-file=packer/full-image/lab.pkrvars.hcl packer/full-image
python scripts/full-image/pipeline.py start-export
python scripts/full-image/pipeline.py wait-export
```

Packer saves the source report and AMI manifest in `.artifacts`. Wait for export
completion before transferring the file. If a command fails, resolve that error
before continuing to the next stage. An aborted Packer build can retain its
temporary EC2 instance and key pair for diagnosis; remove them when finished.

## Create the OCI destination and transfer

```powershell
terraform -chdir=terraform/full-image/oci init
terraform -chdir=terraform/full-image/oci validate
terraform -chdir=terraform/full-image/oci plan -out=lab.tfplan
```

Inspect and apply the storage/network plan, then save its outputs:

```powershell
terraform -chdir=terraform/full-image/oci apply lab.tfplan
terraform -chdir=terraform/full-image/oci output -json |
  Set-Content .artifacts/full-image-oci-outputs.json -Encoding utf8
python scripts/full-image/pipeline.py transfer
```

The helper uses both saved Terraform output files. It writes a transfer report
to `.artifacts/full-image-transfer-report.json`, including the OCI object name,
file size and matching full-file SHA-256 digests.

## Import, launch and validate

1. Set OCI `object_name` to `oci_object_name` from the transfer report. Keep
   `launch_instance = false`. Repeat the OCI plan, inspect and apply commands to
   import the disk and configure E5 shape compatibility.
2. After the import succeeds, set `launch_instance = true`. Repeat the plan,
   inspect and apply commands to launch the VM.
3. Refresh `.artifacts/full-image-oci-outputs.json` with the OCI output command
   above. The validation helper needs the new instance ID and public IP.
4. Follow [Validate the entire migration](full-image-migration.md#6-validate-the-entire-migration)
   to wait for cloud-init, run `verify-target.py` through SSH, save its JSON report,
   and run `finalize.py` on your computer. All checks must pass.

Your configuration, database records, selected packages and web content should
match the original AWS report. To prove the runtime is OCI, compare the instance
OCID returned by OCI metadata with the one in your Terraform output and OCI Console.
Use HTTP for the sample smoke test; the lab does not configure an HTTPS listener.

## Source files and cleanup

The Packer template is in `packer/full-image`; cloud infrastructure is in
`terraform/full-image`; preparation, export, transfer and verification helpers
are in `scripts/full-image`. `terraform/oci/main.tf` is a shared network module
required by the destination module. Preserve the directory layout when copying.

Run the export guard tests without provisioning cloud resources:

```powershell
python -m unittest discover -s tests -p test_full_image.py -v
```

Read [Costs and cleanup](full-image-migration.md#costs-and-cleanup) before removing
the lab. Packer-created AMIs and snapshots need separate cleanup from Terraform,
and export buckets must be emptied before destruction.

To rebuild the source-only companion ZIP, run
`python scripts/package-full-image.py`. It uses an explicit file allowlist and
creates `.artifacts/aws-to-oci-full-image-sample.zip`. Credentials, local variables,
state, reports, disk images and deployed resource IDs are not part of that archive.

The sample code is available under the [MIT license](../LICENSE).
