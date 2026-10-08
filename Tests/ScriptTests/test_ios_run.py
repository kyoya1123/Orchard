import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(os.environ.get('IOS_RUN_SCRIPT', Path(__file__).resolve().parents[2] / 'Scripts/ios-run.sh'))
RUN_ID = '11111111-2222-3333-4444-555555555555'
STUB = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
cfg = json.loads(Path(os.environ['IOS_RUN_TEST_CONFIG']).read_text())
name, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['IOS_RUN_TEST_TRACE'], 'a') as stream:
    stream.write(json.dumps([name, *args]) + '\n')
if name == 'git':
    if args == ['branch', '--show-current']:
        print(cfg.get('branch', 'feature/test'))
    elif args[:3] == ['show-ref', '--verify', '--quiet']:
        sys.exit(0 if args[3] in cfg.get('branches', ['refs/heads/feature/test']) else 1)
    else:
        sys.exit(99)
elif name == 'xcrun':
    if args[:3] == ['devicectl', 'list', 'devices']:
        if cfg.get('device_exit'):
            sys.exit(cfg['device_exit'])
        Path(args[args.index('--json-output') + 1]).write_text(json.dumps({'result': {'devices': cfg.get('devices', [])}}))
    elif args == ['simctl', 'list', '-j']:
        if cfg.get('sim_exit'):
            sys.exit(cfg['sim_exit'])
        print(json.dumps(cfg['sim']))
    elif args in (['simctl', 'list', 'devicetypes', '-j'], ['simctl', 'list', 'runtimes', '-j']):
        print(json.dumps({args[2]: cfg['sim'][args[2]]}))
    elif args[:2] == ['simctl', 'create']:
        if cfg.get('create_exit'):
            sys.exit(cfg['create_exit'])
        print('NEW-SIM')
    else:
        sys.exit(99)
elif name == 'orchard':
    if args[:2] == ['list', 'schemes']:
        print(cfg.get('schemes', 'ProdDebug'))
        sys.exit(cfg.get('scheme_exit', 0))
    elif args[0] == 'runs':
        print(json.dumps(cfg['record']))
        sys.exit(cfg.get('runs_exit', 0))
    elif args[:2] == ['simulator', 'ensure']:
        if cfg.get('ensure_exit'): sys.exit(cfg['ensure_exit'])
        print('SIM27')
    elif args[0] == 'run':
        sys.exit(cfg.get('run_exit', 0))
    else:
        sys.exit(99)
'''


def device(name='Phone', state='connected', reality='physical', udid='PHYSICAL'):
    return {'deviceProperties': {'name': name},
            'connectionProperties': {'tunnelState': state},
            'hardwareProperties': {'platform': 'iOS', 'reality': reality, 'udid': udid}}


def simulator(udid='SIM27', name='feature-test', device_type='type18'):
    return {'name': name, 'udid': udid, 'deviceTypeIdentifier': device_type, 'isAvailable': True}


class RunTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ('git', 'xcrun', 'orchard'):
            path = self.root / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.config = self.root / 'config.json'
        self.trace = self.root / 'trace.jsonl'
        self.cfg = {'sim': {
            'devicetypes': [{'name': 'iPhone 18 Pro', 'identifier': 'type18'},
                            {'name': 'iPhone 16', 'identifier': 'type16'}],
            # The order deliberately differs from version order.
            'runtimes': [{'name': 'iOS 27.0', 'version': '27.0', 'identifier': 'rt27', 'isAvailable': True},
                         {'name': 'iOS 26.5', 'version': '26.5', 'identifier': 'rt26', 'isAvailable': True}],
            'devices': {'rt27': [simulator()], 'rt26': [simulator('SIM26')]}}}

    def invoke(self, args=None):
        self.config.write_text(json.dumps(self.cfg))
        env = dict(os.environ, PATH=f'{self.root}{os.pathsep}{os.environ["PATH"]}',
                   IOS_RUN_TEST_CONFIG=str(self.config), IOS_RUN_TEST_TRACE=str(self.trace))
        proc = subprocess.run(['bash', str(SCRIPT), *(args if args is not None else
                              ['', 'ProdDebug', 'iPhone 18 Pro', 'iOS 27.0', 'delegate'])],
                              env=env, cwd=self.root, text=True, capture_output=True, timeout=5)
        calls = [json.loads(line) for line in self.trace.read_text().splitlines()] if self.trace.exists() else []
        return proc, calls

    def run_call(self, calls):
        return next(call for call in calls if call[:2] == ['orchard', 'run'])

    def assert_no_mutation(self, calls):
        self.assertFalse(any(call[:2] == ['orchard', 'run'] or call[:3] == ['orchard', 'simulator', 'ensure'] for call in calls))

    def test_connected_physical_device(self):
        self.cfg['devices'] = [device()]
        proc, calls = self.invoke(['Phone', 'ProdDebug'])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('--device', self.run_call(calls))
        self.assertIn('PHYSICAL', self.run_call(calls))

    def test_simulated_device_is_not_physical(self):
        self.cfg['devices'] = [device('feature/test', reality='simulated', udid='FAKE-PHYSICAL')]
        proc, calls = self.invoke(['feature/test', 'ProdDebug', 'iPhone 18 Pro', 'iOS 27.0'])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('--simulator', self.run_call(calls))
        self.assertIn('SIM27', self.run_call(calls))

    def test_disconnected_device_never_creates_simulator(self):
        self.cfg['devices'] = [device(state='disconnected')]
        proc, calls = self.invoke(['Phone', 'ProdDebug'])
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assert_no_mutation(calls)

    def test_unknown_name_never_creates_simulator(self):
        proc, calls = self.invoke(['Pohne', 'ProdDebug'])
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assert_no_mutation(calls)

    def test_duplicate_physical_names(self):
        self.cfg['devices'] = [device(), device(udid='SECOND')]
        proc, calls = self.invoke(['Phone', 'ProdDebug'])
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assert_no_mutation(calls)

    def test_device_query_failure_stops(self):
        self.cfg['device_exit'] = 1
        proc, calls = self.invoke(['Phone', 'ProdDebug'])
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assert_no_mutation(calls)

    def test_invalid_mode_has_no_side_effects(self):
        proc, calls = self.invoke(['', 'ProdDebug', 'iPhone 18 Pro', 'iOS 27.0', 'typo'])
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assert_no_mutation(calls)

    def test_detached_head_stops(self):
        self.cfg['branch'] = ''
        proc, calls = self.invoke()
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assert_no_mutation(calls)

    def test_scheme_discovery_failure_is_preserved(self):
        self.cfg.update(schemes='ProdDebug', scheme_exit=3)
        proc, calls = self.invoke([''])
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assert_no_mutation(calls)

    def test_multiple_schemes_require_selection(self):
        self.cfg['schemes'] = 'ProdDebug\nDevDebug'
        proc, calls = self.invoke([''])
        self.assertEqual(proc.returncode, 5, proc.stderr)
        self.assert_no_mutation(calls)

    def test_no_schemes(self):
        self.cfg['schemes'] = ''
        proc, calls = self.invoke([''])
        self.assertEqual(proc.returncode, 2, proc.stderr)
        self.assert_no_mutation(calls)

    def test_latest_runtime_is_forwarded(self):
        proc, calls = self.invoke(['', 'ProdDebug', 'iPhone 18 Pro', ''])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn('SIM27', self.run_call(calls))

    def test_create_failure_does_not_dispatch(self):
        self.cfg['sim']['devices']['rt27'] = []
        self.cfg['ensure_exit'] = 1
        proc, calls = self.invoke()
        self.assertEqual(proc.returncode, 7, proc.stderr)
        self.assertFalse(any(c[:2] == ['orchard', 'run'] for c in calls))

    def test_follow_is_not_delegated(self):
        self.cfg['run_exit'] = 4
        proc, calls = self.invoke(['', 'ProdDebug', 'iPhone 18 Pro', 'iOS 27.0', 'follow'])
        self.assertEqual(proc.returncode, 4, proc.stderr)
        self.assertNotIn('--delegate', self.run_call(calls))

    def test_status_omits_logs_and_does_not_claim_launch(self):
        self.cfg['record'] = {'id': RUN_ID, 'status': 'running', 'activityText': 'Building', 'log': 'large-private-log' * 10000}
        proc, calls = self.invoke(['--status', RUN_ID])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        result = json.loads(proc.stdout)
        self.assertEqual(result['activityText'], 'Building')
        self.assertNotIn('log', result)
        self.assertNotIn('large-private-log', proc.stdout)
        self.assert_no_mutation(calls)

    def test_status_requires_full_id(self):
        self.cfg['record'] = {'id': RUN_ID}
        proc, calls = self.invoke(['--status', RUN_ID[:8]])
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assert_no_mutation(calls)

    def test_default_selection_is_latest(self):
        proc, calls = self.invoke(['', 'ProdDebug'])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        ensure = next(c for c in calls if c[:3] == ['orchard', 'simulator', 'ensure'])
        self.assertEqual(ensure[3:], ['--name', 'feature-test', '--device-type', 'latest', '--runtime', 'latest'])
        self.assertFalse(any(c[:2] == ['xcrun', 'simctl'] for c in calls))

    def test_explicit_selection_is_preserved(self):
        proc, calls = self.invoke()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        ensure = next(c for c in calls if c[:3] == ['orchard', 'simulator', 'ensure'])
        self.assertEqual(ensure[3:], ['--name', 'feature-test', '--device-type', 'iPhone 18 Pro', '--runtime', 'iOS 27.0'])


if __name__ == '__main__':
    unittest.main()
