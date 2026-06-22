from api.core.redact import redact_payload, redact_text


def test_redact_text_masks_api_keys():
    openai_key = "sk-" + "proj-" + "abcdefghijklmnopqrstuvwxyz1234567890"
    anthropic_key = "sk-" + "ant-" + "abcdefghijklmnopqrstuvwxyz"
    text = f"key {openai_key} and {anthropic_key}"

    assert "[REDACTED_KEY]" in redact_text(text)
    assert "abcdefghijklmnopqrstuvwxyz1234567890" not in redact_text(text)


def test_redact_payload_recurses():
    payload = {"text": ["sk-" + "proj-" + "abcdefghijklmnopqrstuvwxyz1234567890"]}

    assert redact_payload(payload) == {"text": ["[REDACTED_KEY]"]}
