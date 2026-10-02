#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import json


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests_remaining = 7

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
            elif self.path.startswith("/disconnect/"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(b'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n')
                self.wfile.flush()
                self.close_connection = True
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
            Handler.requests_remaining -= 1
            if Handler.requests_remaining <= 0:
                self.server.shutdown_requested = True

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
        body = json.dumps({"error": {"message": message}}).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format, *_args):
        pass


server = HTTPServer(("127.0.0.1", 18473), Handler)
server.timeout = 0.2
server.shutdown_requested = False
while not server.shutdown_requested:
    server.handle_request()
server.server_close()
