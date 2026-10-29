# SPDX-License-Identifier: Apache-2.0
"""Every provider's one vision call takes the question it is asked (`inspect_image`).

The facing check asks where a face points; `logo` asks what the lettering spells. Both go
through the same transport on the provider that drew the image, on its own login, once.
The facing question and its request body stay what they were.
"""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from sprite_gen.gen import codex_provider, facing, facing_vision, grok_provider, openai_provider, xai

FIXTURES = Path(__file__).parents[1] / "fixtures" / "facing"
QUESTION = "Read the lettering."


def _answer() -> dict:
    return {"model": "test-vision", "status": "completed",
            "output": [{"type": "message", "content": [{"type": "output_text", "text": '{"lines": ["ION"]}'}]}]}


def test_the_facing_body_is_unchanged() -> None:
    body = facing_vision.request_body(FIXTURES / "left.png", "m")
    content = body["input"][0]["content"]
    assert body["max_output_tokens"] == 256 and content[0]["text"] == facing.INSPECTION_PROMPT
    assert content[1]["detail"] == "low"


def test_a_question_and_its_detail_are_carried() -> None:
    body = facing_vision.request_body(FIXTURES / "left.png", "m", prompt=QUESTION, detail="high")
    content = body["input"][0]["content"]
    assert content[0]["text"] == QUESTION and content[1]["detail"] == "high"


@pytest.mark.parametrize("provider", ["openai", "grok"])
def test_rest_providers_ask_the_question_once(monkeypatch, tmp_path, provider) -> None:
    seen = []
    if provider == "openai":
        monkeypatch.setattr(openai_provider, "resolve_credential", lambda: "synthetic")

        def http(url, token, data, content_type, **kw):
            seen.append(json.loads(data))
            return 200, _answer(), {}

        monkeypatch.setattr(openai_provider, "http_image", http)
        backend = openai_provider.OpenAIProvider()
    else:
        monkeypatch.setattr(xai, "resolve_credential", lambda: xai.Credential("synthetic", "grok-login"))

        def http(method, url, token, body, **kw):
            seen.append(body)
            return 200, _answer()

        monkeypatch.setattr(xai, "http_json", http)
        backend = grok_provider.GrokProvider()
    text, metadata = backend.inspect_image(FIXTURES / "left.png", tmp_path, QUESTION)
    assert json.loads(text) == {"lines": ["ION"]}
    assert len(seen) == 1 and seen[0]["input"][0]["content"][0]["text"] == QUESTION
    assert metadata["model"] == "test-vision"


def test_codex_asks_the_question_on_its_own_login(monkeypatch, tmp_path) -> None:
    seen = []

    def run(command, **kwargs):
        seen.append((command, kwargs))
        Path(command[command.index("-o") + 1]).write_text('{"lines": ["ION"]}')
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(facing_vision.subprocess, "run", run)
    monkeypatch.setattr(codex_provider, "codex_login", lambda: codex_provider.CodexLogin(codex_provider.AUTH_SOURCE_LOGIN))
    text, metadata = codex_provider.CodexProvider().inspect_image(FIXTURES / "left.png", tmp_path, QUESTION)
    assert json.loads(text) == {"lines": ["ION"]} and metadata["auth_source"] == "codex-login"
    assert len(seen) == 1 and seen[0][1]["input"] == QUESTION
    assert "--ephemeral" in seen[0][0] and "read-only" in seen[0][0]


def test_the_facing_check_still_asks_the_facing_question(monkeypatch, tmp_path) -> None:
    seen = []

    def run(command, **kwargs):
        seen.append(kwargs["input"])
        Path(command[command.index("-o") + 1]).write_text("left")
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(facing_vision.subprocess, "run", run)
    monkeypatch.setattr(codex_provider, "codex_login", lambda: codex_provider.CodexLogin(codex_provider.AUTH_SOURCE_LOGIN))
    assert codex_provider.CodexProvider().inspect_facing(FIXTURES / "left.png", tmp_path)[0] == "left"
    assert seen == [facing.INSPECTION_PROMPT]
