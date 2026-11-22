#!/usr/bin/env python3
"""Read a private deployment payload on stdin; never print connection tokens.

Compatible with Python 3.6. Backs up existing files before scoped writes.
"""
import base64
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import sys

payload = json.load(sys.stdin)
home = pathlib.Path.home()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
backup = home / '.local/state/codex-thread-contact/backups' / stamp
backup.mkdir(parents=True, mode=0o700)
os.chmod(str(backup), 0o700)
changed = []


def write_private(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists() and path.read_bytes() == content:
        os.chmod(str(path), mode)
        return
    if path.exists():
        name = str(path).replace('/', '_').lstrip('_')
        shutil.copy2(str(path), str(backup / name))
        os.chmod(str(backup / name), 0o600)
    temp = path.with_name(path.name + '.thread-contact-' + stamp)
    fd = os.open(str(temp), os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(content)
    os.replace(str(temp), str(path))
    os.chmod(str(path), mode)
    changed.append(str(path))


client = home / '.local/lib/codex-thread-contact/thread_contact.py'
client_bytes = base64.b64decode(payload['client_base64'])
compile(client_bytes, str(client), 'exec')
write_private(client, client_bytes, 0o700)
if payload.get('readme_base64'):
    write_private(client.with_name('README.md'), base64.b64decode(payload['readme_base64']))
config = home / '.config/codex-thread-contact/client.json'
write_private(config, (json.dumps({
    'url': payload['url'], 'token': payload['token'],
    'source_host_id': payload['source_host_id']
}, indent=2) + '\n').encode('utf-8'))
os.chmod(str(config.parent), 0o700)

block = '\n'.join([
    '[mcp_servers.thread_contact]',
    'command = "/usr/bin/python3"',
    'args = [' + json.dumps(str(client)) + ', "mcp"]',
    'startup_timeout_sec = 10',
    'tool_timeout_sec = 60',
    '',
    '[mcp_servers.thread_contact.tools.contact_thread]',
    'approval_mode = "approve"',
    ''
])
configs = [home / '.codex/config.toml']
if payload.get('managed_config_path'):
    managed = pathlib.Path(payload['managed_config_path'])
    if not managed.is_absolute() or not managed.is_file() or managed.stat().st_uid != os.getuid():
        raise ValueError('Managed config must be an existing absolute file owned by the current user')
    if managed.resolve() != configs[0].resolve():
        configs.append(managed)
for target in configs:
    before = target.read_bytes() if target.exists() else b''
    text = before.decode('utf-8')
    if '[mcp_servers.thread_contact]' in text:
        # Existing registration and approval choices stay intact.
        if str(client) not in text:
            raise RuntimeError('Existing thread_contact points elsewhere: ' + str(target))
    else:
        write_private(target, (text.rstrip('\r\n') + '\n\n' + block).encode('utf-8'))
print(json.dumps({
    'installed': True, 'source_host_id': payload['source_host_id'],
    'client': str(client), 'client_sha256': hashlib.sha256(client_bytes).hexdigest(),
    'connection_config_mode': oct(config.stat().st_mode & 0o777),
    'registered_configs': [str(p) for p in configs],
    'changed_paths': changed, 'private_backup': str(backup),
    'research_threads_or_app_servers_restarted': 0
}))
