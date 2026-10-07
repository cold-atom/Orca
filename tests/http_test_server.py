#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import time


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests_remaining = int(os.environ.get("ORCA_TEST_REQUESTS", "29"))
    gemini_loop_started = False
    deepseek_loop_started = False
    xai_loop_started = False
    openrouter_loop_started = False

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
                        b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"gemini_call","type":"function","function":{"name":"read_file","arguments":"{}"},"extra_content":{"google":{"thought_signature":"test-signature"}}}]},"finish_reason":"stop"}]}\n\n',
                        b"data: [DONE]\n\n",
                    ])
            elif self.path == "/gemini-loop/chat/completions":
                body = json.loads(request_body)
                messages = body.get("messages", [])
                tool_messages = [message for message in messages if message.get("role") == "tool"]
                if (
                    self.headers.get("Authorization") != "Bearer local-test-key"
                    or body.get("model") != "gemini-3-flash-preview"
                    or body.get("tool_choice") != "auto"
                ):
                    self._send_json_error(400, "Invalid Gemini loop request")
                elif not tool_messages:
                    if Handler.gemini_loop_started:
                        self._send_json_error(409, "Gemini loop was started twice")
                    else:
                        Handler.gemini_loop_started = True
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"gemini_loop_call","type":"function","function":{"name":"read_file","arguments":"{}"},"extra_content":{"google":{"thought_signature":"loop-"}}}]},"finish_reason":null}]}\n\n',
                            b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"extra_content":{"google":{"thought_signature":"signature"}}}]},"finish_reason":"stop"}]}\n\n',
                            b"data: [DONE]\n\n",
                        ])
                else:
                    assistant_messages = [message for message in messages if message.get("role") == "assistant" and message.get("tool_calls")]
                    assistant_call = assistant_messages[-1].get("tool_calls", [{}])[0] if assistant_messages else {}
                    function = assistant_call.get("function", {})
                    signature = assistant_call.get("extra_content", {}).get("google", {}).get("thought_signature")
                    tool_message = tool_messages[-1]
                    valid_continuation = (
                        Handler.gemini_loop_started
                        and len(assistant_messages) == 1
                        and len(assistant_messages[-1].get("tool_calls", [])) == 1
                        and assistant_call.get("id") == "gemini_loop_call"
                        and assistant_call.get("type") == "function"
                        and function.get("name") == "read_file"
                        and function.get("arguments") == "{}"
                        and signature == "loop-signature"
                        and tool_message.get("tool_call_id") == "gemini_loop_call"
                        and tool_message.get("content") == '{"success":true,"path":"res://game.gd"}'
                        and messages.index(assistant_messages[-1]) < messages.index(tool_message)
                    )
                    if not valid_continuation:
                        self._send_json_error(400, "Invalid Gemini tool continuation")
                    else:
                        Handler.gemini_loop_started = False
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"content":"gemini loop complete"},"finish_reason":"stop"}]}\n\n',
                            b"data: [DONE]\n\n",
                        ])
            elif self.path == "/deepseek-loop/chat/completions":
                body = json.loads(request_body)
                messages = body.get("messages", [])
                tool_messages = [message for message in messages if message.get("role") == "tool"]
                valid_options = (
                    self.headers.get("Authorization") == "Bearer local-test-key"
                    and body.get("model") == "deepseek-chat"
                    and body.get("tool_choice") == "auto"
                    and body.get("thinking", {}).get("type") == "enabled"
                    and body.get("reasoning_effort") == "high"
                    and body.get("max_tokens") == 8192
                )
                if not valid_options:
                    self._send_json_error(400, "Invalid DeepSeek loop request")
                elif not tool_messages:
                    if Handler.deepseek_loop_started:
                        self._send_json_error(409, "DeepSeek loop was started twice")
                    else:
                        Handler.deepseek_loop_started = True
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"reasoning_content":"plan-"},"finish_reason":null}]}\n\n',
                            b'data: {"choices":[{"delta":{"reasoning_content":"tool","tool_calls":[{"index":0,"id":"deepseek_loop_call","type":"function","function":{"name":"read_file","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n\n',
                            b"data: [DONE]\n\n",
                        ])
                else:
                    assistant_messages = [message for message in messages if message.get("role") == "assistant" and message.get("tool_calls")]
                    assistant_message = assistant_messages[-1] if assistant_messages else {}
                    assistant_call = assistant_message.get("tool_calls", [{}])[0] if assistant_messages else {}
                    function = assistant_call.get("function", {})
                    tool_message = tool_messages[-1]
                    valid_continuation = (
                        Handler.deepseek_loop_started
                        and len(assistant_messages) == 1
                        and len(assistant_message.get("tool_calls", [])) == 1
                        and assistant_message.get("reasoning_content") == "plan-tool"
                        and "reasoning" not in assistant_message
                        and "reasoning_details" not in assistant_message
                        and assistant_call.get("id") == "deepseek_loop_call"
                        and assistant_call.get("type") == "function"
                        and function.get("name") == "read_file"
                        and function.get("arguments") == "{}"
                        and tool_message.get("tool_call_id") == "deepseek_loop_call"
                        and tool_message.get("content") == '{"success":true,"path":"res://player.gd"}'
                        and messages.index(assistant_message) < messages.index(tool_message)
                    )
                    if not valid_continuation:
                        self._send_json_error(400, "Invalid DeepSeek tool continuation")
                    else:
                        Handler.deepseek_loop_started = False
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"reasoning_content":"final-hidden"},"finish_reason":null}]}\n\n',
                            b'data: {"choices":[{"delta":{"content":"deepseek loop complete"},"finish_reason":"stop"}]}\n\n',
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
            elif self.path == "/xai-loop/chat/completions":
                body = json.loads(request_body)
                messages = body.get("messages", [])
                tool_messages = [message for message in messages if message.get("role") == "tool"]
                valid_options = (
                    self.headers.get("Authorization") == "Bearer local-test-key"
                    and body.get("model") == "grok-4"
                    and body.get("tool_choice") == "auto"
                    and body.get("reasoning_effort") == "high"
                )
                if not valid_options:
                    self._send_json_error(400, "Invalid xAI loop request")
                elif not tool_messages:
                    if Handler.xai_loop_started:
                        self._send_json_error(409, "xAI loop was started twice")
                    else:
                        Handler.xai_loop_started = True
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"reasoning_content":"grok-"},"finish_reason":null}]}\n\n',
                            b'data: {"choices":[{"delta":{"reasoning_content":"plan","tool_calls":[{"index":0,"id":"xai_loop_call","type":"function","function":{"name":"inspect_scene","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n\n',
                            b"data: [DONE]\n\n",
                        ])
                else:
                    assistant_messages = [message for message in messages if message.get("role") == "assistant" and message.get("tool_calls")]
                    assistant_message = assistant_messages[-1] if assistant_messages else {}
                    assistant_call = assistant_message.get("tool_calls", [{}])[0] if assistant_messages else {}
                    function = assistant_call.get("function", {})
                    tool_message = tool_messages[-1]
                    valid_continuation = (
                        Handler.xai_loop_started
                        and len(assistant_messages) == 1
                        and len(assistant_message.get("tool_calls", [])) == 1
                        and assistant_message.get("reasoning_content") == "grok-plan"
                        and "reasoning" not in assistant_message
                        and "reasoning_details" not in assistant_message
                        and assistant_call.get("id") == "xai_loop_call"
                        and assistant_call.get("type") == "function"
                        and function.get("name") == "inspect_scene"
                        and function.get("arguments") == "{}"
                        and tool_message.get("tool_call_id") == "xai_loop_call"
                        and tool_message.get("content") == '{"success":true,"scene":"res://game.tscn"}'
                        and messages.index(assistant_message) < messages.index(tool_message)
                    )
                    if not valid_continuation:
                        self._send_json_error(400, "Invalid xAI tool continuation")
                    else:
                        Handler.xai_loop_started = False
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"content":"xai loop complete"},"finish_reason":"stop"}]}\n\n',
                            b"data: [DONE]\n\n",
                        ])
            elif self.path == "/openrouter-loop/chat/completions":
                body = json.loads(request_body)
                messages = body.get("messages", [])
                tool_messages = [message for message in messages if message.get("role") == "tool"]
                valid_options = (
                    self.headers.get("Authorization") == "Bearer local-test-key"
                    and self.headers.get("X-Title") == "Orca"
                    and body.get("model") == "anthropic/claude-sonnet-test"
                    and body.get("tool_choice") == "auto"
                    and body.get("reasoning", {}).get("effort") == "high"
                )
                if not valid_options:
                    self._send_json_error(400, "Invalid OpenRouter loop request")
                elif not tool_messages:
                    if Handler.openrouter_loop_started:
                        self._send_json_error(409, "OpenRouter loop was started twice")
                    else:
                        Handler.openrouter_loop_started = True
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"reasoning_details":[{"index":0,"id":"reasoning-1","type":"reasoning.text","text":"route-","signature":"sig-"}]},"finish_reason":null}]}\n\n',
                            b'data: {"choices":[{"delta":{"reasoning_details":[{"index":0,"id":"reasoning-1","type":"reasoning.text","text":"plan","signature":"value"}],"tool_calls":[{"index":0,"id":"openrouter_loop_call","type":"function","function":{"name":"search_files","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n\n',
                            b"data: [DONE]\n\n",
                        ])
                else:
                    assistant_messages = [message for message in messages if message.get("role") == "assistant" and message.get("tool_calls")]
                    assistant_message = assistant_messages[-1] if assistant_messages else {}
                    assistant_call = assistant_message.get("tool_calls", [{}])[0] if assistant_messages else {}
                    function = assistant_call.get("function", {})
                    details = assistant_message.get("reasoning_details", [])
                    detail = details[0] if len(details) == 1 else {}
                    tool_message = tool_messages[-1]
                    valid_continuation = (
                        Handler.openrouter_loop_started
                        and len(assistant_messages) == 1
                        and len(assistant_message.get("tool_calls", [])) == 1
                        and len(details) == 1
                        and detail.get("index") == 0
                        and detail.get("id") == "reasoning-1"
                        and detail.get("type") == "reasoning.text"
                        and detail.get("text") == "route-plan"
                        and detail.get("signature") == "sig-value"
                        and assistant_call.get("id") == "openrouter_loop_call"
                        and assistant_call.get("type") == "function"
                        and function.get("name") == "search_files"
                        and function.get("arguments") == "{}"
                        and tool_message.get("tool_call_id") == "openrouter_loop_call"
                        and tool_message.get("content") == '{"success":true,"matches":2}'
                        and messages.index(assistant_message) < messages.index(tool_message)
                    )
                    if not valid_continuation:
                        self._send_json_error(400, "Invalid OpenRouter tool continuation")
                    else:
                        Handler.openrouter_loop_started = False
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"content":"openrouter loop complete"},"finish_reason":"stop"}]}\n\n',
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
