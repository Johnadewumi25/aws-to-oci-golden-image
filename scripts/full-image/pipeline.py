#!/usr/bin/env python3
"""Export one owned AWS boot image and transfer its exact VMDK to OCI.

Uses locally authenticated CLIs. No credentials are copied to cloud instances.
Infrastructure and OCI image/instance lifecycle are managed by Terraform.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
ART = ROOT / '.artifacts'


def read(name):
    return json.loads((ART / name).read_text(encoding='utf-8-sig'))


def save(name, value):
    path = ART / name
    path.write_text(json.dumps(value, indent=2) + '\n', encoding='utf-8')
    return path


def run(args):
    result = subprocess.run([str(x) for x in args], check=True, capture_output=True, text=True)
    return json.loads(result.stdout) if result.stdout.strip() else {}


def aws(*args):
    return run([os.environ.get('AWS_EXE', 'aws'), *args, '--profile', 'default',
                '--region', os.environ.get('AWS_REGION', 'us-west-1'), '--output', 'json', '--no-cli-pager'])


def oci(*args):
    return run([os.environ.get('OCI_EXE', 'oci'), *args, '--profile', 'DEFAULT',
                '--region', os.environ.get('OCI_CLI_REGION', 'us-phoenix-1')])


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def start_export():
    manifest = read('full-image-aws-manifest.json')
    build = next(b for b in reversed(manifest['builds'])
                 if b['custom_data'].get('purpose') == 'export-same-disk-to-OCI')
    image_id = build['artifact_id'].split(':')[-1]
    image = aws('ec2', 'describe-images', '--image-ids', image_id)['Images'][0]
    account = aws('sts', 'get-caller-identity')['Account']
    if image['OwnerId'] != account or image.get('Public'):
        raise ValueError('Export requires a private AMI owned by this account.')
    if image.get('ProductCodes'):
        raise ValueError('Marketplace/product-coded images are not eligible for this lab.')
    disks = [b['Ebs'] for b in image['BlockDeviceMappings'] if 'Ebs' in b]
    if len(disks) != 1:
        raise ValueError('This workflow migrates exactly one boot disk; handle data disks separately.')
    snapshots = aws('ec2', 'describe-snapshots', '--snapshot-ids', disks[0]['SnapshotId'])['Snapshots']
    if any(s['Encrypted'] for s in snapshots):
        raise ValueError('AWS cannot export an encrypted EBS image. Refusing export.')
    if image['State'] != 'available':
        raise ValueError('Wait for Packer and the AMI snapshot to become available.')
    # CreateImage inherits the Canonical base's uefi-preferred registration even
    # when the prepared OS was verified in BIOS. Register the SAME owned snapshot
    # with explicit BIOS metadata; this does not rebuild or convert its bytes.
    if image.get('BootMode') != 'legacy-bios':
        proof = read('full-image-source-report.json')
        if proof['boot_mode'] != 'BIOS' or proof['origin']['build_version'] != build['custom_data']['version']:
            raise ValueError('A matching, successful BIOS boot report is required.')
        name = image['Name'] + '-bios'
        existing = aws('ec2', 'describe-images', '--owners', 'self', '--filters', f'Name=name,Values={name}')['Images']
        if existing:
            candidate = existing[0]
            candidate_disks = [b['Ebs']['SnapshotId'] for b in candidate['BlockDeviceMappings'] if 'Ebs' in b]
            if candidate.get('BootMode') != 'legacy-bios' or candidate_disks != [disks[0]['SnapshotId']]:
                raise ValueError('An existing BIOS alias does not reference the expected disk.')
            image_id = candidate['ImageId']
        else:
            registration = {'Name': name, 'Architecture': 'x86_64', 'VirtualizationType': 'hvm',
                            'RootDeviceName': image['RootDeviceName'], 'BootMode': 'legacy-bios',
                            'EnaSupport': True, 'ImdsSupport': 'v2.0',
                            'BlockDeviceMappings': [{'DeviceName': image['RootDeviceName'],
                                                     'Ebs': {'SnapshotId': disks[0]['SnapshotId'],
                                                             'DeleteOnTermination': True, 'VolumeType': 'gp3'}}],
                            'TagSpecifications': [{'ResourceType': 'image', 'Tags': image.get('Tags', [])}]}
            registration_path = save('full-image-bios-registration.json', registration)
            image_id = aws('ec2', 'register-image', '--cli-input-json', 'file://' + str(registration_path))['ImageId']
        image = aws('ec2', 'describe-images', '--image-ids', image_id)['Images'][0]
        save('full-image-bios-image.json', {'packer_image_id': build['artifact_id'].split(':')[-1],
                                         'export_image_id': image_id, 'same_snapshot_id': disks[0]['SnapshotId']})
    outputs = read('full-image-aws-outputs.json')
    request = {
        'ClientToken': f"aws-oci-full-image-{build['custom_data']['version']}",
        'Description': 'Single AWS-built Ubuntu disk for OCI import',
        'DiskImageFormat': 'VMDK', 'ImageId': image_id,
        'RoleName': outputs['export_role']['value'],
        'S3ExportLocation': {'S3Bucket': outputs['export_bucket']['value'], 'S3Prefix': 'exports/'},
        'TagSpecifications': [{'ResourceType': 'export-image-task',
                               'Tags': [{'Key': 'Project', 'Value': 'aws-oci-full-image'}]}],
    }
    path = save('full-image-export-request.json', request)
    result = aws('ec2', 'export-image', '--cli-input-json', 'file://' + str(path))
    save('full-image-export-task.json', result)
    save('full-image-aws-image.json', image)
    return result


def status():
    task_id = read('full-image-export-task.json')['ExportImageTaskId']
    result = aws('ec2', 'describe-export-image-tasks', '--export-image-task-ids', task_id)['ExportImageTasks'][0]
    save('full-image-export-status.json', result)
    return result


def wait_export(timeout=1800, interval=30):
    deadline = time.monotonic() + timeout
    previous = None
    while True:
        task = status()
        current = (task['Status'], task.get('Progress'), task.get('StatusMessage'))
        if current != previous:
            print(f'Export status: {current}', file=sys.stderr, flush=True)
            previous = current
        if task['Status'] == 'completed':
            return task
        if task['Status'] != 'active':
            raise ValueError(f"Export failed: {task['Status']} {task.get('StatusMessage', '')}")
        if time.monotonic() >= deadline:
            raise ValueError('Export wait timed out; task is preserved. Inspect status before continuing.')
        time.sleep(interval)


def transfer():
    task = status()
    if task['Status'] != 'completed':
        raise ValueError(f"Export is not completed: {task['Status']} {task.get('StatusMessage', '')}")
    bucket = task['S3ExportLocation']['S3Bucket']
    # AWS writes <prefix><export-task-id>.vmdk. Discover the actual completed object.
    listing = aws('s3api', 'list-objects-v2', '--bucket', bucket, '--prefix', 'exports/')
    objects = [o for o in listing.get('Contents', [])
               if task['ExportImageTaskId'] in o['Key'] and o['Key'].endswith('.vmdk')]
    if len(objects) != 1:
        raise ValueError('Expected exactly one VMDK for the completed export task.')
    obj = objects[0]
    target = ART / Path(obj['Key']).name
    print(f"Downloading AWS VMDK ({obj['Size']} bytes).", file=sys.stderr, flush=True)
    subprocess.run([os.environ.get('AWS_EXE', 'aws'), 's3', 'cp',
                    f"s3://{bucket}/{obj['Key']}", str(target), '--profile', 'default',
                    '--region', os.environ.get('AWS_REGION', 'us-west-1'), '--no-progress'], check=True)
    if target.stat().st_size != obj['Size']:
        raise ValueError('Downloaded VMDK size does not match S3.')
    digest = sha256(target)
    outputs = read('full-image-oci-outputs.json')
    name = 'images/' + target.name
    metadata = save('full-image-object-metadata.json', {'sha256': digest, 'source-export-task': task['ExportImageTaskId']})
    print('Uploading the VMDK into private OCI Object Storage.', file=sys.stderr, flush=True)
    result = oci('os', 'object', 'put', '--namespace-name', outputs['namespace']['value'],
                 '--bucket-name', outputs['bucket']['value'], '--name', name, '--file', str(target),
                 '--metadata', 'file://' + str(metadata), '--verify-checksum', '--no-overwrite')
    save('full-image-upload-result.json', result)
    # Read the OCI object back and compare a full-file digest independently of multipart ETags.
    verify_path = ART / ('oci-verify-' + target.name)
    print('Reading back the OCI object for full-file SHA-256 comparison.', file=sys.stderr, flush=True)
    oci('os', 'object', 'get', '--namespace-name', outputs['namespace']['value'],
        '--bucket-name', outputs['bucket']['value'], '--name', name, '--file', str(verify_path))
    destination_digest = sha256(verify_path)
    if destination_digest != digest:
        raise ValueError('The OCI object is not byte-for-byte identical to the AWS export.')
    report = {'aws_image_id': task['ImageId'], 'export_task_id': task['ExportImageTaskId'],
              's3_bucket': bucket, 's3_key': obj['Key'], 'oci_bucket': outputs['bucket']['value'],
              'oci_object_name': name, 'bytes': target.stat().st_size,
              'source_sha256': digest, 'oci_readback_sha256': destination_digest, 'identical': True}
    save('full-image-transfer-report.json', report)
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start-export', 'status', 'wait-export', 'transfer'])
    args = parser.parse_args()
    try:
        result = {'start-export': start_export, 'status': status, 'wait-export': wait_export, 'transfer': transfer}[args.action]()
        print(json.dumps(result, indent=2))
    except (ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        sys.exit(1)
