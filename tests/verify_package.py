#!/usr/bin/env python3
"""Verify the distributable, including execution after extraction outside the repo."""
import hashlib
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile

archive = Path(sys.argv[1]).resolve()
expected_files = {
    'dev.sh', 'setup.sh', 'lib/ui.sh', 'lib/compose_remote.py',
    'config/dev.env.example', 'config/required-endpoints.conf',
    'README.md', 'README.RU.md', '.gitignore',
}
with tarfile.open(archive, 'r:gz') as bundle:
    files = {member.name for member in bundle if member.isfile()}
    assert files == {'remote-dev/' + name for name in expected_files}, files
    for member in bundle.getmembers():
        assert member.name == 'remote-dev' or member.name.startswith('remote-dev/')
        assert '..' not in Path(member.name).parts
        assert member.isdir() or member.isfile(), member.name
    for script in ('dev.sh', 'setup.sh'):
        assert bundle.getmember('remote-dev/' + script).mode & 0o111
    with tempfile.TemporaryDirectory(prefix='release-unpack-') as folder:
        bundle.extractall(folder)
        kit = Path(folder) / 'remote-dev'
        result = subprocess.run([str(kit / 'dev.sh'), '--help'], cwd=folder,
                                check=True, capture_output=True, text=True)
        assert 'Remote Podman' in result.stdout
        assert not (kit / 'config/dev.env').exists()
        assert not (kit / '.runtime').exists()
checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
archive.with_name(archive.name + '.sha256').write_text(f'{checksum}  {archive.name}\n')
print('PASS: release file allowlist, permissions, unpacked launcher and SHA-256')
