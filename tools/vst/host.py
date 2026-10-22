#!/usr/bin/env python3
"""Native VST3 rendering, or --stream request-driven continuous synthesis.

Default input/output are single JSON objects; --stream and --serve use NDJSON.
--serve runs jobs one at a time in one process and keeps the instrument the
latest snapshot or render loaded, so the next job does not load it again. Native
diagnostics go to stderr, including plug-in destructors. Only the explicit edit
job opens a plug-in editor. No operation opens an audio device.
"""

from __future__ import annotations

import hashlib
import base64
from contextlib import ExitStack
from fractions import Fraction
import io
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import struct
import threading
import time
from fractions import Fraction


def nonempty(value, name):
    if not isinstance(value, str) or not value:
        raise ValueError(f"{name} must be a nonempty string")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def frame_timeline(data, expected_hash, sample_rate):
    """Private synthesis projection; original UMP remains in the source asset."""
    if digest(data) != nonempty(expected_hash, "expected_timeline_sha256"):
        raise ValueError("VST frame timeline content changed")
    value = json.loads(data)
    if (not isinstance(value, dict) or set(value) != {"schemaVersion", "kind", "sampleRate", "frames", "events"}
            or type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1
            or value["kind"] != "practice-vst" or type(value["sampleRate"]) is not int
            or value["sampleRate"] != sample_rate or not isinstance(value["events"], list)):
        raise ValueError("invalid VST frame timeline")
    def counter(text):
        if (not isinstance(text, str) or not text.isascii() or not text.isdecimal()
                or str(int(text)) != text or not 0 <= int(text) <= 0xFFFFFFFFFFFFFFFF):
            raise ValueError("invalid VST frame counter")
        return int(text)
    frames = counter(value["frames"])
    if frames == 0:
        raise ValueError("VST frame timeline is empty")
    previous, events = 0, []
    for event in value["events"]:
        if not isinstance(event, dict) or set(event) != {"frame", "bytes"}:
            raise ValueError("invalid VST frame event")
        frame, message = counter(event["frame"]), event["bytes"]
        if (frame < previous or frame >= frames or not isinstance(message, list) or not message
                or any(type(byte) is not int or not 0 <= byte <= 255 for byte in message)):
            raise ValueError("invalid VST event frame or bytes")
        status = message[0] >> 4
        if (status not in (8, 9, 10, 11, 13, 14) or len(message) != (2 if status == 13 else 3)
                or any(byte > 127 for byte in message[1:]) or status == 11 and message[1] in (0, 32)):
            raise ValueError("VST frame event cannot replace the frozen preset or encode this message")
        events.append((bytes(message), frame)); previous = frame
    if not any(message[0] >> 4 == 9 and message[2] > 0 for message, _ in events):
        raise ValueError("VST frame timeline contains no sounding notes")
    return events, frames


def preset_message(message):
    # The captured preset owns program/bank selection for both input formats.
    return message.type == "program_change" or (
        message.type == "control_change" and message.control in (0, 32))


def finite_seconds(value, name, positive=False):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0 or positive and value == 0:
        raise ValueError(f"{name} must be finite and {'positive' if positive else 'nonnegative'}")
    return value


class ProjectedMidi:
    """Stream an owned native region/port projection, verifying every byte.

    No SMF re-encoding: chased notes, expression, release velocities and
    same-time message order reach the instrument exactly as projected.
    """

    def __init__(self, stream, request):
        self.stream = stream
        self.hash = hashlib.sha256()
        self.count = 0
        self.previous = 0.0
        self.verified = False
        self.sounding = False
        self.expected_hash = nonempty(request.get("timeline_sha256"), "timeline_sha256")
        self.expected_count = request.get("timeline_event_count")
        if len(self.expected_hash) != 64 or any(character not in "0123456789abcdef" for character in self.expected_hash):
            raise ValueError("timeline_sha256 must be a SHA-256 digest")
        if type(self.expected_count) is not int or self.expected_count < 0:
            raise ValueError("timeline_event_count must be a nonnegative integer")
        header = self.row()
        if not isinstance(header, dict) or type(header.get("schemaVersion")) is not int or header["schemaVersion"] != 1 or header.get("kind") != "vst-midi-part":
            raise ValueError("invalid native MIDI projection header")
        self.duration = finite_seconds(header.get("duration"), "projection duration", positive=True)
        if self.duration != request.get("timeline_duration"):
            raise ValueError("native MIDI projection duration differs from its receipt")

    def row(self):
        line = self.stream.readline()
        if not line:
            return None
        self.hash.update(line)
        return json.loads(line)

    def __iter__(self):
        return self

    def __next__(self):
        import mido

        while not self.verified:
            # EOF and a JSON null row are different protocol states.
            line = self.stream.readline()
            if not line:
                if self.count != self.expected_count or self.hash.hexdigest() != self.expected_hash:
                    raise ValueError("native MIDI projection bytes/count differ from its receipt")
                self.verified = True
                break
            self.hash.update(line)
            row = json.loads(line)
            if not isinstance(row, dict):
                raise ValueError("invalid native MIDI projection event")
            seconds = finite_seconds(row.get("seconds"), "MIDI event time")
            data = row.get("bytes")
            if seconds < self.previous or seconds > self.duration or not isinstance(data, list) or not data or any(type(byte) is not int or byte < 0 or byte > 255 for byte in data):
                raise ValueError("invalid or unordered native MIDI projection event")
            message = mido.Message.from_bytes(data)
            if message.bytes() != data:
                raise ValueError("native MIDI projection requires complete messages")
            self.previous = seconds
            self.count += 1
            if message.type == 'note_on' and message.velocity > 0 and seconds < self.duration:
                self.sounding = True
            if not preset_message(message):
                return bytes(data), seconds
        raise StopIteration


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
        if preset_message(message):
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


class Cancelled(Exception):
    """A --serve job stopped by its caller between rendered blocks."""


class SilentRender(ValueError):
    """Sounding notes rendered to all-zero PCM."""


class Retained:
    """The instrument a --serve session keeps between jobs.

    One instance: the one the latest snapshot or render left in a known state,
    keyed by plug-in path, plug-in name and the sha256 of that state's preset
    bytes. A job asking for anything else releases it, then loads a fresh
    instance as a one-shot job does, so two instruments are never held.

    The raw state is recorded when the instance is kept. A controller or a
    cancelled render can move a parameter, so reuse first restores that state
    when it differs. `used` tells the serve loop whether the current job
    touched the instance; a job that failed before reaching it keeps it.
    """

    def __init__(self):
        self.drop()

    def take(self, key):
        if self.plugin is None or key != self.key:
            return None
        self.used = True
        if self.plugin.raw_state != self.state:
            self.plugin.raw_state = self.state
        return self.plugin

    def keep(self, key, plugin, loaded_at):
        self.key, self.plugin, self.loaded_at, self.state, self.used = key, plugin, loaded_at, plugin.raw_state, True

    def drop(self):
        self.key, self.plugin, self.loaded_at, self.state, self.used = None, None, None, None, False


def retained_key(request, state_sha256):
    return (nonempty(request.get("plugin_path"), "plugin_path"), request.get("plugin_name"), state_sha256)


def load_frozen_preset(plugin, data):
    """Load preset bytes from a private copy; the caller's file may go away."""
    with tempfile.TemporaryDirectory(prefix="masc-vst-state-") as folder:
        frozen = Path(folder) / "sound.vstpreset"
        frozen.write_bytes(data)
        plugin.load_preset(str(frozen))


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


def snapshot(request, retained=None):
    """Capture an actual default/preset state without opening the native editor."""
    if retained is not None:
        retained.drop()
    plugin = load_instrument(request)
    loaded_at = time.monotonic()
    preset = request.get("preset_path")
    if preset is not None:
        load_frozen_preset(plugin, Path(nonempty(preset, "preset_path")).read_bytes())
    data = plugin.preset_data
    if retained is not None:
        # The instance now holds exactly these bytes; a render of the sound
        # captured here reuses it.
        retained.keep(retained_key(request, digest(data)), plugin, loaded_at)
    return {"instrument": description(plugin),
            "preset": {"data": base64.b64encode(data).decode("ascii"), "sha256": digest(data)}}


def render(request, retained=None, cancelled=lambda: False):
    from pedalboard.io import AudioFile
    import numpy as np

    output_path = Path(nonempty(request.get("output_path"), "output_path"))
    if output_path.exists():
        raise FileExistsError(f"output already exists: {output_path}")
    sample_rate = request.get("sample_rate", 44100)
    if type(sample_rate) is not int or not 0 < sample_rate <= 0xFFFFFFFF:
        raise ValueError("sample_rate must fit the WAV sample-rate field")
    if int(np.float32(sample_rate)) != sample_rate:
        raise ValueError("sample_rate must be exactly representable by the VST host float32 API")
    tail = finite_seconds(request.get("tail_seconds", 1.0), "tail_seconds")
    origin = finite_seconds(request.get("origin_seconds", 0.0), "origin_seconds")
    if sum(request.get(name) is not None for name in ("midi_path", "frames_path", "timeline_path")) != 1:
        raise ValueError("choose one MIDI file, frame timeline, or native MIDI projection")
    with ExitStack() as resources:
        projection = None
        framed = request.get("frames_path") is not None
        if framed:
            if tail != 0 or origin != 0:
                raise ValueError("frame timeline owns its complete sample horizon")
            timeline = Path(nonempty(request["frames_path"], "frames_path")).read_bytes()
            events, frames = frame_timeline(timeline, request.get("expected_timeline_sha256"), sample_rate)
            source_receipt = {"timeline_sha256": digest(timeline)}
        elif request.get("timeline_path") is not None:
            stream = resources.enter_context(open(nonempty(request["timeline_path"], "timeline_path"), "rb"))
            projection = ProjectedMidi(stream, request)
            events, phrase_seconds = projection, projection.duration
            source_receipt = {"timeline_sha256": projection.expected_hash,
                              "timeline_event_count": projection.expected_count}
        else:
            midi_bytes = Path(nonempty(request["midi_path"], "midi_path")).read_bytes()
            events, phrase_seconds = midi_timeline(midi_bytes)
            source_receipt = {"midi_sha256": digest(midi_bytes)}
        preset = request.get("preset_path")
        preset_bytes = preset_hash = None
        if preset is not None:
            preset_bytes = Path(nonempty(preset, "preset_path")).read_bytes()
            preset_hash = digest(preset_bytes)
        key = retained_key(request, preset_hash) if retained is not None else None
        plugin = retained.take(key) if retained is not None else None
        if plugin is None:
            if retained is not None:
                retained.drop()
            plugin = load_instrument(request)
            if preset_bytes is not None:
                load_frozen_preset(plugin, preset_bytes)
            loaded_at = time.monotonic()
            if retained is not None:
                retained.keep(key, plugin, loaded_at)
        else:
            loaded_at = retained.loaded_at
        expected = request.get("expected_instrument")
        if expected is not None:
            actual = description(plugin)
            if not isinstance(expected, dict) or any(expected.get(key) != actual[key] for key in ("identifier", "version")):
                raise ValueError("installed VST identity/version differs from the project sound")
        state_hash = digest(plugin.raw_state)
        # Quantize source time and origin together, once on the common PCM
        # grid. Frame-owned practice projections already carry that decision.
        first_frame = 0 if framed else math.floor(Fraction(origin) * sample_rate)
        if not framed:
            frames = math.ceil((Fraction(origin) + Fraction(phrase_seconds) + Fraction(tail)) * sample_rate) - first_frame
            events = ((message, math.ceil((Fraction(origin) + Fraction(timestamp)) * sample_rate) - first_frame)
                      for message, timestamp in events)
        iterator = iter(events)
        next_event = next(iterator, None)
        peak, rendered = 0.0, 0
        stage_fd, stage_name = tempfile.mkstemp(prefix=".vst-", suffix=".wav", dir=output_path.parent)
        os.close(stage_fd)
        try:
            with AudioFile(stage_name, "w", sample_rate, 2, bit_depth=32) as output:
                started_at = time.monotonic()
                while rendered < frames:
                    if cancelled():
                        raise Cancelled("VST render cancelled")
                    # Exact integer offsets fit the native Float32 ABI.
                    count = min(sample_rate, 1 << 24, frames - rendered)
                    block = []
                    while next_event is not None and next_event[1] < rendered + count:
                        message, frame = next_event
                        block.append((message, frame_seconds(frame - rendered, sample_rate)))
                        next_event = next(iterator, None)
                    audio = plugin(block, duration=frame_seconds(count, sample_rate),
                                   sample_rate=sample_rate, num_channels=2,
                                   reset=rendered == 0)
                    if audio.shape != (2, count) or not np.isfinite(audio).all():
                        raise ValueError(f"VST returned invalid audio samples: expected stereo/{count} frames, got {audio.shape}")
                    peak = max(peak, float(np.max(np.abs(audio))))
                    output.write(audio)
                    rendered += count
            # Cleanup at the final exclusive edge may have no PCM frame left.
            # Consume it too: every input row/count/hash must be verified before
            # publishing, even for a zero-tail render or a controller-only port.
            for _ in iterator:
                pass
            if peak == 0 and (projection is None or projection.sounding):
                if retained is None:
                    raise SilentRender("selected VST produced silence; check its preset, sample library, and license")
                # VST3 reports no "samples loaded" state, so the age is stated, not judged.
                raise SilentRender(f"selected VST produced silence {started_at - loaded_at:.0f}s after it was loaded."
                                   " A sample-streaming instrument may still be reading its samples; play again."
                                   " If it stays silent, check its preset, sample library, and license")
            with open(stage_name, "rb") as rendered_audio:
                wave_hash = hashlib.file_digest(rendered_audio, "sha256").hexdigest()
            os.link(stage_name, output_path)
        finally:
            os.unlink(stage_name)
    return {"instrument": description(plugin), **source_receipt,
            "preset_sha256": preset_hash, "state_sha256": state_hash,
            "sample_rate": sample_rate, "frames": frames, "frame_origin": first_frame,
            "duration_ms": frames / sample_rate * 1000, "peak": peak,
            "wav_sha256": wave_hash, "output_path": str(output_path)}


def mix(request):
    """Place rendered instances on their common PCM grid, without normalization."""
    from pedalboard.io import AudioFile
    import numpy as np

    output_path = Path(nonempty(request.get("output_path"), "output_path"))
    if output_path.exists():
        raise FileExistsError(f"output already exists: {output_path}")
    sample_rate, frames = request.get("sample_rate"), request.get("frames")
    if type(sample_rate) is not int or not 0 < sample_rate <= 0xFFFFFFFF or type(frames) is not int or frames <= 0:
        raise ValueError("invalid arrangement PCM clock")
    parts = request.get("parts")
    if not isinstance(parts, list) or not parts:
        raise ValueError("arrangement requires rendered instances")
    with ExitStack() as resources:
        sources = []
        for part in parts:
            if not isinstance(part, dict) or type(part.get("frame_origin")) is not int or part["frame_origin"] < 0:
                raise ValueError("invalid rendered instance placement")
            # Retain the verified file descriptor for all reads. Replacing its
            # pathname during mixing cannot redirect an admitted instance.
            source = resources.enter_context(open(nonempty(part.get("output_path"), "instance output_path"), "rb"))
            if hashlib.file_digest(source, "sha256").hexdigest() != part.get("wav_sha256"):
                raise ValueError("rendered instance bytes differ from its receipt")
            source.seek(0)
            audio = resources.enter_context(AudioFile(source))
            if audio.samplerate != sample_rate or audio.num_channels != 2 or audio.frames != part.get("frames"):
                raise ValueError("rendered instance PCM clock differs from its receipt")
            sources.append((audio, part["frame_origin"]))
        stage_fd, stage_name = tempfile.mkstemp(prefix=".vst-mix-", suffix=".wav", dir=output_path.parent)
        os.close(stage_fd)
        peak, rendered = 0.0, 0
        try:
            with AudioFile(stage_name, "w", sample_rate, 2, bit_depth=32) as output:
                while rendered < frames:
                    count = min(sample_rate, frames - rendered)
                    block = np.zeros((2, count), dtype=np.float32)
                    for audio, origin in sources:
                        first, end = max(rendered, origin), min(rendered + count, origin + audio.frames)
                        if first >= end:
                            continue
                        audio.seek(first - origin)
                        samples = audio.read(end - first)
                        if samples.shape != (2, end - first) or not np.isfinite(samples).all():
                            raise ValueError("rendered instance contains invalid audio samples")
                        block[:, first - rendered:end - rendered] += samples
                    if not np.isfinite(block).all():
                        raise ValueError("arrangement mix exceeds the finite PCM range")
                    peak = max(peak, float(np.max(np.abs(block))))
                    output.write(block)
                    rendered += count
            with open(stage_name, "rb") as source:
                wave_hash = hashlib.file_digest(source, "sha256").hexdigest()
            os.link(stage_name, output_path)
        finally:
            os.unlink(stage_name)
    return {"output_path": str(output_path), "sample_rate": sample_rate, "frames": frames,
            "duration_ms": frames / sample_rate * 1000, "peak": peak,
            "wav_sha256": wave_hash, "instances": len(parts)}


def run(request, retained=None, cancelled=lambda: False):
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
            return render(request, retained, cancelled)
        case "snapshot":
            return snapshot(request, retained)
        case "mix":
            return mix(request)
        case _:
            raise ValueError("unknown VST job operation")


def stream_synthesis(source, emit):
    """One instrument, request-driven PCM blocks, no audio device or clock."""
    import numpy as np
    import mido

    request = json.loads(source.readline())
    if (not isinstance(request, dict) or request.get('kind') != 'open'
            or type(request.get('schemaVersion')) is not int or request['schemaVersion'] != 1):
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


def serve(source, emit, retained=None):
    """NDJSON jobs in one process: {"id", "job"} runs, {"cancel": id} stops.

    Jobs run in arrival order on this thread; a reader thread admits cancels
    while a render runs. A cancel reaches a render between blocks; other jobs
    finish and their reply is dropped by the caller. The retained instrument
    survives silence and cancellation. Any other failure of a job that used it
    leaves its state unknown, so the next job loads a fresh instance.
    """
    import queue

    retained = Retained() if retained is None else retained
    jobs, cancelled, failure = queue.Queue(), set(), []

    def admit():
        try:
            for line in source:
                request = json.loads(line)
                if isinstance(request, dict) and type(request.get("cancel")) is int:
                    cancelled.add(request["cancel"])
                elif (isinstance(request, dict) and type(request.get("id")) is int
                      and isinstance(request.get("job"), dict)):
                    jobs.put((request["id"], request["job"]))
                else:
                    raise ValueError("VST serve request must be {id, job} or {cancel}")
        except Exception as error:
            failure.append(error)
        finally:
            jobs.put(None)

    threading.Thread(target=admit, daemon=True).start()
    while (item := jobs.get()) is not None:
        job_id, job = item
        retained.used = False
        try:
            if job_id in cancelled:
                raise Cancelled("VST job cancelled")
            reply = {"id": job_id, "ok": True, "result": run(job, retained, lambda: job_id in cancelled)}
        except Cancelled:
            reply = {"id": job_id, "ok": False, "cancelled": True}
        except Exception as error:
            if retained.used and not isinstance(error, SilentRender):
                retained.drop()
            reply = {"id": job_id, "ok": False, "error": f"{type(error).__name__}: {error}"}
        cancelled.discard(job_id)
        emit(reply)
    if failure:
        raise failure[0]


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
        if sys.argv[1:] == ['--serve']:
            try:
                serve(sys.stdin, emit)
                return 0
            except Exception as error:
                # Replies are per job; a broken request stream ends the session.
                print(f'{type(error).__name__}: {error}', file=sys.stderr)
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
