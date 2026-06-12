#!/usr/bin/env python3
"""Add pool-sync bug learning entry to error_history.json"""
import json, sys, os

base = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
path = os.path.join(base, "watcher", "error_history.json")

with open(path, "r", encoding="utf-8") as f:
    data = json.load(f)

entry = {
    "cmd_id": "__LEARN__pool_sync_pscustomobject",
    "timestamp": "2026-06-12 11:33:00.000",
    "type": "system",
    "command_summary": "@{} + $w failed on PSCustomObject in Sync-WorkerPool — V2.4 regression",
    "exit_code": -1,
    "issue": "pscustomobject_hashtable_conversion",
    "duration_ms": 0,
    "patterns": [
        "ps_5_1_compat",
        "hashtable_operation_on_pscustomobject",
        "silent_failure_since_v2.4"
    ],
    "stderr_snippet": (
        "只能将哈希表添加到另一个哈希表中 — fix: use _ConvertTo-Hashtable "
        "via PSObject.Properties iteration (commit 20cf161)"
    ),
    "clixml_stripped": False,
    "auto_detected": True
}

# Deduplicate: replace existing __LEARN__pool_sync entry if present
data["errors"] = [e for e in data.get("errors", [])
                  if e.get("cmd_id") != "__LEARN__pool_sync_pscustomobject"]
data["errors"].append(entry)

# Keep under 200 entries
if len(data["errors"]) > 200:
    data["errors"] = data["errors"][-200:]

data["last_updated"] = "2026-06-12 11:33:00.000"
data["total_errors_logged"] = len(data["errors"])

with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))

print(f"DONE: {len(data['errors'])} errors in history")
