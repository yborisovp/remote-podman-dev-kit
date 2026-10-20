#!/usr/bin/env python3
"""Exercise real terminal input and first-run navigation without a Linux server."""
import os
import fcntl
import termios
from pathlib import Path
import pty
import select
import shutil
import subprocess
import tempfile
import time

KIT = Path(__file__).resolve().parents[1]

class Terminal:
    def __init__(self, project, command=None):
        self.master, slave = pty.openpty()
        def attach_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        self.proc = subprocess.Popen(command or ['bash', str(project / 'dev.sh')], stdin=slave,
                                     stdout=slave, stderr=slave, preexec_fn=attach_terminal,
                                     env={**os.environ, 'TERM': 'xterm', 'NO_COLOR': '1'})
        os.close(slave)
        self.buffer = b''
    def send(self, value):
        time.sleep(.1)
        self.buffer = b''
        while select.select([self.master], [], [], 0)[0]:
            os.read(self.master, 65536)
        os.write(self.master, value.encode())
    def expect(self, value):
        target = value.encode()
        deadline = time.monotonic() + 5
        while target not in self.buffer and time.monotonic() < deadline:
            if select.select([self.master], [], [], .1)[0]:
                try:
                    self.buffer += os.read(self.master, 65536)
                except OSError:
                    break
        assert target in self.buffer, (value, self.buffer.decode(errors='replace'))
        self.buffer = self.buffer.split(target, 1)[1]
    def close(self):
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(timeout=5)
        os.close(self.master)

with tempfile.TemporaryDirectory(prefix='podman-ui-') as tmp:
    project = Path(tmp) / 'kit'
    shutil.copytree(KIT, project)
    config = project / 'config/dev.env'
    config.unlink(missing_ok=True)
    help_result = subprocess.run(['bash', str(project / 'dev.sh'), '--help'], capture_output=True)
    assert help_result.returncode == 0 and not config.exists()
    term = Terminal(project)
    try:
        term.expect('WELCOME')
        term.send('2\n')
        term.expect('Configuration missing')
        term.expect('Enter to return')
        term.send('\n')
        term.expect('WELCOME')
        term.send('\x1b[B\x1b[A\n')  # Arrow navigation returns to Server setup.
        term.expect('Full installation')
        term.send('q')
        term.expect('WELCOME')
        term.send('q')
        assert term.proc.wait(timeout=5) == 0
        assert not config.exists()
    finally:
        term.close()

    # Replace only the server-mutating setup boundary to verify routing and reload.
    (project / 'setup.sh').write_text('''#!/usr/bin/env bash
printf 'MOCK full setup: %s\\n' "$1"
sed 's/PODMAN_HOST=.*/PODMAN_HOST=test-user@mock-host/' "$(dirname "$0")/config/dev.env" > "$(dirname "$0")/config/new.env"
mv "$(dirname "$0")/config/new.env" "$(dirname "$0")/config/dev.env"
''')
    term = Terminal(project)
    try:
        term.expect('WELCOME')
        term.send('\n')
        term.expect('Full installation')
        term.send('\n')
        term.expect('MOCK full setup: full')
        term.expect('Enter to return')
        term.send('\n')
        term.expect('Full installation')
        term.send('q')
        term.expect('test-user@mock-host')
        term.send('q')
        assert term.proc.wait(timeout=5) == 0
    finally:
        term.close()
    term = Terminal(project, ['bash', '-c', 'source "$1/lib/ui.sh"; SERVICE_NAMES=(worker database); SERVICE_LPORTS=("8000,8001" "-"); ui_select_services && printf "RESULT:%s\\n" "${SELECTED[*]}"', 'bash', str(project)])
    try:
        term.expect('SERVICES / select one or more')
        term.send('1\n')
        term.expect('[x] worker')
        term.send('n\n')
        term.expect('[ ] worker')
        term.send('2\n')
        term.expect('[x] database')
        term.send('\n')
        term.expect('RESULT:database')
        assert term.proc.wait(timeout=5) == 0
    finally:
        term.close()
print('PASS: first run, help without config, failure recovery, arrows, setup routing, config reload, service toggles and cancel')
