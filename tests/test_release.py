"""Release policy and publication boundaries without mutating GitHub."""
import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from release_version import next_version, stable_version
import publish_release


class Versions(unittest.TestCase):
    def test_stable_tags_only(self):
        self.assertEqual(stable_version('v0.1.0'), (0, 1, 0))
        for tag in ('pr-1-build-2-1', 'v1.2.3-rc.1', 'v01.2.3', 'other', 'v1.2'):
            self.assertIsNone(stable_version(tag))

    def test_markers_and_reset(self):
        for message, expected in [('major', 'v2.0.0'), ('minor', 'v1.3.0'),
                                  ('patch', 'v1.2.4'), ('fix login', 'v1.2.4'),
                                  ('PATCH\nminor\n[MAJOR]', 'v2.0.0'),
                                  ('minority report', 'v1.2.4')]:
            with self.subTest(message=message):
                self.assertEqual(next_version((1, 2, 3), message), expected)


class Publisher(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.previous_cwd = os.getcwd()
        os.chdir(self.temporary.name)
        self.addCleanup(os.chdir, self.previous_cwd)
        Path('dist').mkdir()
        Path('dist/remote-dev.tar.gz').write_bytes(b'opaque archive; must not execute')
        self.sha = 'a' * 40
        self.run = {'id': 123, 'run_attempt': 1, 'head_sha': self.sha,
                    'head_branch': 'main', 'event': 'push', 'conclusion': 'success',
                    'repository': {'full_name': 'owner/repo'}, 'pull_requests': []}
        self.env = patch.dict(os.environ, {'GH_REPO': 'owner/repo', 'GITHUB_EVENT_PATH': 'event.json'})
        self.env.start()
        self.addCleanup(self.env.stop)
        self.calls = []
        self.existing = None

    def api(self, *args):
        route = args[-1]
        if '/actions/runs/' in route:
            return self.run
        if '/git/ref/heads/main' in route:
            return {'object': {'sha': self.sha}}
        if '/pulls/9' in route:
            return {'number': 9, 'head': {'sha': self.sha},
                    'base': {'ref': 'main', 'repo': {'full_name': 'owner/repo'}}}
        raise AssertionError(route)

    def command(self, *args):
        if args[:3] == ('git', 'tag', '--merged'):
            return 'v0.1.0\npr-9-build-120-1'
        if args[:3] == ('git', 'rev-list', '-n'):
            return 'b' * 40
        if args[:2] == ('git', 'log'):
            return '[minor] Support SSH aliases'
        if args[:2] == ('git', 'fetch'):
            return ''
        raise AssertionError(args)

    def execute(self, args, **kwargs):
        self.calls.append(args)
        if args[:3] == ['gh', 'release', 'view']:
            return subprocess.CompletedProcess(args, 1 if self.existing is None else 0,
                                               stdout=json.dumps(self.existing))
        return subprocess.CompletedProcess(args, 0)

    def invoke(self):
        Path('event.json').write_text(json.dumps({'workflow_run': self.run}))
        with patch.object(publish_release, 'gh_json', side_effect=self.api), \
             patch.object(publish_release, 'command', side_effect=self.command), \
             patch.object(publish_release.subprocess, 'run', side_effect=self.execute), \
             contextlib.redirect_stdout(io.StringIO()):
            publish_release.publish()

    def test_stable_minor_tag_and_upload_before_publication(self):
        self.invoke()
        create = next(c for c in self.calls if c[2] == 'create')
        self.assertEqual(create[3], 'v0.2.0')
        self.assertEqual(create[create.index('--target') + 1], self.sha)
        self.assertIn('--draft', create)
        self.assertEqual(self.calls[-1], ['gh', 'release', 'edit', 'v0.2.0', '--draft=false', '--latest'])

    def test_pr_has_unique_tag_and_never_becomes_latest(self):
        self.run.update(event='pull_request', head_branch='feature', pull_requests=[{'number': 9}])
        self.invoke()
        create = next(c for c in self.calls if c[2] == 'create')
        self.assertEqual(create[3], 'pr-9-build-123-1')
        self.assertIn('--prerelease', create)
        self.assertEqual(self.calls[-1][-1], '--latest=false')
        expected = hashlib.sha256(Path('dist/remote-dev.tar.gz').read_bytes()).hexdigest()
        self.assertTrue(Path('dist/remote-dev.tar.gz.sha256').read_text().startswith(expected))

    def test_published_release_is_immutable_on_retry(self):
        self.existing = {'isDraft': False, 'targetCommitish': self.sha}
        self.invoke()
        self.assertEqual(len(self.calls), 1)

    def test_draft_retry_uploads_before_publish(self):
        self.existing = {'isDraft': True, 'targetCommitish': self.sha}
        self.invoke()
        self.assertEqual([c[2] for c in self.calls], ['view', 'upload', 'edit'])

    def test_unrelated_draft_is_rejected(self):
        self.existing = {'isDraft': True, 'targetCommitish': 'c' * 40}
        with self.assertRaisesRegex(RuntimeError, 'different commit'):
            self.invoke()
        self.assertEqual(len(self.calls), 1)

    def test_wrong_repository_is_rejected(self):
        self.run['repository']['full_name'] = 'attacker/other'
        with self.assertRaisesRegex(RuntimeError, 'Unexpected workflow'):
            self.invoke()
        self.assertEqual(self.calls, [])


if __name__ == '__main__':
    unittest.main()
