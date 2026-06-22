import json

from api.core.loop_core import ToolCall, TurnResult
from api.core.openai_loop import OpenAIAdapter, _function_tool, _computer_tool_schema


class _StubMessage:
    def __init__(self, content="", tool_calls=None):
        self.content = content
        self.tool_calls = tool_calls or []

    def model_dump(self, exclude_none=False):
        payload = {"role": "assistant", "content": self.content}
        if self.tool_calls:
            payload["tool_calls"] = [
                {
                    "id": call.id,
                    "type": "function",
                    "function": {"name": call.function.name, "arguments": call.function.arguments},
                }
                for call in self.tool_calls
            ]
        return payload


class _StubChoice:
    def __init__(self, message):
        self.message = message


class _StubResponse:
    def __init__(self, message):
        self.choices = [_StubChoice(message)]


class _StubToolCall:
    def __init__(self, id, name, arguments):
        self.id = id
        self.function = type("Function", (), {"name": name, "arguments": arguments})()


def _adapter():
    return OpenAIAdapter(client=None, model="gpt-test")


def test_initial_messages_inserts_system_first():
    adapter = _adapter()

    messages = adapter.initial_messages(
        [{"role": "assistant", "content": "prior"}, {"role": "tool", "content": "skip"}],
        "do it",
        "you are klo",
    )

    assert messages == [
        {"role": "system", "content": "you are klo"},
        {"role": "assistant", "content": "prior"},
        {"role": "user", "content": "do it"},
    ]


def test_adapter_tools_includes_generic_and_computer():
    adapter = _adapter()
    generic = [
        {"name": "macos", "description": "x", "input_schema": {"type": "object"}},
    ]

    tools = adapter.adapter_tools(generic, 1440, 900)

    names = {tool["function"]["name"] for tool in tools}
    assert names == {"macos", "computer"}


def test_parse_extracts_text_and_tool_calls():
    adapter = _adapter()
    response = _StubResponse(
        _StubMessage(
            content="hello",
            tool_calls=[_StubToolCall("c1", "macos", json.dumps({"action": "open_url", "url": "x"}))],
        )
    )

    parsed = adapter.parse(response)

    assert parsed.text == "hello"
    assert len(parsed.tool_calls) == 1
    assert parsed.tool_calls[0].id == "c1"
    assert parsed.tool_calls[0].name == "macos"
    assert parsed.tool_calls[0].input == {"action": "open_url", "url": "x"}


def test_parse_handles_invalid_arguments_json():
    adapter = _adapter()
    response = _StubResponse(
        _StubMessage(tool_calls=[_StubToolCall("c1", "macos", "not-json")])
    )

    parsed = adapter.parse(response)

    assert parsed.tool_calls[0].input == {}


def test_extend_with_tool_results_appends_role_tool_messages():
    adapter = _adapter()
    messages: list = []
    adapter.extend_with_tool_results(
        messages,
        [
            TurnResult(tool_id="c1", text="ok", has_screenshot=False, raw_content=[], is_error=False),
            TurnResult(tool_id="c2", text=None, has_screenshot=False, raw_content=[], is_error=True),
        ],
    )

    assert messages == [
        {"role": "tool", "tool_call_id": "c1", "content": "ok"},
        {"role": "tool", "tool_call_id": "c2", "content": "ok"},
    ]


def test_function_tool_converts_schema():
    tool = _function_tool({
        "name": "demo",
        "description": "demo tool",
        "input_schema": {"type": "object", "properties": {}},
    })

    assert tool == {
        "type": "function",
        "function": {
            "name": "demo",
            "description": "demo tool",
            "parameters": {"type": "object", "properties": {}},
        },
    }


def test_computer_tool_schema_lists_actions():
    schema = _computer_tool_schema()
    actions = schema["input_schema"]["properties"]["action"]["enum"]
    assert "screenshot" in actions
    assert "type" in actions
