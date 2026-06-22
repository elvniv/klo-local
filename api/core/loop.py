from __future__ import annotations

from typing import Any

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


COMPUTER_BETA = "computer-use-2025-11-24"
COMPUTER_TOOL_TYPE = "computer_20251124"


class AnthropicAdapter(ModelAdapter):
    def __init__(self, client: Any, model: str) -> None:
        self.client = client
        self.model = model

    def initial_messages(
        self,
        prior_messages: list[dict[str, Any]],
        prompt: str,
        system_prompt: str,
    ) -> list[Any]:
        messages = list(prior_messages)
        messages.append({"role": "user", "content": prompt})
        return messages

    def adapter_tools(
        self, generic_tools: list[dict[str, Any]], display_width: int, display_height: int
    ) -> list[dict[str, Any]]:
        return [
            {
                "type": COMPUTER_TOOL_TYPE,
                "name": "computer",
                "display_width_px": display_width,
                "display_height_px": display_height,
            },
            *generic_tools,
        ]

    async def create_turn(
        self, system_prompt: str, messages: list[Any], tools: list[dict[str, Any]]
    ) -> Any:
        return await self.client.beta.messages.create(
            model=self.model,
            max_tokens=2048,
            system=system_prompt,
            messages=messages,
            tools=tools,
            betas=[COMPUTER_BETA],
        )

    def parse(self, raw: Any) -> ParsedResponse:
        text_parts: list[str] = []
        calls: list[ToolCall] = []
        for block in getattr(raw, "content", []) or []:
            block_type = getattr(block, "type", None)
            if block_type == "text":
                content = getattr(block, "text", "")
                if content:
                    text_parts.append(content)
            elif block_type == "tool_use":
                calls.append(
                    ToolCall(
                        id=getattr(block, "id"),
                        name=getattr(block, "name", ""),
                        input=dict(getattr(block, "input", {}) or {}),
                    )
                )
        return ParsedResponse(text="\n".join(text_parts), tool_calls=calls)

    def append_assistant(self, messages: list[Any], raw: Any) -> None:
        messages.append({"role": "assistant", "content": raw.content})

    def extend_with_tool_results(
        self, messages: list[Any], results: list[TurnResult]
    ) -> None:
        if not results:
            return
        blocks: list[dict[str, Any]] = []
        for result in results:
            blocks.append(
                {
                    "type": "tool_result",
                    "tool_use_id": result.tool_id,
                    "content": result.raw_content,
                    "is_error": result.is_error,
                }
            )
        messages.append({"role": "user", "content": blocks})

    def append_user_text(self, messages: list[Any], text: str) -> None:
        messages.append({"role": "user", "content": text})

    def usage(self, raw: Any) -> dict[str, int]:
        u = getattr(raw, "usage", None)
        if u is None:
            return {}
        out: dict[str, int] = {}
        for src, dst in (
            ("input_tokens", "input_tokens"),
            ("output_tokens", "output_tokens"),
            ("cache_read_input_tokens", "cached_input_tokens"),
            ("cache_creation_input_tokens", "cache_creation_tokens"),
        ):
            v = getattr(u, src, None)
            if isinstance(v, int):
                out[dst] = v
        return out


class ComputerUseLoop:
    def __init__(
        self,
        settings: Settings,
        store: RunStore,
        client: Any | None = None,
    ) -> None:
        anthropic_client = client or _anthropic_client(settings.anthropic_api_key)
        adapter = AnthropicAdapter(anthropic_client, settings.anthropic_model)
        self._core = LoopCore(settings, store, adapter)

    async def run(
        self,
        run_id: str,
        prompt: str,
        prior_messages: list[dict[str, Any]] | None = None,
        resume_state: PauseState | None = None,
    ) -> None:
        await self._core.run(run_id, prompt, prior_messages, resume_state=resume_state)


def _anthropic_client(api_key: str) -> Any:
    if not api_key:
        raise RuntimeError("Set ANTHROPIC_API_KEY in .env before starting a run.")

    from anthropic import AsyncAnthropic

    return AsyncAnthropic(api_key=api_key)
