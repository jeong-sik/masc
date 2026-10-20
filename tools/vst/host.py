#!/usr/bin/env python3
"""Native VST3 rendering, or --stream request-driven continuous synthesis.

Default input/output are single JSON objects; --stream uses NDJSON. Native
diagnostics go to stderr, including plug-in destructors. Only the explicit edit
job opens a plug-in editor. No operation opens an audio device.
"""

from __future__ import annotations

import hashlib
import base64
import io
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import struct
from fractions import Fraction


def nonempty(value, name):
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a nonempty string")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def midi_timeline(data):
    """Merge source ticks in stable track order; keep tempo integration exact."""
    import mido

    midi = mido.MidiFile(file=io.BytesIO(data))
    if midi.type == 2:
        raise ValueError("asynchronous SMF type 2 has no single phrase timeline")
    if midi.ticks_per_beat <= 0:
        raise ValueError("render a selected synchronous PPQ performance")
    elapsed = Fraction(0)
    tempo = 500000
    events = []
    for message in mido.merge_tracks(midi.tracks):
        elapsed += Fraction(message.time * tempo, midi.ticks_per_beat * 1000000)
        if elapsed < 0:
            raise ValueError("MIDI contains an invalid event time")
        if message.type == "set_tempo":
            tempo = message.tempo
        if message.is_meta:
            continue
        # The chosen VST preset is authoritative. GM bank/program messages
        # belong to the source's soundfont and must not replace that preset.
        if message.type == "program_change" or (
                message.type == "control_change" and message.control in (0, 32)):
            continue
        events.append((bytes(message.bytes()), elapsed))
    if not any(event[0][0] & 0xF0 == 0x90 and event[0][2] > 0 for event in events):
        raise ValueError("MIDI phrase contains no sounding note-on events")
    return events, elapsed


def frame_seconds(frame, sample_rate):
    """Encode a sample index through Pedalboard 0.9.26's Float32 product.

    Both MIDI timestamps and duration use trunc(float32(time)*float32(rate)).
    Choosing time=frame/rate can lose a sample. Verify the native conversion;
    search the positive Float32 ordering if the midpoint is not representable.
    """
    def f32(value):
        return struct.unpack("f", struct.pack("f", value))[0]

    rate = f32(sample_rate)
    if rate != sample_rate:
        raise ValueError("sample rate is not exact in the VST host Float32 API")

    def index(value):
        return int(f32(value * rate))

    value = f32((frame + .5) / sample_rate) if frame else 0.0
    if index(value) == frame:
        return value
    low = 0
    high = struct.unpack("I", struct.pack("f", (frame + 1) / sample_rate))[0] + 1
    while low < high:
        middle = (low + high) // 2
        value = struct.unpack("f", struct.pack("I", middle))[0]
        if index(value) >= frame:
            high = middle
        else:
            low = middle + 1
    value = struct.unpack("f", struct.pack("I", low))[0]
    if index(value) != frame:
        raise ValueError("sample position is not representable by the VST host Float32 API")
    return value


def candidates():
    from pedalboard import VST3Plugin

    return {"candidates": [{"path": path, "name": Path(path).stem}
                           for path in sorted(set(VST3Plugin.installed_plugins))]}


def load_instrument(request):
    from pedalboard import load_plugin

    path = nonempty(request.get("plugin_path"), "plugin_path")
    name = request.get("plugin_name")
    if name is not None:
        nonempty(name, "plugin_name")
    plugin = load_plugin(path, plugin_name=name)
    if not plugin.is_instrument:
        raise ValueError(f"{plugin.name} does not accept MIDI as an instrument")
    return plugin


def description(plugin):
    return {"name": plugin.name, "identifier": plugin.identifier,
            "manufacturer": plugin.manufacturer_name, "version": plugin.version,
            "is_instrument": plugin.is_instrument}


def inspect(request):
    from pedalboard import VST3Plugin

    path = nonempty(request.get("plugin_path"), "plugin_path")
    names = VST3Plugin.get_plugin_names_for_file(path)
    if len(names) != 1 and request.get("plugin_name") is None:
        return {"plugin_names": names}
    plugin = load_instrument(request)
    return {"instrument": description(plugin), "plugin_names": names}


def edit(request):
    """An explicitly requested native editor captures a reusable VST preset."""
    target = Path(nonempty(request.get("output_path"), "output_path"))
    if target.exists():
        raise FileExistsError(f"preset already exists: {target}")
    plugin = load_instrument(request)
    preset = request.get("preset_path")
    if preset is not None:
        plugin.load_preset(nonempty(preset, "preset_path"))
    plugin.show_editor()
    data = plugin.preset_data
    stage_fd, stage_name = tempfile.mkstemp(prefix=".vst-", suffix=".vstpreset", dir=target.parent)
    try:
        with os.fdopen(stage_fd, "wb") as output:
            output.write(data)
        os.link(stage_name, target)
    finally:
        os.unlink(stage_name)
    return {"instrument": description(plugin), "preset_path": str(target),
            "preset_sha256": digest(data)}


def snapshot(request):
    """Capture an actual default/preset state without opening the native editor."""
    plugin = load_instrument(request)
    preset = request.get("preset_path")
    if preset is not None:
        data = Path(nonempty(preset, "preset_path")).read_bytes()
        with tempfile.TemporaryDirectory(prefix="masc-vst-state-") as folder:
            frozen = Path(folder) / "sound.vstpreset"
            frozen.write_bytes(data)
            plugin.load_preset(str(frozen))
    data = plugin.preset_data
    return {"instrument": description(plugin),
            "preset": {"data": base64.b64encode(data).decode("ascii"), "sha256": digest(data)}}


def render(request):
    from pedalboard.io import AudioFile
    import numpy as np

    midi_path = Path(nonempty(request.get("midi_path"), "midi_path"))
    output_path = Path(nonempty(request.get("output_path"), "output_path"))
    if output_path.exists():
        raise FileExistsError(f"output already exists: {output_path}")
    midi_bytes = midi_path.read_bytes()
    events, phrase_seconds = midi_timeline(midi_bytes)
    sample_rate = request.get("sample_rate", 44100)
    if type(sample_rate) is not int or not 0 < sample_rate <= 0xFFFFFFFF:
        raise ValueError("sample_rate must fit the WAV sample-rate field")
    tail = request.get("tail_seconds", 1.0)
    if isinstance(tail, bool) or not isinstance(tail, (int, float)) or not math.isfinite(tail) or tail < 0:
        raise ValueError("tail_seconds must be finite and nonnegative")
    plugin = load_instrument(request)
    expected = request.get("expected_instrument")
    if expected is not None:
        actual = description(plugin)
        if not isinstance(expected, dict) or any(expected.get(key) != actual[key] for key in ("identifier", "version")):
            raise ValueError("installed VST identity/version differs from the project sound")
    preset = request.get("preset_path")
    preset_hash = None
    if preset is not None:
        preset = Path(nonempty(preset, "preset_path"))
        preset_hash = digest(preset.read_bytes())
        plugin.load_preset(str(preset))
    state_hash = digest(plugin.raw_state)
    frames = math.ceil((phrase_seconds + Fraction(tail)) * sample_rate)
    events = [(message, math.ceil(timestamp * sample_rate)) for message, timestamp in events]
    # Float stereo WAV is streamed one second at a time. This bounds memory
    # without imposing any limit on phrase length. All MIDI timestamps are
    # relative to the block currently being rendered.
    peak = 0.0
    event_index = 0
    rendered = 0
    stage_fd, stage_name = tempfile.mkstemp(prefix=".vst-", suffix=".wav", dir=output_path.parent)
    os.close(stage_fd)
    try:
        with AudioFile(stage_name, "w", sample_rate, 2, bit_depth=32) as output:
            while rendered < frames:
                # Float32 represents every integer only through 2**24. Keep
                # relative event indices inside that native API boundary.
                count = min(sample_rate, 1 << 24, frames - rendered)
                block = []
                while event_index < len(events) and events[event_index][1] < rendered + count:
                    message, sample = events[event_index]
                    block.append((message, frame_seconds(sample - rendered, sample_rate)))
                    event_index += 1
                audio = plugin(block, duration=frame_seconds(count, sample_rate),
                               sample_rate=sample_rate, num_channels=2,
                               reset=rendered == 0)
                if audio.shape != (2, count) or not np.isfinite(audio).all():
                    raise ValueError("VST returned invalid audio samples")
                peak = max(peak, float(np.max(np.abs(audio))))
                output.write(audio)
                rendered += count
        if peak == 0:
            raise ValueError("selected VST produced silence; check its preset, sample library, and license")
        with open(stage_name, "rb") as rendered_audio:
            wave_hash = hashlib.file_digest(rendered_audio, "sha256").hexdigest()
        # Publish a complete file, refusing to replace an existing destination.
        os.link(stage_name, output_path)
    finally:
        os.unlink(stage_name)
    return {"instrument": description(plugin), "midi_sha256": digest(midi_bytes),
            "preset_sha256": preset_hash, "state_sha256": state_hash,
            "sample_rate": sample_rate, "frames": frames,
            "duration_ms": frames / sample_rate * 1000, "peak": peak,
            "wav_sha256": wave_hash,
            "output_path": str(output_path)}


def run(request):
    if not isinstance(request, dict):
        raise ValueError("VST job must be an object")
    match request.get("operation"):
        case "candidates":
            return candidates()
        case "inspect":
            return inspect(request)
        case "edit":
            return edit(request)
        case "render":
            return render(request)
        case "snapshot":
            return snapshot(request)
        case _:
            raise ValueError("unknown VST job operation")


def stream_synthesis(source, emit):
    """One instrument, request-driven PCM blocks, no audio device or clock."""
    import numpy as np
    import mido

    request = json.loads(source.readline())
    if not isinstance(request, dict) or request.get('kind') != 'open' or request.get('schemaVersion') != 1:
        raise ValueError('expected VST stream open schemaVersion 1')
    rate = request.get('sampleRate')
    if type(rate) is not int or not 0 < rate <= 0xFFFFFFFF:
        raise ValueError('invalid VST stream sample rate')
    frame_seconds(1, rate)  # Pinned Float32 sample-rate ABI.
    expected = request.get('instrument')
    if not isinstance(expected, dict) or any(not isinstance(expected.get(k), str) or not expected[k]
                                            for k in ('identifier', 'version')):
        raise ValueError('missing project instrument identity/version')
    preset = request.get('preset')
    if not isinstance(preset, dict) or not isinstance(preset.get('data'), str):
        raise ValueError('missing project preset bytes')
    data = base64.b64decode(preset['data'], validate=True)
    if not data or base64.b64encode(data).decode('ascii') != preset['data'] or digest(data) != preset.get('sha256'):
        raise ValueError('project preset content changed')
    plugin = load_instrument(request)
    actual = description(plugin)
    if any(actual[k] != expected[k] for k in ('identifier', 'version')):
        raise ValueError('installed VST identity/version differs from the project sound')
    # Load the exact owned bytes, never the mutable path saved as a label.
    with tempfile.TemporaryDirectory(prefix='masc-vst-stream-') as folder:
        frozen = Path(folder) / 'sound.vstpreset'
        frozen.write_bytes(data)
        plugin.load_preset(str(frozen))
    emit({'kind': 'ready', 'schemaVersion': 1, 'sampleRate': rate, 'channels': 2,
          'instrument': actual, 'preset_sha256': digest(data)})
    sequence, total = 0, 0
    try:
        for line in source:
            request = json.loads(line)
            if not isinstance(request, dict):
                raise ValueError('VST stream command must be an object')
            if request.get('kind') == 'stop':
                break
            count, identifier = request.get('frames'), request.get('id')
            # Float32 sample indices are contiguous only through 2**24. This
            # is the native ABI boundary, not a session duration limit.
            if (request.get('kind') != 'render' or type(identifier) is not int or identifier != sequence + 1
                    or type(count) is not int or not 0 < count <= 2**24):
                raise ValueError('invalid ordered VST block request')
            messages = request.get('messages')
            if not isinstance(messages, list):
                raise ValueError('missing VST block MIDI messages')
            block, previous = [], -1
            for event in messages:
                if not isinstance(event, dict):
                    raise ValueError('invalid VST MIDI event')
                offset, values = event.get('frame'), event.get('bytes')
                if (type(offset) is not int or not previous <= offset < count or offset < 0
                        or not isinstance(values, list) or not values
                        or any(type(value) is not int or not 0 <= value <= 255 for value in values)):
                    raise ValueError('invalid ordered VST MIDI sample offset/data')
                message = mido.Message.from_bytes(values)
                previous = offset
                # The project preset owns timbre, as in offline rendering.
                if message.type == 'program_change' or (message.type == 'control_change' and message.control in (0, 32)):
                    continue
                block.append((bytes(values), frame_seconds(offset, rate)))
            audio = plugin(block, duration=frame_seconds(count, rate), sample_rate=rate,
                           num_channels=2, reset=sequence == 0)
            if audio.shape != (2, count) or not np.isfinite(audio).all():
                raise ValueError('VST returned invalid streaming audio samples')
            pcm = np.asarray(audio.T, dtype='<f4').tobytes(order='C')
            if not np.isfinite(np.frombuffer(pcm, dtype='<f4')).all():
                raise ValueError('VST returned samples outside Float32 PCM')
            sequence = identifier
            total += count
            emit({'kind': 'block', 'id': identifier, 'frames': count,
                  'pcm': base64.b64encode(pcm).decode('ascii')})
        else:
            raise ValueError('VST stream closed without stop')
    finally:
        # Process-local notes cannot survive a failed operation or successor.
        plugin.reset()
    emit({'kind': 'stopped', 'frames': str(total)})


def main():
    # C++ plug-ins can print directly to fd 1; Python redirect_stdout alone
    # does not protect the JSON channel. Keep a private descriptor for replies.
    reply_fd = os.dup(sys.stdout.fileno())
    os.dup2(sys.stderr.fileno(), sys.stdout.fileno())
    def emit(value):
        payload = memoryview((json.dumps(value, allow_nan=False) + '\n').encode())
        while payload:
            payload = payload[os.write(reply_fd, payload):]
    try:
        if sys.argv[1:] == ['--stream']:
            try:
                stream_synthesis(sys.stdin, emit)
                return 0
            except Exception as error:
                emit({'kind': 'error', 'message': f'{type(error).__name__}: {error}'})
                return 1
            finally:
                os.close(reply_fd)
        if sys.argv[1:]:
            raise ValueError('unknown VST host arguments')
        request = json.load(sys.stdin)
        result = {"ok": True, "result": run(request)}
    except Exception as error:
        result = {"ok": False, "error": f"{type(error).__name__}: {error}"}
    emit(result)
    os.close(reply_fd)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
