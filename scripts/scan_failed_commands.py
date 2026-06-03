#!/usr/bin/env python3
"""
Scan r_*.json result files across all claude-bridge directories
for failed commands (exit_code != 0) and specific bug patterns.

Outputs detailed findings to stdout.
"""

import json
import os
import re
import glob

# ── Configuration ──
BASE_DIR = r"/sessions/compassionate-peaceful-goldberg/mnt/zebbingo/tools/claude-bridge"
SEARCH_DIRS = [
    os.path.join(BASE_DIR, "watcher"),
    os.path.join(BASE_DIR, "cluster", "user_bridge"),
    os.path.join(BASE_DIR, "cluster", "process_bridge"),
    os.path.join(BASE_DIR, "cluster", "file_bridge"),
    os.path.join(BASE_DIR, "cluster", "network_bridge"),
    os.path.join(BASE_DIR, "cluster", "registry_bridge"),
    os.path.join(BASE_DIR, "cluster", "system_bridge"),
    os.path.join(BASE_DIR, "cluster", "wsl_bridge"),
]

ERROR_HISTORY_PATH = os.path.join(BASE_DIR, "watcher", "error_history.json")
WATCHER_LOG_PATH = os.path.join(BASE_DIR, "watcher", "watcher.log")
PROCESS_WATCHER_LOG_PATH = os.path.join(BASE_DIR, "cluster", "process_bridge", "watcher.log")


def parse_json_lenient(text):
    """Try to parse JSON with tolerance for encoding issues."""
    if not text or not text.strip():
        return None
    for enc in ['utf-8', 'utf-16-le', 'utf-16-be', 'gbk', 'latin-1']:
        try:
            if isinstance(text, bytes):
                return json.loads(text.decode(enc, errors='replace'))
            return json.loads(text)
        except (json.JSONDecodeError, UnicodeDecodeError, UnicodeEncodeError):
            continue
    try:
        cleaned = text.replace('\x00', '').strip()
        return json.loads(cleaned)
    except json.JSONDecodeError:
        return None


def safe_text(val):
    if val is None:
        return ""
    if isinstance(val, bytes):
        val = val.decode('utf-8', errors='replace')
    return str(val)


def get_field(d, *keys):
    for k in keys:
        if k in d and d[k] is not None:
            return d[k]
    return None


def get_exit_code(d):
    return get_field(d, 'e', 'exit_code', 'ExitCode', 'exitcode')


def get_cmd_id(d):
    return get_field(d, 'id', 'cmd_id', 'Id', 'ID', 'command_id')


def get_stderr(d):
    return safe_text(get_field(d, 's', 'stderr', 'StdErr', 'standard_error'))


def get_stdout(d):
    return safe_text(get_field(d, 'o', 'stdout', 'StdOut', 'standard_output'))


def get_error(d):
    return safe_text(get_field(d, 'err', 'error', 'Error', 'ErrorMessage', 'exception'))


def get_type(d):
    return safe_text(get_field(d, 'type', 't', 'Type', 'cmd_type', 'channel'))


def get_state(d):
    return safe_text(get_field(d, 'state', 'State', 'status', 'Status'))


def get_timestamp(d):
    return safe_text(get_field(d, 'ts', 'timestamp', 'Timestamp', 'time', 'Time'))


def get_duration(d):
    return get_field(d, 'd', 'duration_ms', 'Duration', 'DurationMs', 'elapsed_ms')


# ── Pattern definitions ──
PATTERNS = {
    'dollar_underscore': {
        'name': '$_ in command/error',
        'pattern': re.compile(r'\$_'),
        'description': 'PowerShell $_ automatic variable in string interpolation',
    },
    'ampersand_and': {
        'name': '&& operator',
        'pattern': re.compile(r'&&'),
        'description': '&& operator used (may need escaping in cmd)',
    },
    'start_process': {
        'name': 'Start-Process cmdlet',
        'pattern': re.compile(r'Start-Process', re.IGNORECASE),
        'description': 'Start-Process cmdlet (not available in some PowerShell contexts)',
    },
    'fstring_format': {
        'name': 'Python f-string format spec',
        'pattern': re.compile(r':<\d+\}'),
        'description': 'Python f-string format specifier like :<35',
    },
    'not_recognized': {
        'name': 'Not recognized / not a cmdlet',
        'pattern': re.compile(r'(not recognized|not a cmdlet|not an internal|is not recognized|不是内部)',
                              re.IGNORECASE),
        'description': 'Command not recognized error',
    },
    'clixml': {
        'name': 'CLIXML noise',
        'pattern': re.compile(r'CLIXML|<Objs\s'),
        'description': 'PowerShell CLIXML progress output noise',
    },
    'timeout': {
        'name': 'TIMEOUT',
        'pattern': re.compile(r'TIMEOUT', re.IGNORECASE),
        'description': 'Command timed out',
    },
    'unknown_type': {
        'name': 'Unknown type',
        'pattern': re.compile(r'Unknown type', re.IGNORECASE),
        'description': 'Unknown command type error',
    },
}


def check_patterns(text):
    """Check text against all patterns. Returns list of matched pattern names."""
    matches = []
    if not text:
        return matches
    for key, pdata in PATTERNS.items():
        if pdata['pattern'].search(text):
            matches.append(key)
    return matches


def format_value_full(val, max_len=5000):
    s = safe_text(val)
    if not s:
        return "(empty)"
    if len(s) > max_len:
        return s[:max_len] + f"\n  ... [truncated, total {len(s)} chars]"
    return s


def extract_commands_from_watcher_log(log_path):
    """Extract full command text from watcher log lines."""
    commands = {}
    if not os.path.isfile(log_path):
        print(f"  [WARN] Watcher log not found: {log_path}")
        return commands
    try:
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                m = re.search(r'\[(\S+)\]\s+type=(\S+)\s+cmd=(.+?)(?:\s+timeout=\d+s)?$', line)
                if m:
                    cmd_id = m.group(1)
                    cmd_type = m.group(2)
                    cmd_text = m.group(3)
                    commands[cmd_id] = {'type': cmd_type, 'command': cmd_text}
    except Exception as e:
        print(f"  [WARN] Error reading watcher log {log_path}: {e}")
    return commands


def extract_commands_from_process_watcher_log(log_path):
    """Extract from process_bridge watcher.log which has format: [bridge] [cmd_id] ..."""
    commands = {}
    if not os.path.isfile(log_path):
        return commands
    try:
        with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
            for line in f:
                m = re.search(r'\[(\w+)\]\s+\[(\S+)\]\s+type=(\S+)\s+cmd=(.+?)(?:\s+timeout=\d+s)?$', line)
                if m:
                    cmd_id = m.group(2)
                    cmd_type = m.group(3)
                    cmd_text = m.group(4)
                    commands[cmd_id] = {'type': cmd_type, 'command': cmd_text, 'bridge': m.group(1)}
    except Exception as e:
        print(f"  [WARN] Error reading process watcher log {log_path}: {e}")
    return commands


def extract_from_error_history(path):
    """Extract command summaries from error_history.json."""
    summaries = {}
    if not os.path.isfile(path):
        return summaries
    try:
        with open(path, 'r', encoding='utf-8', errors='replace') as f:
            raw = f.read()
        brace_count = 0
        json_end = 0
        for i, ch in enumerate(raw):
            if ch == '{':
                brace_count += 1
            elif ch == '}':
                brace_count -= 1
                if brace_count == 0:
                    json_end = i + 1
                    break
        if json_end == 0:
            print("  [WARN] Could not find valid JSON boundary in error_history.json")
            return summaries
        data = json.loads(raw[:json_end])
        for entry in data.get('errors', []):
            cmd_id = entry.get('cmd_id')
            summary = entry.get('command_summary', '')
            if cmd_id and summary:
                summaries[cmd_id] = summary
    except Exception as e:
        print(f"  [WARN] Error reading error_history.json: {e}")
    return summaries


def scan_directory(dir_path, commands_map, summaries_map):
    """Scan a single directory for r_*.json files."""
    results = []
    if not os.path.isdir(dir_path):
        return results

    pattern = os.path.join(dir_path, "r_*.json")
    files = sorted(glob.glob(pattern))
    if files:
        print(f"  Scanning {len(files)} files in: {dir_path}")

    for fpath in files:
        fname = os.path.basename(fpath)
        try:
            with open(fpath, 'r', encoding='utf-8', errors='replace') as f:
                raw = f.read()
        except Exception as e:
            print(f"    [ERR] Cannot read {fpath}: {e}")
            continue

        data = parse_json_lenient(raw)
        if data is None:
            print(f"    [ERR] Cannot parse JSON: {fpath}")
            continue

        exit_code = get_exit_code(data)
        cmd_id = get_cmd_id(data)
        stderr_text = get_stderr(data)
        stdout_text = get_stdout(data)
        error_text = get_error(data)
        cmd_type = get_type(data)
        state = get_state(data)
        timestamp = get_timestamp(data)
        duration = get_duration(data)

        if cmd_id is None:
            cmd_id = fname.replace('r_', '').replace('.json', '')

        combined = f"{stderr_text} {error_text} {stdout_text}"

        command_text = ""
        command_source = ""
        if cmd_id and cmd_id in commands_map:
            command_text = commands_map[cmd_id].get('command', '')
            command_source = f"watcher_log (type={commands_map[cmd_id].get('type','?')})"
        elif cmd_id and cmd_id in summaries_map:
            command_text = summaries_map[cmd_id]
            command_source = "error_history.json (summary, may be truncated)"

        # Fallback: try to extract from Chinese error message
        if not command_text and error_text:
            m = re.search(r'行:1\s+.*?\+\s+(.*?)(?:\r?\n|$)', error_text)
            if m:
                extracted = m.group(1).strip()
                if extracted:
                    command_text = extracted
                    command_source = "extracted from Chinese error message (partial)"

        result = {
            'file': fpath,
            'basename': fname,
            'cmd_id': cmd_id,
            'exit_code': exit_code,
            'state': state,
            'type': cmd_type,
            'stdout': stdout_text,
            'stderr': stderr_text,
            'error': error_text,
            'timestamp': timestamp,
            'duration': duration,
            'command_text': command_text,
            'command_source': command_source,
            'patterns': check_patterns(combined),
            'patterns_in_cmd': check_patterns(command_text) if command_text else [],
        }
        results.append(result)

    return results


def print_separator(title):
    print()
    print("=" * 78)
    print(f"  {title}")
    print("=" * 78)


def print_failed_command(r):
    dir_name = os.path.basename(os.path.dirname(r['file']))
    parent_dir = os.path.basename(os.path.dirname(os.path.dirname(r['file'])))
    location = f"{parent_dir}/{dir_name}" if parent_dir != dir_name else dir_name

    print(f"\n  --- {r['cmd_id']} [{location}] ---")
    print(f"  File:        {r['file']}")
    print(f"  State:       {r['state']}")
    print(f"  Exit code:   {r['exit_code']}")
    if r['type']:
        print(f"  Type:        {r['type']}")
    if r['timestamp']:
        print(f"  Timestamp:   {r['timestamp']}")
    if r['duration'] is not None:
        print(f"  Duration:    {r['duration']} ms")

    if r['command_text']:
        print(f"  Command [{r['command_source']}]:")
        print(f"    {format_value_full(r['command_text'])}")

    if r['stdout']:
        print(f"  Stdout ({len(r['stdout'])} chars):")
        out_preview = r['stdout'][:300].replace('\n', '\\n')
        print(f"    {out_preview}{'...' if len(r['stdout']) > 300 else ''}")

    if r['stderr']:
        print(f"  Stderr ({len(r['stderr'])} chars):")
        err_preview = r['stderr'][:500].replace('\n', '\\n')
        print(f"    {err_preview}{'...' if len(r['stderr']) > 500 else ''}")

    if r['error']:
        print(f"  Error ({len(r['error'])} chars):")
        err_preview = r['error'][:500]
        print(f"    {err_preview}{'...' if len(r['error']) > 500 else ''}")

    if r['patterns']:
        print(f"  Pattern hits:    {', '.join(r['patterns'])}")
    if r['patterns_in_cmd']:
        print(f"  Cmd-pattern hits: {', '.join(r['patterns_in_cmd'])}")


def main():
    print("=" * 78)
    print("  Claude Bridge r_*.json Failure Scanner")
    print("  Base: " + BASE_DIR)
    print("=" * 78)

    # Step 1: Extract command texts from watcher logs
    print_separator("STEP 1: Extracting command texts from watcher logs")
    commands_map = {}
    commands_map.update(extract_commands_from_watcher_log(WATCHER_LOG_PATH))
    commands_map.update(extract_commands_from_process_watcher_log(PROCESS_WATCHER_LOG_PATH))
    print(f"  Commands found in watcher logs: {len(commands_map)}")

    summaries_map = extract_from_error_history(ERROR_HISTORY_PATH)
    print(f"  Command summaries in error_history: {len(summaries_map)}")

    # Step 2: Scan directories
    print_separator("STEP 2: Scanning r_*.json files")
    all_results = []
    for d in SEARCH_DIRS:
        results = scan_directory(d, commands_map, summaries_map)
        all_results.extend(results)

    # Remove duplicates
    seen = set()
    unique_results = []
    for r in sorted(all_results, key=lambda x: (x['file'], 0 if x['exit_code'] != 0 else 1)):
        key = (r['file'], r['cmd_id'])
        if key not in seen:
            seen.add(key)
            unique_results.append(r)
        else:
            for i, existing in enumerate(unique_results):
                if (existing['file'], existing['cmd_id']) == key:
                    if existing['exit_code'] == 0 and r['exit_code'] != 0:
                        unique_results[i] = r
                    break

    print(f"\n  Total unique result entries: {len(unique_results)}")

    # Step 3: Failed commands
    print_separator("STEP 3: Failed Commands (exit_code != 0)")
    failed = [r for r in unique_results if r['exit_code'] is not None and r['exit_code'] != 0]
    print(f"  Failed commands: {len(failed)}")
    for r in failed:
        print_failed_command(r)

    # Step 4: Pattern analysis
    print_separator("STEP 4: Pattern Analysis Across ALL Files (including successful)")
    for key, pdata in PATTERNS.items():
        matches = [r for r in unique_results
                   if key in r['patterns'] or key in r['patterns_in_cmd']]
        print(f"\n  --- Pattern: {pdata['name']} ---")
        print(f"  Found {len(matches)} total occurrences")
        for r in matches:
            where = []
            if key in r['patterns']:
                where.append("error/stderr/stdout")
            if key in r['patterns_in_cmd']:
                where.append("command")
            ec = r['exit_code']
            ec_str = f"exit={ec}" if ec is not None else "exit=N/A"
            print(f"    {r['cmd_id']:30s} {ec_str:12s} [{', '.join(where)}]")
            if r['command_text'] and key in r['patterns_in_cmd']:
                cmd_text = r['command_text']
                m = pdata['pattern'].search(cmd_text)
                if m:
                    start = max(0, m.start() - 40)
                    end = min(len(cmd_text), m.end() + 40)
                    ctx = cmd_text[start:end]
                    if start > 0:
                        ctx = "..." + ctx
                    if end < len(cmd_text):
                        ctx = ctx + "..."
                    print(f"      context: {repr(ctx)}")

    # Step 5: The 5 specific target commands
    print_separator("STEP 5: The 5 Specific Target Commands")
    target_ids = ['check_keys', 'kill_proxy', 'daily_report_v1', 'test_prefix_oa', 'start_new_proxy']
    for tid in target_ids:
        targets = [r for r in unique_results if r['cmd_id'] == tid]
        if not targets:
            print(f"\n  --- {tid}: NOT FOUND IN RESULT FILES ---")
            if tid in commands_map:
                cmd_info = commands_map[tid]
                print(f"  But found in watcher log: type={cmd_info['type']}")
                print(f"  Full command ({len(cmd_info['command'])} chars):")
                print(f"    {cmd_info['command']}")
        else:
            for t in targets:
                print(f"\n  --- {tid} [in {os.path.basename(os.path.dirname(t['file']))}] ---")
                print_failed_command(t)

    # Step 6: Summary statistics
    print_separator("SUMMARY STATISTICS")
    total = len(unique_results)
    total_failed = len(failed)

    exit_codes = {}
    for r in unique_results:
        ec = r['exit_code']
        exit_codes[ec] = exit_codes.get(ec, 0) + 1

    print(f"\n  Total r_*.json files:      {total}")
    print(f"  Failed (exit_code != 0):    {total_failed}")
    print(f"  Success (exit_code == 0):   {exit_codes.get(0, 0)}")
    print(f"  No exit code:               {exit_codes.get(None, 0)}")
    print(f"\n  Exit code distribution:")
    for ec in sorted(exit_codes.keys(), key=lambda x: (x is None, x)):
        count = exit_codes[ec]
        bar = "#" * (count // 3)
        print(f"    {ec!s:10s}: {count:4d} {bar}")

    print(f"\n  Pattern occurrence summary:")
    for key, pdata in PATTERNS.items():
        count = len([r for r in unique_results if key in r['patterns'] or key in r['patterns_in_cmd']])
        bar = "#" * (count // 3)
        print(f"    {pdata['name']:40s}: {count:4d} {bar}")


if __name__ == '__main__':
    main()
