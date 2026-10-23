#!/bin/bash
set -euo pipefail
test ! -d /sys/firmware/efi
uname -r | grep -- '-generic$'
sudo cloud-init status --wait
curl --fail --silent http://127.0.0.1/ >/dev/null
sudo python3 - <<'PY'
import hashlib,json,pathlib,platform,sqlite3,subprocess
files=['/opt/migration-proof/origin.json','/etc/migration-proof/application.conf','/var/lib/migration-proof/application.db','/var/www/html/index.html']
report={'kernel':platform.release(),'boot_mode':'BIOS','origin':json.loads(pathlib.Path(files[0]).read_text()),'sha256':{p:hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest() for p in files},'packages':subprocess.check_output(['dpkg-query','-W','-f=${Package}=${Version}\n','nginx','sqlite3','cloud-init','linux-generic'],text=True).splitlines(),'database_rows':sqlite3.connect(files[2]).execute('SELECT * FROM records').fetchall(),'block_devices':subprocess.check_output(['lsblk','-o','NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS'],text=True)}
pathlib.Path('/opt/migration-proof/source-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
PY
