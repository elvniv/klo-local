from api.core.os_context import AppInfo, OSContext, format_os_context, frontmost_app_name


def test_format_os_context_mentions_default_browser_and_active_app():
    context = OSContext(
        default_browser_name="Dia",
        default_browser_bundle_id="company.thebrowser.dia",
        running_apps=[AppInfo(name="Dia", active=True), AppInfo(name="Music")],
    )

    text = format_os_context(context)

    assert "Default web browser: Dia" in text
    assert "Active app: Dia" in text
    assert "Running regular apps: Dia, Music" in text


def test_frontmost_app_name_returns_string_or_none():
    value = frontmost_app_name()
    assert value is None or isinstance(value, str)
