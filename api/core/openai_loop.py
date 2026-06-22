from __future__ import annotations

import json
from typing import Any

from openai import AsyncOpenAI

from api.config import Settings
from api.core.loop_core import (
    LoopCore,
    ModelAdapter,
    ParsedResponse,
    PauseState,
    ToolCall,
    TurnResult,
)
from api.store.persist import RunStore


class OpenAIAdapter(ModelAdapter):
    def __init__(self, client: AsyncOpenAI, model: str) -> None:
        self.client = client
        self.model = model

    def initial_messages(
        self,
        prior_messages: list[dict[str, Any]],
        prompt: str,
        system_prompt: str,
    ) -> list[Any]:
        messages: list[dict[str, Any]] = [{"role": "system", "content": system_prompt}]
        for message in prior_messages:
            role = message.get("role")
            content = message.get("content")
            if role in {"user", "assistant"} and isinstance(content, str):
                messages.append({"role": role, "content": content})
        messages.append({"role": "user", "content": prompt})
        return messages

    def adapter_tools(
        self, generic_tools: list[dict[str, Any]], display_width: int, display_height: int
    ) -> list[dict[str, Any]]:
        tools: list[dict[str, Any]] = [_function_tool(tool) for tool in generic_tools]
        tools.append(_function_tool(_computer_tool_schema()))
        return tools

    async def create_turn(
        self, system_prompt: str, messages: list[Any], tools: list[dict[str, Any]]
    ) -> Any:
        return await self.client.chat.completions.create(
            model=self.model,
            messages=messages,
            tools=tools,
            tool_choice="auto",
            temperature=0,
        )

    def parse(self, raw: Any) -> ParsedResponse:
        message = raw.choices[0].message
        text = message.content or ""
        calls: list[ToolCall] = []
        for call in message.tool_calls or []:
            try:
                arguments = json.loads(call.function.arguments or "{}")
            except json.JSONDecodeError:
                arguments = {}
            calls.append(
                ToolCall(id=call.id, name=call.function.name, input=arguments)
            )
        return ParsedResponse(text=text, tool_calls=calls)

    def append_assistant(self, messages: list[Any], raw: Any) -> None:
        message = raw.choices[0].message
        messages.append(message.model_dump(exclude_none=True))

    def extend_with_tool_results(
        self, messages: list[Any], results: list[TurnResult]
    ) -> None:
        for result in results:
            messages.append(
                {
                    "role": "tool",
                    "tool_call_id": result.tool_id,
                    "content": result.text or "ok",
                }
            )

    def append_user_text(self, messages: list[Any], text: str) -> None:
        messages.append({"role": "user", "content": text})

    def usage(self, raw: Any) -> dict[str, int]:
        u = getattr(raw, "usage", None)
        if u is None:
            return {}
        out: dict[str, int] = {}
        prompt = getattr(u, "prompt_tokens", None)
        completion = getattr(u, "completion_tokens", None)
        if isinstance(prompt, int):
            out["input_tokens"] = prompt
        if isinstance(completion, int):
            out["output_tokens"] = completion
        details = getattr(u, "prompt_tokens_details", None)
        cached = getattr(details, "cached_tokens", None) if details is not None else None
        if isinstance(cached, int):
            out["cached_input_tokens"] = cached
        return out


class OpenAIAXLoop:
    def __init__(
        self,
        settings: Settings,
        store: RunStore,
        client: Any | None = None,
    ) -> None:
        openai_client = client or _openai_client(settings.openai_api_key)
        adapter = OpenAIAdapter(openai_client, settings.openai_model)
        self._core = LoopCore(settings, store, adapter)

    async def run(
        self,
        run_id: str,
        prompt: str,
        prior_messages: list[dict[str, Any]] | None = None,
        resume_state: PauseState | None = None,
    ) -> None:
        await self._core.run(run_id, prompt, prior_messages, resume_state=resume_state)


def _function_tool(tool: dict[str, Any]) -> dict[str, Any]:
    return {
        "type": "function",
        "function": {
            "name": tool["name"],
            "description": tool["description"],
            "parameters": tool["input_schema"],
        },
    }


def _computer_tool_schema() -> dict[str, Any]:
    return {
        "name": "computer",
        "description": (
            "Generic physical computer input. Prefer macos/accessibility/system first. "
            "Use screenshot only for visual verification or coordinate targeting."
        ),
        "input_schema": {
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "enum": [
                        "screenshot",
                        "left_click",
                        "right_click",
                        "double_click",
                        "triple_click",
                        "mouse_move",
                        "left_click_drag",
                        "type",
                        "paste_text",
                        "key",
                        "hold_key",
                        "scroll",
                        "wait",
                        "get_cursor_position",
                    ],
                },
                "coordinate": {"type": "array", "items": {"type": "number"}},
                "start_coordinate": {"type": "array", "items": {"type": "number"}},
                "text": {"type": "string"},
                "key": {"type": "string"},
                "duration": {"type": "number"},
                "scroll_x": {"type": "integer"},
                "scroll_y": {"type": "integer"},
            },
            "required": ["action"],
            "additionalProperties": True,
        },
    }


def _openai_client(api_key: str) -> AsyncOpenAI:
    if not api_key:
        raise RuntimeError("Set OPENAI_API_KEY in .env before starting an OpenAI run.")
    return AsyncOpenAI(api_key=api_key)
