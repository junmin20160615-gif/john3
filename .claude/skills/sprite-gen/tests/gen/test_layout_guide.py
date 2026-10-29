# SPDX-License-Identifier: Apache-2.0
"""`gen --layout-guide`: the one-slot form of the row layout guide on a single image.

A still drawn without it fills its frame top to bottom; the guide asks for the
row guide's safe padding around the whole subject. Offline, with a fake provider
that records what it was handed while the workdir still exists.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from PIL import Image

from sprite_gen import gen
from sprite_gen.gen import base as gen_base
from sprite_gen.gen.base import GenRequest
from sprite_gen.gen.prepare import DEFAULT_SAFE_MARGIN_RATIO

SAFE_BLUE = (0x2F, 0x80, 0xED)
CROWN_ORANGE = (0xFF, 0x7A, 0x00)
FLOOR_TEAL = (0x00, 0xA7, 0xA7)


class _RecordingProvider:
    name = "fake"
    transparency = gen_base.TRANSPARENCY_NATIVE

    def __init__(self) -> None:
        self.requests: list[GenRequest] = []
        self.attached: list[Image.Image] = []

    def generate(self, request: GenRequest, workdir: Path):
        self.requests.append(request)
        self.attached = [Image.open(ref).copy() for ref in request.refs]
        Image.new("RGBA", (8, 8), (0, 255, 0, 255)).save(request.raw)
        return gen_base.ProviderRun(provider=self.name, elapsed_seconds=0.1, model=request.model)


def _run(tmp_path: Path, monkeypatch, **overrides) -> tuple[_RecordingProvider, dict]:
    fake = _RecordingProvider()
    monkeypatch.setattr(gen, "_make_provider", lambda name, *, keep_session: fake)
    report = tmp_path / "report.json"
    kwargs = dict(provider="fake", prompt="a tall knight, full body", out=tmp_path / "still.png", report=report)
    kwargs.update(overrides)
    assert gen.run(**kwargs) == 0
    return fake, json.loads(report.read_text(encoding="utf-8"))


def test_attaches_a_one_slot_guide_with_the_row_margin_and_asks_for_room_around_the_subject(tmp_path, monkeypatch):
    fake, report = _run(tmp_path, monkeypatch, layout_guide=True, aspect_ratio="1:1")

    request = fake.requests[0]
    assert len(request.refs) == 1
    guide = fake.attached[0].convert("RGB")
    assert guide.size == (1024, 1024)
    margin = int(1024 * DEFAULT_SAFE_MARGIN_RATIO)
    # The inner safe box sits the row guide's margin in from every edge, on the guide's grey; the crown
    # and floor lines lie one more margin inside it, off its edges.
    assert guide.getpixel((margin, 512)) == SAFE_BLUE
    assert guide.getpixel((300, margin)) == SAFE_BLUE
    assert guide.getpixel((300, 2 * margin)) == CROWN_ORANGE
    assert guide.getpixel((300, 1023 - 2 * margin)) == FLOOR_TEAL
    assert guide.getpixel((300, 1023 - margin)) == SAFE_BLUE
    assert guide.getpixel((300, margin // 2)) == (0xF6, 0xF6, 0xF6)
    assert request.prompt.startswith("a tall knight, full body\n\n")
    assert request.prompt.endswith(gen.layout_guide_text(report["extra"]["layout_guide"]))
    assert report["extra"]["layout_guide"] == {
        "shape": "square", "width": 1024, "height": 1024,
        "safe_margin_x": margin, "safe_margin_y": margin, "size": 1024, "safe_margin": margin,
        "crown_y": 2 * margin, "floor_y": 1023 - 2 * margin,
    }
    # The lines' places in the words are the ones drawn: 192 / 1024 and 831 / 1024 of the frame.
    assert "top of the skull on the orange line, 19% of the frame height from the top" in request.prompt
    assert "lowest supporting sole on the teal line, 81% from the top" in request.prompt
    assert "span of 62% of the frame height" in request.prompt
    # The report's refs are the caller's; the guide is the report's own field.
    assert report["refs"] == []


def test_goes_after_the_callers_references_so_the_prompt_can_call_it_the_last(tmp_path, monkeypatch):
    upload = tmp_path / "upload.png"
    Image.new("RGB", (300, 500), (200, 30, 30)).save(upload)
    fake, report = _run(tmp_path, monkeypatch, layout_guide=True, ref=[upload])

    assert [image.size for image in fake.attached] == [(300, 500), (1024, 1024)]
    assert "the last attached image is a layout guide" in fake.requests[0].prompt
    assert report["refs"] == [str(upload.resolve())]


def test_takes_the_requested_ratio(tmp_path, monkeypatch):
    fake, report = _run(tmp_path, monkeypatch, layout_guide=True, aspect_ratio="9:16")

    assert fake.attached[0].size == (576, 1024)
    assert report["extra"]["layout_guide"]["safe_margin_x"] == int(576 * DEFAULT_SAFE_MARGIN_RATIO)
    assert report["extra"]["layout_guide"]["safe_margin_y"] == int(1024 * DEFAULT_SAFE_MARGIN_RATIO)


def test_changes_nothing_when_not_asked_for(tmp_path, monkeypatch):
    fake, report = _run(tmp_path, monkeypatch)

    assert fake.requests[0].refs == []
    assert fake.requests[0].prompt == "a tall knight, full body"
    assert "layout_guide" not in report.get("extra", {})


def test_counts_as_an_attached_image_for_transparency(tmp_path, monkeypatch):
    fake, report = _run(tmp_path, monkeypatch, layout_guide=True, transparent=True, chroma_key="green")

    assert fake.requests[0].native_alpha is False
    assert report["alpha"]["strategy"] == "chroma"
    assert report["alpha"]["strategy_source"] == "refs-attached"


def test_refuses_a_ratio_it_cannot_read(tmp_path, monkeypatch):
    with pytest.raises(SystemExit, match="cannot read aspect ratio"):
        _run(tmp_path, monkeypatch, layout_guide=True, aspect_ratio="tall")


def test_ui_kit_guide_attaches_the_kit_layout_and_names_every_element(tmp_path, monkeypatch):
    from sprite_gen.frames import ui_kit

    fake, report = _run(tmp_path, monkeypatch, layout_guide="ui-kit", aspect_ratio="1:1")

    guide = fake.attached[0].convert("RGB")
    assert guide.size == (1024, 1024)
    for x, y, w, h in ui_kit.boxes((1024, 1024)).values():
        assert guide.getpixel((x + w // 2, y)) == ui_kit.GUIDE_BOX
        assert guide.getpixel((x + w // 2, y + h // 2)) == ui_kit.GUIDE_BACKGROUND
    request = fake.requests[0]
    assert request.prompt.startswith("a tall knight, full body\n\n")
    assert request.prompt.endswith(ui_kit.guide_text())
    assert "crown" not in request.prompt
    cell = report["extra"]["layout_guide"]
    assert cell["kind"] == "ui-kit"
    assert cell["boxes"]["panel"] == {"x": 48, "y": 48, "w": 576, "h": 400}
    assert report["refs"] == []


def test_ui_kit_guide_is_square_or_2_3(tmp_path, monkeypatch):
    for ratio in ("16:9", "3:4", "9:16"):
        with pytest.raises(SystemExit, match=r"square \(1:1.*2:3"):
            _run(tmp_path, monkeypatch, layout_guide="ui-kit", aspect_ratio=ratio)
    fake, _ = _run(tmp_path, monkeypatch, layout_guide="ui-kit")
    assert fake.attached[0].size == (1024, 1024)


def test_ui_kit_guide_at_2_3_is_the_whole_kit(tmp_path, monkeypatch):
    from sprite_gen.frames import ui_kit

    fake, report = _run(tmp_path, monkeypatch, layout_guide="ui-kit", aspect_ratio="2:3")

    guide = fake.attached[0].convert("RGB")
    assert guide.size == (683, 1024)
    boxes = ui_kit.boxes((683, 1024))
    assert list(boxes) == [slot.name for slot in ui_kit.LAYOUT]
    for name, (x, y, w, h) in boxes.items():
        # a box's top edge, or a round part's circle, passes the top centre of its place
        assert ui_kit.GUIDE_BOX in [guide.getpixel((x + w // 2, y + i)) for i in range(3)], name
        assert guide.getpixel((x + w // 2, y + h // 2)) == ui_kit.GUIDE_BACKGROUND
    request = fake.requests[0]
    assert request.aspect_ratio == "2:3"
    assert request.prompt.endswith(ui_kit.guide_text((683, 1024)))
    assert ui_kit.guide_text((683, 1024)) != ui_kit.guide_text()
    cell = report["extra"]["layout_guide"]
    assert cell["kind"] == "ui-kit" and (cell["width"], cell["height"]) == (683, 1024)
    assert cell["boxes"]["joystick_knob"] == dict(zip("xywh", boxes["joystick_knob"]))
    assert cell["boxes"]["panel"] == {"x": 32, "y": 32, "w": 384, "h": 267}


def test_the_flag_alone_is_still_the_figure_guide():
    parser = gen._build_parser()
    assert parser.parse_args(["--out", "x.png", "--layout-guide"]).layout_guide == "figure"
    assert parser.parse_args(["--out", "x.png", "--layout-guide", "ui-kit"]).layout_guide == "ui-kit"
    assert parser.parse_args(["--out", "x.png"]).layout_guide is None
