# Full AWS disk-image migration: validation record

Validated October 22, 2026, Pacific time. This record covers the new full boot-disk
migration, independently of the previous website-file lab.

## Result

**Passed:** one Ubuntu disk was built and captured in AWS, exported as VMDK,
transferred to OCI Object Storage, imported as an OCI custom image, and booted on
an OCI E5 Flex instance. No second OCI operating-system build was performed.

| Stage | Evidence |
| --- | --- |
| AWS build | Packer successful; temporary builder and key pair removed |
| Source boot | BIOS; Ubuntu generic kernel 6.8.0-147-generic; nginx HTTP successful |
| Capture | One 16 GiB unencrypted EBS snapshot; BIOS AMI registration references the same captured snapshot |
| AWS export | Native VM Import/Export task completed |
| VMDK | Header confirmed streamOptimized; 11,528,035,840-byte file; 16 GiB virtual capacity |
| Storage | Private SSE-S3 bucket and private OCI Object Storage bucket |
| Transfer | Full OCI readback SHA-256 identical to AWS download |
| OCI import | Succeeded in 11m49s; image Available; BIOS; paravirtualized storage/network |
| Target launch | E5 Flex, 1 OCPU / 4 GB; created in 45 seconds |
| Target OS | Ubuntu 24.04.5 LTS; kernel 6.8.0-147-generic |
| Initialization | DataSourceOracle; cloud-init done; no errors or recoverable errors |
| Files | All four source hashes matched, including configuration and SQLite files outside the web root |
| Software | cloud-init, linux-generic, nginx and sqlite3 package versions matched |
| Database | Original AWS-created row matched |
| HTTP | nginx active; local HTTP passed; external HTTP 200 and original content hash matched |
| Identity | OCI instance metadata matched the Terraform-created instance |

VMDK SHA-256:

```text
e4243e108ff8ed83f1a3e0dc7a638ea626f7a9fb511ce27a67b712d9b072f6ab
```

## Source checks

Nine full-image guard tests passed: foreign/public/Marketplace image rejection,
single-disk enforcement, encrypted/pending image rejection, BIOS alias snapshot
matching, terminal export failure handling, and bounded export wait behavior.
Terraform configuration validation and formatting passed. Packer syntax and
formatting passed, followed by the real successful AWS build. Terraform provider
checksums were obtained from the official registry for Windows and Linux.

The GitHub Actions workflow was updated for these sources; no remote CI run or
production certification is claimed.

## Local evidence

- `.artifacts/full-image-source-report.json`
- `.artifacts/full-image-packer.log`
- `.artifacts/full-image-bios-image.json`
- `.artifacts/full-image-export-status.json`
- `.artifacts/full-image-transfer-report.json`
- `.artifacts/full-image-oci-image-status.json`
- `.artifacts/full-image-target-report.json`
- `.artifacts/full-image-result.json`
- `.artifacts/full-image-os-facts.txt`

The final result reports `passed`. Its independent checks compare the target with
the original AWS source report stored outside the imported VM, and verify the
public HTTP response. Credential files and private keys are excluded from these
reports and from the source-only sample package.

The OCI VM and retained cloud artifacts remain available and can incur charges.
See [the migration walkthrough](full-image-migration.md) for cleanup boundaries.
