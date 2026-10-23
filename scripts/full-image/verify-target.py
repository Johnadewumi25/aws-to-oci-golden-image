#!/usr/bin/env python3
"""Run on the imported OCI VM. Compare captured application data with AWS proof."""
import hashlib
import json
from pathlib import Path
import platform
import sqlite3
import subprocess
import urllib.request

source = json.loads(Path('/opt/migration-proof/source-report.json').read_text())
actual = {name: hashlib.sha256(Path(name).read_bytes()).hexdigest() for name in source['sha256']}
request = urllib.request.Request('http://169.254.169.254/opc/v2/instance/',
                                 headers={'Authorization': 'Bearer Oracle'})
with urllib.request.urlopen(request, timeout=10) as response:
    metadata = json.load(response)
with urllib.request.urlopen('http://127.0.0.1/', timeout=10) as response:
    http_status = response.status
packages = subprocess.check_output(['dpkg-query', '-W', '-f=${Package}=${Version}\n',
                                   'nginx', 'sqlite3', 'cloud-init', 'linux-generic'], text=True).splitlines()
rows = sqlite3.connect('/var/lib/migration-proof/application.db').execute('SELECT * FROM records').fetchall()
cloud_init = subprocess.run(['cloud-init', 'status', '--format', 'json'],
                            capture_output=True, text=True)
try:
    cloud_init_status = json.loads(cloud_init.stdout)
except json.JSONDecodeError:
    cloud_init_status = {'status': 'unknown', 'output': cloud_init.stdout, 'error': cloud_init.stderr}
checks = {'captured_files_identical': actual == source['sha256'],
          'packages_identical': packages == source['packages'],
          'database_records_identical': [list(row) for row in rows] == source['database_rows'],
          'generic_kernel_running': platform.release().endswith('-generic'),
          'bios_boot': not Path('/sys/firmware/efi').exists(),
          'oci_instance_metadata': metadata.get('id', '').startswith('ocid1.instance.'),
          'cloud_init_completed': cloud_init.returncode == 0 and cloud_init_status.get('status') == 'done',
          'http_ok': http_status == 200,
          'nginx_active': subprocess.run(['systemctl', 'is-active', '--quiet', 'nginx']).returncode == 0}
result = {'passed': all(checks.values()), 'checks': checks, 'kernel': platform.release(),
          'original_aws_build': source['origin'], 'oci_instance_id': metadata.get('id'),
          'sha256': actual, 'packages': packages, 'database_rows': rows,
          'cloud_init': cloud_init_status}
print(json.dumps(result, indent=2))
raise SystemExit(0 if result['passed'] else 1)
