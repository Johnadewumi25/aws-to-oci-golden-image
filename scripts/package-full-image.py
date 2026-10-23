#!/usr/bin/env python3
"""Package the full boot-image workflow from an explicit source allowlist."""
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [
    'README.md', 'LICENSE', '.gitignore', '.gitattributes',
    'docs/sample-code.md', 'docs/full-image-migration.md', 'docs/article-full-image-aws-to-oci.md', 'docs/full-image-validation.md',
    'packer/full-image/image.pkr.hcl', 'packer/full-image/lab.example.pkrvars.hcl',
    'terraform/full-image/aws/main.tf', 'terraform/full-image/aws/lab.tfvars.example',
    'terraform/full-image/aws/.terraform.lock.hcl',
    'terraform/full-image/oci/main.tf', 'terraform/full-image/oci/lab.tfvars.example',
    'terraform/full-image/oci/.terraform.lock.hcl',
    'terraform/oci/main.tf',
    'scripts/full-image/prepare.sh', 'scripts/full-image/verify-source.sh',
    'scripts/full-image/pipeline.py', 'scripts/full-image/verify-target.py', 'scripts/full-image/finalize.py',
    'scripts/clean-image.sh', 'scripts/package-full-image.py', 'tests/test_full_image.py',
]
output = ROOT / '.artifacts/aws-to-oci-full-image-sample.zip'
output.parent.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
    for name in SOURCES:
        data = (ROOT / name).read_bytes()
        info = zipfile.ZipInfo(name)
        info.create_system = 3
        info.external_attr = (0o100000 | (0o755 if name.endswith('.sh') else 0o644)) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, data)
print(f'Created {output.name}: {len(SOURCES)} source files; no deployment data or credentials.')
