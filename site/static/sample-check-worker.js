// Deferred SXC-1 readiness analysis.
//
// The worker is created only after a person explicitly asks to check one
// sound. WAV headers are read from the file's own bytes. Files at or below the
// scan limit are then inspected as PCM in this worker so a long sample never
// occupies the UI thread and decodeAudioData never resamples the evidence.

const HEADER_LIMIT_BYTES = 1024 * 1024;
const PCM_SCAN_LIMIT_BYTES = 48 * 1024 * 1024;
const SILENCE_AMPLITUDE = 0.001; // -60 dBFS

function ascii(view, offset, length) {
  if (offset < 0 || offset + length > view.byteLength) return "";
  let result = "";
  for (let index = 0; index < length; index += 1) {
    result += String.fromCharCode(view.getUint8(offset + index));
  }
  return result;
}

async function wavHeader(file) {
  const headerBytes = await file.slice(0, Math.min(file.size, HEADER_LIMIT_BYTES)).arrayBuffer();
  const view = new DataView(headerBytes);
  if (view.byteLength < 12 || ascii(view, 0, 4) !== "RIFF" || ascii(view, 8, 4) !== "WAVE") return null;

  let offset = 12;
  let format = null;
  let data = null;
  while (offset + 8 <= view.byteLength) {
    const id = ascii(view, offset, 4);
    const size = view.getUint32(offset + 4, true);
    const start = offset + 8;
    if (id === "fmt " && size >= 16 && start + 16 <= view.byteLength) {
      format = {
        audioFormat: view.getUint16(start, true),
        channels: view.getUint16(start + 2, true),
        sampleRate: view.getUint32(start + 4, true),
        byteRate: view.getUint32(start + 8, true),
        blockAlign: view.getUint16(start + 12, true),
        bitDepth: view.getUint16(start + 14, true),
      };
    }
    if (id === "data") {
      data = { offset: start, size };
      break;
    }
    const next = start + size + (size % 2);
    if (!Number.isSafeInteger(next) || next <= offset) break;
    offset = next;
  }
  if (!format || !data) return null;
  const available = Math.max(0, file.size - data.offset);
  const dataSize = Math.min(data.size, available);
  return {
    ...format,
    dataOffset: data.offset,
    dataSize,
    duration: format.byteRate > 0 ? dataSize / format.byteRate : 0,
  };
}

function pcmSample(view, offset, format, bitDepth) {
  if (format === 3 && bitDepth === 32) return view.getFloat32(offset, true);
  if (format !== 1) return null;
  if (bitDepth === 8) {
    const value = view.getUint8(offset) - 128;
    return value >= 0 ? value / 127 : value / 128;
  }
  if (bitDepth === 16) return view.getInt16(offset, true) / 32768;
  if (bitDepth === 24) {
    let value = view.getUint8(offset)
      | (view.getUint8(offset + 1) << 8)
      | (view.getUint8(offset + 2) << 16);
    if (value & 0x800000) value |= 0xff000000;
    return value / 8388608;
  }
  if (bitDepth === 32) return view.getInt32(offset, true) / 2147483648;
  return null;
}

async function scanPcm(file, header) {
  if (header.dataSize > PCM_SCAN_LIMIT_BYTES) return { status: "too-large" };
  const bytesPerSample = header.bitDepth / 8;
  const supported = Number.isInteger(bytesPerSample)
    && [8, 16, 24, 32].includes(header.bitDepth)
    && ((header.audioFormat === 1) || (header.audioFormat === 3 && header.bitDepth === 32))
    && header.channels > 0
    && header.blockAlign >= bytesPerSample * header.channels;
  if (!supported) return { status: "unsupported-pcm" };

  const buffer = await file.slice(header.dataOffset, header.dataOffset + header.dataSize).arrayBuffer();
  const view = new DataView(buffer);
  const frames = Math.floor(view.byteLength / header.blockAlign);
  let peak = 0;
  let clippedFrames = 0;
  let leadingSilentFrames = 0;
  let trailingSilentFrames = 0;
  let heardSignal = false;

  for (let frame = 0; frame < frames; frame += 1) {
    const base = frame * header.blockAlign;
    let framePeak = 0;
    for (let channel = 0; channel < header.channels; channel += 1) {
      const offset = base + channel * bytesPerSample;
      const sample = pcmSample(view, offset, header.audioFormat, header.bitDepth);
      if (sample === null || !Number.isFinite(sample)) continue;
      framePeak = Math.max(framePeak, Math.abs(sample));
    }
    peak = Math.max(peak, framePeak);
    if (framePeak >= 0.999969) clippedFrames += 1;
    if (framePeak <= SILENCE_AMPLITUDE) {
      if (!heardSignal) leadingSilentFrames += 1;
      trailingSilentFrames += 1;
    } else {
      heardSignal = true;
      trailingSilentFrames = 0;
    }
  }

  return {
    status: "scanned",
    frames,
    peak,
    peakDb: peak > 0 ? 20 * Math.log10(peak) : null,
    clippedFrames,
    leadingSilence: header.sampleRate > 0 ? leadingSilentFrames / header.sampleRate : 0,
    trailingSilence: header.sampleRate > 0 ? trailingSilentFrames / header.sampleRate : 0,
    silent: frames > 0 && !heardSignal,
  };
}

async function inspect(file) {
  const extension = String(file?.name || "").toLowerCase().split(".").pop() || "";
  if (extension !== "wav") {
    return { kind: "other", extension, bytes: Number(file?.size) || 0, scan: { status: "not-wav" } };
  }
  const header = await wavHeader(file);
  if (!header) return { kind: "invalid-wav", extension, bytes: file.size, scan: { status: "invalid-wav" } };
  const scan = await scanPcm(file, header);
  return { kind: "wav", extension, bytes: file.size, header, scan };
}

self.addEventListener("message", async (event) => {
  const { id, file } = event.data || {};
  if (!id || !(file instanceof Blob)) return;
  try {
    self.postMessage({ id, ok: true, result: await inspect(file) });
  } catch (error) {
    self.postMessage({ id, ok: false, error: error?.message || String(error) });
  }
});
