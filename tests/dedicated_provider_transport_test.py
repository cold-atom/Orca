"""Real HTTP/SSE provider integration with disposable Godot state and synthetic replies."""
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import threading
import base64
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_POST(self):
        try:
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            self.server.requests.append((self.path, body))
            self.anthropic(body) if "/anthropic/" in self.path else self.qwen(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        except Exception as error:
            self.server.failures.append(str(error))
            self.send_error(400, "fixture contract failed")

    def sse(self, events):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        payload = b"".join(("data: " + (event if isinstance(event, str) else json.dumps(event)) + "\n\n").encode() for event in events)
        for index in range(0, len(payload), 29):
            self.wfile.write(payload[index:index + 29])
            self.wfile.flush()

    def do_GET(self):
        try:
            self.server.requests.append((self.path, None))
            assert self.path.endswith("/anthropic/discovery/models")
            assert self.headers["x-api-key"] == "synthetic-fixture-key"
            assert self.headers["anthropic-version"] == "2026-10-21"
            payload = json.dumps({"data": [{"type": "model", "id": "claude-sonnet-4-6", "display_name": "Claude Sonnet", "max_input_tokens": 200000, "capabilities": {"image_input": {"supported": True}}}, {"type": "model", "id": "claude-retired", "lifecycle": "retired"}], "has_more": True}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except Exception as error:
            self.server.failures.append(str(error))

    def anthropic(self, body):
        assert self.headers["x-api-key"] == "synthetic-fixture-key"
        assert self.headers["anthropic-version"] == "2026-10-21"
        assert self.headers.get("Authorization") is None
        assert body["model"] == "claude-sonnet-4-6" and body["max_tokens"] == 8192
        assert body["thinking"] == {"type": "adaptive", "display": "omitted"}
        assert body["output_config"] == {"effort": "high"}
        assert "stream_options" not in body and "reasoning_effort" not in body
        assert all(message["role"] in ("user", "assistant") for message in body["messages"])
        results = [block for message in body["messages"] for block in message["content"] if block["type"] == "tool_result"]
        scenario = self.path.split("/")[-2]
        def start():
            return {"type": "message_start", "message": {"type": "message", "id": "msg_fixture", "model": body["model"], "role": "assistant", "content": [], "stop_reason": None, "usage": {"input_tokens": 12, "output_tokens": 1, "cache_read_input_tokens": 3, "cache_creation_input_tokens": 5}}}
        def block(index, content):
            return [{"type": "content_block_start", "index": index, "content_block": content}, {"type": "content_block_stop", "index": index}]
        def end(reason):
            return [{"type": "message_delta", "delta": {"stop_reason": reason}, "usage": {"output_tokens": 9}}, {"type": "message_stop"}]
        def text(answer):
            return block(0, {"type": "text", "text": answer})
        if scenario == "json":
            reply = start()["message"]
            reply.update(content=[{"type": "text", "text": "native JSON complete"}], stop_reason="end_turn")
            payload = json.dumps(reply).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if scenario == "error_http":
            payload = json.dumps({"type": "error", "error": {"type": "invalid_request_error", "message": "PRIVATE_THINKING signed_native opaque_native"}}).encode()
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        if scenario == "image":
            images = [part for message in body["messages"] for part in message["content"] if part["type"] == "image"]
            assert len(images) == 1 and images[0]["source"]["type"] == "base64"
            assert images[0]["source"]["media_type"] == "image/png"
            assert base64.b64decode(images[0]["source"]["data"]).startswith(b"\x89PNG")
        if results:
            if scenario == "probe":
                assert "ORCA SYNTHETIC CONTINUATION CHECK" in body["system"]
                answer = json.loads(results[0]["content"])["required_reply"]
            else:
                assert len(results) == 2 and {item["tool_use_id"] for item in results} == {"native_1", "native_2"}
                assert len([item for item in body["messages"][-1]["content"] if item["type"] == "tool_result"]) == 2
                thinking = body["messages"][-2]["content"][0]
                assert thinking == {"type": "thinking", "thinking": "PRIVATE_THINKING", "signature": "signed_native"}
                assert body["messages"][-2]["content"][1] == {"type": "redacted_thinking", "data": "opaque_native"}
                if scenario == "loop":
                    assert "refreshed native task context" in body["system"]
                answer = "Claude complete"
            self.sse([start(), *text(answer), *end("end_turn")])
            return
        if scenario in ("error", "cancel"):
            events = [start(), *text("visible prefix")]
            if scenario == "error": events.append({"type": "error", "error": {"type": "overloaded_error", "message": "PRIVATE_THINKING signed_native opaque_native"}})
            self.sse(events)
            return
        if scenario == "unsupported":
            self.sse([start(), {"type": "content_block_start", "index": 0, "content_block": {"type": "server_tool_use", "id": "server", "name": "code_execution", "input": {}}}])
            return
        events = [start(), {"type": "ping"}]
        events += [{"type": "content_block_start", "index": 0, "content_block": {"type": "thinking", "thinking": "", "signature": ""}}, {"type": "content_block_delta", "index": 0, "delta": {"type": "thinking_delta", "thinking": "PRIVATE_THINKING"}}, {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "signed_"}}, {"type": "content_block_delta", "index": 0, "delta": {"type": "signature_delta", "signature": "native"}}, {"type": "content_block_stop", "index": 0}]
        if scenario == "hidden_only":
            self.sse([*events, *end("end_turn")])
            return
        events += block(1, {"type": "redacted_thinking", "data": "opaque_native"})
        if scenario == "probe":
            assert body["tools"][0]["name"] == "orca_agent_probe"
            question = body["messages"][-1]["content"][0]["text"]
            challenge = re.search(r'challenge "([^"]+)"', question)[1]
            events += block(2, {"type": "tool_use", "id": "probe_native", "name": "orca_agent_probe", "input": {"challenge": challenge}})
        else:
            events += [{"type": "content_block_start", "index": 2, "content_block": {"type": "tool_use", "id": "native_1", "name": "read_file", "input": {}}}, {"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": '{"path":'}}, {"type": "content_block_delta", "index": 2, "delta": {"type": "input_json_delta", "partial_json": '"res://player.gd"}' if scenario != "malformed" else '"unterminated'}}, {"type": "content_block_stop", "index": 2}]
            events += block(3, {"type": "tool_use", "id": "native_1" if scenario == "duplicate" else "native_2", "name": "list_directory", "input": {}})
        events += end("max_tokens" if scenario == "max_tokens" else "tool_use")
        if scenario == "truncated": events.pop()
        self.sse(events)

    def qwen(self, body):
        assert self.headers["Authorization"] == "Bearer synthetic-fixture-key"
        assert body["model"] == "qwen-plus" and body["enable_thinking"] is False
        assert body["stream"] is True and body["max_tokens"] == 8192
        messages = body["messages"]
        assert sum(message["role"] == "system" for message in messages) <= 1
        if any(message["role"] == "system" for message in messages):
            assert messages[0]["role"] == "system"
        def chunk(delta, finish=None):
            return {"model": "qwen-plus", "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
        results = [message for message in messages if message["role"] == "tool"]
        if "/probe/" in self.path:
            if results:
                assert "ORCA SYNTHETIC CONTINUATION CHECK" in messages[0]["content"]
                answer = json.loads(results[0]["content"])["required_reply"]
                self.sse([chunk({"content": answer}, "stop"), "[DONE]"])
            else:
                challenge = re.search(r'challenge "([^"]+)"', messages[-1]["content"])[1]
                call = {"index": 0, "id": "probe-call", "type": "function", "function": {"name": "orca_agent_probe", "arguments": json.dumps({"challenge": challenge})}}
                self.sse([chunk({"tool_calls": [call]}, "tool_calls"), "[DONE]"])
        elif "/cancel/" in self.path:
            self.sse([chunk({"content": "cancel here"})])
        elif results:
            assert results[0]["tool_call_id"] == "qwen-call" and results[0]["content"] == "saved script source"
            assert "refreshed task context" in messages[0]["content"]
            self.sse([chunk({"content": "Qwen complete"}, "stop"), {"choices": [], "usage": {"prompt_tokens": 30, "completion_tokens": 5}}, "[DONE]"])
        else:
            assert "fresh editor context" in messages[0]["content"]
            call = {"index": 0, "id": "qwen-call", "type": "function", "function": {"name": "read_file", "arguments": '{"path":'}}
            tail = {"index": 0, "id": "", "function": {"name": None, "arguments": '"res://player.gd"}'}}
            self.sse([chunk({"tool_calls": [call]}), chunk({"tool_calls": [tail]}, "tool_calls"), "[DONE]"])


class DedicatedProviderTransportTest(unittest.TestCase):
    def test_real_provider_round_trips(self):
        binary = os.environ.get("GODOT_BIN")
        if not binary:
            self.skipTest("Set GODOT_BIN to run actual Godot HTTP/SSE integration")
        from run_editor_test import execute
        with tempfile.TemporaryDirectory(prefix="orca-provider-transport-", dir=os.environ.get("ORCA_TEST_TMPDIR")) as folder:
            state = Path(folder)
            project = state / "project"
            project.mkdir()
            shutil.copytree(ROOT / "addons/orca", project / "addons/orca", ignore=shutil.ignore_patterns("*.import", "__pycache__", "*.pyc"))
            (project / "tests").mkdir()
            shutil.copy2(ROOT / "tests/dedicated_provider_integration_test.gd", project / "tests/dedicated_provider_integration_test.gd")
            (project / "project.godot").write_text('config_version=5\n[application]\nconfig/name="Orca provider transport fixture"\n')
            server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
            server.requests, server.failures = [], []
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            env = dict(os.environ, ORCA_DISABLE_ACCOUNT_RESTORE="1", ORCA_DISABLE_UPDATE_CHECKS="1", ORCA_DISABLE_NATIVE_HELPER_DOWNLOADS="1", XDG_CONFIG_HOME=str(state / "config"), XDG_DATA_HOME=str(state / "data"), XDG_CACHE_HOME=str(state / "cache"), ORCA_PROVIDER_FIXTURE_URL=f"http://127.0.0.1:{server.server_port}")
            try:
                self.assertTrue(execute([binary, "--headless", "--editor", "--path", str(project), "--import", "--quiet"], env))
                passed = execute([binary, "--headless", "--path", str(project), "--script", "res://tests/dedicated_provider_integration_test.gd"], env, "dedicated_provider_integration_test: PASS")
                self.assertEqual(server.failures, [])
                self.assertTrue(passed)
                self.assertEqual(len(server.requests), 22, "accepted requests must not be replayed")
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
