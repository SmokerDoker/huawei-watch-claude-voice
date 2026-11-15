#!/usr/bin/env python3
"""Minimal MCP server (stdio) that gives Claude a fixed set of DocuSort staging commands.

Every tool maps to one whitelisted claude-ops command on the DocuSort VM
(ssh docusort-ops <command>, forced to `sudo -n /usr/local/sbin/claude-ops` by authorized_keys).
No shell, no free-form arguments: Claude can only call these tools. Standard library only.

Register for the claude-watch user:
  claude mcp add --scope user docusort-staging -- python3 /home/claude-watch/.local/share/claude-watch-bridge/staging_mcp.py
"""
import json
import os
import subprocess
import sys

SSH_HOST = os.environ.get("STAGING_SSH_HOST", "docusort-ops")
SSH = os.environ.get("STAGING_SSH_BIN", "ssh")

# name -> (claude-ops command, description, timeout seconds, changes something?)
TOOLS = {
    "staging_status": ("staging-status", "State and health of the DocuSort staging stack.", 60, False),
    "staging_stats": ("staging-stats", "CPU and RAM of the staging containers.", 60, False),
    "staging_up": ("staging-up", "Start the staging stack (refuses when the VM has too little free RAM).", 240, True),
    "staging_down": ("staging-down", "Stop the staging stack (checks 20 s later that it stays stopped).", 240, True),
    "staging_restart": ("staging-restart", "Restart the staging stack.", 240, True),
    "prod_status": ("prod-status", "Read-only state/health of production (docusort-server, Meilisearch). No logs.", 60, False),
    "host_stats": ("host-stats", "RAM, load, disk and container usage of the DocuSort VM.", 60, False),
}
LOGS = ("staging_logs", "Recent logs of a staging service (server or meilisearch).")


def tool_list():
    tools = []
    for name, (_, desc, _, changes) in TOOLS.items():
        tools.append({
            "name": name,
            "description": desc + (" Changes the server: confirm with the user first." if changes else ""),
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
            "annotations": {"readOnlyHint": not changes, "destructiveHint": changes},
        })
    tools.append({
        "name": LOGS[0], "description": LOGS[1],
        "inputSchema": {
            "type": "object",
            "properties": {
                "service": {"type": "string", "enum": ["server", "meilisearch"], "default": "server"},
                "lines": {"type": "integer", "minimum": 1, "maximum": 500, "default": 50},
            },
            "additionalProperties": False,
        },
        "annotations": {"readOnlyHint": True},
    })
    return tools


def run_ops(args, timeout):
    try:
        proc = subprocess.run([SSH, "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", SSH_HOST, *args],
                              capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return f"Timeout after {timeout} s (the command may still be running on the server).", True
    out = (proc.stdout + ("\n" + proc.stderr if proc.stderr.strip() else "")).strip()
    return out[-6000:] or f"(no output, exit {proc.returncode})", proc.returncode != 0


def call_tool(name, arguments):
    arguments = arguments or {}
    if name in TOOLS:
        if arguments:
            return "This tool takes no arguments.", True
        command, _, timeout, _ = TOOLS[name]
        return run_ops([command], timeout)
    if name == LOGS[0]:
        service = arguments.get("service", "server")
        lines = arguments.get("lines", 50)
        if service not in ("server", "meilisearch") or not isinstance(lines, int) or not 1 <= lines <= 500 \
                or set(arguments) - {"service", "lines"}:
            return "Invalid arguments: service must be server|meilisearch, lines 1..500.", True
        return run_ops(["staging-logs", service, str(lines)], 60)
    return f"Unknown tool {name}", True


def reply(msg_id, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": msg_id}
    if error:
        msg["error"] = error
    else:
        msg["result"] = result
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        method, msg_id = msg.get("method"), msg.get("id")
        if msg_id is None:  # notification (e.g. notifications/initialized)
            continue
        if method == "initialize":
            requested = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
            reply(msg_id, {"protocolVersion": requested,
                           "capabilities": {"tools": {}},
                           "serverInfo": {"name": "docusort-staging", "version": "1.0.0"}})
        elif method == "ping":
            reply(msg_id, {})
        elif method == "tools/list":
            reply(msg_id, {"tools": tool_list()})
        elif method == "tools/call":
            params = msg.get("params") or {}
            text, is_error = call_tool(params.get("name"), params.get("arguments"))
            reply(msg_id, {"content": [{"type": "text", "text": text}], "isError": is_error})
        else:
            reply(msg_id, error={"code": -32601, "message": f"Method not found: {method}"})


if __name__ == "__main__":
    main()
