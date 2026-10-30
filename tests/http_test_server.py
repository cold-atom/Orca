#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import time
import base64
import re


class ReusableHTTPServer(HTTPServer):
    allow_reuse_address = True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    requests_remaining = int(os.environ.get("ORCA_TEST_REQUESTS", "29"))
    gemini_loop_started = False
    deepseek_loop_started = False
    xai_loop_started = False
    openrouter_loop_started = False
    local_layout_steps = {}
    image_switch_step = 0
    image_switch_urls = []

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
            if self.path.startswith("/timeout/"):
                self._handle_timeout(json.loads(request_body))
            elif self.path.startswith("/foundry/"):
                self._handle_foundry(json.loads(request_body))
            elif self.path.startswith("/leading-system/"):
                self._handle_local_layout(json.loads(request_body))
            elif self.path == "/image-switch/chat/completions":
                self._handle_image_switch(json.loads(request_body))
            elif self.path == "/image-input/chat/completions":
                body = json.loads(request_body)
                messages = body.get("messages", [])
                users = [message for message in messages if message.get("role") == "user"]
                parts = users[0].get("content", []) if users else []
                valid = (
                    len(parts) == 2
                    and parts[0].get("type") == "text"
                    and parts[0].get("text", "").startswith("Inspect image\n\nATTACHED PROJECT SCRIPT SNAPSHOTS:")
                    and parts[1].get("type") == "image_url"
                    and "images" not in users[0]
                    and "script_references" not in users[0]
                )
                if valid:
                    text = parts[0]["text"]
                    references = json.loads("[" + text.split("\n[", 1)[1])
                    valid = references == [{
                        "filepath": "res://scripts/reference_fixture.gd",
                        "source_kind": "disk",
                        "content": "extends Node\n# SYNTHETIC_REFERENCE_CONTEXT",
                        "total_lines": 2, "included_lines": 2, "truncated": False,
                    }]
                url = parts[1].get("image_url", {}).get("url", "") if valid else ""
                valid = valid and url.startswith("data:image/png;base64,")
                if valid:
                    decoded = base64.b64decode(url.split(",", 1)[1], validate=True)
                    valid = decoded.startswith(b"\x89PNG\r\n\x1a\n")
                if not valid:
                    self._send_json_error(400, "Invalid multimodal request")
                elif messages[-1].get("role") == "tool":
                    if messages[-1].get("tool_call_id") != "image_tool":
                        self._send_json_error(400, "Invalid continuation")
                    else:
                        self._send_sse([
                            b'data: {"choices":[{"delta":{"content":"image continuation ok"},"finish_reason":"stop"}]}\n\n',
                            b"data: [DONE]\n\n",
                        ])
                else:
                    self._send_sse([
                        b'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"image_tool","type":"function","function":{"name":"read_file","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n\n',
                        b"data: [DONE]\n\n",
                    ])
            elif self.path.startswith("/success/"):
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
                if not self._has_one_leading_system(messages):
                    self._send_json_error(500, "Jinja Exception: System message must be at the beginning.")
                elif not tool_messages:
                    user_content = str(messages[-1].get("content", ""))
                    challenge = user_content.split('"')[1] if '"' in user_content else ""
                    arguments = json.dumps({"challenge": challenge}, separators=(",", ":"))
                    event = {"choices": [{"delta": {"tool_calls": [{"index": 0, "id": "probe-http-call", "type": "function", "function": {"name": "orca_agent_probe", "arguments": arguments}}]}, "finish_reason": "tool_calls"}]}
                    self._send_sse([("data: " + json.dumps(event) + "\n\n").encode(), b"data: [DONE]\n\n"])
                else:
                    result = json.loads(tool_messages[-1].get("content", "{}"))
                    if (
                        tool_messages[-1].get("tool_call_id") != "probe-http-call"
                        or messages[-1] != tool_messages[-1]
                        or "ORCA SYNTHETIC CONTINUATION CHECK:" not in messages[0].get("content", "")
                    ):
                        self._send_json_error(400, "Invalid probe call/result or refreshed system context")
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

    def _handle_image_switch(self, body):
        step = Handler.image_switch_step
        vision = step in (1, 2, 5, 7)
        messages = body.get("messages", [])
        users = [message for message in messages if message.get("role") == "user"]
        if (
            step >= 8
            or self.headers.get("Authorization") != "Bearer local-test-key"
            or body.get("model") != ("vision-fixture" if vision else "text-fixture")
            or "_orca_include_history_images" in body
        ):
            self._send_json_error(400, "Invalid model-switch request")
            return

        def image_content(index):
            parts = users[index].get("content") if len(users) > index else None
            if not isinstance(parts, list) or len(parts) != 2 or parts[0] != {"type": "text", "text": ""}:
                return None
            url = parts[1].get("image_url", {}).get("url", "")
            if parts[1].get("type") != "image_url" or not url.startswith("data:image/png;base64,"):
                return None
            decoded = base64.b64decode(url.split(",", 1)[1], validate=True)
            return parts if decoded.startswith(b"\x89PNG\r\n\x1a\n") else None

        placeholder = "[Earlier attachment: 1 image(s). Image pixels are unavailable to this model. Use any earlier text descriptions; do not claim direct image inspection.]"
        expected = [{"role": "user", "content": "Start text"}]
        if step >= 1:
            if vision:
                first_image = image_content(1)
                if first_image is None:
                    self._send_json_error(400, "Missing original image")
                    return
                first_url = first_image[1]["image_url"]["url"]
                if not Handler.image_switch_urls:
                    Handler.image_switch_urls.append(first_url)
                elif first_url != Handler.image_switch_urls[0]:
                    self._send_json_error(400, "Original image changed")
                    return
            else:
                first_image = placeholder
            expected.extend([{"role": "assistant", "content": "text start ok"}, {"role": "user", "content": first_image}])
        vision_call = {"id": "switch_vision_tool", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
        text_call = {"id": "switch_text_tool", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}
        if step >= 2:
            expected.extend([{"role": "assistant", "content": "", "tool_calls": [vision_call]}, {"role": "tool", "tool_call_id": "switch_vision_tool", "content": "Read completed"}])
        if step >= 3:
            expected.extend([{"role": "assistant", "content": "vision description: purple rectangle"}, {"role": "user", "content": "Continue text"}])
        if step >= 4:
            expected.extend([{"role": "assistant", "content": "", "tool_calls": [text_call]}, {"role": "tool", "tool_call_id": "switch_text_tool", "content": "Read completed"}])
        if step >= 5:
            if vision:
                second_image = image_content(3)
                if second_image is None:
                    self._send_json_error(400, "Missing second image")
                    return
                second_url = second_image[1]["image_url"]["url"]
                if len(Handler.image_switch_urls) == 1:
                    Handler.image_switch_urls.append(second_url)
                elif second_url != Handler.image_switch_urls[1]:
                    self._send_json_error(400, "Second image changed")
                    return
            else:
                second_image = placeholder
            expected.extend([{"role": "assistant", "content": "text continuation ok"}, {"role": "user", "content": second_image}])
        if step >= 6:
            expected.extend([{"role": "assistant", "content": "vision again ok"}, {"role": "user", "content": "Text again"}])
        if step >= 7:
            expected.extend([{"role": "assistant", "content": "text again ok"}, {"role": "user", "content": "Final vision"}])
        if messages != expected or (not vision and ("image_url" in json.dumps(body) or "data:image" in json.dumps(body))):
            self._send_json_error(400, "Model switching lost text, images, or tool protocol")
            return
        Handler.image_switch_step += 1
        if step in (1, 3):
            call = vision_call if step == 1 else text_call
            event = {"choices": [{"delta": {"tool_calls": [dict(call, index=0)]}, "finish_reason": "tool_calls"}]}
        else:
            content = {0: "text start ok", 2: "vision description: purple rectangle", 4: "text continuation ok", 5: "vision again ok", 6: "text again ok", 7: "final vision ok"}[step]
            event = {"choices": [{"delta": {"content": content}, "finish_reason": "stop"}]}
        self._send_sse([("data: " + json.dumps(event) + "\n\n").encode(), b"data: [DONE]\n\n"])

    @staticmethod
    def _has_one_leading_system(messages):
        return (
            bool(messages)
            and messages[0].get("role") == "system"
            and isinstance(messages[0].get("content"), str)
            and all(message.get("role") != "system" for message in messages[1:])
        )

    def _handle_local_layout(self, body):
        messages = body.get("messages", [])
        # Reproduce the reported template restriction without model weights.
        if not self._has_one_leading_system(messages):
            self._send_json_error(500, "Jinja Exception: System message must be at the beginning.")
            return
        profile = self.path.split("/")[2]
        step = Handler.local_layout_steps.get(profile, 0)
        if step >= 5 or self.headers.get("Authorization") is not None or body.get("model") != "local-layout-fixture":
            self._send_json_error(400, "Invalid local layout request")
            return
        system_parts = [
            "Primary instructions",
            "Current editor context: " + ("first" if step == 0 else "second" if step == 1 else "third"),
            "Tasks: " + ("pending" if step < 2 else "in_progress"),
        ]
        call = {"id": "layout-read-call", "type": "function", "function": {"name": "read_file", "arguments": '{"path":"res://fixture.gd"}'}}
        conversation = [{"role": "user", "content": "hi"}]
        if step >= 1:
            conversation.extend([{"role": "assistant", "content": "hello"}, {"role": "user", "content": "test"}])
        if step >= 2:
            conversation.extend([{"role": "assistant", "content": "second ok"}, {"role": "user", "content": "Inspect fixture"}])
        if step >= 3:
            system_parts.extend(["Runtime observation", "Correction and action budget"])
            conversation.extend([
                {"role": "assistant", "content": "", "tool_calls": [call]},
                {"role": "tool", "tool_call_id": "layout-read-call", "content": "Read completed"},
            ])
        if step == 4:
            system_parts.extend(["Controller cleanup", "Finalize without tools"])
            conversation.append({"role": "assistant", "content": "tool complete"})
        expected_tools = [{"type": "function", "function": {"name": "read_file", "parameters": {"type": "object", "properties": {"path": {"type": "string"}}, "required": ["path"]}}}]
        if (
            messages[0].get("content") != "\n\n".join(system_parts)
            or messages[1:] != conversation
            or body.get("stream") is not True
            or (step in (2, 3) and (body.get("tools") != expected_tools or body.get("tool_choice") != "auto"))
            or (step not in (2, 3) and ("tools" in body or "tool_choice" in body))
        ):
            self._send_json_error(400, "Local layout lost context, conversation, or tool protocol")
            return
        Handler.local_layout_steps[profile] = step + 1
        if step == 2:
            event = {"choices": [{"delta": {"tool_calls": [dict(call, index=0)]}, "finish_reason": "tool_calls"}]}
        else:
            content = {0: "hello", 1: "second ok", 3: "tool complete", 4: "final ok"}[step]
            event = {"choices": [{"delta": {"content": content}, "finish_reason": "stop"}]}
        self._send_sse([("data: " + json.dumps(event) + "\n\n").encode(), b"data: [DONE]\n\n"])

    def _handle_foundry(self, body):
        case = self.path.split("/")[2]
        if self.headers.get("Authorization") != "Bearer synthetic-foundry-key":
            self._send_json_error(400, "Incorrect synthetic authentication")
            return
        if case in ("deepseek-probe-sse", "deepseek-probe-json", "deepseek-probe-wrong", "deepseek-probe-standard"):
            self._handle_deepseek_probe(body, case)
            return
        if self.path.endswith("/chat/completions"):
            if case == "deepseek":
                assistants = [m for m in body.get("messages", []) if m.get("role") == "assistant"]
                if assistants:
                    if assistants[-1].get("reasoning_content") != "deepseek-opaque" or body["messages"][-1].get("tool_call_id") != "ds-call":
                        self._send_json_error(400, "Missing DeepSeek reasoning continuation")
                    else:
                        self._send_json(200, {"choices": [{"message": {"role": "assistant", "content": "deepseek ok"}, "finish_reason": "stop"}]})
                else:
                    self._send_json(200, {"choices": [{"message": {"role": "assistant", "content": "", "reasoning_content": "deepseek-opaque", "tool_calls": [{"id": "ds-call", "type": "function", "function": {"name": "read_file", "arguments": "{}"}}]}, "finish_reason": "tool_calls"}]})
            elif body.get("tools") and body.get("reasoning_effort") != "none":
                self._send_json_error(400, "Function tools with reasoning_effort are not supported. Use /v1/responses or set reasoning_effort to 'none'.")
            else:
                self._send_json(200, {"choices": [{"message": {"role": "assistant", "content": "chat none ok"}, "finish_reason": "stop"}]})
            return
        if not self.path.endswith("/responses") or body.get("store") is not False or body.get("stream") is not True or body.get("truncation") != "disabled" or "messages" in body or "stream_options" in body or "previous_response_id" in body or "_orca_" in json.dumps(body) or body.get("reasoning") != {"effort": "high"}:
            self._send_json_error(400, "Incorrect stateless Responses request")
            return
        inputs = body.get("input", [])
        outputs = [item for item in inputs if item.get("type") == "function_call_output"]
        tools = body.get("tools", [])
        if any(t.get("type") != "function" or "function" in t or t.get("strict") is not False for t in tools):
            self._send_json_error(400, "Incorrect Responses function schemas")
            return
        reasoning = {"id": "rs_fixture", "type": "reasoning", "encrypted_content": "foundry-opaque", "summary": []}
        text = "foundry Ω ok"
        response = {"status": "completed", "model": body.get("model"), "output": [], "usage": {"input_tokens": 30, "output_tokens": 8, "total_tokens": 38, "input_tokens_details": {"cached_tokens": 12}}}
        if case == "probe" and not outputs:
            user = next((m.get("content") for m in inputs if m.get("role") == "user"), "")
            match = re.search(r'challenge "([^"]+)"', user)
            if not match or len(tools) != 1 or tools[0].get("name") != "orca_agent_probe" or "res://" in json.dumps(inputs):
                self._send_json_error(400, "Probe was not isolated")
                return
            response["output"] = [reasoning, {"id": "fc_probe", "type": "function_call", "call_id": "probe-response-call", "name": "orca_agent_probe", "arguments": json.dumps({"challenge": match.group(1)})}]
        elif case == "probe":
            if reasoning not in inputs or outputs[0].get("call_id") != "probe-response-call" or inputs[-1].get("role") != "system":
                self._send_json_error(400, "Probe lost reasoning, call identity, or refreshed context")
                return
            text = json.loads(outputs[0]["output"])["required_reply"]
        elif case == "multi":
            users = [m for m in inputs if m.get("role") == "user"]
            parts = users[0].get("content", []) if users else []
            if len(parts) != 2 or parts[0] != {"type": "input_text", "text": "Inspect synthetic image"} or parts[1].get("type") != "input_image" or not parts[1].get("image_url", "").startswith("data:image/png;base64,"):
                self._send_json_error(400, "Responses lost canonical image input")
                return
            if outputs:
                expected = [{"type": "function_call_output", "call_id": "read-call", "output": "read done"}, {"type": "function_call_output", "call_id": "search-call", "output": "search done"}]
                if outputs != expected or reasoning not in inputs or tools or inputs[-1].get("role") != "system":
                    self._send_json_error(400, "No-tools finalization lost reasoning, results, or context")
                    return
                message = next((m for m in inputs if m.get("id") == "msg_preface"), {})
                if message.get("phase") != "commentary":
                    self._send_json_error(400, "Assistant phase was not preserved")
                    return
            else:
                response["output"] = [reasoning, {"id": "msg_preface", "type": "message", "role": "assistant", "phase": "commentary", "status": "completed", "content": [{"type": "output_text", "text": "Inspecting", "annotations": []}]},
                    {"id": "fc_read", "type": "function_call", "call_id": "read-call", "name": "read_file", "arguments": "{}"},
                    {"id": "fc_search", "type": "function_call", "call_id": "search-call", "name": "search_files", "arguments": "{}"}]
        if not response["output"]:
            response["output"] = [{"id": "msg_final", "type": "message", "role": "assistant", "phase": "final_answer", "status": "completed", "content": [{"type": "output_text", "text": text, "annotations": []}]}]
        if case == "json":
            self._send_json(200, response)
            return
        events = []
        for index, item in enumerate(response["output"]):
            events.append({"type": "response.output_item.added", "output_index": index, "item": {"id": item["id"], "type": item["type"]}})
            if item["type"] == "message":
                events.append({"type": "response.output_text.delta", "output_index": index, "delta": item["content"][0]["text"]})
            if item["type"] == "function_call":
                args = item["arguments"]
                for fragment in [args[:1], args[1:]]:
                    events.append({"type": "response.function_call_arguments.delta", "output_index": index, "delta": fragment})
        if case == "incomplete":
            events.append({"type": "response.incomplete", "response": {"status": "incomplete", "incomplete_details": {"reason": "max_output_tokens"}}})
        elif case == "error":
            events.append({"type": "error", "error": {"message": "synthetic Responses failure"}})
        elif case not in ("disconnect", "cancel"):
            events.append({"type": "response.completed", "response": response})
        chunks = [("event: " + e["type"] + "\ndata: " + json.dumps(e, ensure_ascii=False) + "\n\n").encode() for e in events]
        if case == "cancel":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"".join(chunks))
            self.wfile.flush()
            time.sleep(0.5)
        else:
            self._send_sse(chunks)

    def _handle_timeout(self, body):
        if any(field in body for field in ("response_start_timeout_seconds", "stream_inactivity_timeout_seconds", "custom_timeouts_enabled")):
            self._send_json_error(400, "Client timing preferences leaked into provider payload")
            return
        case = self.path.split("/")[2]
        if case == "headers":
            time.sleep(0.3)
        elif case == "shared":
            time.sleep(0.2)
        if case == "json":
            response = json.dumps({"choices": [{"message": {"content": "timing ok"}, "finish_reason": "stop"}]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.flush()
            time.sleep(0.3)
            self.wfile.write(response)
            self.wfile.flush()
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.flush()
        if case in ("body", "shared"):
            time.sleep(0.3 if case == "body" else 0.25)
        elif case == "idle":
            self.wfile.write(b'data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}\n\n')
            self.wfile.flush()
            time.sleep(0.3)
        elif case == "active":
            for _ in range(6):
                self.wfile.write(b'data: {"choices":[{"delta":{"reasoning_content":"hidden"}}]}\n\n')
                self.wfile.flush()
                time.sleep(0.08)
        if self.path.endswith("/responses"):
            self.wfile.write(b'data: {"type":"response.output_text.delta","output_index":0,"delta":"timing ok"}\n\n')
            response = {"status": "completed", "output": [{"id": "timeout-message", "type": "message", "role": "assistant", "status": "completed", "content": [{"type": "output_text", "text": "timing ok"}]}]}
            self.wfile.write(("data: " + json.dumps({"type": "response.completed", "response": response}) + "\n\n").encode())
        else:
            self.wfile.write(b'data: {"choices":[{"delta":{"content":"timing ok"},"finish_reason":"stop"}]}\n\n')
            self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def _handle_deepseek_probe(self, body, case):
        responses = self.path.endswith("/responses")
        source = body.get("input", []) if responses else body.get("messages", [])
        tools = body.get("tools", [])
        function = tools[0] if responses and tools else tools[0].get("function", {}) if tools else {}
        if len(tools) != 1 or function.get("name") != "orca_agent_probe" or "res://" in json.dumps(source):
            self._send_json_error(400, "DeepSeek probe was not isolated")
            return
        if responses and (body.get("store") is not False or body.get("truncation") != "disabled" or "previous_response_id" in body):
            self._send_json_error(400, "DeepSeek Responses must remain stateless")
            return
        results = [m for m in source if m.get("type") == "function_call_output"] if responses else [m for m in source if m.get("role") == "tool"]
        private = "PRIVATE_DEEPSEEK_PROBE_REASONING"
        text = ""
        calls = []
        reasoning = {"id": "ds-reason", "type": "reasoning", "content": [{"type": "reasoning_text", "text": private}]}
        if not results:
            user = next((m.get("content", "") for m in source if m.get("role") == "user"), "")
            match = re.search(r'challenge "([^"]+)"', user)
            if not match:
                self._send_json_error(400, "Missing synthetic challenge")
                return
            calls = [{"id": "ds-probe-call", "type": "function", "function": {"name": "orca_agent_probe", "arguments": json.dumps({"challenge": match.group(1)})}}]
            text = "" if case == "deepseek-probe-standard" else "</think>"
        else:
            if source[-1].get("role") != "system":
                self._send_json_error(400, "Refreshed context was lost")
                return
            if responses:
                if not any(m.get("id") == "ds-reason" and m.get("type") == "reasoning" and m.get("content") == reasoning["content"] for m in source) or results[0].get("call_id") != "ds-probe-call":
                    self._send_json_error(400, "DeepSeek plain reasoning or function identity was lost")
                    return
                assistants = [m for m in source if m.get("type") == "message" and m.get("role") == "assistant"]
                if not assistants or any("</think>" in p.get("text", "") for m in assistants for p in m.get("content", [])):
                    self._send_json_error(400, "DeepSeek assistant delimiter was not normalized for replay")
                    return
                required = json.loads(results[0]["output"])["required_reply"]
            else:
                assistant = next((m for m in source if m.get("role") == "assistant"), {})
                if results[0].get("tool_call_id") != "ds-probe-call" or (case != "deepseek-probe-standard" and (assistant.get("reasoning_content") != private or assistant.get("content") != "")):
                    self._send_json_error(400, "DeepSeek Chat lost reasoning or normalized assistant content")
                    return
                required = json.loads(results[0]["content"])["required_reply"]
            text = "</think>" + ("ORCA_AGENT_PROBE_OK wrong-nonce" if case == "deepseek-probe-wrong" else required)
        if responses:
            output = [reasoning] if not results else []
            output.append({"id": "ds-message", "type": "message", "role": "assistant", "phase": "commentary" if calls else "final_answer", "status": "completed", "content": [{"type": "output_text", "text": text}]})
            if calls:
                output.append({"id": "ds-call-item", "type": "function_call", "call_id": "ds-probe-call", "name": "orca_agent_probe", "arguments": calls[0]["function"]["arguments"]})
            reply = {"status": "completed", "model": body.get("model"), "output": output}
            if case == "deepseek-probe-json":
                self._send_json(200, reply)
                return
            events = []
            if not results:
                events.append({"type": "response.reasoning_text.delta", "delta": private})
            for fragment in [text[:3], text[3:7], text[7:]]:
                if fragment:
                    events.append({"type": "response.output_text.delta", "delta": fragment})
            events.append({"type": "response.completed", "response": reply})
        else:
            message = {"role": "assistant", "content": text}
            if calls:
                message.update({"reasoning_content": private, "tool_calls": calls})
            finish = "tool_calls" if calls else "stop"
            if case == "deepseek-probe-json":
                self._send_json(200, {"choices": [{"message": message, "finish_reason": finish}]})
                return
            events = []
            for fragment in [text[:3], text[3:7], text[7:]]:
                if fragment:
                    events.append({"choices": [{"delta": {"content": fragment}}]})
            delta = {"reasoning_content": private, "tool_calls": [dict(c, index=i) for i, c in enumerate(calls)]} if calls else {}
            events.append({"choices": [{"delta": delta, "finish_reason": finish}]})
        chunks = [("data: " + json.dumps(e) + "\n\n").encode() for e in events]
        if not responses:
            chunks.append(b"data: [DONE]\n\n")
        self._send_sse(chunks)

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
