// SPDX-License-Identifier: Apache-2.0
// Frame contract v2. Loop preparation runs after decoding, never on each repeat.
const prepared = new WeakMap();
const cached = new WeakMap();
const guarded = new WeakMap();

export function prepareAudioBuffer(decoded, playback) {
  const { version, sample_rate: rate, start_frame: start, end_frame: end,
    overlap_frames: overlap } = playback;
  if (version !== 2 || ![rate, start, end, overlap].every(Number.isSafeInteger) ||
      rate < 8000 || rate > 192000 || start < 0 || end <= start || end > 601 * rate ||
      overlap < 0 || (overlap !== 0 && (overlap < 2 || overlap * 2 >= end - start))) {
    throw new RangeError('Invalid audio playback frame contract');
  }
  const key = [version, rate, start, end, overlap].join(':');
  if (prepared.has(decoded)) {
    if (prepared.get(decoded) !== key) throw new RangeError('AudioBuffer is already prepared');
    return decoded;
  }
  if (cached.get(decoded)?.has(key)) return cached.get(decoded).get(key);
  const rescale = frames => frames * decoded.sampleRate / rate;
  // Resampling truncates fractional frames; double division can also lose one
  // complete frame. Permit that single shortfall and discard decoder padding.
  const first = Math.floor(rescale(start));
  const mappedEnd = Math.floor(rescale(end));
  if (decoded.length < mappedEnd - 1) {
    throw new RangeError(`Decoded audio does not contain the playback interval: requires at least ${mappedEnd - 1} frames, has ${decoded.length} frames at ${decoded.sampleRate} Hz`);
  }
  const last = Math.min(mappedEnd, decoded.length);
  // Round the declared final duration once. Independent rounding of N and M can
  // change N-M by a frame; derive the overlap from the mapped interval instead.
  const length = overlap ? Math.round(rescale(end - start - overlap)) : last - first;
  const count = last - first - length;
  if (overlap > 0 && count < 2) {
    const reason = last < mappedEnd ? 'overlap too short after decoder one-frame shortfall' : 'overlap too short after sample-rate conversion';
    throw new RangeError(`Audio playback ${reason}: requires at least 2 frames, has ${count}`);
  }
  if (length < 1 || count < 0 || (overlap > 0 && count * 2 >= last - first)) {
    throw new RangeError(`Decoded audio does not contain the playback interval: requires [${first}, ${last}), has ${decoded.length} frames at ${decoded.sampleRate} Hz`);
  }
  const output = new AudioBuffer({ numberOfChannels: decoded.numberOfChannels,
    length, sampleRate: decoded.sampleRate });
  for (let channel = 0; channel < decoded.numberOfChannels; channel++) {
    const source = decoded.getChannelData(channel);
    const target = output.getChannelData(channel);
    if (!overlap) {
      target.set(source.subarray(first, first + length));
      continue;
    }
    const middle = last - first - 2 * count;
    target.set(source.subarray(first + count, last - count));
    for (let i = 0; i < count; i++) {
      const headWeight = 0.5 - 0.5 * Math.cos(Math.PI * i / (count - 1));
      target[middle + i] = source[last - count + i] * (1 - headWeight) +
        source[first + i] * headWeight;
    }
  }
  prepared.set(output, key);
  if (!cached.has(decoded)) cached.set(decoded, new Map());
  cached.get(decoded).set(key, output);
  return output;
}

export function createAudioSource(context, decoded, audio) {
  if (typeof audio.loop !== 'boolean' || audio.loop !== (audio.playback.overlap_frames > 0)) {
    throw new RangeError('Audio loop flag does not match playback overlap');
  }
  const source = context.createBufferSource();
  const buffer = prepareAudioBuffer(decoded, audio.playback);
  if (audio.loop && !guarded.has(buffer)) {
    // Some renderers interpolate at the buffer end before wrapping. Supply
    // the next cyclic sample without extending the declared loop interval.
    const playback = new AudioBuffer({ numberOfChannels: buffer.numberOfChannels,
      length: buffer.length + 1, sampleRate: buffer.sampleRate });
    for (let channel = 0; channel < buffer.numberOfChannels; channel++) {
      const target = playback.getChannelData(channel);
      target.set(buffer.getChannelData(channel));
      target[buffer.length] = target[0];
    }
    guarded.set(buffer, playback);
  }
  source.buffer = audio.loop ? guarded.get(buffer) : buffer;
  source.loop = audio.loop;
  source.loopStart = 0;
  source.loopEnd = buffer.duration;
  return source;
}
