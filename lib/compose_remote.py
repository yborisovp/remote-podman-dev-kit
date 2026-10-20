#!/usr/bin/env python3
"""Server-side Compose adapter. Invoked only over SSH as the project account."""
import json
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys

NAME = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,63}$')


def require_name(value):
    if not NAME.fullmatch(value):
        raise ValueError('Invalid project/service name: ' + value)
    return value


def provider():
    if shutil.which('docker-compose'):
        return ['docker-compose']
    if shutil.which('docker') and subprocess.run(['docker', 'compose', 'version'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        return ['docker', 'compose']
    raise ValueError('Install a Compose provider on Linux: docker-compose or docker compose.')


def environment():
    if os.getuid() == 0:
        raise ValueError('Run as a dedicated non-root Linux user.')
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(('DOCKER_', 'COMPOSE_')):
            env.pop(key)
    env['DOCKER_HOST'] = f'unix:///run/user/{os.getuid()}/podman/podman.sock'
    return env


def run_compose(project, files, args, cwd=None, capture=False):
    cmd = provider() + ['--project-name', project]
    for file in files:
        cmd += ['--file', str(file)]
    cmd += ['--profile', '*'] + args
    return subprocess.run(cmd, cwd=cwd, env=environment(), check=True,
                          stdout=subprocess.PIPE if capture else None, text=True).stdout


def local_path(value, workspace):
    path = Path(value)
    if not path.is_absolute():
        path = workspace / path
    path = path.resolve()
    try:
        path.relative_to(workspace.resolve())
    except ValueError:
        raise ValueError('Compose paths must stay inside the uploaded project: ' + str(value))
    return str(path)


def normalize(model, workspace, offset):
    services = model.get('services') or {}
    if not services:
        raise ValueError('Compose file has no services.')
    ports, used = [], set()
    model.pop('name', None)  # Project identity is always supplied explicitly.
    for name, svc in services.items():
        require_name(name)
        if svc.get('network_mode') == 'host' or str(svc.get('network_mode', '')).startswith('container:'):
            raise ValueError(name + ': host/container networking bypasses project port isolation.')
        svc.pop('container_name', None)  # Let Compose use project-scoped names.
        build = svc.get('build')
        if isinstance(build, str):
            svc['build'] = {'context': local_path(build, workspace)}
        elif build:
            build['context'] = local_path(build.get('context', '.'), workspace)
            if build.get('additional_contexts') or build.get('ssh'):
                raise ValueError(name + ': additional build contexts/SSH forwarding are not supported.')
            if build.get('dockerfile'):
                local_path(Path(build['context']) / build['dockerfile'], workspace)
        for volume in svc.get('volumes', []):
            if not isinstance(volume, dict):
                raise ValueError('Compose provider did not normalize volume syntax.')
            if volume.get('type') == 'bind':
                volume['source'] = local_path(volume['source'], workspace)
        for entry in svc.get('env_file', []):
            local_path(entry.get('path') if isinstance(entry, dict) else entry, workspace)
        for port in svc.get('ports', []):
            if not isinstance(port, dict):
                raise ValueError('Compose provider did not normalize port syntax.')
            if port.get('protocol', 'tcp') != 'tcp':
                raise ValueError(name + ': SSH forwarding supports published TCP ports only.')
            published = str(port.get('published', ''))
            if not published.isdigit() or not 1 <= int(published) <= 65535:
                raise ValueError(name + ': set a fixed published port (no ranges or random ports).')
            local = int(published)
            remote = local + offset
            if not 1024 <= remote <= 65535:
                raise ValueError(name + ': remote port outside 1024..65535; adjust REMOTE_PORT_OFFSET.')
            if local in used:
                raise ValueError('Duplicate published port: ' + published)
            used.add(local)
            port['host_ip'] = '127.0.0.1'
            port['published'] = str(remote)
            ports.append({'service': name, 'local': local, 'remote': remote})
    for kind in ('secrets', 'configs'):
        for spec in model.get(kind, {}).values():
            if spec.get('file'):
                spec['file'] = local_path(spec['file'], workspace)
    return ports


def closure(model, requested):
    services = model['services']
    result = []
    def visit(name):
        if name not in services:
            raise ValueError('Unknown Compose service: ' + name)
        if name in result:
            return
        result.append(name)
        service = services[name]
        for dep in service.get('depends_on', {}):
            visit(dep)
        for link in service.get('links', []):
            visit(link.split(':')[0])
        for field in ('network_mode', 'ipc', 'pid'):
            value = service.get(field, '')
            if isinstance(value, str) and value.startswith('service:'):
                visit(value[8:])
        for value in service.get('volumes_from', []):
            if value.startswith('container:'):
                raise ValueError('External container volumes_from is unsupported.')
            visit(value.split(':')[0])
    for name in requested:
        visit(require_name(name))
    return result


def escape_dollars(value):
    # config resolves interpolation once; the generated file must preserve literals.
    if isinstance(value, str):
        return value.replace('$', '$$')
    if isinstance(value, list):
        return [escape_dollars(v) for v in value]
    if isinstance(value, dict):
        return {k: escape_dollars(v) for k, v in value.items()}
    return value


def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value))
    temp.chmod(0o600)
    temp.replace(path)


def load(path):
    return json.loads(path.read_text())


def report(data, selected=None):
    for name in data['model']['services']:
        if selected is None or name in selected:
            local = [str(p['local']) for p in data['ports'] if p['service'] == name]
            print('S\t' + name + '\t' + (','.join(local) or '-'))
    for port in data['ports']:
        if selected is None or port['service'] in selected:
            print(f"P\t{port['service']}\t{port['local']}\t{port['remote']}")


def check_registries(model, selected):
    hosts = set()
    for name in selected:
        image = model['services'][name].get('image', '')
        if not image or model['services'][name].get('build'):
            continue
        first = image.split('/')[0]
        registry = first if '/' in image and ('.' in first or ':' in first or first == 'localhost') else 'registry-1.docker.io'
        if registry == 'docker.io':
            registry = 'registry-1.docker.io'
        host, sep, port = registry.partition(':')
        hosts.add((host, int(port) if sep else 443))
    for host, port in sorted(hosts):
        with socket.create_connection((host, port), timeout=5):
            pass


def main():
    os.umask(0o077)
    action, root_arg, project, *args = sys.argv[1:]
    require_name(project)
    root = Path(root_arg).resolve()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    import fcntl
    operation_lock = (root / 'operation.lock').open('a')
    fcntl.flock(operation_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    state = root / 'active.json'
    if action == 'prepare':
        snapshot, offset, *files = args
        workspace = Path(local_path(Path(snapshot).resolve(), root))
        resolved = [local_path(file, workspace) for file in files]
        help_text = run_compose(project, resolved, ['config', '--help'], cwd=workspace, capture=True)
        if '--format' in help_text:
            model = json.loads(run_compose(project, resolved, ['config', '--format', 'json'], cwd=workspace, capture=True))
        else:
            import yaml  # Debian/Ubuntu python3-yaml for Compose v1.
            model = yaml.safe_load(run_compose(project, resolved, ['config'], cwd=workspace, capture=True))
        ports = normalize(model, workspace, int(offset))
        data = {'model': model, 'ports': ports, 'workspace': str(workspace)}
        save(workspace / '.devkit-model.json', data)
        save(workspace / '.devkit-compose.json', escape_dollars(model))
        report(data)
    elif action in ('plan', 'up'):
        snapshot, *requested = args
        workspace = Path(local_path(Path(snapshot).resolve(), root))
        data = load(workspace / '.devkit-model.json')
        selected = closure(data['model'], requested)
        if action == 'plan':
            report(data, selected)
        else:
            if state.exists() and load(state).get('running'):
                raise ValueError('Stop all project services before starting a new selection.')
            check_registries(data['model'], selected)
            data['running'] = True
            data['selected'] = selected
            save(state, data)  # Keep cleanup possible even if up partially fails.
            run_compose(project, [workspace / '.devkit-compose.json'], ['up', '--detach', '--build'] + requested, cwd=workspace)
    elif action in ('status', 'stop'):
        if not state.exists():
            print('No Compose deployment saved for this project.')
            return
        data = load(state)
        workspace = Path(local_path(data['workspace'], root))
        command = ['ps', '--all'] if action == 'status' else (['stop'] + args if args else ['down'])
        for name in args:
            if name not in data['model']['services']:
                raise ValueError('Unknown active service: ' + name)
        run_compose(project, [workspace / '.devkit-compose.json'], command, cwd=workspace)
        if action == 'stop' and not args:
            data['running'] = False
            save(state, data)
    elif action == 'active-services':
        if state.exists():
            data = load(state)
            report(data, data.get('selected'))
    else:
        raise ValueError('Unknown remote action: ' + action)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, ImportError, subprocess.CalledProcessError) as error:
        print('Compose: ' + str(error), file=sys.stderr)
        sys.exit(1)
