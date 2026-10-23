#!/usr/bin/env python3
"""Verify outside-the-VM evidence and the OCI HTTP endpoint before declaring success."""
import hashlib
import ipaddress
import json
from pathlib import Path
import urllib.request

root = Path(__file__).resolve().parents[2]
art = root / '.artifacts'
def read(name):
    return json.loads((art / name).read_text(encoding='utf-8-sig'))

source = read('full-image-source-report.json')
target = read('full-image-target-report.json')
transfer = read('full-image-transfer-report.json')
outputs = read('full-image-oci-outputs.json')
address = str(ipaddress.IPv4Address(outputs['public_ip']['value']))
url = 'http://' + address + '/'
with urllib.request.urlopen(url, timeout=20) as response:
    http_status = response.status
    web_hash = hashlib.sha256(response.read()).hexdigest()
checks = {
    'target_checks_passed': target['passed'] is True,
    'target_matches_original_external_source_hashes': target['sha256'] == source['sha256'],
    'target_matches_original_external_source_packages': target['packages'] == source['packages'],
    'target_matches_original_external_source_database': target['database_rows'] == source['database_rows'],
    'aws_origin_unchanged': target['original_aws_build'] == source['origin'],
    'oci_instance_matches_terraform': target['oci_instance_id'] == outputs['instance_id']['value'],
    'export_file_readback_identical': transfer['identical'] is True and transfer['source_sha256'] == transfer['oci_readback_sha256'],
    'external_http_ok': http_status == 200,
    'external_http_matches_aws_content': web_hash == source['sha256']['/var/www/html/index.html'],
}
result = {'status': 'passed' if all(checks.values()) else 'failed', 'checks': checks,
          'build_version': source['origin']['build_version'], 'aws_image_id': transfer['aws_image_id'],
          'export_task_id': transfer['export_task_id'], 'vmdk_sha256': transfer['source_sha256'],
          'vmdk_bytes': transfer['bytes'], 'oci_image_id': outputs['image_id']['value'],
          'oci_instance_id': outputs['instance_id']['value'], 'website': url,
          'kernel': target['kernel'], 'method': 'one AWS-built boot disk exported and imported into OCI'}
(art / 'full-image-result.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
print(json.dumps(result, indent=2))
raise SystemExit(0 if result['status'] == 'passed' else 1)
