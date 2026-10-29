# SPDX-License-Identifier: Apache-2.0
"""RIFE in-betweens for RGBA sprite frames, through the external `rife-ncnn-vulkan` binary.

Where it runs, what it costs and why this build: docs/loop-repair.md section 1. RIFE reads
three colour channels and no alpha, so a frame is interpolated as two images — its colour and
its coverage as a grey image — and put back together. The two are two runs of the flow, and
where legs cross they do not agree: the coverage says body where the colour run still carries
what lay around the body. So around the body the colour image holds the body's own colour,
pushed out from inside its outline (`bleed`): a disagreement there reads as the body, not as the
black a frame premultiplied over black put under it (2.24 and before: a black smear between
crossing legs). Inside the coverage the colour is the frame's own, outline included.
`smear` measures what a made frame has that neither neighbour has, and the outline it lost where
the flow failed and melted a limb into the fill; `outline_shift` reads that edge against the
neighbours' rank by rank, so a mid-tone line the flow only softened is not read as lost — where the
neighbours are outlined (`outlined`), and not on art painted without a line; `ghost` reads a band of
part coverage on a frame alone, filmed or made; `crossfade` reads two drawings cross-faded inside a
whole silhouette, a reading to look at, not a fault (docs/loop-repair.md section 4). `passes` runs
the sixteen single passes the binary's augmentation combines inside one call, one at a time, and
`torn` reads where they disagree: a small part RIFE drags apart beside a large one moving far.

The binary's own CPU path (`-g -1`) returns a wrong frame with rife-v4.6 on both macOS and
Linux (measured 2026-10-03: mean error 39 against 3.3 through Vulkan), so it is never passed;
a machine without a GPU runs the Vulkan path on Mesa's llvmpipe, which gives the GPU's frame.
Every call asks for the binary's test-time augmentation, spatial and temporal (`-x -z`, `TTA`;
docs/loop-repair.md section 1, "Which setting"); SPRITE_GEN_RIFE_TTA names another (`tta()`).

The binary is found by SPRITE_GEN_RIFE, then on PATH, then where `sprite-gen rife install`
puts it (`install_root()`, docs/loop-repair.md section 1). A RIFE that cannot be found is
`RifeNotInstalled`, which a caller may answer by cutting the loop as filmed with a warning; a
RIFE that is found and then fails is `RifeUnavailable` and always an error.

The interpolator is a plain callable `(a, b, t) -> frame`, so a caller can be handed a stand-in
(`Interpolate`), and a test needs no binary. A caller that reads the passes takes a callable
`(a, b, t) -> (frame, disagreement)` (`Read`, `Rife.read`).

A frame made between two frames can be kept and taken again (`Cache`): an alignment run twice on
the same source frames — again with the feet told — makes the same frames a second time, two RIFE
calls each (section 1 of docs/loop-repair.md has their cost; section 4 the cache). It is kept under
everything it is made from, the interpolator's `identity()` included — read again for every frame,
as the files a RIFE runs from can be written over under it — so it is taken only where making it
again would give the same bytes.
"""

from __future__ import annotations

import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Callable

import PIL
from PIL import Image, ImageFilter, PngImagePlugin

from sprite_gen._deps import np

BINARY = "rife-ncnn-vulkan"
MODEL = "rife-v4.6"
RELEASE = "20221029"
# The binary's test-time augmentation, passed on every call: `-x` runs the pair as its eight flips and
# transposes, `-z` runs it both ways in time as well, and what comes back is averaged — so a frame made
# from a to b is the one made from b to a (docs/loop-repair.md section 1, "Which setting"). On a machine
# without a GPU it costs 15 to 19 times the CPU of a plain call. SPRITE_GEN_RIFE_TTA names another
# (`tta()`): either mode, or none.
TTA = ("-x", "-z")
TTA_MODES = ("-x", "-z")
# Coverage RIFE leaves under this is its own blur, not body: dropped so no halo is invented.
ALPHA_FLOOR = 2 / 255
# The colour pushed out around the body is read this far inside its solid edge (a fraction of the
# body's height, at least a pixel): past a drawn outline, so a disagreement reads as the body's
# fill, not its outline: 0.008 is 6 px on an 800 px body, past an outline a few pixels wide.
BLEED_DEPTH = 0.008
# `smear`: a pixel is dark under this luma (0..1), and part-covered between these alphas.
DARK_LUMA = 70 / 255
PARTIAL_ALPHA = (0.1, 0.9)
# `smear`'s outline: a pixel of the coverage's edge (alpha from PARTIAL_ALPHA's floor) is outlined
# when a dark solid pixel lies within this many pixels of it. A drawn outline sits on the edge, under
# an antialiased pixel or two, whatever the frame's size.
OUTLINE_REACH = 2
# `outline_shift`: a pixel of the made frame's edge is lost where its darkest solid pixel within OUTLINE_REACH is
# lighter than the lighter neighbour's at the same rank by more than this (luma, 0..1). A line the flow keeps
# and softens comes out lighter by less; a line gone to the fill beside it, by the line's own contrast.
OUTLINE_SHIFT = 50 / 255
# `outlined`: a frame's fill is read this far inside its solid edge (a share of the body's height, at least a
# pixel) and pushed out over the edge, as `bleed` pushes the colour from BLEED_DEPTH: twice as deep, so the fill
# read beside a line is past it where the line is twice as wide as the one `bleed` reads past.
LINE_DEPTH = 2 * BLEED_DEPTH
# `outline_shift` reads a pair only where both neighbours are outlined on at least this share of their coverage
# edge (`outlined`). Under it — art painted without a line, or lined in a tone near its fill — a line gone to fill
# is lighter by less than OUTLINE_SHIFT, or there is no line to lose, and the dark line judges alone: a frame
# refused there is replaced by a filmed one, a melted frame kept would be delivered (docs/loop-repair.md section 4).
OUTLINED = 0.75
# `ghost`: part-covered pixels count where they make a region at least this many pixels thick. An
# antialiased edge or a keyed strand of hair is a pixel or two wide and erodes away; the band a video
# model leaves between two drawings, or a flow carries from it, does not.
GHOST_THICK = 5
# `crossfade`: an edge's local range is read over this many pixels, wider than RIFE's blur, so a
# softened edge keeps its height and a cross-faded one does not; strong edges are counted in windows
# this share of the body's height; a window that kept under CROSSFADE_KEEP of its source frames'
# strong edges lost them.
CROSSFADE_RANGE = 7
CROSSFADE_WINDOW = 0.08
CROSSFADE_KEEP = 0.6
# `passes`: the binary's augmentation runs the pair turned eight ways (`-x`: every flip and transpose) and both ways in
# time (`-z`), combines the sixteen inside, and gives back one frame — where the passes disagree, the frame does not say
# so. Run one at a time with no augmentation, each turned back, they can be read apart. Each pass is two calls, colour
# and coverage, as `between` makes them.
PASS_GEOMETRIES = tuple((transpose, flips) for transpose in (False, True) for flips in range(4))  # flips: 1 left-right, 2 up-down
PASS_CALLS = 2 * 2 * len(PASS_GEOMETRIES)
# `torn`: the forward passes' mean and the backward passes' mean put a different colour or coverage at a pixel where
# they are more than this apart (premultiplied RGBA, 0..1); an edge they place a pixel or two apart is thinner than
# TORN_THICK pixels and opened away; a part torn is read in windows TORN_WINDOW of the body's height on a side, the
# size of a hand on a walk.
TORN_LEVEL = 0.05
TORN_THICK = 3
TORN_WINDOW = 0.10
# One call past this is stopped and reported as a RIFE that failed. TTA's slowest call measured, on a
# 960 x 960 frame on Modal's CPU, took about 30 s, and Modal's hosts differ by up to 2.5 times on one frame
# (2026-10-15, docs/loop-repair.md section 1).
CALL_TIMEOUT_SECONDS = 600
# `Cache`: the first thing a kept frame's key is made from — another way of keying or keeping frames is another
# name, so no frame kept the old way is taken — and the PNG text a kept frame names its own pixels' sha256 under.
CACHE_FORMAT = "sprite-gen frame between, 1"
PIXELS_TEXT = "sprite-gen-pixels-sha256"
# The engine code that makes a frame between, as this process loaded it (`Rife.identity`): read once, at import —
# rife.py written over on disk later changes no code that runs here, so a frame made here is kept under the code that
# made it, and a process that loads other code makes it again.
CODE_SHA256 = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()

Interpolate = Callable[[Image.Image, Image.Image, float], Image.Image]
Read = Callable[[Image.Image, Image.Image, float], tuple[Image.Image, np.ndarray]]

# The one line that installs it, quoted wherever a missing RIFE is reported.
INSTALL_COMMAND = "sprite-gen rife install"
INSTALL_HINT = (
    f"run `{INSTALL_COMMAND}` (rife-ncnn-vulkan {RELEASE} with the model {MODEL}, sha256-checked, into the "
    f"user data directory), or put {BINARY} on PATH or set SPRITE_GEN_RIFE to the binary — the model {MODEL}/ "
    f"ships beside it (SPRITE_GEN_RIFE_MODEL overrides); on Linux without a GPU also `libvulkan1 mesa-vulkan-drivers`; "
    f"see docs/loop-repair.md"
)


class RifeUnavailable(RuntimeError):
    """No usable RIFE: not installed, or found and failed. The message names what went wrong."""


class RifeNotInstalled(RifeUnavailable):
    """No RIFE binary or model where the engine looks. The message carries the install line."""


def platform_release() -> str:
    """The release zip's platform name for this machine (`macos`, `ubuntu`, `windows`), or '' when it ships none."""
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("linux"):
        return "ubuntu"
    if sys.platform == "win32":
        return "windows"
    return ""


def data_dir() -> Path:
    """sprite-gen's user data directory: SPRITE_GEN_DATA_DIR, else %LOCALAPPDATA%\\sprite-gen on
    Windows, else $XDG_DATA_HOME/sprite-gen or ~/.local/share/sprite-gen."""
    named = os.environ.get("SPRITE_GEN_DATA_DIR")
    if named:
        return Path(named).expanduser()
    if sys.platform == "win32" and os.environ.get("LOCALAPPDATA"):
        return Path(os.environ["LOCALAPPDATA"]) / "sprite-gen"
    return Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share").expanduser() / "sprite-gen"


def install_root() -> Path:
    """Where `sprite-gen rife install` puts RIFE by default, and the last place `locate()` looks."""
    return data_dir() / "rife"


def installed_binary(root: Path | None = None, platform: str | None = None) -> Path:
    """The binary inside an install root: `<root>/rife-ncnn-vulkan-<release>-<platform>/rife-ncnn-vulkan[.exe]`."""
    platform = platform or platform_release()
    return (root or install_root()) / f"{BINARY}-{RELEASE}-{platform}" / (BINARY + (".exe" if platform == "windows" else ""))


def locate() -> tuple[Path, Path]:
    """(binary, model directory): the binary from SPRITE_GEN_RIFE, else PATH, else `install_root()`;
    the model from SPRITE_GEN_RIFE_MODEL, else beside the binary."""
    named = os.environ.get("SPRITE_GEN_RIFE")
    installed = installed_binary() if platform_release() else None
    found = named or shutil.which(BINARY) or (str(installed) if installed and installed.is_file() else None)
    if not found:
        raise RifeNotInstalled(f"{BINARY} not found (SPRITE_GEN_RIFE is not set, it is not on PATH, and "
                               f"{installed or install_root()} does not exist); {INSTALL_HINT}")
    binary = Path(found).expanduser()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise RifeNotInstalled(f"{binary} is not an executable file; {INSTALL_HINT}")
    binary = binary.resolve()
    model = Path(os.environ.get("SPRITE_GEN_RIFE_MODEL") or binary.parent / MODEL).expanduser()
    if not (model / "flownet.param").is_file() or not (model / "flownet.bin").is_file():
        raise RifeNotInstalled(f"RIFE model {model} has no flownet.param / flownet.bin; {INSTALL_HINT}")
    return binary, model


def tta() -> tuple[str, ...]:
    """The test-time augmentation every call asks for: SPRITE_GEN_RIFE_TTA when it is set (`-x`, `-z`
    or both, space-separated; empty for none), else TTA. Anything else is refused: a flag passed
    through unread could be the binary's CPU path, which is wrong with this model."""
    named = os.environ.get("SPRITE_GEN_RIFE_TTA")
    if named is None:
        return TTA
    modes = tuple(named.split())
    if any(m not in TTA_MODES for m in modes) or len(set(modes)) < len(modes):
        raise RifeUnavailable(f"SPRITE_GEN_RIFE_TTA={named!r}: name -x, -z or both, space-separated, or leave it empty for none")
    return modes


def _call(binary: Path, model: Path, a: Image.Image, b: Image.Image, t: float, tmp: Path,
          modes: tuple[str, ...] | None = None) -> Image.Image:
    """One run of the binary from `a` to `b` at `t`, with the augmentation `tta()` names, or `modes` (`passes`: none)."""
    modes = tta() if modes is None else modes
    a.save(tmp / "a.png")
    b.save(tmp / "b.png")
    out = tmp / "o.png"
    out.unlink(missing_ok=True)
    try:
        proc = subprocess.run(
            [str(binary), "-0", str(tmp / "a.png"), "-1", str(tmp / "b.png"), "-o", str(out), "-s", f"{t:.4f}", "-m", str(model), *modes],
            capture_output=True, text=True, timeout=CALL_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        raise RifeUnavailable(f"{binary.name} made no frame in {CALL_TIMEOUT_SECONDS} s and was stopped "
                              f"(augmentation {' '.join(modes) or 'none'}, SPRITE_GEN_RIFE_TTA)") from exc
    except OSError as exc:
        # A binary that is found but cannot be started (a damaged or wrong-platform build:
        # WinError 193 on Windows, ENOEXEC elsewhere) is a RIFE that fails, not a crash.
        raise RifeUnavailable(f"{binary.name} could not be started: {exc}") from exc
    if proc.returncode != 0 or not out.is_file():
        raise RifeUnavailable(f"{binary.name} failed (exit {proc.returncode}): {(proc.stderr or proc.stdout).strip()[-300:]}")
    with Image.open(out) as im:
        return im.convert("RGB")


def _push_pull(rgb: np.ndarray, known: np.ndarray) -> np.ndarray:
    """`rgb` with every pixel where `known` is 0 filled by the weighted colour around it, coarse to
    fine (each level averages 2x2 blocks of the known colour; an unknown pixel takes its block's)."""
    if known.min() > 0 or min(known.shape) <= 1:
        return rgb
    h, w = known.shape
    pad = ((0, h % 2), (0, w % 2))
    weighted, weight = np.pad(rgb * known[..., None], pad + ((0, 0),)), np.pad(known, pad)
    wsum, csum = (x[0::2, 0::2] + x[1::2, 0::2] + x[0::2, 1::2] + x[1::2, 1::2] for x in (weight, weighted))
    coarse = _push_pull(np.where(wsum[..., None] > 0, csum / np.maximum(wsum[..., None], 1e-9), 0.0), np.minimum(wsum, 1.0))
    up = coarse.repeat(2, axis=0).repeat(2, axis=1)[:h, :w]
    return np.where(known[..., None] > 0, rgb, up)


def _core_fill(frame: np.ndarray, depth: float) -> np.ndarray | None:
    """The colour of an RGBA frame (0..1) from `depth` (a share of its solid body's height, at least a pixel)
    inside its solid edge, pushed out over every pixel outside that core; None where nothing is solid."""
    solid = frame[..., 3] >= 0.5
    rows = np.nonzero(solid.any(axis=1))[0]
    if rows.size == 0:
        return None
    px = max(1, round((rows[-1] - rows[0] + 1) * depth))
    core = _square_min(solid, px, mode="edge")  # PIL's MinFilter, which repeats the edge pixels outward
    if not core.any():  # a body thinner than its outline: read at its edge
        core = solid
    return _push_pull(frame[..., :3], core.astype(np.float32))


def bleed(frame: np.ndarray) -> np.ndarray:
    """The colour image of an RGBA frame (0..1) RIFE is given: the frame's own colour wherever it
    has coverage, and around it the colour from BLEED_DEPTH inside its solid edge, pushed out."""
    fill = _core_fill(frame, BLEED_DEPTH)
    return np.where(frame[..., 3:] > 0, frame[..., :3], 0.0 if fill is None else fill)


def between(a: Image.Image, b: Image.Image, t: float, *, binary: Path, model: Path, tmp: Path) -> Image.Image:
    """The RGBA frame at fraction `t` (0..1) of the way from `a` to `b`."""
    if a.size != b.size:
        raise ValueError(f"rife: frames differ in size ({a.size} vs {b.size})")
    fa, fb = (np.asarray(f.convert("RGBA"), dtype=np.float32) / 255.0 for f in (a, b))
    colour = [Image.fromarray(np.uint8(np.clip(bleed(x), 0, 1) * 255 + 0.5), "RGB") for x in (fa, fb)]
    cov = [Image.fromarray(np.uint8(x[..., 3] * 255 + 0.5), "L").convert("RGB") for x in (fa, fb)]
    rgb = np.asarray(_call(binary, model, colour[0], colour[1], t, tmp), dtype=np.float32) / 255.0
    alpha = np.asarray(_call(binary, model, cov[0], cov[1], t, tmp).convert("L"), dtype=np.float32) / 255.0
    return _joined(rgb, alpha)


def _joined(rgb: np.ndarray, alpha: np.ndarray) -> Image.Image:
    """The RGBA frame of a colour run and a coverage run (0..1): coverage under ALPHA_FLOOR dropped, the colour kept
    wherever there is coverage."""
    alpha = np.where(alpha < ALPHA_FLOOR, 0.0, alpha)
    out = np.dstack([np.where(alpha[..., None] > 0, rgb, 0.0), alpha])
    return Image.fromarray(np.uint8(np.clip(out, 0, 1) * 255 + 0.5), "RGBA")


def _turned(x: np.ndarray, geometry: tuple[bool, int]) -> np.ndarray:
    """An image (H x W x C) turned one of PASS_GEOMETRIES' ways: transposed, then flipped."""
    transpose, flips = geometry
    if transpose:
        x = x.transpose(1, 0, 2)
    if flips & 1:
        x = x[:, ::-1]
    if flips & 2:
        x = x[::-1]
    return np.ascontiguousarray(x)


def _turned_back(x: np.ndarray, geometry: tuple[bool, int]) -> np.ndarray:
    """`_turned` undone."""
    transpose, flips = geometry
    if flips & 2:
        x = x[::-1]
    if flips & 1:
        x = x[:, ::-1]
    if transpose:
        x = x.transpose(1, 0, 2)
    return np.ascontiguousarray(x)


def passes(a: Image.Image, b: Image.Image, t: float, *, binary: Path, model: Path, tmp: Path) -> np.ndarray:
    """How far the binary's sixteen single passes from `a` to `b` at fraction `t` disagree, per pixel (docs/loop-repair.md
    section 4).

    Each pass is the pair turned one of PASS_GEOMETRIES' ways and run with no augmentation — from `a` to `b` at `t`, and
    from `b` to `a` at 1 - t — colour and coverage as `between` runs them, and turned back. The disagreement is how far
    apart the mean of the eight forward passes and the mean of the eight backward ones put the premultiplied colour and
    coverage (0..1, `torn` reads it). Their mean is not the frame: where they disagree it blends their guesses part-covered,
    which the augmentation, combining them inside the binary, does not. PASS_CALLS calls of the binary."""
    if a.size != b.size:
        raise ValueError(f"rife: frames differ in size ({a.size} vs {b.size})")
    fa, fb = (np.asarray(f.convert("RGBA"), dtype=np.float32) / 255.0 for f in (a, b))
    colour = [np.uint8(np.clip(bleed(x), 0, 1) * 255 + 0.5) for x in (fa, fb)]
    cover = [np.repeat(np.uint8(x[..., 3:] * 255 + 0.5), 3, axis=-1) for x in (fa, fb)]
    rgbs, alphas = [], []
    for geometry in PASS_GEOMETRIES:
        for first, second, at in ((0, 1, t), (1, 0, 1 - t)):
            runs = [_call(binary, model, Image.fromarray(_turned(pair[first], geometry), "RGB"),
                          Image.fromarray(_turned(pair[second], geometry), "RGB"), at, tmp, ()) for pair in (colour, cover)]
            rgbs.append(_turned_back(np.asarray(runs[0], dtype=np.float32) / 255.0, geometry))
            alphas.append(_turned_back(np.asarray(runs[1].convert("L"), dtype=np.float32)[..., None] / 255.0, geometry)[..., 0])
    rgb, alpha = np.stack(rgbs), np.stack(alphas)
    pre = np.concatenate([rgb * alpha[..., None], alpha[..., None]], axis=-1)
    apart = np.sqrt(((pre[0::2].mean(axis=0) - pre[1::2].mean(axis=0)) ** 2).sum(axis=-1) / 4.0)
    return apart.astype(np.float32)


def _mask(mask: np.ndarray, size: int, op: type) -> np.ndarray:
    return np.asarray(Image.fromarray(np.uint8(mask) * 255).filter(op(size))) > 0


def _square_min(a: np.ndarray, r: int, **pad) -> np.ndarray:
    """Per pixel, the minimum over the square 2r+1 wide around it, one axis at a time, outside the frame as
    `np.pad` fills it with `pad`."""
    out = np.pad(a, r, **pad)
    for axis in (0, 1):
        out = np.lib.stride_tricks.sliding_window_view(out, 2 * r + 1, axis=axis).min(axis=-1)
    return out


def _luma(x: np.ndarray) -> np.ndarray:
    return x[..., 0] * 0.299 + x[..., 1] * 0.587 + x[..., 2] * 0.114


def _smear_counts(frame: Image.Image) -> tuple[int, int, int, int, int]:
    """(dark pixels inside the solid body, one pixel in from its edge; solid pixels; part-covered
    pixels; pixels on the coverage's edge; those of them with no outline within OUTLINE_REACH)."""
    x = np.asarray(frame.convert("RGBA"), dtype=np.float32) / 255.0
    solid = x[..., 3] >= 0.5
    inner = _mask(solid, 3, ImageFilter.MinFilter)
    luma = _luma(x)
    lo, hi = PARTIAL_ALPHA
    covered = x[..., 3] >= lo
    edge = covered & ~_mask(covered, 3, ImageFilter.MinFilter)
    outlined = _mask(solid & (luma < DARK_LUMA), 2 * OUTLINE_REACH + 1, ImageFilter.MaxFilter)
    return (int((inner & (luma < DARK_LUMA)).sum()), int(solid.sum()), int(((x[..., 3] > lo) & (x[..., 3] < hi)).sum()),
            int(edge.sum()), int((edge & ~outlined).sum()))


def smear(made: Image.Image, a: Image.Image, b: Image.Image) -> dict[str, float]:
    """What a made frame has that neither of its two neighbours has: `dark_excess`, dark pixels
    inside the body beyond the darker neighbour's count (a black smear raises it; a moved dark
    part — a hat, a watch — keeps its count), and `partial_excess`, part-covered pixels beyond the
    more ragged neighbour's, both as fractions of its solid pixels; and `outline_loss`, the edge of
    its coverage that has no outline beyond the less outlined neighbour's, as a fraction of its edge
    (where legs crossing too far for the flow melt into one shape of fill, or a limb is left a pale
    ghost, the outline is gone; a frame drawn without outlines loses none against neighbours that
    have none). Zero or less: nothing added, no outline lost."""
    dm, sm, pm, em, um = _smear_counts(made)
    (da, _, pa, _, ua), (db, _, pb, _, ub) = _smear_counts(a), _smear_counts(b)
    solid = max(1, sm)
    return {"dark_excess": round((dm - max(da, db)) / solid, 5), "partial_excess": round((pm - max(pa, pb)) / solid, 5),
            "outline_loss": round((um - max(ua, ub)) / max(1, em), 5)}


def _edge_line(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """The coverage edge of an RGBA frame (0..1; alpha from PARTIAL_ALPHA's floor, as `smear` reads it) and, per
    pixel, its line: the luma of the darkest solid pixel within OUTLINE_REACH, 1 where there is none."""
    covered = x[..., 3] >= PARTIAL_ALPHA[0]
    edge = covered & ~_mask(covered, 3, ImageFilter.MinFilter)
    return edge, _square_min(np.where(x[..., 3] >= 0.5, _luma(x), 1.0), OUTLINE_REACH, constant_values=1.0)


def _edge_darkness(frame: Image.Image) -> np.ndarray:
    """Per pixel of the coverage edge, its line (`_edge_line`)."""
    edge, line = _edge_line(np.asarray(frame.convert("RGBA"), dtype=np.float32) / 255.0)
    return line[edge]


def outlined(frame: Image.Image) -> float:
    """The share of a frame's coverage edge outlined against its fill: where its line, the darkest solid pixel
    within OUTLINE_REACH, is darker than the colour from LINE_DEPTH inside, pushed out over the edge, by more than
    OUTLINE_SHIFT — so a line there gone to that fill reads lost rank by rank (`outline_shift`). Art outlined all
    round reads most of its edge; art painted without a line, whose edge is its fill, or lined in a tone near
    it, little. 0 where it has no edge (docs/loop-repair.md section 4)."""
    x = np.asarray(frame.convert("RGBA"), dtype=np.float32) / 255.0
    edge, line = _edge_line(x)
    fill = _core_fill(x, LINE_DEPTH)
    if fill is None or not edge.any():
        return 0.0
    return round(float(np.mean((_luma(fill) - line)[edge] > OUTLINE_SHIFT)), 5)


def outline_shift(made: Image.Image, a: Image.Image, b: Image.Image) -> float | None:
    """The edge of a made frame that lost its line, read against its two neighbours rank by rank: each pixel
    of its coverage edge by how dark the darkest solid pixel within OUTLINE_REACH is, in order, against the
    lighter of the two neighbours' edges at the same rank (their quantiles), and counted where it is lighter
    by more than OUTLINE_SHIFT — as a fraction of its edge. A line drawn in a mid tone and softened by the
    flow reads lighter by less at every rank and is not counted, whatever tone the art outlines in; a line
    gone to the fill beside it (legs melted into one shape, a pale ghost limb) is. 0 where nothing is lighter.
    None where either neighbour is outlined on less than OUTLINED of its edge (`outlined`): there a part can
    melt with no line to lose, lighter by less at every rank, and the dark line (`smear`'s `outline_loss`)
    judges alone (docs/loop-repair.md section 4)."""
    if min(outlined(a), outlined(b)) < OUTLINED:
        return None
    dm, da, db = (_edge_darkness(f) for f in (made, a, b))
    if not (dm.size and da.size and db.size):
        return 0.0
    rank = (np.arange(dm.size) + 0.5) / dm.size
    lighter = np.maximum(np.quantile(da, rank), np.quantile(db, rank))
    return round(float(np.mean(np.sort(dm) > lighter + OUTLINE_SHIFT)), 5)


def ghost(frame: Image.Image) -> float:
    """Part-covered pixels (PARTIAL_ALPHA) inside regions at least GHOST_THICK pixels thick, as a
    fraction of the frame's solid pixels: a ghost band, read on the frame's own coverage and not
    against its neighbours, so a band a filmed frame carries reads the same in a frame made beside
    it (docs/loop-repair.md section 4)."""
    alpha = np.asarray(frame.convert("RGBA").getchannel("A"), dtype=np.float32) / 255.0
    lo, hi = PARTIAL_ALPHA
    thick = _mask((alpha > lo) & (alpha < hi), GHOST_THICK, ImageFilter.MinFilter)
    return round(float(thick.sum()) / max(1, int((alpha >= 0.5).sum())), 5)


def _local_range(x: np.ndarray) -> np.ndarray:
    """Per pixel, the largest over the channels of max - min within CROSSFADE_RANGE pixels."""
    out = np.zeros(x.shape[:2], dtype=np.float32)
    for c in range(x.shape[2]):
        channel = Image.fromarray(np.uint8(np.clip(x[..., c], 0, 1) * 255 + 0.5), "L")
        hi = np.asarray(channel.filter(ImageFilter.MaxFilter(CROSSFADE_RANGE)), dtype=np.float32)
        lo = np.asarray(channel.filter(ImageFilter.MinFilter(CROSSFADE_RANGE)), dtype=np.float32)
        out = np.maximum(out, (hi - lo) / 255.0)
    return out


def crossfade(made: Image.Image, a: Image.Image, b: Image.Image, t: float) -> float:
    """A cross-fade of two drawings inside the silhouette, the coverage whole: the near and far boots
    of `a` and `b` both shown at part strength where a flow found nothing to follow. Read where two
    things meet in one window of the frame where `a` and `b` differ: pixels of the made frame's solid
    body at the plain blend of `a` and `b` at its own fraction `t` and well away from each (in patches
    GHOST_THICK pixels thick, past an edge's soft rim), and the made frame keeping under CROSSFADE_KEEP
    of the source frames' strong edges there — a blend shows each edge at part height, a flow that
    moved the part shows it whole, only softer. The strong-edge pixels lost in such windows, as a
    fraction of the made frame's solid pixels — the windows step by half their size, so one lost pixel
    is counted in up to four of them (nine where the window is an odd number of pixels wide); 0 where
    it shows no blend. Relative to the source frames' own edges, so a palette's lightness does not
    decide it (docs/loop-repair.md section 4)."""
    m, fa, fb = (np.asarray(f.convert("RGBA"), dtype=np.float32) / 255.0 for f in (made, a, b))
    pm, pa, pb = (np.dstack([x[..., :3] * x[..., 3:], x[..., 3:]]) for x in (m, fa, fb))

    def dist(x: np.ndarray, y: np.ndarray) -> np.ndarray:  # premultiplied RGBA, 0..1
        return np.sqrt(((x - y) ** 2).sum(-1) / 4.0)

    d = dist(pa, pb)
    solid = m[..., 3] >= 0.5
    blend = (solid & (d > 0.15) & (dist(pm, (1 - t) * pa + t * pb) < 0.35 * d)
             & (dist(pm, pa) > 0.25 * d) & (dist(pm, pb) > 0.25 * d))
    blend &= _mask(_mask(blend, GHOST_THICK, ImageFilter.MinFilter), GHOST_THICK, ImageFilter.MaxFilter)
    if not blend.any():
        return 0.0
    rows = np.nonzero((np.maximum.reduce([fa[..., 3], fb[..., 3], m[..., 3]]) >= 0.5).any(axis=1))[0]
    w = max(16, round(CROSSFADE_WINDOW * (rows[-1] - rows[0] + 1)))
    changed = _mask(d > 0.08, CROSSFADE_RANGE, ImageFilter.MaxFilter)
    ys, xs = np.nonzero(blend)
    y0, y1, x0, x1 = max(0, ys.min() - w), ys.max() + w, max(0, xs.min() - w), xs.max() + w
    rm, ra, rb = (np.zeros(d.shape, np.float32) for _ in range(3))
    for into, x in ((rm, pm), (ra, pa), (rb, pb)):
        into[y0:y1, x0:x1] = _local_range(x[y0:y1, x0:x1])
    lost, step = 0.0, w // 2
    for y in range((y0 // step) * step, y1, step):
        for x in range((x0 // step) * step, x1, step):
            win = (slice(y, y + w), slice(x, x + w))
            near = changed[win]
            if blend[win].sum() < 0.01 * w * w or near.sum() < 0.1 * w * w:
                continue
            strong = max(np.percentile(ra[win][near], 95), np.percentile(rb[win][near], 95))
            if strong < 0.15:  # no edge to keep here
                continue
            ka, kb, km = (int((r[win][near] > 0.5 * strong).sum()) for r in (ra, rb, rm))
            kept = (ka + kb) / 2
            if kept >= 0.02 * w * w and km < CROSSFADE_KEEP * kept:
                lost += kept - km
    return round(lost / max(1, int(solid.sum())), 5)


def torn(apart: np.ndarray, made: Image.Image) -> float:
    """A part torn in a made frame, read on how far its single passes disagree (`passes`): of the pixels where they are
    more than TORN_LEVEL apart, those in regions at least TORN_THICK pixels thick, and of them the largest share of a
    window TORN_WINDOW of the made frame's body height on a side (8 px at least; the windows step by a quarter of it). A
    hand the flow drags apart beside a tail swung far fills its window; an edge the passes place a pixel apart, or hair
    they redraw strand by strand, leaves it nearly empty. Read in a window, not over the body, so a small part torn on a
    large body is not lost in it. 0 where the frame has no solid body (docs/loop-repair.md section 4)."""
    alpha = np.asarray(made.convert("RGBA").getchannel("A"), dtype=np.float32) / 255.0
    rows = np.nonzero((alpha >= 0.5).any(axis=1))[0]
    if rows.size == 0:
        return 0.0
    side = max(8, int(round((rows[-1] - rows[0] + 1) * TORN_WINDOW)))
    thick = _mask(_mask(apart > TORN_LEVEL, TORN_THICK, ImageFilter.MinFilter), TORN_THICK, ImageFilter.MaxFilter)
    h, w = thick.shape
    if side >= min(h, w):
        return round(float(thick.sum()) / (side * side), 5)
    sums = np.pad(thick.astype(np.float64).cumsum(axis=0).cumsum(axis=1), ((1, 0), (1, 0)))
    step = max(1, side // 4)
    ys, xs = np.arange(0, h - side + 1, step)[:, None], np.arange(0, w - side + 1, step)[None, :]
    covered = sums[ys + side, xs + side] - sums[ys, xs + side] - sums[ys + side, xs] + sums[ys, xs]
    return round(float(covered.max()) / (side * side), 5)


def _file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


class Rife:
    """A located RIFE as an `Interpolate` callable, and as a `Read` (`read`). Counts the frames it made (`made`) and the
    times it ran the binary (`calls`)."""

    def __init__(self, binary: Path | None = None, model: Path | None = None):
        if binary is None or model is None:
            binary, model = locate()
        self.binary, self.model = binary, model
        self.tta = tta()  # refused here, before a frame is asked for
        self.made = 0
        self.calls = 0

    def __call__(self, a: Image.Image, b: Image.Image, t: float) -> Image.Image:
        with tempfile.TemporaryDirectory(prefix="sprite-gen-rife-") as td:
            frame = between(a, b, t, binary=self.binary, model=self.model, tmp=Path(td))
        self.made += 1
        self.calls += 2
        return frame

    def read(self, a: Image.Image, b: Image.Image, t: float) -> tuple[Image.Image, np.ndarray]:
        """The frame at `t`, made as every call makes it (`between`), and how far the sixteen single passes disagree
        there (`passes`): 2 + PASS_CALLS calls of the binary."""
        with tempfile.TemporaryDirectory(prefix="sprite-gen-rife-") as td:
            frame = between(a, b, t, binary=self.binary, model=self.model, tmp=Path(td))
            apart = passes(a, b, t, binary=self.binary, model=self.model, tmp=Path(td))
        self.made += 1
        self.calls += 2 + PASS_CALLS
        return frame, apart

    def describe(self) -> dict[str, str]:
        return {"binary": str(self.binary), "model": self.model.name, "tta": " ".join(self.tta)}

    def identity(self) -> str:
        """What a frame this RIFE makes depends on besides its two frames and t, as one string (`Cache` keys
        on it), read as it is now on every call — nothing of it is kept, so a binary, model or machine changed
        under this very RIFE is another identity: the binary's and each of the model's files by sha256, and the
        model's path as the binary is handed it (the binary reads the model's version from its name); the
        augmentation every call asks for now (`tta()`: SPRITE_GEN_RIFE_TTA is read on every call, and another is
        another frame); the engine code this process loaded (`CODE_SHA256`: it turns a frame into RIFE's two runs and back) and NumPy's and
        Pillow's versions; and the machine — the OS, and `uname`'s host name, OS release and build and
        architecture (platform.uname() keeps its first answer) — as the Apple GPU and llvmpipe are only measured
        to agree to the third decimal of an error (docs/loop-repair.md section 1), so a frame made on one is not
        taken on another. Files that cannot be read are a RIFE that fails (`RifeUnavailable`)."""
        try:
            model = sorted(p for p in self.model.iterdir() if p.is_file())
            files = {"binary": _file_sha256(self.binary), "model": str(self.model), "model_files": {p.name: _file_sha256(p) for p in model}}
        except OSError as exc:
            raise RifeUnavailable(f"{self.binary.name}: the binary or model it runs from could not be read: {exc}") from exc
        return json.dumps({
            **files, "tta": list(tta()), "code": CODE_SHA256, "numpy": np.__version__, "pillow": PIL.__version__,
            "machine": [sys.platform, *(os.uname() if hasattr(os, "uname") else platform.uname()[:5])]}, sort_keys=True)


def _kept(path: Path, size: tuple[int, int]) -> Image.Image | None:
    """The frame kept at `path`, or None where it is not one: not a PNG, not RGBA at `size`, cut short, or
    its pixels not the ones its PIXELS_TEXT names."""
    try:
        with Image.open(path) as im:
            if im.format != "PNG" or im.mode != "RGBA" or im.size != size:
                return None
            im.load()
            data, named = im.tobytes(), im.info.get(PIXELS_TEXT)
    except (OSError, SyntaxError, ValueError, EOFError):
        return None
    if named != hashlib.sha256(data).hexdigest():
        return None
    return Image.frombytes("RGBA", size, data)


class Cache:
    """Frames made between two frames, kept in `directory` and taken from there when the same frame is
    asked for again (`video-cycle-align --between-cache`, docs/loop-repair.md section 4).

    A frame is kept under the sha256 of everything it is made from: CACHE_FORMAT, the interpolator's
    `identity()`, each of the two frames' mode, size and bytes, and `t` exactly. Another frame, fraction,
    RIFE or machine is another key, so a frame kept for other inputs is never taken. The key is read
    for every frame asked for, and once more after a frame is made: a frame made while what it is made
    from changed (a binary or model written over between RIFE's two runs) is handed on as made but not
    kept, as no key names what made it, counted `not_kept`. Frames are kept for RGBA frames only: their
    mode, size and bytes are all of them, where a palette or a transparent colour is not in an image's
    bytes. A kept frame is a PNG naming its own pixels' sha256, written whole or not at all; a file that
    does not read back as that frame (cut short, written over) is made again and kept over it, counted
    `unreadable`. A frame taken is a new image of the kept pixels, as the interpolator's own frame is.

    Nothing is kept unless a caller names the directory, and nothing here removes it: it belongs to the
    caller, who gives each alignment its own. It is created readable by this user only. Counts the frames
    taken (`hits`) and made (`misses`)."""

    def __init__(self, directory: Path):
        self.directory = Path(directory).expanduser().resolve()
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.hits = self.misses = self.unreadable = self.not_kept = 0

    def key(self, interpolate: Interpolate, a: Image.Image, b: Image.Image, t: float) -> str:
        for f in (a, b):
            if f.mode != "RGBA":
                raise ValueError(f"rife: a frame between is kept for RGBA frames only, not {f.mode}: a palette or a "
                                 "transparent colour is not in an image's bytes, which are what it is kept under")
        h = hashlib.sha256()
        for part in (CACHE_FORMAT, interpolate.identity(), a.mode, *map(str, a.size), b.mode, *map(str, b.size), float(t).hex()):  # type: ignore[attr-defined]
            h.update(part.encode() + b"\0")
        h.update(a.tobytes())
        h.update(b.tobytes())
        return h.hexdigest()

    def frame(self, interpolate: Interpolate, a: Image.Image, b: Image.Image, t: float) -> Image.Image:
        """The frame at `t` between `a` and `b`: the one kept for exactly these, else `interpolate`'s — kept where
        its key reads the same once it is made."""
        key = self.key(interpolate, a, b, t)
        path = self.directory / f"{key}.png"
        if path.exists():
            kept = _kept(path, a.size)
            if kept is not None:
                self.hits += 1
                return kept
            self.unreadable += 1
        made = interpolate(a, b, t)
        if made.mode != "RGBA" or made.size != a.size:
            raise ValueError(f"rife: a frame between is kept as RGBA at its frames' size {a.size}, not {made.mode} at {made.size}")
        self.misses += 1
        if self.key(interpolate, a, b, t) != key:
            self.not_kept += 1
            return made
        # saved from a copy of its pixels, so the frame handed on carries nothing of this save
        pixels = made.tobytes()
        info = PngImagePlugin.PngInfo()
        info.add_text(PIXELS_TEXT, hashlib.sha256(pixels).hexdigest())
        fd, staged = tempfile.mkstemp(prefix=".", suffix=".tmp", dir=self.directory)
        try:
            with os.fdopen(fd, "wb") as out:
                Image.frombytes("RGBA", made.size, pixels).save(out, format="PNG", pnginfo=info)
            os.replace(staged, path)
        except BaseException:
            Path(staged).unlink(missing_ok=True)
            raise
        return made

    def record(self) -> dict[str, object]:
        return {"dir": str(self.directory), "hits": self.hits, "misses": self.misses, "unreadable": self.unreadable,
                "not_kept": self.not_kept}
