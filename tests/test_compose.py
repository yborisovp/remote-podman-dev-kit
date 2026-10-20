import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('remote', Path(__file__).parents[1] / 'lib/compose_remote.py')
remote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(remote)

class ComposeModelTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name).resolve()
        self.model = {'services': {
            'web': {'ports': [{'target': 80, 'published': '8080', 'host_ip': '0.0.0.0'}, {'target': 81, 'published': '8081'}], 'depends_on': {'db': {'condition': 'service_healthy'}}, 'container_name': 'global-name'},
            'db': {'image': 'postgres:16', 'ports': [{'target': 5432, 'published': '5432'}]},
            'worker': {'image': 'worker:latest'}
        }}
    def test_multiple_ports_dependencies_and_project_names(self):
        ports = remote.normalize(self.model, self.root, 10000)
        self.assertEqual(remote.closure(self.model, ['web']), ['web', 'db'])
        self.assertEqual(len(ports), 3)
        self.assertNotIn('container_name', self.model['services']['web'])
        self.assertEqual(self.model['services']['web']['ports'][0]['published'], '18080')
        self.assertEqual(self.model['services']['web']['ports'][0]['host_ip'], '127.0.0.1')
        self.assertEqual(remote.closure(self.model, ['worker']), ['worker'])
    def test_duplicate_ports_rejected(self):
        self.model['services']['db']['ports'][0]['published'] = '8080'
        with self.assertRaisesRegex(ValueError, 'Duplicate'): remote.normalize(self.model, self.root, 0)
    def test_udp_random_ranges_rejected(self):
        for port in ({'target': 53, 'published': '8053', 'protocol': 'udp'}, {'target': 80}, {'target': 80, 'published':'8000-8002'}):
            with self.subTest(port=port):
                model = copy.deepcopy(self.model); model['services']['web']['ports'] = [port]
                with self.assertRaises(ValueError): remote.normalize(model, self.root, 0)
    def test_host_network_rejected(self):
        self.model['services']['web']['network_mode'] = 'host'
        with self.assertRaisesRegex(ValueError, 'networking'): remote.normalize(self.model, self.root, 0)
    def test_outside_context_and_symlink_rejected(self):
        for context in ('../outside', str(self.root.parent)):
            with self.subTest(context=context):
                model = copy.deepcopy(self.model); model['services']['web']['build'] = context
                with self.assertRaisesRegex(ValueError, 'inside'): remote.normalize(model, self.root, 0)
        (self.root / 'escape').symlink_to(self.root.parent, target_is_directory=True)
        with self.assertRaises(ValueError): remote.local_path('escape/file', self.root)
    def test_literals_do_not_interpolate_twice(self):
        self.assertEqual(remote.escape_dollars({'environment': {'TOKEN': 'a$HOME${TEST}'}}), {'environment': {'TOKEN': 'a$$HOME$${TEST}'}})
    def test_ports_outside_rootless_range_rejected(self):
        with self.assertRaises(ValueError): remote.normalize(self.model, self.root, 60000)
    def test_unknown_service_rejected(self):
        with self.assertRaisesRegex(ValueError, 'Unknown'): remote.closure(self.model, ['postgres'])
    def test_model_file_private(self):
        path = self.root/'model.json'
        remote.save(path, self.model)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(remote.load(path), self.model)

if __name__ == '__main__':
    unittest.main()
