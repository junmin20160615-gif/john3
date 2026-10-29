# SPDX-License-Identifier: Apache-2.0
"""`sprite-gen logo`: a mood image with the title in it, the lettering redrawn on a key, the key removed.

The provider is a stand-in that paints synthetic pictures and answers the text check from a
script, so the verb's contract is held offline: what each step sends, what it publishes,
what it refuses (no text, a title the model dropped, letters that differ) and what the
report says. Nothing here draws a font: a logo comes from the model or not at all.
"""

from __future__ import annotations

import json
import unicodedata
from pathlib import Path

import numpy as np
import pytest
from PIL import Image

from logo_lettering import GREEN_PAINTED, MAGENTA_PAINTED, lettering
from sprite_gen import gen
from sprite_gen.gen import base as gen_base
from sprite_gen.gen import logo


def _scene(colour=(30, 40, 90)) -> Image.Image:
    image = Image.new("RGB", (320, 180), colour)
    for x in range(320):
        for y in range(120, 180):
            image.putpixel((x, y), (60, 50, 40))
    return image


class FakeProvider:
    """Paints a scene for the mood step, synthetic lettering for the edit, and reads a script."""

    name = "fake"
    transparency = gen_base.TRANSPARENCY_NATIVE

    def __init__(self, *, reads=(["ION"], ["ION"]), mood=None, letters=None, auth="codex-login") -> None:
        self.reads = list(reads)
        self.mood = mood if mood is not None else _scene()
        self.letters = letters
        self.auth = auth
        self.requests: list[gen_base.GenRequest] = []
        self.looked: list[tuple[Path, str]] = []

    def generate(self, request: gen_base.GenRequest, workdir: Path) -> gen_base.ProviderRun:
        self.requests.append(request)
        if request.refs:
            green = "#00FF00" in request.prompt
            picture = self.letters or lettering(key=GREEN_PAINTED if green else MAGENTA_PAINTED).image
        else:
            picture = self.mood
        picture.save(request.raw)
        return gen_base.ProviderRun(provider=self.name, elapsed_seconds=1.5, model="fake-image",
                                    extra={"auth_source": self.auth, "transport": "fake"})

    def inspect_image(self, path: Path, workdir: Path, prompt: str, *, label: str = "") -> tuple[str, dict]:
        with Image.open(path) as shown:
            shown.load()
            self.looked.append((Path(path), shown.mode))
        lines = self.reads.pop(0)
        if isinstance(lines, Exception):
            raise lines
        return json.dumps({"lines": lines}), {"model": "fake-vision", "auth_source": self.auth, "transport": "fake"}

    def inspect_facing(self, path: Path, workdir: Path):  # pragma: no cover - not used by logo
        raise AssertionError("logo never asks for a facing")


@pytest.fixture
def fake(monkeypatch):
    def install(**kwargs) -> FakeProvider:
        provider = FakeProvider(**kwargs)
        monkeypatch.setattr(gen, "_make_provider", lambda name, *, keep_session=False: provider)
        return provider

    return install


def _run(tmp_path: Path, **overrides):
    kwargs = dict(text="ION", style="painted fantasy", out_dir=tmp_path / "logo", provider="fake")
    kwargs.update(overrides)
    return logo.run(**kwargs)


def _report(tmp_path: Path) -> dict:
    return json.loads((tmp_path / "logo" / "logo.report.json").read_text(encoding="utf-8"))


def test_three_steps_publish_a_transparent_logo_with_its_mood_image_and_report(tmp_path, fake) -> None:
    provider = fake()
    assert _run(tmp_path) == 0
    out = tmp_path / "logo"
    for name in ("mood.png", "lettering.png", "logo.png", "logo.preview.png", "logo.report.json"):
        assert (out / name).is_file(), name
    first, second = provider.requests
    assert first.refs == []
    assert '"ION"' in first.prompt and "painted fantasy" in first.prompt and "title screen" in first.prompt
    assert [Path(r).name for r in second.refs] == ["mood.png"]
    assert '"ION"' in second.prompt and "#FF00FF" in second.prompt
    assert "only the title lettering" in second.prompt
    with Image.open(out / "logo.png") as cut, Image.open(out / "lettering.png") as drawn:
        assert cut.mode == "RGBA"
        assert cut.width < drawn.width and cut.height < drawn.height
        alpha = np.asarray(cut)[..., 3]
    assert alpha.max() == 255 and ((alpha > 0) & (alpha < 255)).any()
    report = _report(tmp_path)
    assert report["kind"] == "sprite-gen-logo-report" and report["status"] == "ok"
    assert report["text"] == "ION" and report["subtitle"] is None
    assert report["steps"]["mood"]["source"] == "generated"
    assert report["steps"]["matte"]["method"] == "logo-unmix" and report["steps"]["matte"]["key"] == "magenta"
    assert report["logo"]["size"] == list(Image.open(out / "logo.png").size)
    assert report["logo"]["alpha"]["partial_pct"] > 0
    assert report["text_check"]["mood"]["verdict"] == "match"
    assert report["text_check"]["logo"] == {**report["text_check"]["logo"], "verdict": "match", "read": ["ION"]}
    assert [c["step"] for c in report["calls"]] == ["mood", "mood-check", "lettering", "logo-check"]
    assert {c["route"] for c in report["calls"]} == {"subscription"}
    assert all(c["elapsed_seconds"] >= 0 for c in report["calls"])


def test_the_text_check_sees_the_logo_on_a_plain_backdrop_not_on_the_key(tmp_path, fake) -> None:
    provider = fake()
    assert _run(tmp_path) == 0
    shown, mode = provider.looked[-1]
    assert shown.name != "logo.png" and mode == "RGB"  # the logo laid on a flat backdrop, not the transparent file


def test_empty_text_is_refused_before_anything_is_bought(tmp_path, fake) -> None:
    provider = fake()
    with pytest.raises(SystemExit, match="empty --text"):
        _run(tmp_path, text="   ")
    assert provider.requests == [] and provider.looked == []


def test_a_title_the_mood_image_dropped_is_refused_before_the_lettering_is_bought(tmp_path, fake) -> None:
    provider = fake(reads=(["IO"],))
    with pytest.raises(SystemExit, match="mood image"):
        _run(tmp_path)
    assert len(provider.requests) == 1
    out = tmp_path / "logo"
    assert (out / "mood.png").is_file()
    assert not (out / "lettering.png").exists() and not (out / "logo.png").exists()
    report = _report(tmp_path)
    assert report["status"] == "refused" and report["refused_at"] == "mood-check"
    assert report["text_check"]["mood"]["verdict"] == "mismatch" and report["text_check"]["mood"]["read"] == ["IO"]


def test_a_logo_whose_letters_differ_from_the_text_is_refused_and_kept_aside(tmp_path, fake) -> None:
    fake(reads=(["ION"], ["I0N"]))
    with pytest.raises(SystemExit, match="logo reads"):
        _run(tmp_path)
    out = tmp_path / "logo"
    assert not (out / "logo.png").exists() and (out / "logo.rejected.png").is_file()
    report = _report(tmp_path)
    assert report["status"] == "refused" and report["refused_at"] == "logo-check"
    assert report["text_check"]["logo"]["verdict"] == "mismatch"


def test_no_text_read_at_all_is_refused(tmp_path, fake) -> None:
    fake(reads=(["ION"], []))
    with pytest.raises(SystemExit, match="logo reads"):
        _run(tmp_path)
    assert _report(tmp_path)["text_check"]["logo"]["verdict"] == "no-text"


def test_a_check_that_could_not_run_is_said_not_passed(tmp_path, fake, capsys) -> None:
    fake(reads=(["ION"], RuntimeError("vision down")))
    assert _run(tmp_path) == 0
    report = _report(tmp_path)
    assert report["status"] == "unverified"
    assert report["text_check"]["logo"]["verdict"] == "unverified"
    assert "vision-call-failed:RuntimeError" in report["text_check"]["logo"]["reason"]
    assert "not verified" in capsys.readouterr().err
    assert (tmp_path / "logo" / "logo.png").is_file()


def test_subtitle_and_language_reach_the_prompts_and_the_check(tmp_path, fake) -> None:
    provider = fake(reads=(["ION", "Chapter One"], ["ION", "CHAPTER ONE"]))
    assert _run(tmp_path, subtitle="Chapter One", language="Korean") == 0
    for request in provider.requests:
        assert '"Chapter One"' in request.prompt and "Korean" in request.prompt
    report = _report(tmp_path)
    assert report["subtitle"] == "Chapter One" and report["language"] == "Korean"


def test_a_dropped_subtitle_is_a_mismatch(tmp_path, fake) -> None:
    fake(reads=(["ION", "Chapter One"], ["ION"]))
    with pytest.raises(SystemExit, match="logo reads"):
        _run(tmp_path, subtitle="Chapter One")


def test_a_vowel_sign_the_model_dropped_is_refused_at_either_check(tmp_path, fake) -> None:
    asked, read = "\u0915\u093f\u0932\u093e", "\u0915\u0932\u093e"  # किला read as कला: the vowel sign ि dropped
    provider = fake(reads=([read],))
    with pytest.raises(SystemExit, match="mood image"):
        _run(tmp_path, text=asked, language="Hindi")
    assert len(provider.requests) == 1  # the lettering was not bought
    assert _report(tmp_path)["text_check"]["mood"]["verdict"] == "mismatch"
    fake(reads=([asked], [read]))
    with pytest.raises(SystemExit, match="logo reads"):
        _run(tmp_path, text=asked, language="Hindi")
    out = tmp_path / "logo"
    assert not (out / "logo.png").exists() and (out / "logo.rejected.png").is_file()
    assert _report(tmp_path)["text_check"]["logo"]["verdict"] == "mismatch"


def test_a_given_mood_image_skips_the_first_generation(tmp_path, fake) -> None:
    provider = fake(reads=(["ION"], ["ION"]))
    given = tmp_path / "title.png"
    _scene().save(given)
    assert _run(tmp_path, mood=given) == 0
    assert len(provider.requests) == 1 and provider.requests[0].refs
    report = _report(tmp_path)
    assert report["steps"]["mood"]["source"] == "given"
    assert [c["step"] for c in report["calls"]] == ["mood-check", "lettering", "logo-check"]


def test_the_key_is_chosen_from_the_title_box_the_mood_check_reads(tmp_path, fake) -> None:
    mood = _scene((40, 200, 60))  # a forest ...
    for x in range(120, 200):
        for y in range(60, 100):
            mood.putpixel((x, y), (230, 60, 210))  # ... with a pink title in it
    provider = fake(mood=mood)

    def answer(path, workdir, prompt, *, label=""):
        provider.looked.append((Path(path), "RGB"))
        if len(provider.looked) == 1:  # the mood check: it is asked for the title's box
            assert '"box"' in prompt
            return json.dumps({"lines": ["ION"], "box": [0.375, 0.333, 0.625, 0.555]}), {"auth_source": "codex-login"}
        assert '"box"' not in prompt
        return json.dumps({"lines": ["ION"]}), {"auth_source": "codex-login"}

    provider.inspect_image = answer
    assert _run(tmp_path) == 0
    report = _report(tmp_path)
    assert report["text_check"]["mood"]["box"] == [0.375, 0.333, 0.625, 0.555]
    assert report["steps"]["key"]["region"] == "lettering-box" and report["steps"]["key"]["key"] == "green"
    assert "#00FF00" in provider.requests[1].prompt


def test_a_lettering_image_is_cut_again_without_generating(tmp_path, fake) -> None:
    provider = fake(reads=(["ION"],))
    out = tmp_path / "logo"
    out.mkdir()
    lettering(key=GREEN_PAINTED, fill=(255, 214, 40), glow=(255, 120, 20), glow_strength=0.7).image.save(
        out / "lettering.png")
    assert _run(tmp_path, lettering=out / "lettering.png") == 0  # in place: the input is not cleared first
    assert provider.requests == [] and len(provider.looked) == 1
    report = _report(tmp_path)
    assert report["steps"]["lettering"]["source"] == "given" and report["steps"]["mood"]["source"] == "none"
    assert report["steps"]["key"] == {"key": "green", "source": "border"}
    assert [c["step"] for c in report["calls"]] == ["logo-check"]
    assert (out / "logo.png").is_file()


def test_a_mood_image_full_of_magenta_moves_the_lettering_to_the_green_key(tmp_path, fake) -> None:
    provider = fake(mood=_scene((220, 50, 200)))
    assert _run(tmp_path) == 0
    assert "#00FF00" in provider.requests[1].prompt and "#FF00FF" not in provider.requests[1].prompt
    report = _report(tmp_path)
    assert report["steps"]["matte"]["key"] == "green"
    assert report["steps"]["key"]["source"] == "auto" and report["steps"]["key"]["key"] == "green"


def test_an_explicit_key_is_kept(tmp_path, fake) -> None:
    provider = fake(mood=_scene((220, 50, 200)))
    assert _run(tmp_path, chroma_key="magenta") == 0
    assert "#FF00FF" in provider.requests[1].prompt
    assert _report(tmp_path)["steps"]["key"]["source"] == "explicit"


def test_no_font_is_ever_drawn(tmp_path, fake, monkeypatch) -> None:
    from PIL import ImageDraw, ImageFont

    def forbidden(*_args, **_kwargs):
        raise AssertionError("a font was drawn")

    for name in ("truetype", "load_default", "load"):
        monkeypatch.setattr(ImageFont, name, forbidden)
    monkeypatch.setattr(ImageDraw.ImageDraw, "text", forbidden)
    fake()
    assert _run(tmp_path) == 0


def test_a_failed_lettering_generation_publishes_nothing_in_its_place(tmp_path, fake) -> None:
    provider = fake()

    def broken(request, workdir):
        if request.refs:
            raise SystemExit("fake-gen: the provider refused")
        return FakeProvider.generate(provider, request, workdir)

    provider.generate = broken
    with pytest.raises(SystemExit, match="refused"):
        _run(tmp_path)
    out = tmp_path / "logo"
    assert not (out / "logo.png").exists() and not (out / "lettering.png").exists()


def test_a_painted_checkerboard_is_refused(tmp_path, fake) -> None:
    board = Image.new("RGB", (320, 160))
    for y in range(160):
        for x in range(320):
            board.putpixel((x, y), (204, 204, 204) if (x // 16 + y // 16) % 2 else (255, 255, 255))
    fake(letters=board)
    with pytest.raises(SystemExit, match="checkerboard"):
        _run(tmp_path)
    assert not (tmp_path / "logo" / "logo.png").exists()


def test_the_report_names_a_per_call_route(tmp_path, fake) -> None:
    fake(auth="codex-api-key")
    assert _run(tmp_path) == 0
    assert {c["route"] for c in _report(tmp_path)["calls"]} == {"per-call"}


def test_an_answer_names_its_lines_and_may_name_a_box() -> None:
    assert logo.parse_answer('```json\n{"lines": ["ION"], "box": [0.1, 0.2, 0.9, 0.6]}\n```') == (["ION"], [0.1, 0.2, 0.9, 0.6])
    assert logo.parse_answer('{"lines": ["ION"], "box": [0.9, 0.2, 0.1, 0.6]}') == (["ION"], None)
    assert logo.parse_answer('{"lines": "ION"}') == (None, None)
    assert logo.parse_answer("ION") == (None, None)


@pytest.mark.parametrize("asked, read, same", [
    ("Hero's Quest", ["HERO’S", "QUEST!"], True),
    ("ION", ["I O N"], True),
    ("ION", ["I0N"], False),
    ("ION", ["IONS"], False),
    ("별빛 기사", ["별빛", "기사"], True),
    ("별빛 기사", ["별빛 기시"], False),
])
def test_the_text_is_compared_letter_for_letter(asked, read, same) -> None:
    check = logo.compare_text(read, asked, None)
    assert (check["verdict"] == "match") is same


# What a script spells is its letters and the marks written on them. The strings are synthetic, escaped where a
# code point matters; each id names what the reading dropped, changed or only wrote another way.
@pytest.mark.parametrize("asked, read, same", [
    pytest.param("\u0915\u093f\u0932\u093e", ["\u0915\u0932\u093e"], False, id="devanagari-vowel-sign-dropped"),
    pytest.param("\u0915\u094d\u0937", ["\u0915\u0937"], False, id="devanagari-virama-dropped"),
    pytest.param("\u095b\u092e\u0940\u0928", ["\u091c\u092e\u0940\u0928"], False, id="devanagari-nukta-dropped"),
    pytest.param("\u0e44\u0e01\u0e48", ["\u0e44\u0e01"], False, id="thai-tone-mark-dropped"),
    pytest.param("\u0639\u064e\u0644\u064e\u0645", ["\u0639\u0650\u0644\u0652\u0645"], False,
                 id="arabic-vowel-marks-changed"),
    pytest.param("O\u0323\u0300sun", ["O\u0323sun"], False, id="latin-accent-with-no-precomposed-letter-dropped"),
    pytest.param("Caf\u00e9", ["CAFE"], False, id="latin-accent-dropped"),
    pytest.param("Caf\u00e9", ["CAFE\u0301"], True, id="latin-accent-precomposed-or-combining"),
    pytest.param(unicodedata.normalize("NFD", "별빛 기사"), ["별빛 기사"], True, id="hangul-jamo-or-syllables"),
    pytest.param("ドラゴン", ["ﾄﾞﾗｺﾞﾝ"], True, id="half-width-katakana"),
    pytest.param("QUEST \u2163", ["Quest IV"], True, id="roman-numeral-form"),
    pytest.param("I \u2764\ufe0f NY", ["I \u2764 NY"], True, id="variation-selector-on-a-symbol"),
    pytest.param("1\ufe0f\u20e3UP", ["1UP"], True, id="keycap-enclosing-mark"),
    pytest.param("\u0915\u094d\u200d\u0937", ["\u0915\u094d\u0937"], True, id="zero-width-joiner"),
])
def test_marks_written_on_a_letter_are_its_spelling(asked, read, same) -> None:
    assert (logo.compare_text(read, asked, None)["verdict"] == "match") is same


def test_the_subtitle_may_be_read_before_or_after_the_title() -> None:
    assert logo.compare_text(["Chapter One", "ION"], "ION", "Chapter One")["verdict"] == "match"


def test_the_cli_lists_the_verb() -> None:
    from sprite_gen import cli

    assert "logo" in cli.COMMANDS
    parser = cli._build_parser()
    args = parser.parse_args(["logo", "--text", "ION", "--out-dir", "x"])
    assert args.command == "logo" and args.composition == "title-screen" and args.chroma_key == "auto"
