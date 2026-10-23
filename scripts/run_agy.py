#!/usr/bin/env python3
"""Run one account-authenticated Antigravity turn, or read its durable receipt."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import uuid

ACCOUNT_ONLY_EXCLUDE = (
    'GEMINI_API_KEY', 'GOOGLE_API_KEY', 'AGY_ADC_AUTH',
    'GOOGLE_APPLICATION_CREDENTIALS', 'GOOGLE_GENAI_USE_VERTEXAI',
    'GOOGLE_GENAI_USE_ENTERPRISE', 'GOOGLE_GEMINI_BASE_URL',
)


def now():
    return datetime.now(timezone.utc).isoformat()


def emit(value):
    # ASCII JSON also round-trips safely through Windows PowerShell 5.1.
    print(json.dumps(value, ensure_ascii=True, indent=2), flush=True)


def record_path(workspace, request_id):
    digest = hashlib.sha256(request_id.encode('utf-8')).hexdigest()
    return workspace / '.codex-antigravity' / 'runs' / (digest + '.json')


def save(path, value):
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)


def load_record(path):
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except FileNotFoundError:
        return None
    except json.JSONDecodeError:
        return {'status': 'PENDING_OUTCOME_UNKNOWN_DO_NOT_RETRY'}


def cli_path(explicit):
    candidate = explicit or shutil.which('agy')
    if not candidate and os.name == 'nt' and os.environ.get('LOCALAPPDATA'):
        candidate = str(Path(os.environ['LOCALAPPDATA']) / 'agy' / 'bin' / 'agy.exe')
    if not candidate or not Path(candidate).is_file():
        raise RuntimeError('Official agy CLI was not found. Verify and install it from antigravity.google first.')
    return str(Path(candidate).resolve())


def check_account_mode():
    settings_path = Path.home() / '.gemini' / 'antigravity-cli' / 'settings.json'
    if settings_path.exists():
        settings = json.loads(settings_path.read_text(encoding='utf-8-sig'))
        if settings.get('modelProvider') == 'gemini':
            raise RuntimeError('CLI is configured for API Key mode. Do not silently replace the user\'s authentication settings.')


def read_events(path):
    conversation_id = None
    result = None
    tool_calls = []
    with path.open(encoding='utf-8', errors='replace') as source:
        for line in source:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get('event') == 'init':
                conversation_id = event.get('conversation_id')
            elif event.get('event') == 'result':
                result = event.get('result')
                conversation_id = (result or {}).get('conversation_id') or conversation_id
            step = event.get('step_update', {})
            if step.get('tool_name') and step.get('state') == 'DONE':
                tool_calls.append({'name': step['tool_name'], 'details': step.get('tool_info')})
    return conversation_id, result, tool_calls


def run(args):
    workspace = Path(args.workspace).expanduser().resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    prompt = Path(args.prompt_file).read_text(encoding='utf-8-sig') if args.prompt_file else args.prompt
    if not prompt or not prompt.strip():
        raise ValueError('A nonempty prompt is required')
    filename = record_path(workspace, args.request_id)
    fingerprint = hashlib.sha256(json.dumps({
        'prompt': prompt, 'conversation': args.conversation, 'model': args.model,
        'workspace': str(workspace),
    }, sort_keys=True, ensure_ascii=False).encode('utf-8')).hexdigest()
    old = load_record(filename)
    if old:
        if old.get('input_hash') and old['input_hash'] != fingerprint:
            raise ValueError('request_id was already used with different input')
        emit({**old, 'duplicate_suppressed': True})
        return 0 if old.get('status') == 'RESPONSE_RECEIVED' else 2
    # Replaying a receipt must not need a still-installed CLI or current login.
    check_account_mode()
    agy = cli_path(args.agy)
    filename.parent.mkdir(parents=True, exist_ok=True)
    stdout_path = filename.with_suffix('.events.jsonl')
    stderr_path = filename.with_suffix('.stderr.txt')
    record = {
        'request_id': args.request_id, 'input_hash': fingerprint,
        'status': 'PENDING_OUTCOME_UNKNOWN_DO_NOT_RETRY', 'started_at_utc': now(),
        'workspace': str(workspace), 'conversation_id': args.conversation,
        'parent_codex_thread_id': os.environ.get('CODEX_THREAD_ID'),
        'api_key_used': False, 'cli_executable': agy,
        'events_file': str(stdout_path), 'stderr_file': str(stderr_path),
    }
    try:
        with filename.open('x', encoding='utf-8') as claim:
            json.dump(record, claim, ensure_ascii=False, indent=2)
            claim.flush()
            os.fsync(claim.fileno())
    except FileExistsError:
        existing = load_record(filename) or {'status': 'PENDING_OUTCOME_UNKNOWN_DO_NOT_RETRY'}
        if existing.get('input_hash') and existing['input_hash'] != fingerprint:
            raise ValueError('request_id was already used with different input')
        emit({**existing, 'duplicate_suppressed': True})
        return 0 if existing.get('status') == 'RESPONSE_RECEIVED' else 2
    env = {key: value for key, value in os.environ.items() if key not in ACCOUNT_ONLY_EXCLUDE}
    command = [agy, '-p', prompt, '--output-format', 'stream-json', '--print-timeout', f'{args.timeout}s']
    if args.conversation:
        command += ['--conversation', args.conversation]
    if args.model:
        command += ['--model', args.model]
    process = None
    timed_out = False
    try:
        with stdout_path.open('w', encoding='utf-8') as stdout, stderr_path.open('w', encoding='utf-8') as stderr:
            process = subprocess.Popen(command, cwd=workspace, env=env, stdin=subprocess.DEVNULL,
                                       stdout=stdout, stderr=stderr,
                                       creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
            record['pid'] = process.pid
            save(filename, record)
            try:
                code = process.wait(timeout=args.timeout + 15)
            except subprocess.TimeoutExpired:
                timed_out = True
                process.terminate()
                try:
                    code = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    code = process.wait(timeout=5)
        conversation, result, tools = read_events(stdout_path)
        record.update(conversation_id=conversation or args.conversation, exit_code=code,
                      result=result, completed_tool_calls=tools, completed_at_utc=now())
        if timed_out:
            record['status'] = 'TIMED_OUT_OUTCOME_UNKNOWN_DO_NOT_RETRY'
        elif code == 0 and result and result.get('status') == 'SUCCESS' and result.get('response', '').strip():
            record['status'] = 'RESPONSE_RECEIVED'
        else:
            # Even a nonzero exit may follow real tool effects. No automatic retry.
            record['status'] = 'FAILED_CHECK_EVENTS_AND_RECEIPTS_BEFORE_RETRY'
    except BaseException as error:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        record.update(error=f'{type(error).__name__}: {error}', completed_at_utc=now())
        save(filename, record)
        if isinstance(error, (KeyboardInterrupt, SystemExit)):
            raise
        emit(record)
        return 2
    save(filename, record)
    emit(record)
    return 0 if record['status'] == 'RESPONSE_RECEIVED' else 2


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='operation', required=True)
    launch = sub.add_parser('run')
    launch.add_argument('--workspace', required=True)
    launch.add_argument('--request-id', required=True)
    prompts = launch.add_mutually_exclusive_group(required=True)
    prompts.add_argument('--prompt')
    prompts.add_argument('--prompt-file')
    launch.add_argument('--conversation')
    launch.add_argument('--model', help='Use an actual slug from agy models; omitted by default')
    launch.add_argument('--agy')
    launch.add_argument('--timeout', type=int, default=180)
    receipt = sub.add_parser('receipt')
    receipt.add_argument('--workspace', required=True)
    receipt.add_argument('--request-id', required=True)
    args = parser.parse_args()
    if not args.request_id or len(args.request_id) > 128:
        parser.error('request-id must contain 1 to 128 characters')
    if args.operation == 'receipt':
        value = load_record(record_path(Path(args.workspace).expanduser().resolve(), args.request_id))
        emit(value or {'status': 'NOT_FOUND', 'request_id': args.request_id})
        return 0
    if not 10 <= args.timeout <= 86400:
        parser.error('timeout must be between 10 and 86400 seconds')
    return run(args)


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (RuntimeError, ValueError, OSError) as error:
        emit({'status': 'NOT_STARTED', 'error': f'{type(error).__name__}: {error}'})
        raise SystemExit(1)
