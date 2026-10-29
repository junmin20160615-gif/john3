# SPDX-License-Identifier: Apache-2.0
"""EBU R128 normalization and unspliced browser audio encodes."""
from __future__ import annotations

import hashlib
import json
import math
from pathlib import Path
import re
import shutil
import subprocess

from sprite_gen._deps import np

from sprite_gen.audio import playback

RATE = 48000
PROCESSING_VERSION = 4
PCM_PEAK_DBTP = -2.0   # the normalizer's limiter ceiling
FILE_PEAK_DBTP = -1.0  # no encoded file may decode above this true peak
SETTLED = .2           # normalization stops this close (LU) to the target with its peak this close (dB) to the ceiling
TOLERANCE_LU = 1.0     # an encoded file's loudness may sit this far from its goal
BLOCK, HOP = RATE*2//5, RATE//10  # ITU-R BS.1770-4 gating blocks: 400 ms long, one every 100 ms
# ITU-R BS.1770-4 K-weighting at 48 kHz (the high shelf, then the RLB high-pass), filtered in double precision.
K_WEIGHTING = ('aformat=sample_fmts=dblp,'
               'biquad=b0=1.53512485958697:b1=-2.69169618940638:b2=1.19839281085285:'
               'a0=1:a1=-1.69065929318241:a2=0.73248077421585,'
               'biquad=b0=1:b1=-2:b2=1:a0=1:a1=-1.99004745483398:a2=0.99007225036621,'
               'aformat=sample_fmts=flt')


def require_programs():
    for name in ('ffmpeg', 'ffprobe'):
        if not shutil.which(name):
            raise ValueError(f'{name} is required on PATH for sound processing')


def require_tools():
    require_programs()
    encoders = _ffmpeg(['-encoders']).stdout.decode(errors='replace')
    for codec in ('libopus', 'aac'):
        if not re.search(r'(?m)^\s*A\S*\s+'+codec+r'\s', encoders):
            raise ValueError(f'ffmpeg requires the {codec} encoder before a paid sound request')


def _ffmpeg(args, data=None):
    result = subprocess.run(['ffmpeg', '-hide_banner', '-nostdin', '-y', *args],
                            input=data, capture_output=True, timeout=180)
    if result.returncode:
        # Source metadata can contain untrusted prose. Keep diagnostics local and bounded.
        raise ValueError('ffmpeg audio processing failed; check input audio and codec availability')
    return result


def decode(path):
    result = _ffmpeg(['-v', 'error', '-i', str(path), '-map', '0:a:0', '-ac', '2', '-ar', str(RATE),
                      '-f', 'f32le', 'pipe:1'])
    samples = np.frombuffer(result.stdout, dtype='<f4').reshape(-1, 2).copy()
    if not len(samples) or not np.isfinite(samples).all():
        raise ValueError('source has no finite audio samples')
    return samples


def _pcm_args():
    return ['-f', 'f32le', '-ar', str(RATE), '-ac', '2', '-i', 'pipe:0']


def _check_m4a_duration(path, frames):
    result = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'a:0',
                             '-show_entries', 'stream=duration_ts,time_base', '-of', 'json', str(path)],
                            capture_output=True, timeout=180)
    try:
        stream, = json.loads(result.stdout)['streams']
    except (ValueError, KeyError, TypeError):
        stream = None
    if (result.returncode or not isinstance(stream, dict) or
            (stream.get('time_base'), stream.get('duration_ts')) != (f'1/{RATE}', frames)):
        raise ValueError(f'm4a container duration must match the declared {frames} frames at {RATE} Hz')


def _loudnorm(samples, target):
    """loudnorm's own first-pass analysis, the parameters of its second pass."""
    result = _ffmpeg([*_pcm_args(), '-af', f'loudnorm=I={target}:TP={PCM_PEAK_DBTP:g}:LRA=11:print_format=json',
                     '-f', 'null', '-'], samples.astype('<f4').tobytes())
    matches = re.findall(r'\{\s*"input_i".*?\}', result.stderr.decode(errors='replace'), re.S)
    if not matches:
        raise ValueError('ffmpeg did not report loudness')
    values = json.loads(matches[-1])
    return {k: float(v) for k, v in values.items() if k != 'normalization_type'}


def _block_power(samples):
    """K-weighted mean square of every complete gating block, summed over both channels."""
    result = _ffmpeg([*_pcm_args(), '-af', K_WEIGHTING, '-f', 'f32le', 'pipe:1'], samples.astype('<f4').tobytes())
    weighted = np.frombuffer(result.stdout, dtype='<f4').reshape(-1, 2)
    hops = np.array([np.square(weighted[i:i+HOP], dtype=np.float64).sum()
                     for i in range(0, len(weighted) - HOP + 1, HOP)])
    # Four 100 ms hops make one 400 ms block; a clip shorter than one block has none.
    return (hops[:-3] + hops[1:-2] + hops[2:-1] + hops[3:]) / BLOCK


def _true_peak(samples):
    """Sample peak (dBTP) after 4x oversampling to 192 kHz, as loudnorm reports true peak."""
    result = _ffmpeg([*_pcm_args(), '-af', 'aresample=192000,astats=measure_perchannel=none:measure_overall=Peak_level',
                      '-f', 'null', '-'], samples.astype('<f4').tobytes())
    peaks = re.findall(r'Peak level dB:\s*(\S+)', result.stderr.decode(errors='replace'))
    if not peaks:
        raise ValueError('ffmpeg did not report a true peak')
    return float(peaks[-1])


def measure(samples, gate=None):
    """ITU-R BS.1770-4 integrated loudness (LUFS) and true peak (dBTP) of 48 kHz stereo PCM.

    `gate` is the block selection of the PCM a file was encoded from. The file is then measured
    over the same frames and the same blocks as its PCM: a short clip has two or three blocks,
    and a codec that moves one of them a tenth of a dB across the relative gate would otherwise
    move the file's loudness by whole LU."""
    power = _block_power(samples)
    if gate is None:
        gate = power > 10 ** ((-70 + .691) / 10)  # absolute gate, -70 LUFS
        if gate.any():
            gate &= power > power[gate].mean() / 10  # relative gate, 10 LU under the absolute-gated loudness
    elif len(gate) != len(power):
        raise ValueError('an encoded file must be measured over the frames of its PCM')
    mean = power[gate].mean() if gate.any() else 0.
    return {'lufs': -.691 + 10 * math.log10(mean) if mean > 0 else -math.inf,
            'true_peak': _true_peak(samples), 'gate': gate}


def file_frames(path, frames, loop):
    """The decoded length of an encoded file, and the frames its loudness is measured over: its
    playback frames, three times over for a loop."""
    if frames['sample_rate'] != RATE:
        raise ValueError(f'sound files are measured at {RATE} Hz frames')
    if path.suffix == '.m4a':
        _check_m4a_duration(path, frames['end_frame']-frames['start_frame'])
    decoded = decode(path)
    if len(decoded) < frames['end_frame']:
        raise ValueError(f'{path.suffix[1:]} truncated the audio')
    interval = decoded[frames['start_frame']:frames['end_frame']]  # AAC may retain a final partial codec frame.
    return len(decoded), np.tile(interval, (3, 1)) if loop else interval


def measure_version_3(samples, target):
    """Loudness and true peak as processing version 3 measured its files: loudnorm's first pass.

    A version 3 bundle keeps no PCM, so its files have no PCM gate to be measured over, and a
    block at the relative gate can move this engine's measure across the tolerance where
    loudnorm's accepted the file (docs/sound.md)."""
    values = _loudnorm(samples, target)
    return {'lufs': values['input_i'], 'true_peak': values['input_tp']}


def loudness_goal(target, pcm_lufs, pcm_peak):
    """The integrated loudness every encoded file of a sound must reach, within TOLERANCE_LU.

    Normalization gains a sound toward the target until its true peak meets the PCM ceiling. A
    sound it leaves short of the target with its peak at that ceiling (a click, a short hit)
    cannot get louder without the limiter rewriting its transient, so its files must match the
    loudness its PCM reached. Every other sound must reach the target."""
    if pcm_lufs < target - SETTLED and pcm_peak >= PCM_PEAK_DBTP - SETTLED:
        return pcm_lufs
    return target


def meets(lufs, peak, goal):
    """The one loudness check of an encoded file."""
    return math.isfinite(lufs) and abs(lufs - goal) <= TOLERANCE_LU and peak <= FILE_PEAK_DBTP


def limit_gain(samples, gain, ceiling, loop):
    context = np.tile(samples, (3, 1)) if loop else samples
    limit = 10 ** (ceiling / 20)
    filt = (f'aresample=192000,volume={gain}dB,'
            f'alimiter=limit={limit}:level=false:latency=true:attack=1:release=20')
    result = _ffmpeg([*_pcm_args(), '-af', filt, '-ar', str(RATE), '-f', 'f32le', 'pipe:1'],
                     context.astype('<f4').tobytes())
    pcm = np.frombuffer(result.stdout, dtype='<f4').reshape(-1, 2).copy()
    return pcm[len(samples):2*len(samples)] if loop else pcm[:len(samples)]


def normalize(samples, target, loop):
    """The PCM to encode, its manifest `normalization` record, and its measure."""
    # Repeated context avoids loudnorm's startup/lookahead envelope at the loop boundary.
    source = np.tile(samples, (3, 1)) if loop else samples
    if not math.isfinite(measure(source)['lufs']):
        raise ValueError('silent or unmeasurable audio cannot be loudness normalized')
    measured, output, method = _loudnorm(source, target), samples, 'limiter'
    # loudnorm's first pass over some short clips measures its own output at -inf LUFS, so it
    # has no second-pass offset; such a clip starts the limiter passes below as decoded.
    if all(math.isfinite(measured[k]) for k in ('input_i', 'input_tp', 'input_thresh', 'target_offset')):
        filt = (f'loudnorm=I={target}:TP={PCM_PEAK_DBTP:g}:LRA=11:measured_I={measured["input_i"]}:'
                f'measured_TP={measured["input_tp"]}:measured_LRA={measured["input_lra"]}:'
                f'measured_thresh={measured["input_thresh"]}:offset={measured["target_offset"]}:linear=true')
        result = _ffmpeg([*_pcm_args(), '-af', filt, '-ar', str(RATE), '-f', 'f32le', 'pipe:1'],
                         source.astype('<f4').tobytes())
        output = np.frombuffer(result.stdout, dtype='<f4').reshape(-1, 2).copy()
        output = output[len(samples):2*len(samples)] if loop else output[:len(samples)]
        method = 'loudnorm-two-pass'
    corrections = 0
    # A short transient can make loudnorm stop at the peak ceiling below the LUFS target.
    # Measure the actual playback, then apply gain with an oversampled lookahead limiter.
    # These are local DSP passes over the paid source, never provider retries.
    while True:
        stats = measure(np.tile(output, (3, 1)) if loop else output)
        if corrections == 3 or (abs(stats['lufs'] - target) <= SETTLED and
                                stats['true_peak'] <= PCM_PEAK_DBTP + SETTLED):
            break
        output = limit_gain(output, target - stats['lufs'], PCM_PEAK_DBTP, loop)
        corrections += 1
    return output, {'method': method, 'peak_limit_dbtp': PCM_PEAK_DBTP, 'gain_limiter_passes': corrections,
                    'pcm_lufs': stats['lufs'], 'pcm_true_peak_dbtp': stats['true_peak']}, stats


def export(source: Path, out_dir: Path, *, target_lufs, loop, crossfade):
    samples = decode(source)
    frames = playback.validate({'version': playback.VERSION, 'sample_rate': RATE,
                                'start_frame': 0, 'end_frame': len(samples),
                                'overlap_frames': round(crossfade*RATE) if loop else 0}, loop)
    samples, normalization, pcm = normalize(samples, target_lufs, loop)
    goal = loudness_goal(target_lufs, pcm['lufs'], pcm['true_peak'])
    files = {}
    # The twoloop AAC coder rebuilds a limited transient up to several dB over its PCM true peak;
    # FFmpeg documents the fast coder as the better one above 64 kbps (docs/sound.md).
    for fmt, codec in (('ogg', ['-c:a', 'libopus', '-b:a', '160k']),
                       ('m4a', ['-c:a', 'aac', '-aac_coder', 'fast', '-b:a', '192k', '-movflags', '+faststart',
                                '-movie_timescale', str(RATE)])):
        path = out_dir / f'sound.{fmt}'
        encoded_samples, ceiling = samples, PCM_PEAK_DBTP
        for attempt in range(3):
            _ffmpeg([*_pcm_args(), '-map_metadata', '-1', *codec, str(path)], encoded_samples.astype('<f4').tobytes())
            length, played = file_frames(path, frames, loop)
            measured = measure(played, pcm['gate'])
            lufs, peak = measured['lufs'], measured['true_peak']
            if meets(lufs, peak, goal):
                break
            if not math.isfinite(lufs) or attempt == 2:
                raise ValueError(f'{fmt} failed loudness/peak check ({lufs:g} LUFS, {peak:g} dBTP; needs {goal:g} '
                                 f'+/-{TOLERANCE_LU:g} LUFS at <= {FILE_PEAK_DBTP:g} dBTP); cached source retained')
            # Lossy codec reconstruction can overshoot PCM peaks. Tighten the PCM limiter
            # by the measured overshoot plus headroom, then encode and measure again.
            ceiling -= max(0, peak + 1.5) if peak > FILE_PEAK_DBTP else 0
            encoded_samples = limit_gain(encoded_samples, goal - lufs, ceiling, loop)
        files[fmt] = {'path': path.name, 'duration_seconds': length/RATE,
                      'lufs': lufs, 'true_peak_dbfs': peak, 'encode_passes': attempt + 1,
                      'pcm_peak_limit_dbtp': ceiling,
                      'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
    return {'files': files, 'duration_seconds': playback.duration(frames), 'playback': frames,
            'normalization': normalization}
