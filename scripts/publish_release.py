#!/usr/bin/env python3
"""Publish a successful CI artifact; never execute code from a PR build."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

from release_version import next_version, stable_version


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def gh_json(*args):
    return json.loads(command('gh', *args))


def publish():
    run = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())['workflow_run']
    repo = os.environ['GH_REPO']
    if run['repository']['full_name'] != repo or run['conclusion'] != 'success':
        raise RuntimeError('Unexpected workflow source or conclusion')
    sha = run['head_sha']
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise RuntimeError('Invalid source commit')
    prerelease = run['event'] == 'pull_request'
    # Retrieve metadata from GitHub, never from the downloaded build artifact.
    source = gh_json('api', f'repos/{repo}/actions/runs/{run["id"]}')
    if source['head_sha'] != sha or source['run_attempt'] != run['run_attempt']:
        raise RuntimeError('Workflow run no longer matches the event')
    if prerelease:
        pulls = source['pull_requests']
        if not pulls:
            # GitHub can omit the pull_requests array for fork builds.
            pulls = gh_json('api', f'repos/{repo}/commits/{sha}/pulls')
        pulls = [gh_json('api', f'repos/{repo}/pulls/{p["number"]}') for p in pulls]
        pulls = [p for p in pulls if p['base']['repo']['full_name'] == repo
                 and p['base']['ref'] == 'main' and p['head']['sha'] == sha]
        if len(pulls) != 1:
            raise RuntimeError('Cannot uniquely associate build with a PR into main')
        number = pulls[0]['number']
        tag = f'pr-{number}-build-{run["id"]}-{run["run_attempt"]}'
        title = f'PR #{number} — build {run["id"]}.{run["run_attempt"]}'
        previous = None
    else:
        if run['head_branch'] != 'main' or run['event'] not in ('push', 'workflow_dispatch'):
            raise RuntimeError('Stable releases must originate from main')
        main_sha = gh_json('api', f'repos/{repo}/git/ref/heads/main')['object']['sha']
        if sha != main_sha:
            print('A newer main commit exists; skipping superseded build.')
            return
        # Git tags, not release dates or prereleases, define the stable baseline.
        command('git', 'fetch', 'origin', 'main', '--tags')
        tags = command('git', 'tag', '--merged', sha).splitlines()
        stable = [(stable_version(t), t) for t in tags if stable_version(t)]
        previous = max(stable)[1] if stable else None
        exact = [t for _, t in stable if command('git', 'rev-list', '-n', '1', t) == sha]
        if exact:
            tag = max(exact, key=stable_version)
        else:
            revision = f'{previous}..{sha}' if previous else sha
            messages = command('git', 'log', '--format=%B', revision)
            tag = next_version(stable_version(previous) if previous else (0, 0, 0), messages)
        title = f'{tag} — Remote Podman Dev Kit'

    archive = Path('dist/remote-dev.tar.gz')
    if not archive.is_file():
        raise RuntimeError('Missing verified archive')
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    # Compute our own digest: uploaded checksum text is untrusted for PR builds.
    checksum_path = archive.with_name(archive.name + '.sha256')
    checksum_path.write_text(f'{checksum}  {archive.name}\n')
    existing = subprocess.run(['gh', 'release', 'view', tag, '--json', 'isDraft,targetCommitish'],
                              capture_output=True, text=True)
    if existing.returncode == 0:
        release = json.loads(existing.stdout)
        if not release['isDraft']:
            print(f'Release {tag} is already published; leaving it unchanged.')
            return
        if release['targetCommitish'] != sha:
            raise RuntimeError('Existing draft targets a different commit')
        subprocess.run(['gh', 'release', 'upload', tag, str(archive), str(checksum_path), '--clobber'], check=True)
    else:
        notes = (f'Source commit: `{sha}`\n\n'
                 f'Verified CI run: https://github.com/{repo}/actions/runs/{run["id"]}\n\n'
                 'Download **remote-dev.tar.gz**, unpack into your repository and run '
                 '`./remote-dev/dev.sh`. The archive contains a single movable `remote-dev/` folder. '
                 'Use the attached SHA-256 file to verify the download.\n\n'
                 'Validation: Ubuntu and macOS smoke tests, terminal UI tests, unit tests, '
                 'and unpacked archive checks. Real Debian installation is not covered by CI.\n')
        if prerelease:
            notes = ('PR preview build; not a stable release. Only use builds from contributors you trust.\n\n' + notes)
        with tempfile.TemporaryDirectory() as folder:
            notes_file = Path(folder) / 'notes.md'
            notes_file.write_text(notes)
            args = ['gh', 'release', 'create', tag, str(archive), str(checksum_path),
                    '--draft', '--target', sha, '--title', title, '--notes-file', str(notes_file)]
            if prerelease:
                args.append('--prerelease')
            else:
                args.append('--generate-notes')
                if previous and previous != tag:
                    args.extend(['--notes-start-tag', previous])
            subprocess.run(args, check=True)
    # Publishing follows upload, so a stable release never appears without its files.
    subprocess.run(['gh', 'release', 'edit', tag, '--draft=false',
                    '--latest=false' if prerelease else '--latest'], check=True)
    print(f'Published https://github.com/{repo}/releases/tag/{tag}')


if __name__ == '__main__':
    publish()
