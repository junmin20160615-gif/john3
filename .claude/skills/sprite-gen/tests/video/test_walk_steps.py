# SPDX-License-Identifier: Apache-2.0
"""A walk is cut two steps long — the left foot forward once and the right once — wherever the clip shows its steps
(docs/loop-repair.md section 3, "The step count"; sprite_gen/video/crossings.py, local_cycle.by_steps).

Each walker is drawn so the pixel search alone makes one of the faults a walk loop is cut with:

- a diagonal walk with its legs drawn alike and a tail on its own beat, cut one step long (a half step loop:
  one foot goes forward);
- a walk slower than the search's window, cut one step long;
- a front walk with a big tail on its own beat, cut three steps long by the gait fallback (the wrap puts the
  nearer foot back: a stomp in place);
- a slow front walk in a short clip, refused outright (no periodic cycle found);
- a walk that stalls, its cut playing the stalled step.

And two the count alone gets wrong, where the search's cut stands: a held walk seen from behind whose far foot
passes hidden (one crossing a cycle, the cycle counted one step), and a walk on threes whose tail closes on no cut
of two steps.

A walk the search already cuts two steps long, joined at the walk's own point, is cut exactly as before; a body
whose feet cannot be read is cut as before. Synthetic frames only."""

from __future__ import annotations

import json
import math
import shutil
from pathlib import Path

import numpy as np
import pytest
from PIL import Image, ImageDraw

from conftest import feet_unseen
from sprite_gen.video import align, crossings, local_cycle, loop

FRAMES = 73


def _side(k: float, *, cycle: float, phase: float = 0, tail_cycle: float = 1, tail: int = 0, arms: bool = True) -> Image.Image:
    """A side or diagonal walker: legs drawn alike, half a cycle apart and seen apart for most of a step; arms opposite,
    the far one darker (`arms`); a tail swinging up and down behind on its own beat (`tail_cycle`, `tail` px long)."""
    ph = 2 * math.pi * (k + phase) / cycle
    im = Image.new("RGBA", (300, 220))
    d = ImageDraw.Draw(im)
    x, y = 90, 40 + round(3 * math.cos(2 * ph))
    sw = 16 * math.sin(ph)
    if arms:
        d.rectangle((x + 14 - sw - 4, y + 34, x + 14 - sw + 4, y + 72), fill=(150, 150, 150, 255))
    for sign in (1, -1):
        lx = x + 14 + 14 * sign * math.sin(ph)
        d.rectangle((lx - 5, y + 80, lx + 5, y + 126), fill=(60, 60, 70, 255))
    if tail:
        a = 0.8 * math.sin(2 * math.pi * k / tail_cycle)
        d.line((x, y + 50, x - tail * math.cos(a), y + 50 - tail * math.sin(a)), fill=(180, 120, 40, 255), width=12)
    d.rectangle((x, y + 30, x + 28, y + 84), fill=(200, 80, 80, 255))
    d.rectangle((x + 2, y, x + 26, y + 28), fill=(230, 200, 170, 255))
    if arms:
        d.rectangle((x + 14 + sw - 4, y + 34, x + 14 + sw + 4, y + 72), fill=(225, 225, 225, 255))
    d.point((x + 6, y + 40 + int(k) % 11), fill=(250, 250, 250, 255))  # no two frames the same picture
    return im


def _front(k: float, *, cycle: float, phase: float = 0, tail_cycle: float = 1, tail: int = 0) -> Image.Image:
    """A walker seen from the front: legs side by side and touching (never seen apart), the nearer foot drawn lower
    each step; arms swinging opposite; a tail swinging sideways at the hips on its own beat."""
    ph = 2 * math.pi * (k + phase) / cycle
    im = Image.new("RGBA", (260, 220))
    d = ImageDraw.Draw(im)
    cx, y = 130, 40 + round(2 * math.cos(2 * ph))
    drop = round(6 * math.sin(ph))
    if tail:
        a = math.sin(2 * math.pi * k / tail_cycle)
        d.line((cx, y + 72, cx + tail * a, y + 90), fill=(180, 120, 40, 255), width=14)
    d.rectangle((cx - 12, y + 80, cx - 1, y + 120 + drop), fill=(60, 60, 70, 255))
    d.rectangle((cx, y + 80, cx + 11, y + 120 - drop), fill=(60, 60, 70, 255))
    d.rectangle((cx - 16, y + 30, cx + 16, y + 84), fill=(200, 80, 80, 255))
    d.rectangle((cx - 12, y, cx + 12, y + 28), fill=(230, 200, 170, 255))
    sw = round(8 * math.sin(ph))
    d.rectangle((cx - 22, y + 34 + sw, cx - 16, y + 70 + sw), fill=(225, 225, 225, 255))
    d.rectangle((cx + 16, y + 34 - sw, cx + 22, y + 70 - sw), fill=(225, 225, 225, 255))
    d.point((cx - 6, y + 40 + int(k) % 11), fill=(250, 250, 250, 255))
    return im


def _behind(k: int, *, cycle: int, hold: int) -> Image.Image:
    """A walker seen from behind on a diagonal, drawn on twos or threes (`hold`): the near leg swings ahead and back,
    and the far one is seen beside it only while it is behind — ahead, it stands hidden behind the near leg. The feet
    are seen apart once a cycle and together through the other step, its pass hidden among them: one crossing shows a
    cycle. Arms opposite, the far one darker; each repeat of a drawing redrawn a little (a pixel aside, a few tones)."""
    redraw = k % hold
    ph = 2 * math.pi * (k - redraw) / cycle
    im = Image.new("RGBA", (300, 220))
    d = ImageDraw.Draw(im)
    x, y = 90 + redraw, 40 + round(3 * math.cos(2 * ph))
    sw = 16 * math.sin(ph)
    near = x + 14 + sw
    far = x + 14 - sw if sw > 0 else near
    d.rectangle((x + 14 - sw - 4, y + 34, x + 14 - sw + 4, y + 72), fill=(150, 150, 150, 255))
    d.rectangle((far - 5, y + 80, far + 5, y + 126), fill=(50, 50, 60, 255))
    d.rectangle((near - 5, y + 80, near + 5, y + 126), fill=(70, 70, 80, 255))
    d.rectangle((x, y + 30, x + 28, y + 84), fill=(200 + 12 * redraw, 80, 80, 255))
    d.rectangle((x + 2, y, x + 26, y + 28), fill=(230, 200, 170, 255))
    d.rectangle((x + 14 + sw - 4, y + 34, x + 14 + sw + 4, y + 72), fill=(225, 225, 225, 255))
    return im


def _alike(k: float, *, cycle: float, phase: float = 0, tone: int = 1, lean: float = 0) -> Image.Image:
    """A side walker whose two steps are the same silhouette: the far leg and arm `tone` tones lighter than the near
    ones, the arms swinging `lean` px further back than forward — nothing else tells a step from the next."""
    ph = 2 * math.pi * (k + phase) / cycle
    im = Image.new("RGBA", (300, 220))
    d = ImageDraw.Draw(im)
    x, y = 90, 40 + round(3 * math.cos(2 * ph))
    for sign, t in ((1, 0), (-1, tone)):
        sw = sign * (16 * math.sin(ph) + lean)
        d.rectangle((x + 14 - sw - 4, y + 34, x + 14 - sw + 4, y + 72), fill=(190 + t, 190 + t, 190 + t, 255))
    for sign, t in ((1, 0), (-1, tone)):
        lx = x + 14 + 14 * sign * math.sin(ph)
        d.rectangle((lx - 5, y + 80, lx + 5, y + 126), fill=(60 + t, 60 + t, 70 + t, 255))
    d.rectangle((x, y + 30, x + 28, y + 84), fill=(200, 80, 80, 255))
    d.rectangle((x + 2, y, x + 26, y + 28), fill=(230, 200, 170, 255))
    return im


def _tailed(k: int) -> Image.Image:
    """A side walker on threes, 30 frames a cycle, its legs hurrying through each pass and slowing apart, with a big
    tail swinging on a beat of its own (34 frames); each repeat of a drawing redrawn a few tones."""
    redraw = k % 3
    t = k - redraw
    u = 2 * math.pi * t / 30
    ph = u - 0.25 * math.sin(u)
    im = Image.new("RGBA", (300, 220))
    d = ImageDraw.Draw(im)
    x, y = 90, 40 + round(3 * math.cos(2 * ph))
    sw = 16 * math.sin(ph)
    d.rectangle((x + 14 - sw - 4, y + 34, x + 14 - sw + 4, y + 72), fill=(150, 150, 150, 255))
    for sign in (1, -1):
        lx = x + 14 + 14 * sign * math.sin(ph)
        d.rectangle((lx - 5, y + 80, lx + 5, y + 126), fill=(60, 60, 70, 255))
    a = 0.8 * math.sin(2 * math.pi * t / 34)
    d.line((x, y + 50, x - 70 * math.cos(a), y + 50 - 70 * math.sin(a)), fill=(180, 120, 40, 255), width=12)
    d.rectangle((x, y + 30, x + 28, y + 84), fill=(200 + 3 * redraw, 80, 80, 255))
    d.rectangle((x + 2, y, x + 26, y + 28), fill=(230, 200, 170, 255))
    d.rectangle((x + 14 + sw - 4, y + 34, x + 14 + sw + 4, y + 72), fill=(225, 225, 225, 255))
    return im


def _blob(k: int) -> Image.Image:
    """A legless body bouncing every 16 frames: one foot band, nothing to step."""
    im = Image.new("RGBA", (200, 200))
    h = 60 + round(8 * math.cos(2 * math.pi * k / 16))
    ImageDraw.Draw(im).ellipse((70, 170 - h, 130, 170), fill=(90, 160, 220, 255))
    ImageDraw.Draw(im).point((90, 150 - k % 9), fill=(250, 250, 250, 255))
    return im


def _keyed(root: Path, draw, frames: int = FRAMES, hold: tuple[int, int] | None = None) -> Path:
    """The walker's frames; `hold` (from, frames) holds the walk still that long at `from`."""
    keyed = root / "keyed"
    keyed.mkdir(parents=True)
    for k in range(frames):
        t = k if hold is None or k < hold[0] else hold[0] if k < hold[0] + hold[1] else k - hold[1]
        draw(t).save(keyed / f"{k:03}.png")
    return keyed


def _cut(out: Path, keyed: Path, *extra: str) -> dict:
    assert loop.main(["--frames-dir", str(keyed), "--out-dir", str(out), "--state", "walk",
                      "--anchor", "motion-auto", "--repair", "off", *extra]) == 0
    return json.loads((out / "loop.loop.report.json").read_text())


def _two_steps(report: dict, cycle: float) -> dict:
    """The cut covers two steps by the clip's crossings — one cycle of the walker, `cycle` frames — and says so."""
    c = report["cycle"]
    counted = c["step_count"]
    assert counted["readable"] and counted["chosen_by"] == "two steps" and c["method"] == "observed-two-steps-v1"
    assert counted["cut"]["verdict"] == "two" and counted["cut"]["k"] == [2] and counted["cut"]["ring"] == 2
    assert abs(counted["cut"]["phase"]) <= crossings.PHASE_TOLERANCE
    assert abs(c["length"] - cycle) <= 1.5
    assert c["steps"] == {"count": 2, "by": "crossings"}
    assert report["status"] == "passed"
    return counted


def test_a_half_step_diagonal_walk_is_cut_two_steps(tmp_path):
    """Legs drawn alike, 14.5 frames a step, a tail on a 45-frame beat: one step on, the legs are swapped and the
    tail is nearer where it was than a cycle on, so the search takes 14 frames — one foot goes forward. The
    crossings count it one step; the cut is two."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _side(k, cycle=29, tail_cycle=45, tail=60, arms=False)))
    counted = _two_steps(report, 29)
    assert counted["mode"] == "gap" and counted["step_range"][1] == 14.5
    assert counted["search"]["verdict"] == "refuted" and counted["search"]["k"] == [1] and counted["search"]["cut"][1] in (14, 15)
    # Its feet pass briefly: no pass can hide, and the count is not asked whether the clip a cut on is the same picture.
    assert "same_picture" not in counted["search"]
    strip = json.loads((tmp_path / "out" / "loop.strip.json").read_text())
    assert strip["steps"] == 2 and strip["cycle_frames"] == report["cycle"]["length"]
    # The step screen's pixel suspicion of a cycle twice as long is settled by the count.
    screen = report["cycle"]["step_screen"]
    assert screen["suspect"] is False and (screen.get("settled_by") == "crossings" or "pixel_suspect" not in screen)


def test_a_walk_slower_than_the_window_is_cut_two_steps(tmp_path):
    """A 46-frame cycle (1.92 s) in a 73-frame clip: past the window's 36, so the search cut a 23-frame step. Two
    steps are 46 frames, and the clip holds 0.59 of a cycle past them."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _side(k, cycle=46, phase=13)))
    counted = _two_steps(report, 46)
    assert report["window"][1] < report["cycle"]["length"]
    assert counted["search"]["k"] == [1]
    assert report["cycle"]["coverage"] == round((FRAMES - report["cycle"]["length"]) / report["cycle"]["length"], 4) > loop.COVERAGE_MIN


def test_a_tail_on_its_own_beat_no_longer_cuts_three_steps(tmp_path):
    """A front walk, 13.5 frames a step, its big tail on a 41-frame beat: the search refuses the walk's 27 frames
    (repeat error over two steps), and the gait fallback takes the tail's 41 — three steps, the wrap putting the
    nearer foot back: a stomp in place. The crossings count three and cut two."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _front(k, cycle=27, phase=5, tail_cycle=41, tail=70)))
    counted = _two_steps(report, 27)
    assert counted["mode"] == "sign" and counted["alternation"] <= crossings.ALTERNATION_MAX
    assert "gait_fallback" in report and counted["search"]["k"] == [3] and counted["search"]["cut"][1] in (40, 41, 42)


def test_a_slow_walk_in_a_short_clip_the_search_refuses_is_cut_two_steps(tmp_path):
    """A 34-frame front walk with a tail on a 52-frame beat: no window repeats within two steps of its own, so the
    search and the gait fallback find no cycle. The crossings show two."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _front(k, cycle=34, phase=5, tail_cycle=52, tail=70)))
    counted = _two_steps(report, 34)
    assert counted["search"]["refused"].startswith("no periodic cycle found")


def test_a_walk_that_stalls_is_not_cut_across_the_stalled_step(tmp_path):
    """A side walk held still 20 frames: the step the hold is in is far longer than the walk's own, and no frame of
    it is played (the search's cut played its last frames, and its seam did not close)."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _side(k, cycle=29, phase=3), frames=96, hold=(30, 20)))
    counted = _two_steps(report, 29)
    c = [x if isinstance(x, (int, float)) else x[1] for x in counted["crossings"]]
    hi = counted["step_range"][2]
    stalled = [(a, b) for a, b in zip(c, c[1:]) if b - a > hi]
    assert stalled == [(26.0, 60.5)]
    s, L = report["cycle"]["start"], report["cycle"]["length"]
    assert s + L - 1 < 26 or s > 60.5
    assert counted["search"]["code"] == "step-long"


@pytest.mark.parametrize("cycle, hold", [(20, 2), (24, 3)])
def test_a_held_walk_whose_far_foot_hides_is_cut_one_cycle(tmp_path, cycle, hold):
    """Seen from behind on a diagonal, on twos or threes, the far foot passes hidden behind the near one: one crossing
    shows a cycle, and the count takes the cycle for one step. The search's cut is the clip's cycle, the same picture a
    cut on, which the count calls one step; a step on the legs are swapped, and a swap nearer than the next frame is
    none — the count missed a crossing. The search's cut stands, one cycle, and no `steps` is written (the parent
    engine cut it two cycles long, `steps: 2`, the set alignment's two-cycle screen settled by it)."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _behind(k, cycle=cycle, hold=hold)))
    c = report["cycle"]
    counted = c["step_count"]
    assert c["length"] == cycle and "steps" not in c
    assert "steps" not in json.loads((tmp_path / "out" / "loop.strip.json").read_text())
    assert report["drawings"]["hold"] == hold and report["status"] == "passed"
    assert counted["mode"] == "gap" and abs(counted["step_range"][1] - cycle) <= 1
    assert counted["search"]["verdict"] == "refuted" and counted["search"]["k"] == [1]
    assert counted["search"]["same_picture"]["over_step"] <= local_cycle.SAME_PICTURE_MAX
    assert counted["chosen_by"] == "search" and counted["cut"]["verdict"] == "uncertain" and counted["cut"]["code"] == "same-picture"
    assert c["method"] == "local-repeat-drift-v1"


@pytest.mark.parametrize("tone, lean", [(1, 0), (4, 1)])
def test_a_side_walk_whose_two_steps_look_alike_is_cut_two_steps_however_near_a_step_on(tmp_path, tone, lean):
    """The case the count was made for, guarded: from the side the two steps are one silhouette, the near leg and arm
    a tone or a few apart from the far ones. The walk is slower than the window, so the search cuts one step, and at
    one tone the clip a step on draws nearer than the next frame (0.89 playback steps). Its feet pass briefly — no pass
    can hide — so the count stands: two steps, a cycle long (as the parent engine cut it; asking the picture alone kept
    the half step)."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _alike(k, cycle=46, phase=13, tone=tone, lean=lean)))
    counted = _two_steps(report, 46)
    assert counted["search"]["verdict"] == "refuted" and counted["search"]["k"] == [1]
    assert "same_picture" not in counted["search"]


def test_a_cut_of_two_steps_that_does_not_close_leaves_the_searchs_cut(tmp_path):
    """On threes, a big tail on its own beat: the search's cut is one the count does not refute (it plays feet held
    together past a pass: uncertain), and every cut of two steps leaves the tail open at the wrap, out of phase, its
    seam over the gate. The search's cut stands and the loop passes; the record and a warning line name the two-step
    cut declined (the parent engine took it, and the seam gate failed the loop)."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, _tailed))
    c = report["cycle"]
    counted = c["step_count"]
    assert report["status"] == "passed" and report["drawings"]["hold"] == 3
    assert counted["chosen_by"] == "search" and counted["search"]["verdict"] == "uncertain"
    assert [c["start"], c["length"]] == counted["search"]["cut"] and "steps" not in c
    assert counted["declined"]["gated"] is False and counted["declined"]["seam"] > report["seam_max"]
    assert all(t["seam"] > report["seam_max"] for t in counted["seam_gate"]["tried"])
    assert any("the search's cut" in w and "stands" in w for w in report["jolt"]["warnings"])


def _same_cut(a: Path, b: Path) -> None:
    for name in ("loop.strip.png", "loop.gif", "loop.webp"):
        assert (a / name).read_bytes() == (b / name).read_bytes(), name
    frames = sorted(p.name for p in (a / "cycle").glob("*.png"))
    assert frames and frames == sorted(p.name for p in (b / "cycle").glob("*.png"))
    assert all((a / "cycle" / f).read_bytes() == (b / "cycle" / f).read_bytes() for f in frames)


def test_a_walk_the_search_cuts_two_steps_in_phase_is_cut_as_before(tmp_path):
    """The same front walk with a small tail: the search cuts its 27 frames, two steps joined at the walk's own point,
    and the cut is kept — every image as the search alone cut it; the strip says `steps: 2`."""
    keyed = _keyed(tmp_path, lambda k: _front(k, cycle=27, phase=5, tail_cycle=41, tail=40))
    report = _cut(tmp_path / "read", keyed)
    counted = report["cycle"]["step_count"]
    assert counted["chosen_by"] == "search" and counted["cut"]["verdict"] == "two"
    assert report["cycle"]["method"] == "local-repeat-drift-v1" and report["cycle"]["steps"] == {"count": 2, "by": "crossings"}
    with feet_unseen():
        plain = _cut(tmp_path / "unread", keyed)
    assert (plain["cycle"]["start"], plain["cycle"]["length"]) == (report["cycle"]["start"], report["cycle"]["length"])
    _same_cut(tmp_path / "read", tmp_path / "unread")
    strips = [json.loads((tmp_path / d / "loop.strip.json").read_text()) for d in ("read", "unread")]
    assert strips[0].pop("steps") == 2 and "steps" not in strips[1] and strips[0] == strips[1]


def test_a_body_with_no_feet_to_read_is_cut_as_the_search_cuts_it(tmp_path):
    keyed = _keyed(tmp_path, _blob, frames=64)
    report = _cut(tmp_path / "out", keyed)
    counted = report["cycle"]["step_count"]
    assert counted["readable"] is False and counted["chosen_by"] == "search" and counted["why"]
    assert counted["search"]["cut"] == [report["cycle"]["start"], report["cycle"]["length"]]
    assert "steps" not in report["cycle"] and "steps" not in json.loads((tmp_path / "out" / "loop.strip.json").read_text())


def test_a_count_given_is_the_word_on_the_searchs_cut(tmp_path):
    """--steps counts the cut the search takes: the crossings are not asked."""
    report = _cut(tmp_path / "out", _keyed(tmp_path, lambda k: _side(k, cycle=46, phase=13)), "--steps", "2")
    assert "step_count" not in report["cycle"] and report["cycle"]["steps"]["by"] == "given"
    assert report["cycle"]["length"] in (22, 23, 24)  # the search's one step, kept on the count


def test_cycle_align_takes_a_loop_cut_two_steps_as_one_cycle(tmp_path):
    """The half-step walk cut two steps long returns half way at its second step; its loop says `steps: 2`, so the
    alignment reads that return as its step, and the set aligns."""
    _cut(tmp_path / "a", _keyed(tmp_path / "ka", lambda k: _side(k, cycle=29, tail_cycle=45, tail=60, arms=False)))
    _cut(tmp_path / "b", _keyed(tmp_path / "kb", lambda k: _side(k, cycle=46, phase=13)))
    dirs = []
    for name in ("a", "b"):
        shutil.copytree(tmp_path / name, tmp_path / "set" / name)
        dirs.append(tmp_path / "set" / name)
    out = align.align_set(dirs, between="nearest")
    assert out["applied"] is True
    assert all(entry["status"] == "steps" for entry in out["suspects"])


def _distances(period: int = 13, frames: int = 120) -> np.ndarray:
    t = np.arange(frames)
    angle = t * 2 * np.pi / period
    points = np.column_stack([np.cos(angle), np.sin(angle)])
    return np.abs(points[:, None] - points[None, :]).mean(axis=2).astype(np.float32)


@pytest.mark.parametrize("uncertain_from", [None, 5])
def test_the_search_refuses_what_the_crossings_refute_and_names_their_count(uncertain_from):
    """`detect` with `judge`: a window the crossings count other than two is refused, and a search that finds nothing
    lists each refused window's count, those the crossings refute after the rest."""
    def judge(s, L):
        if uncertain_from is not None and s >= uncertain_from:
            return {"verdict": "uncertain", "code": "partial", "k": [], "why": "plays frames no crossing confirms"}
        return {"verdict": "refuted", "code": "refuted", "k": [1], "why": "one step, each seen"}

    D = _distances()
    if uncertain_from is not None:
        found = local_cycle.detect(D, np.zeros(len(D)), min_len=12, max_len=14, gait_floor=8, periodicity_min=loop.PERIODICITY_MIN,
                                   double_tolerance=loop.GAIT_DOUBLE_TOL, double_search=loop.GAIT_DOUBLE_SEARCH, judge=judge)
        assert found["start"] >= uncertain_from
        return
    with pytest.raises(ValueError, match="no periodic cycle found") as refused:
        local_cycle.detect(D, np.zeros(len(D)), min_len=12, max_len=14, gait_floor=8, periodicity_min=loop.PERIODICITY_MIN,
                           double_tolerance=loop.GAIT_DOUBLE_TOL, double_search=loop.GAIT_DOUBLE_SEARCH, judge=judge)
    shown = refused.value.diagnostics["candidates"]
    assert shown and all(row["step_count"]["verdict"] == "refuted" for row in shown)
    assert any("one step, each seen in the clip's crossings" == row["refused"] for row in shown)
    assert "refute after the rest" in refused.value.diagnostics["order"]


def _choose(found: dict, *, period: int, seam: float, run: int = 9, search_seam: float = 1.0) -> tuple[dict, dict]:
    """`by_steps` on a clip whose picture goes round every `period` frames, its feet passing every 15 (crossings at 8,
    23 … 68), seen together `run` frames at each pass (9: over half a step, a pass can hide there; 3: brief), with the
    search's cut `found`: every two-step cut's seam reads `seam` at the gate, its top calm and its flow off 1.0 either
    side, and the search's own cut `search_seam`."""
    D = _distances(period=period, frames=FRAMES)
    middles = (8, 23, 38, 53, 68)
    reading = crossings.Reading(FRAMES, "gap", [(float(c), float(c)) for c in middles],
                                runs=[(c - run // 2, c + run // 2) for c in middles])
    return local_cycle.by_steps(
        D, np.zeros(FRAMES), reading, found=dict(found), refused=None, min_len=12, max_len=FRAMES,
        seam_flow=lambda s, L: {"off": [1.0, 1.0], "turn": [0.0, 0.0], "window": [[0, 0, 1, 1], [0, 0, 1, 1]]},
        wrap_pop=lambda s, L: {"pops": False, "pop": 0.1},
        seam_gate=lambda s, L: search_seam if (s, L) == (found["start"], found["length"]) else seam, flow_limit=3.0, seam_max=2.0,
        gait_floor=12, periodicity_min=loop.PERIODICITY_MIN, signals=None)


@pytest.mark.parametrize("seam, search_seam, kept", [(3.0, 1.0, True), (1.0, 1.0, False), (3.0, 3.0, False)])
def test_a_cut_the_count_does_not_refute_gives_way_only_to_a_two_step_cut_that_closes(seam, search_seam, kept):
    """The search's cut 10/33 covers two steps a fifth of a step off (out of phase, not refuted), and the seam gate
    passes it. A two-step cut in phase replaces it only where the seam gate passes that too; where none passes, the
    search's cut stands and the record names the two-step cut it declined, with a warning line (the parent engine took
    the two-step cut either way). A search's cut the gate refuses as well gives way: the two-step cut's wrap may yet be
    closed by the overlapped wrap."""
    picked, record = _choose({"start": 10, "length": 33}, period=30, seam=seam, search_seam=search_seam)
    assert record["search"]["verdict"] == "two" and abs(record["search"]["phase"]) > crossings.PHASE_TOLERANCE
    if kept:
        assert (picked["start"], picked["length"]) == (10, 33) and record["chosen_by"] == "search"
        assert record["declined"]["seam"] == seam and record["declined"]["gated"] is True
        assert picked["steps"] == {"count": 2, "by": "crossings"}
        warned = local_cycle.step_verdict({**picked, "step_count": record})
        assert len(warned) == 1 and "the search's cut 10/33 stands" in warned[0]
    else:
        assert record["chosen_by"] == "two steps" and "declined" not in record and picked["length"] != 33


def test_a_cut_the_count_refutes_gives_way_to_two_steps_closing_or_not():
    """A search's cut the count refutes, one step seen, is a fault of its own: the two-step cut is taken though its seam
    fails the gate, and the gate says whether the loop passes."""
    picked, record = _choose({"start": 10, "length": 15}, period=30, seam=3.0)
    assert record["search"]["verdict"] == "refuted" and record["search"]["k"] == [1]
    assert record["search"]["same_picture"]["over_step"] > local_cycle.SAME_PICTURE_MAX
    assert record["chosen_by"] == "two steps" and picked["steps"] == {"count": 2, "by": "crossings"}


def test_a_one_step_cut_that_is_the_same_picture_a_cut_on_is_the_searchs_cycle():
    """The same count — one step — on a clip whose picture goes round every 15 frames: the frame a cut on is the
    frame itself, so no legs were swapped and the count missed a crossing. The search's cut stands, no steps written."""
    picked, record = _choose({"start": 10, "length": 15}, period=15, seam=1.0)
    assert (picked["start"], picked["length"]) == (10, 15) and "steps" not in picked
    assert record["chosen_by"] == "search" and record["cut"]["code"] == "same-picture" and record["cut"]["verdict"] == "uncertain"
    assert record["search"]["same_picture"]["over_step"] <= local_cycle.SAME_PICTURE_MAX
    assert record["search"]["same_picture"]["overlap"] > crossings.HIDE_SHARE


def test_where_the_feet_pass_briefly_the_count_stands_however_alike_a_step_on():
    """The same clip, its feet seen together only at the moment they pass: no pass can hide, and a step on drawing as
    near as the next frame is what legs drawn alike do from the side. The count stands: two steps."""
    picked, record = _choose({"start": 10, "length": 15}, period=15, seam=1.0, run=3)
    assert record["search"]["verdict"] == "refuted" and "same_picture" not in record["search"]
    assert record["chosen_by"] == "two steps" and picked["steps"] == {"count": 2, "by": "crossings"}
