#!/usr/bin/env python3
"""Watch bridge: lets the watch's "Hermes" voice provider talk to Claude Code on your own server.

The iPhone app sends an OpenAI-style chat request (POST /v1/chat/completions, Bearer key).
This bridge runs `claude -p` (Claude Code, logged in with your own Claude account) and returns
the answer. Claude Code brings your claude.ai connectors (Gmail, Calendar, ...) and your MCP
servers. While Claude uses a tool, the bridge sends a "hermes.tool.progress" event so the watch
announces "I'm using a tool".

Personal use only: one person, one Claude account, your own server. Standard library only.

Settings (environment variables, all optional except the key file):
  BRIDGE_KEY_FILE      file with the bearer key (default ~/.config/claude-watch-bridge/key, mode 600)
  BRIDGE_HOST / PORT   listen address (default 127.0.0.1:18650; put HTTPS in front, see README)
  CLAUDE_BIN           path to the claude CLI (default: claude on PATH)
  CLAUDE_MODEL         model alias/ID passed to --model (default: the CLI default)
  CLAUDE_WORKDIR       working directory for claude (default ~/.local/share/claude-watch-bridge/work)
  CLAUDE_TIMEOUT       seconds per request (default 110; the iPhone gives up after 120)
  CLAUDE_DISALLOWED    built-in tools to block (default: Bash Edit Write NotebookEdit Read Glob Grep Task)
"""
import hmac
import json
import os
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOME = Path.home()
KEY_FILE = Path(os.environ.get("BRIDGE_KEY_FILE", HOME / ".config/claude-watch-bridge/key"))
HOST = os.environ.get("BRIDGE_HOST", "127.0.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "18650"))
CLAUDE_BIN = os.environ.get("CLAUDE_BIN", "claude")
CLAUDE_MODEL = os.environ.get("CLAUDE_MODEL", "").strip()
WORKDIR = Path(os.environ.get("CLAUDE_WORKDIR", HOME / ".local/share/claude-watch-bridge/work"))
TIMEOUT = int(os.environ.get("CLAUDE_TIMEOUT", "110"))
# Mail or calendar content could carry instructions for Claude, so by default it gets no shell,
# no file access and no sub-agents on this server: only connectors, MCP servers and web tools.
DISALLOWED = os.environ.get(
    "CLAUDE_DISALLOWED", "Bash Edit Write NotebookEdit Read Glob Grep Task"
).split()
MAX_BODY = 256 * 1024

SYSTEM_PROMPT = (
    "You are answering through the user's smartwatch. Your reply is read aloud over a phone-call "
    "line and shown on a small round screen. Answer in the language the user speaks (usually German). "
    "Keep it short: two or three spoken sentences unless asked for more. Plain text only: no markdown, "
    "lists, tables, emojis or URLs. Use the user's connectors when the question needs them. Before "
    "sending, deleting or changing anything (mail, events, files, messages), say exactly what you "
    "would do and only do it after the user confirms in a later message."
)

busy = threading.Lock()


def load_key() -> str:
    try:
        key = KEY_FILE.read_text().strip()
    except FileNotFoundError:
        sys.exit(f"Key file {KEY_FILE} is missing (see tools/claude-bridge/README.md)")
    if len(key) < 24:
        sys.exit(f"The key in {KEY_FILE} is too short (at least 24 characters)")
    if KEY_FILE.stat().st_mode & 0o077:
        sys.exit(f"{KEY_FILE} must not be readable by others: chmod 600 {KEY_FILE}")
    return key


KEY = ""


def build_prompt(messages: list) -> str:
    """claude -p takes one prompt, so earlier turns go in as a short transcript."""
    turns = [m for m in messages if isinstance(m, dict) and m.get("role") in ("user", "assistant")]
    if not turns or turns[-1].get("role") != "user":
        raise ValueError("the last message must come from the user")
    question = str(turns[-1].get("content", "")).strip()
    if not question:
        raise ValueError("empty question")
    history = turns[:-1][-12:]
    if not history:
        return question
    lines = ["Earlier in this conversation:"]
    for m in history:
        who = "User" if m["role"] == "user" else "You"
        lines.append(f"{who}: {str(m.get('content', '')).strip()}")
    lines += ["", "The user now says:", question]
    return "\n".join(lines)


def claude_command(prompt: str) -> list:
    cmd = [CLAUDE_BIN, "-p", prompt, "--output-format", "stream-json", "--verbose",
           "--append-system-prompt", SYSTEM_PROMPT,
           # needed so connector tools run without an interactive approval; the dangerous
           # built-in tools are removed with --disallowedTools below
           "--permission-mode", "bypassPermissions"]
    if DISALLOWED:
        cmd += ["--disallowedTools", *DISALLOWED]
    if CLAUDE_MODEL:
        cmd += ["--model", CLAUDE_MODEL]
    return cmd


def run_claude(prompt: str, on_tool):
    """Runs Claude Code and returns the final text; calls on_tool() whenever a tool starts."""
    WORKDIR.mkdir(parents=True, exist_ok=True)
    proc = subprocess.Popen(claude_command(prompt), cwd=WORKDIR, stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    timer = threading.Timer(TIMEOUT, proc.kill)
    timer.start()
    result, texts = None, []
    try:
        for line in proc.stdout:
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            kind = event.get("type")
            if kind == "assistant":
                for block in (event.get("message") or {}).get("content") or []:
                    if block.get("type") == "tool_use":
                        on_tool(block.get("name", ""))
                    elif block.get("type") == "text" and block.get("text"):
                        texts.append(block["text"])
            elif kind == "result":
                if event.get("is_error"):
                    raise RuntimeError(str(event.get("result") or event.get("subtype") or "claude error"))
                result = event.get("result")
        proc.wait()
    finally:
        timer.cancel()
        if proc.poll() is None:
            proc.kill()
    if proc.returncode not in (0, None) and not result:
        err = (proc.stderr.read() or "").strip().splitlines()
        raise RuntimeError(err[-1] if err else f"claude exited with {proc.returncode}")
    answer = (result or (texts[-1] if texts else "")).strip()
    if not answer:
        raise RuntimeError("Claude returned no text (timeout?)")
    return answer


class Handler(BaseHTTPRequestHandler):
    server_version = "claude-watch-bridge"
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):  # no request bodies or keys in the log
        sys.stderr.write("%s %s\n" % (time.strftime("%H:%M:%S"), fmt % args))

    def send_json(self, status: int, payload: dict):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if status >= 400:
            # the request body may not have been read: close instead of reusing the connection
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(body)

    def authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        token = header[7:] if header.startswith("Bearer ") else ""
        return hmac.compare_digest(token.encode(), KEY.encode())

    def do_GET(self):
        if self.path.rstrip("/") == "/health":
            return self.send_json(200, {"ok": True})
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        if not self.authorized():
            return self.send_json(401, {"error": "unauthorized"})
        if not self.path.rstrip("/").endswith("/v1/chat/completions"):
            return self.send_json(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY:
            return self.send_json(413, {"error": "bad request size"})
        try:
            request = json.loads(self.rfile.read(length))
            prompt = build_prompt(request.get("messages") or [])
        except (ValueError, json.JSONDecodeError) as error:
            return self.send_json(400, {"error": str(error)})
        if not busy.acquire(timeout=5):
            return self.send_json(429, {"error": "busy"})
        try:
            if request.get("stream"):
                self.answer_stream(prompt)
            else:
                self.answer_json(prompt)
        finally:
            busy.release()

    def answer_json(self, prompt: str):
        try:
            answer = run_claude(prompt, on_tool=lambda name: None)
        except Exception as error:  # noqa: BLE001 - report every failure to the watch
            self.log_message("claude failed: %s", error)
            return self.send_json(502, {"error": str(error)})
        self.send_json(200, {
            "id": "chatcmpl-" + uuid.uuid4().hex, "object": "chat.completion",
            "choices": [{"index": 0, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": answer}}],
        })

    def answer_stream(self, prompt: str):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

        def send(data: str, event: str = ""):
            chunk = (f"event: {event}\n" if event else "") + f"data: {data}\n\n"
            self.wfile.write(chunk.encode())
            self.wfile.flush()

        def on_tool(name: str):
            self.log_message("tool: %s", name)
            send(json.dumps({"status": "running", "tool": name}), event="hermes.tool.progress")

        cid = "chatcmpl-" + uuid.uuid4().hex
        try:
            answer = run_claude(prompt, on_tool)
            send(json.dumps({"id": cid, "object": "chat.completion.chunk",
                             "choices": [{"index": 0, "delta": {"content": answer}, "finish_reason": "stop"}]}))
        except Exception as error:  # noqa: BLE001
            self.log_message("claude failed: %s", error)
            send(json.dumps({"id": cid, "object": "chat.completion.chunk",
                             "choices": [{"index": 0, "delta": {}, "finish_reason": "error"}]}))
        send("[DONE]")


def main():
    global KEY
    KEY = load_key()
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"claude-watch-bridge listening on http://{HOST}:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
