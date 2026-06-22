from cli.bench import (
    BenchResult,
    EvidenceCheck,
    ExpectedEvidence,
    Prompt,
    SUITES,
    _build_result,
    print_report,
)


def _events(*events):
    return [{"type": etype, "payload": payload} for etype, payload in events]


def test_build_result_marks_evidence_satisfied():
    prompt = Prompt(
        "play music",
        (ExpectedEvidence("macos", "run_applescript", "playing"),),
    )
    events = _events(
        ("plan", {}),
        (
            "evidence_satisfied",
            {"from_tool": "macos", "from_action": "run_applescript", "subtask_id": "s1"},
        ),
        ("subtask_commit", {"subtask_id": "s1"}),
    )

    result = _build_result(
        prompt=prompt,
        run_id="r",
        final_status="completed",
        elapsed_ms=1000,
        summary={"tool_calls": 3, "screenshots": 0, "final_message": "done"},
        events=events,
    )

    assert result.plan_present is True
    assert result.subtask_commits == 1
    assert result.evidence[0].satisfied is True
    assert result.passed is True


def test_build_result_fails_when_evidence_missing():
    prompt = Prompt(
        "play music",
        (ExpectedEvidence("macos", "run_applescript"),),
    )
    events = _events(("plan", {}))

    result = _build_result(
        prompt=prompt,
        run_id="r",
        final_status="completed",
        elapsed_ms=1000,
        summary={"tool_calls": 1, "screenshots": 0, "final_message": "done"},
        events=events,
    )

    assert result.passed is False
    assert result.evidence_pass_rate == 0.0


def test_build_result_fails_when_verification_required_fired():
    prompt = Prompt("x", ())
    events = _events(("verification_required", {"pending": []}))

    result = _build_result(
        prompt=prompt,
        run_id="r",
        final_status="completed",
        elapsed_ms=500,
        summary={},
        events=events,
    )

    assert result.passed is False
    assert result.verification_required == 1


def test_print_report_marks_pass_and_fail(capsys):
    pass_result = BenchResult(
        prompt="ok",
        run_id="r1",
        status="completed",
        elapsed_ms=1000,
        tool_calls=2,
        screenshots=0,
        final_message="done",
        evidence=[
            EvidenceCheck(expected=ExpectedEvidence("macos", "run_applescript"), satisfied=True)
        ],
        plan_present=True,
        subtask_commits=1,
    )
    fail_result = BenchResult(
        prompt="bad",
        run_id="r2",
        status="completed",
        elapsed_ms=1500,
        tool_calls=1,
        screenshots=0,
        final_message="claimed done",
        evidence=[
            EvidenceCheck(expected=ExpectedEvidence("browser", "playback_state"), satisfied=False)
        ],
    )

    print_report([pass_result, fail_result])
    output = capsys.readouterr().out

    assert "PASS" in output
    assert "FAIL" in output
    assert "+ evidence macos/run_applescript" in output
    assert "- evidence browser/playback_state" in output
    assert "passed: 1/2" in output


def test_suites_have_prompts_with_evidence():
    assert "smoke" in SUITES
    assert "acceptance" in SUITES
    for suite in SUITES.values():
        for prompt in suite:
            assert isinstance(prompt, Prompt)
            assert prompt.text
