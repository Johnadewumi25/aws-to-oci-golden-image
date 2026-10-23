# AWS to OCI: build once, move the boot image

This project prepares one Ubuntu VM in AWS, captures its AMI, exports that disk
as VMDK, transfers it to OCI Object Storage, imports an OCI custom image and
launches it. The OS, installed software, configuration, website and SQLite data
are captured together. Networking and IAM are configured separately.

**Validated October 22, 2026:** the full migration passed. OCI booted the exported
AWS disk with matching package versions, configuration files, SQLite records and
website content. Full-file SHA-256 matched after transfer, and external HTTP passed.

Read the [full image migration walkthrough](docs/full-image-migration.md).
The [completed article](docs/article-full-image-aws-to-oci.md) follows the same approach.
See the [validation record](docs/full-image-validation.md) for completed checks.
The new source lives in `packer/full-image`, `terraform/full-image` and
`scripts/full-image`. Cloud credentials remain in local CLI profiles.

## Get started

```powershell
git clone https://github.com/Johnadewumi25/aws-to-oci-golden-image.git
cd aws-to-oci-golden-image
```

You can also select **Code → Download ZIP** on the repository page.
Follow the [reader setup guide](docs/sample-code.md) to configure your own cloud
profiles, copy the example variables and run each migration stage.
The project uses the [MIT license](LICENSE).

This sample builds a fresh, disposable Ubuntu lab image. Its boot preparation
scripts are intended for that new lab builder. Adapting an existing production
server requires a separate compatibility assessment and migration plan.

## Workflow

1. Plan and create AWS export infrastructure and OCI destination storage/network.
2. Build and reboot one portable Ubuntu image using Packer in AWS.
3. Export its owned, unencrypted snapshot to VMDK using AWS VM Import/Export.
4. Transfer the VMDK to private OCI Object Storage and verify SHA-256 by readback.
5. Import that object as an OCI custom image and launch an E5 Flex VM.
6. Compare OS/kernel, packages, configuration hashes, SQLite rows and HTTP health.

The staging EBS disk is unencrypted because AWS export requires it. Use only lab
data. Both object storage buckets are private and encrypted at rest. Builds,
compute, disks, stored images and transfers can incur charges.

## Validation

```powershell
python -m unittest discover -s tests -p test_full_image.py -v
terraform -chdir=terraform/full-image/aws validate
terraform -chdir=terraform/full-image/oci validate
packer validate -syntax-only packer/full-image
```

Local build/transfer/target evidence is saved under the ignored `.artifacts`
directory. Deployment variables, Terraform state, private keys and disk exports
must stay out of source archives and version control.
