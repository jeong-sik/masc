#!/usr/bin/env python3
"""Qwen3.5 llama-server -> MASC capability probe.

This script exercises the currently running local llama-server using the
OpenAI-compatible chat completions endpoint, then validates whether the model
can discover and use selected MASC tools exposed through the MCP HTTP
transport.

It intentionally keeps the probe scope narrow and reversible:
* plain text + JSON mode
* synthetic tool calling
* selected MASC tool families: status, coding, board, cleanup, team session,
  voice

The goal is not to prove every public tool is safe to execute. Instead, it
classifies the entire tool catalog and actively exercises the representative
high-value families needed for the OAS -> MASC product ladder.
"""

from __future__ import annotations

import argparse
import json
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any


DEFAULT_LLAMA_BASE = "http://127.0.0.1:8085"
DEFAULT_MCP_URL = "http://127.0.0.1:8935/mcp"
SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_OUTPUT = Path("/tmp/qwen35-llama-masc-probe.json")

FALLBACK_TOOL_SCHEMAS: dict[str, dict[str, Any]] = {
    "masc_board_post": {
        "type": "function",
        "function": {
            "name": "masc_board_post",
            "description": "Create a post on the MASC internal board",
            "parameters": {
                "type": "object",
                "properties": {
                    "title": {"type": "string"},
                    "body": {"type": "string"},
                    "content": {"type": "string"},
                    "author": {"type": "string"},
                    "post_kind": {"type": "string"},
                    "meta": {"type": "object"},
                    "visibility": {"type": "string"},
                    "ttl_hours": {"type": "integer"},
                    "hearth": {"type": "string"},
                    "thread_id": {"type": "string"},
                },
                "required": ["content"],
            },
        },
    },
    "masc_voice_speak": {
        "type": "function",
        "function": {
            "name": "masc_voice_speak",
            "description": "Send text to the voice bridge for an agent.",
            "parameters": {
                "type": "object",
                "properties": {
                    "agent_id": {"type": "string"},
                    "message": {"type": "string"},
                    "provider": {"type": "string"},
                    "priority": {"type": "integer"},
                },
                "required": ["agent_id", "message"],
            },
        },
    },
}


def build_sampling_profile(name: str) -> dict[str, Any]:
    profiles: dict[str, dict[str, Any]] = {
        "local_default": {
            "temperature": 0.6,
            "top_p": 0.95,
            "top_k": 20,
            "min_p": 0.01,
            "max_tokens": 256,
            "enable_thinking": False,
        },
        "unsloth_general": {
            "temperature": 1.0,
            "top_p": 0.95,
            "top_k": 20,
            "min_p": 0.0,
            "max_tokens": 256,
            "enable_thinking": False,
        },
        "unsloth_precise_coding": {
            "temperature": 0.6,
            "top_p": 0.95,
            "top_k": 20,
            "min_p": 0.0,
            "max_tokens": 256,
            "enable_thinking": False,
        },
    }
    if name not in profiles:
        raise KeyError(f"unknown sampling profile: {name}")
    return dict(profiles[name])


def http_post_json(
    url: str,
    payload: dict[str, Any],
    *,
    accept: str = "application/json",
    timeout: float = 30.0,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, str]:
    data = json.dumps(payload).encode("utf-8")
    headers = {
        "Content-Type": "application/json",
        "Accept": accept,
    }
    if extra_headers:
        headers.update(extra_headers)
    request = urllib.request.Request(
        url,
        data=data,
        headers=headers,
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return exc.code, body


def http_get_text(url: str, *, timeout: float = 10.0) -> tuple[int, str]:
    request = urllib.request.Request(url, headers={"Accept": "application/json"}, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        return exc.code, body


def parse_json(text: str) -> Any:
    return json.loads(text)


def parse_sse_json(text: str) -> dict[str, Any]:
    for line in text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[6:])
    return json.loads(text)


def strip_markdown_fences(text: str) -> str:
    stripped = text.strip()
    if not stripped.startswith("```"):
        return stripped
    lines = stripped.splitlines()
    if len(lines) >= 3 and lines[0].startswith("```") and lines[-1].strip() == "```":
        return "\n".join(lines[1:-1]).strip()
    return stripped


def contains_text(value: str, needles: list[str]) -> bool:
    haystack = value.lower()
    return all(needle.lower() in haystack for needle in needles)


@dataclass
class ScenarioResult:
    scenario_id: str
    stage: str
    category: str
    status: str
    summary: str
    details: dict[str, Any] = field(default_factory=dict)


class ProbeFailure(RuntimeError):
    pass


class Probe:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.base_profile = build_sampling_profile(args.sampling_profile)
        self.base_profile["max_tokens"] = args.max_tokens or self.base_profile["max_tokens"]
        self.base_profile["enable_thinking"] = args.enable_thinking
        self.catalog: list[dict[str, Any]] = []
        self.results: list[ScenarioResult] = []
        self.model_id = args.model or self.detect_model()
        nonce = f"{int(time.time())}-{random.randint(1000, 9999)}"
        self.mcp_agent_name = f"qwen35-probe-{nonce}"
        self.mcp_session_id = f"qwen35-session-{nonce}"

    def detect_model(self) -> str:
        status, body = http_get_text(f"{self.args.llama_base_url.rstrip('/')}/v1/models")
        if status != 200:
            raise ProbeFailure(f"failed to read /v1/models: HTTP {status}")
        payload = parse_json(body)
        data = payload.get("data") or []
        if not data:
            raise ProbeFailure("llama-server returned no models")
        return str(data[0].get("id") or data[0].get("model") or "default")

    def run(self) -> dict[str, Any]:
        self.fetch_catalog()
        self.run_engine_contract()
        self.run_synthetic_tool_probes()
        self.run_masc_family_probes()
        return {
            "llama_base_url": self.args.llama_base_url,
            "mcp_url": self.args.mcp_url,
            "model": self.model_id,
            "sampling_profile": self.args.sampling_profile,
            "enable_thinking": self.args.enable_thinking,
            "catalog_summary": self.catalog_summary(),
            "results": [result.__dict__ for result in self.results],
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        }

    def fetch_catalog(self) -> None:
        cursor: str | None = None
        seen_names: set[str] = set()
        collected: list[dict[str, Any]] = []
        request_id = 1
        while True:
            params: dict[str, Any] = {}
            if cursor:
                params["cursor"] = cursor
            payload = {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": "tools/list",
                "params": params,
            }
            request_id += 1
            status, body = http_post_json(
                self.args.mcp_url,
                payload,
                accept="application/json, text/event-stream",
                timeout=20.0,
            )
            if status != 200:
                raise ProbeFailure(f"tools/list failed: HTTP {status}")
            parsed = parse_sse_json(body)
            result = parsed.get("result", {})
            tools = result.get("tools") or []
            if not isinstance(tools, list):
                raise ProbeFailure("tools/list did not return a tool array")
            for tool in tools:
                name = str(tool.get("name") or "")
                if not name or name in seen_names:
                    continue
                seen_names.add(name)
                collected.append(tool)
            next_cursor = result.get("nextCursor")
            if not isinstance(next_cursor, str) or not next_cursor.strip():
                break
            cursor = next_cursor.strip()
        self.catalog = collected

    def catalog_summary(self) -> dict[str, Any]:
        by_tier: dict[str, int] = {}
        for tool in self.catalog:
            tier = str(tool.get("tier") or "unknown")
            by_tier[tier] = by_tier.get(tier, 0) + 1
        return {
            "tool_count": len(self.catalog),
            "tiers": by_tier,
            "names": [str(tool.get("name")) for tool in self.catalog],
        }

    def select_tools(self, names: list[str]) -> list[dict[str, Any]]:
        selected: list[dict[str, Any]] = []
        for name in names:
            match = next((tool for tool in self.catalog if tool.get("name") == name), None)
            if match is None:
                fallback = FALLBACK_TOOL_SCHEMAS.get(name)
                if fallback is None:
                    raise ProbeFailure(f"tool not found in catalog: {name}")
                selected.append(fallback)
                continue
            selected.append(
                {
                    "type": "function",
                    "function": {
                        "name": match["name"],
                        "description": match.get("description") or "",
                        "parameters": match.get("inputSchema") or {"type": "object", "properties": {}},
                    },
                }
            )
        return selected

    def chat_completion(
        self,
        *,
        prompt: str,
        tools: list[dict[str, Any]] | None = None,
        messages: list[dict[str, Any]] | None = None,
        response_format: dict[str, Any] | None = None,
        tool_choice: Any | None = None,
        overrides: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "model": self.model_id,
            "messages": messages or [{"role": "user", "content": prompt}],
            "temperature": self.base_profile["temperature"],
            "top_p": self.base_profile["top_p"],
            "top_k": self.base_profile["top_k"],
            "min_p": self.base_profile["min_p"],
            "max_tokens": self.base_profile["max_tokens"],
        }
        if self.base_profile["enable_thinking"]:
            payload["chat_template_kwargs"] = {"enable_thinking": True}
        if tools:
            payload["tools"] = tools
        if response_format:
            payload["response_format"] = response_format
        if tool_choice is not None:
            payload["tool_choice"] = tool_choice
        if overrides:
            payload.update(overrides)

        status, body = http_post_json(
            f"{self.args.llama_base_url.rstrip('/')}/v1/chat/completions",
            payload,
            timeout=40.0,
        )
        if status != 200:
            raise ProbeFailure(f"chat completion failed: HTTP {status} body={body[:400]}")
        return parse_json(body)

    def mcp_call(
        self,
        name: str,
        arguments: dict[str, Any],
        *,
        use_explicit_agent: bool = True,
        timeout: float = 45.0,
    ) -> dict[str, Any]:
        payload = {
            "jsonrpc": "2.0",
            "id": int(time.time() * 1000) % 100000,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        }
        extra_headers = {
            "Mcp-Session-Id": self.mcp_session_id,
        }
        if use_explicit_agent:
            extra_headers["X-MASC-Agent"] = self.mcp_agent_name
            extra_headers["X-MASC-Agent-Name"] = self.mcp_agent_name
        status, body = http_post_json(
            self.args.mcp_url,
            payload,
            accept="application/json, text/event-stream",
            timeout=timeout,
            extra_headers=extra_headers,
        )
        if status != 200:
            raise ProbeFailure(f"{name} call failed: HTTP {status} body={body[:400]}")
        parsed = parse_sse_json(body)
        if parsed.get("error"):
            raise ProbeFailure(f"{name} error: {parsed['error']}")
        return parsed.get("result") or {}

    def add_result(self, scenario_id: str, stage: str, category: str, status: str, summary: str, **details: Any) -> None:
        self.results.append(
            ScenarioResult(
                scenario_id=scenario_id,
                stage=stage,
                category=category,
                status=status,
                summary=summary,
                details=details,
            )
        )

    def run_engine_contract(self) -> None:
        # Plain text probe
        plain = self.chat_completion(prompt="Reply with exactly OK.")
        plain_message = plain["choices"][0]["message"]["content"]
        plain_ok = plain_message.strip() == "OK"
        self.add_result(
            "engine_plain_text",
            "engine_contract",
            "engine",
            "SUPPORTED" if plain_ok else "BROKEN",
            "plain text completion",
            response=plain,
        )

        # JSON mode probe
        json_resp = self.chat_completion(
            prompt="Output JSON with keys engine and tool_calling.",
            response_format={"type": "json_object"},
        )
        json_content = json_resp["choices"][0]["message"]["content"]
        stripped_content = strip_markdown_fences(json_content)
        try:
            parsed = json.loads(stripped_content)
            json_ok = isinstance(parsed, dict) and "engine" in parsed and "tool_calling" in parsed
        except json.JSONDecodeError:
            json_ok = False
        self.add_result(
            "engine_json_mode",
            "engine_contract",
            "engine",
            (
                "SUPPORTED"
                if json_ok and stripped_content == json_content
                else "SUPPORTED_WITH_GUARDRAIL"
                if json_ok
                else "BROKEN"
            ),
            "json mode completion",
            response=json_resp,
            normalized_content=stripped_content,
        )

    def run_synthetic_tool_probes(self) -> None:
        weather_tool = [
            {
                "type": "function",
                "function": {
                    "name": "get_weather",
                    "description": "Get weather for a city",
                    "parameters": {
                        "type": "object",
                        "properties": {"city": {"type": "string"}},
                        "required": ["city"],
                    },
                },
            }
        ]
        auto = self.chat_completion(
            prompt="What is the weather in Seoul? Use the get_weather tool if you can.",
            tools=weather_tool,
        )
        tool_calls = auto["choices"][0]["message"].get("tool_calls") or []
        auto_ok = bool(tool_calls) and tool_calls[0]["function"]["name"] == "get_weather"
        self.add_result(
            "synthetic_auto_tool",
            "tool_protocol",
            "synthetic",
            "SUPPORTED" if auto_ok else "BROKEN",
            "single synthetic tool call",
            response=auto,
        )

        if not auto_ok:
            return

        roundtrip = self.chat_completion(
            prompt="synthetic roundtrip",
            messages=[
                {"role": "user", "content": "What is the weather in Seoul? Use the get_weather tool if you can."},
                {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {
                            "id": "call_weather_1",
                            "type": "function",
                            "function": {
                                "name": "get_weather",
                                "arguments": json.dumps({"city": "Seoul"}),
                            },
                        }
                    ],
                },
                {
                    "role": "tool",
                    "tool_call_id": "call_weather_1",
                    "content": json.dumps({"city": "Seoul", "weather": "Sunny", "temp_c": 22}),
                },
            ],
        )
        final_content = roundtrip["choices"][0]["message"]["content"]
        roundtrip_ok = contains_text(final_content, ["Seoul", "Sunny"])
        self.add_result(
            "synthetic_roundtrip",
            "tool_protocol",
            "synthetic",
            "SUPPORTED" if roundtrip_ok else "BROKEN",
            "synthetic tool roundtrip",
            response=roundtrip,
        )

    def run_masc_family_probes(self) -> None:
        original_mode = self.fetch_current_mode()
        self.probe_single_tool(
            scenario_id="masc_status",
            category="status",
            prompt="Check the current MASC cluster status using masc_status. Do not answer from memory.",
            tool_names=["masc_status"],
            expected_tool="masc_status",
            execute_and_roundtrip=True,
        )
        self.probe_single_tool(
            scenario_id="masc_code_search",
            category="coding",
            prompt=(
                "Search the masc-mcp codebase for the text 'type completion_request' "
                "using masc_code_search. Use path '/Users/dancer/me/workspace/yousleepwhen/masc-mcp' "
                "and query 'type completion_request'."
            ),
            tool_names=["masc_code_search"],
            expected_tool="masc_code_search",
            execute_and_roundtrip=True,
        )

        # Cleanup family: seed, then ask model to delete the key.
        cache_key = f"qwen35-probe-cache-{int(time.time())}"
        self.mcp_call("masc_cache_set", {"key": cache_key, "value": "temporary", "tags": ["qwen35-probe"]})
        self.probe_single_tool(
            scenario_id="masc_cache_delete",
            category="cleanup",
            prompt=f"Delete the temporary cache key '{cache_key}' using masc_cache_delete.",
            tool_names=["masc_cache_delete"],
            expected_tool="masc_cache_delete",
            execute_and_roundtrip=True,
        )

        self.probe_team_session_flow()
        switched = False
        try:
            if original_mode != "full":
                self.switch_mode("full")
                switched = True
            unique_post = f"qwen35-probe-{int(time.time())}"
            self.probe_single_tool(
                scenario_id="masc_board_post",
                category="board",
                prompt=(
                    f"Create an internal board post using masc_board_post with author '{self.mcp_agent_name}', "
                    f"content '{unique_post}', hearth 'qwen35-probe', visibility 'internal', and ttl_hours 1."
                ),
                tool_names=["masc_board_post"],
                expected_tool="masc_board_post",
                execute_and_roundtrip=True,
            )
            self.probe_single_tool(
                scenario_id="masc_voice_speak",
                category="voice",
                prompt=(
                    f"Use masc_voice_speak to say 'Qwen 3.5 llama probe' for agent_id '{self.mcp_agent_name}'."
                ),
                tool_names=["masc_voice_speak"],
                expected_tool="masc_voice_speak",
                execute_and_roundtrip=True,
                execution_timeout=120.0,
            )
        finally:
            if switched:
                self.switch_mode(original_mode)

    def fetch_current_mode(self) -> str:
        config = self.mcp_call("masc_get_config", {})
        content_items = config.get("content")
        if isinstance(content_items, list):
            for item in content_items:
                if isinstance(item, dict):
                    text_value = item.get("text")
                    if isinstance(text_value, str):
                        try:
                            parsed = json.loads(text_value)
                        except json.JSONDecodeError:
                            continue
                        if isinstance(parsed, dict):
                            mode = parsed.get("mode")
                            if isinstance(mode, str) and mode.strip():
                                return mode.strip()
        raise ProbeFailure("masc_get_config did not expose current mode")

    def switch_mode(self, mode: str) -> None:
        self.mcp_call("masc_switch_mode", {"mode": mode})

    def probe_single_tool(
        self,
        *,
        scenario_id: str,
        category: str,
        prompt: str,
        tool_names: list[str],
        expected_tool: str,
        execute_and_roundtrip: bool = False,
        execution_timeout: float = 45.0,
    ) -> None:
        try:
            tools = self.select_tools(tool_names)
            response = self.chat_completion(prompt=prompt, tools=tools)
            message = response["choices"][0]["message"]
            tool_calls = message.get("tool_calls") or []
            if not tool_calls:
                self.add_result(
                    scenario_id,
                    "masc_family",
                    category,
                    "BROKEN",
                    "model did not call the expected MASC tool",
                    response=response,
                )
                return
            call = tool_calls[0]
            tool_name = call["function"]["name"]
            if tool_name != expected_tool:
                self.add_result(
                    scenario_id,
                    "masc_family",
                    category,
                    "BROKEN",
                    f"expected {expected_tool}, got {tool_name}",
                    response=response,
                )
                return

            if not execute_and_roundtrip:
                self.add_result(
                    scenario_id,
                    "masc_family",
                    category,
                    "SUPPORTED",
                    f"model selected {expected_tool}",
                    response=response,
                )
                return

            raw_arguments = call["function"].get("arguments") or "{}"
            try:
                arguments = json.loads(raw_arguments)
            except json.JSONDecodeError:
                repair_prompt = (
                    prompt
                    + "\nReturn only the tool call with strictly valid JSON function arguments. "
                    + "Do not emit free text."
                )
                repair_response = self.chat_completion(
                    prompt=repair_prompt,
                    tools=tools,
                    overrides={"temperature": 0.0},
                )
                repair_message = repair_response["choices"][0]["message"]
                repair_calls = repair_message.get("tool_calls") or []
                if not repair_calls or repair_calls[0]["function"]["name"] != expected_tool:
                    raise
                response = repair_response
                call = repair_calls[0]
                raw_arguments = call["function"].get("arguments") or "{}"
                arguments = json.loads(raw_arguments)
            execution = self.mcp_call(expected_tool, arguments, timeout=execution_timeout)
            execution_error = bool(execution.get("isError"))
            execution_text = json.dumps(execution, ensure_ascii=False)
            roundtrip = self.chat_completion(
                prompt="masc roundtrip",
                messages=[
                    {"role": "user", "content": prompt},
                    {
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [
                            {
                                "id": call["id"],
                                "type": "function",
                                "function": {
                                    "name": expected_tool,
                                    "arguments": json.dumps(arguments),
                                },
                            }
                        ],
                    },
                    {
                        "role": "tool",
                        "tool_call_id": call["id"],
                        "content": execution_text,
                    },
                ],
            )
            final_content = roundtrip["choices"][0]["message"]["content"]
            if execution_error and "disabled in current mode" in execution_text.lower():
                status = "SUPPORTED_WITH_GUARDRAIL"
                summary = f"{expected_tool} exists but is blocked by current mode"
            elif execution_error:
                status = "BROKEN"
                summary = f"{expected_tool} call returned an execution error"
            else:
                status = "SUPPORTED"
                summary = f"{expected_tool} selected, executed, and round-tripped"
            self.add_result(
                scenario_id,
                "masc_family",
                category,
                status,
                summary,
                response=response,
                execution=execution,
                roundtrip=roundtrip,
                final_content=final_content,
            )
        except Exception as exc:  # noqa: BLE001
            self.add_result(
                scenario_id,
                "masc_family",
                category,
                "BROKEN",
                str(exc),
            )

    def probe_team_session_flow(self) -> None:
        start_prompt = (
            "Start a short MASC team session using masc_team_session_start with goal "
            "'Qwen35 probe: verify team session tool loop' and worker_count 2."
        )
        try:
            tools = self.select_tools(["masc_team_session_start"])
            start_resp = self.chat_completion(prompt=start_prompt, tools=tools)
            tool_calls = start_resp["choices"][0]["message"].get("tool_calls") or []
            if not tool_calls or tool_calls[0]["function"]["name"] != "masc_team_session_start":
                self.add_result(
                    "masc_team_session_flow",
                    "masc_family",
                    "team_session",
                    "BROKEN",
                    "model did not call masc_team_session_start",
                    response=start_resp,
                )
                return
            start_args = json.loads(tool_calls[0]["function"]["arguments"] or "{}")
            start_exec = self.mcp_call(
                "masc_team_session_start",
                start_args,
                use_explicit_agent=False,
            )
            session_text = json.dumps(start_exec, ensure_ascii=False)
            session_id = ""
            nested_candidates = [start_exec]
            nested_result = start_exec.get("result")
            if isinstance(nested_result, dict):
                nested_candidates.append(nested_result)
            envelope = start_exec.get("resultEnvelope")
            if isinstance(envelope, dict):
                nested_candidates.append(envelope)
            content_items = start_exec.get("content")
            if isinstance(content_items, list):
                for item in content_items:
                    if isinstance(item, dict):
                        text_value = item.get("text")
                        if isinstance(text_value, str) and text_value.strip().startswith("{"):
                            try:
                                parsed_text = json.loads(text_value)
                            except json.JSONDecodeError:
                                continue
                            if isinstance(parsed_text, dict):
                                nested_candidates.append(parsed_text)
                                nested_result = parsed_text.get("result")
                                if isinstance(nested_result, dict):
                                    nested_candidates.append(nested_result)
            for blob in nested_candidates:
                for candidate in ("session_id", "id"):
                    value = blob.get(candidate)
                    if isinstance(value, str) and value.strip():
                        session_id = value.strip()
                        break
                if session_id:
                    break
            if not session_id:
                # Try to scrape from summary text if envelope only.
                summary = (envelope or {}).get("summary") if isinstance(envelope, dict) else ""
                summary = summary or ""
                marker = "session_id="
                if marker in summary:
                    session_id = summary.split(marker, 1)[1].split()[0]
            if not session_id:
                raise ProbeFailure("team session start did not return session_id")

            # Status
            status_prompt = (
                f"Check the status of team session '{session_id}' using masc_team_session_status."
            )
            status_tools = self.select_tools(["masc_team_session_status"])
            status_resp = self.chat_completion(prompt=status_prompt, tools=status_tools)
            status_call = status_resp["choices"][0]["message"].get("tool_calls") or []
            if not status_call or status_call[0]["function"]["name"] != "masc_team_session_status":
                raise ProbeFailure("team session status call missing")
            status_args = json.loads(status_call[0]["function"]["arguments"] or "{}")
            status_exec = self.mcp_call(
                "masc_team_session_status",
                status_args,
                use_explicit_agent=False,
            )

            # Step
            step_prompt = (
                f"Add a note turn to team session '{session_id}' using masc_team_session_step. "
                "Use turn_kind 'note' and message '[qwen35 probe] status confirmed'."
            )
            step_tools = self.select_tools(["masc_team_session_step"])
            step_resp = self.chat_completion(prompt=step_prompt, tools=step_tools)
            step_call = step_resp["choices"][0]["message"].get("tool_calls") or []
            if not step_call or step_call[0]["function"]["name"] != "masc_team_session_step":
                raise ProbeFailure("team session step call missing")
            step_args = json.loads(step_call[0]["function"]["arguments"] or "{}")
            step_exec = self.mcp_call(
                "masc_team_session_step",
                step_args,
                use_explicit_agent=False,
            )

            # Stop
            stop_prompt = (
                f"Stop team session '{session_id}' using masc_team_session_stop with a short note."
            )
            stop_tools = self.select_tools(["masc_team_session_stop"])
            stop_resp = self.chat_completion(prompt=stop_prompt, tools=stop_tools)
            stop_call = stop_resp["choices"][0]["message"].get("tool_calls") or []
            if not stop_call or stop_call[0]["function"]["name"] != "masc_team_session_stop":
                raise ProbeFailure("team session stop call missing")
            stop_args = json.loads(stop_call[0]["function"]["arguments"] or "{}")
            stop_exec = self.mcp_call(
                "masc_team_session_stop",
                stop_args,
                use_explicit_agent=False,
            )

            execution_blob = json.dumps(
                {
                    "status": status_exec,
                    "step": step_exec,
                    "stop": stop_exec,
                },
                ensure_ascii=False,
            ).lower()
            if "not authorized for this team session" in execution_blob:
                status_value = "SUPPORTED_WITH_GUARDRAIL"
                summary = "team session starts, but follow-up calls are blocked by authorization"
            else:
                status_value = "SUPPORTED"
                summary = "team session start/status/step/stop completed"

            self.add_result(
                "masc_team_session_flow",
                "masc_family",
                "team_session",
                status_value,
                summary,
                start_response=start_resp,
                start_execution=start_exec,
                status_response=status_resp,
                status_execution=status_exec,
                step_response=step_resp,
                step_execution=step_exec,
                stop_response=stop_resp,
                stop_execution=stop_exec,
                session_id=session_id,
                start_payload=session_text,
            )
        except Exception as exc:  # noqa: BLE001
            self.add_result(
                "masc_team_session_flow",
                "masc_family",
                "team_session",
                "BROKEN",
                str(exc),
            )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Probe Qwen3.5 llama-server tool calling against MASC tool families.",
    )
    parser.add_argument("--llama-base-url", default=DEFAULT_LLAMA_BASE)
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    parser.add_argument("--model", default="")
    parser.add_argument(
        "--sampling-profile",
        default="local_default",
        choices=["local_default", "unsloth_general", "unsloth_precise_coding"],
    )
    parser.add_argument("--max-tokens", type=int, default=0)
    parser.add_argument("--enable-thinking", action="store_true")
    parser.add_argument("--output", default=str(DEFAULT_OUTPUT))
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        probe = Probe(args)
        report = probe.run()
        output_path = Path(args.output)
        output_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
