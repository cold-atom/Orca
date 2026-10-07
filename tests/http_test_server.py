#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import time


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests_remaining = int(os.environ.get("ORCA_TEST_REQUESTS", "21"))

    def do_GET(self):
        try:
            if self.path == "/local-models/api/tags":
                if self.headers.get("Authorization") is not None:
                    self._send_json_error(400, "Unexpected authorization")
                else:
                    self._send_json(200, {"models": [
                        {"model": "qwen-coder-local", "name": "Qwen Coder Local", "capabilities": ["completion", "tools"], "details": {"context_length": 32768}},
                        {"model": "nomic-embed-local", "capabilities": ["embedding"]},
                        {"model": "neutral-local", "name": "Neutral Local"},
                    ]})
            elif self.path == "/lmstudio-models/api/v1/models":
                self._send_json(200, {"models": [
                    {"type": "llm", "key": "llama-local", "display_name": "Llama Local", "max_context_length": 131072, "loaded_instances": [{"config": {"context_length": 8192}}]},
                    {"type": "embedding", "key": "text-embedding-local", "display_name": "Embedding Local"},
                ]})
            elif self.path == "/redirect-models/api/tags":
                self.send_response(302)
                self.send_header("Location", "http://127.0.0.1:18473/local-models/api/tags")
                self.send_header("Content-Length", "0")
                self.send_header("Connection", "close")
                self.end_headers()
            else:
                self._send_json_error(404, "Not found")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self._complete_request()

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", "0"))
        request_body = self.rfile.read(content_length)
        try:
            if self.path.startswith("/success/"):
                self._send_sse([
                    b'data: {"choices":[{"delta":{"content":"ok"},"finish_reason":"stop"}]}\n\n',
                    b'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path.startswith("/empty-done/"):
                self._send_sse([b"data: [DONE]\n\n"])
            elif self.path.startswith("/reasoning-only/"):
                self._send_sse([
                    b'data: {"choices":[{"delta":{"reasoning_content":"hidden"},"finish_reason":"stop"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path.startswith("/whitespace-only/"):
                self._send_sse([
                    b'data: {"choices":[{"delta":{"content":"  \\n"},"finish_reason":"stop"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path.startswith("/normal-content/"):
                self._send_sse([
                    b'data: {"choices":[{"delta":{"content":"visible"},"finish_reason":"stop"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path.startswith("/tool-only/"):
                self._send_sse([
                    b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_fixture","type":"function","function":{"name":"read_file","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path.startswith("/finish-length/"):
                self._send_sse([
                    b'data: {"choices":[{"delta":{"content":"partial"},"finish_reason":"length"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path.startswith("/finish-content-filter/"):
                self._send_sse([
                    b'data: {"choices":[{"delta":{"content":"partial"},"finish_reason":"content_filter"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path.startswith("/disconnect/"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n')
                self.wfile.flush()
                self.close_connection = True
            elif self.path.startswith("/generation-deadline/"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                self.send_header("Connection", "close")
                self.end_headers()
                for index in range(100):
                    event = {"choices": [{"delta": {"reasoning_content": "hidden-%d" % index}, "finish_reason": None}]}
                    self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                    self.wfile.flush()
                    time.sleep(0.04)
            elif self.path.startswith("/retry-generation-deadline/"):
                body = json.loads(request_body)
                if "stream_options" in body:
                    time.sleep(0.3)
                    self._send_json_error(400, "stream_options are unsupported")
                else:
                    self.send_response(200)
                    self.send_header("Content-Type", "text/event-stream; charset=utf-8")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    for index in range(40):
                        event = {"choices": [{"delta": {"reasoning_content": "retry-hidden-%d" % index}, "finish_reason": None}]}
                        self.wfile.write(("data: " + json.dumps(event) + "\n\n").encode())
                        self.wfile.flush()
                        time.sleep(0.1)
                    self.wfile.write(b'data: {"choices":[{"delta":{"content":"retry complete"},"finish_reason":"stop"}]}\n\n')
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
            elif self.path.startswith("/oversized/"):
                chunk = b": padding padding padding padding padding padding padding padding\n"
                body = chunk * ((16 * 1024 * 1024 // len(chunk)) + 100)
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                self.wfile.flush()
            elif self.path.startswith("/framed/"):
                chunk = b": provider framing that carries no accumulated response content\n"
                padding = chunk * ((5 * 1024 * 1024 // len(chunk)) + 1)
                self._send_sse([
                    padding,
                    b'data: {"choices":[{"delta":{"content":"framed ok"},"finish_reason":"stop"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            elif self.path == "/gemini/chat/completions":
                body = json.loads(request_body)
                if (
                    self.headers.get("Authorization") != "Bearer local-test-key"
                    or body.get("model") != "gemini-3-flash-preview"
                    or body.get("tool_choice") != "auto"
                ):
                    self._send_json_error(400, "Invalid Gemini request")
                else:
                    self._send_sse([
                        b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"gemini_call","type":"function","function":{"name":"read_file","arguments":"{}"},"extra_content":{"google":{"thought_signature":"test-signature"}}}]},"finish_reason":"tool_calls"}]}\n\n',
                        b"data: [DONE]\n\n",
                    ])
            elif self.path == "/xai/chat/completions":
                body = json.loads(request_body)
                if (
                    self.headers.get("Authorization") != "Bearer local-test-key"
                    or body.get("model") != "grok-4"
                    or body.get("reasoning_effort") != "high"
                ):
                    self._send_json_error(400, "Invalid xAI request")
                else:
                    self._send_sse([
                        b'data: {"choices":[{"delta":{"content":"grok ok","reasoning_content":"hidden"},"finish_reason":"stop"}]}\n\n',
                        b"data: [DONE]\n\n",
                    ])
            elif self.path == "/local/v1/chat/completions":
                body = json.loads(request_body)
                if self.headers.get("Authorization") is not None or body.get("model") != "local-model":
                    self._send_json_error(400, "Invalid keyless local request")
                else:
                    self._send_sse([
                        b'data: {"choices":[{"delta":{"content":"local ok"},"finish_reason":"stop"}]}\n\n',
                        b"data: [DONE]\n\n",
                    ])
            elif self.path == "/probe/v1/chat/completions":
                body = json.loads(request_body)
                messages = body.get("messages", [])
                tool_messages = [message for message in messages if message.get("role") == "tool"]
                if not tool_messages:
                    user_content = str(messages[-1].get("content", ""))
                    challenge = user_content.split('"')[1] if '"' in user_content else ""
                    arguments = json.dumps({"challenge": challenge}, separators=(",", ":"))
                    event = {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "probe-http-call", "type": "function", "function": {"name": "orca_agent_probe", "arguments": arguments}}]}, "finish_reason": "tool_calls"}]}
                    self._send_sse([("data: " + json.dumps(event) + "\n\n").encode(), b"data: [DONE]\n\n"])
                else:
                    result = json.loads(tool_messages[-1].get("content", "{}"))
                    if tool_messages[-1].get("tool_call_id") != "probe-http-call":
                        self._send_json_error(400, "Mismatched probe call ID")
                    else:
                        marker = "ORCA_AGENT_PROBE_OK " + str(result.get("challenge", ""))
                        event = {"choices": [{"delta": {"content": marker}, "finish_reason": "stop"}]}
                        self._send_sse([("data: " + json.dumps(event) + "\n\n").encode(), b"data: [DONE]\n\n"])
            elif self.path == "/embedding-error/v1/chat/completions":
                self._send_json_error(400, "The selected model does not support chat")
            elif self.path == "/model-mismatch/v1/chat/completions":
                self._send_sse([
                    b'data: {"model":"llama-chat","choices":[{"delta":{"content":"substituted"},"finish_reason":"stop"}]}\n\n',
                    b"data: [DONE]\n\n",
                ])
            else:
                body = b"not an OpenAI response"
                self.send_response(200)
                self.send_header("Content-Type", "text/html")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            self._complete_request()

    def _send_sse(self, chunks):
        body = b"".join(chunks)
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()

    def _send_json_error(self, status, message):
        self._send_json(status, {"error": {"message": message}})

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def _complete_request(self):
        Handler.requests_remaining -= 1
        if Handler.requests_remaining <= 0:
            self.server.shutdown_requested = True

    def log_message(self, _format, *_args):
        pass


server = ReusableHTTPServer(("127.0.0.1", 18473), Handler)
server.timeout = 0.2
server.shutdown_requested = False
while not server.shutdown_requested:
    server.handle_request()
server.server_close()
