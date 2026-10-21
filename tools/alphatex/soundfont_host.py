"""Offline FluidSynth owner. No audio/MIDI driver or file-player is created."""
import ctypes as c
import ctypes.util
import hashlib
import json
import math
import os
from pathlib import Path
import struct
import sys


def digest(path):
    h = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def integer(value, name, maximum=None):
    if type(value) is not int or value < 0 or (maximum is not None and value > maximum):
        raise ValueError('Invalid ' + name)
    return value


class Engine:
    def __init__(self):
        library = ctypes.util.find_library('fluidsynth')
        if not library:
            raise ValueError('FluidSynth library unavailable; install FluidSynth before selecting this engine')
        self.lib = c.CDLL(library)
        ptr, num = c.c_void_p, c.c_int
        def bind(name, result, args):
            function = getattr(self.lib, name)
            function.restype, function.argtypes = result, args
            return function
        self.version = bind('fluid_version_str', c.c_char_p, [])().decode()
        self.settings = bind('new_fluid_settings', ptr, [])
        self.free_settings = bind('delete_fluid_settings', None, [ptr])
        self.setnum = bind('fluid_settings_setnum', num, [ptr, c.c_char_p, c.c_double])
        self.setint = bind('fluid_settings_setint', num, [ptr, c.c_char_p, num])
        self.setstr = bind('fluid_settings_setstr', num, [ptr, c.c_char_p, c.c_char_p])
        self.synth = bind('new_fluid_synth', ptr, [ptr])
        self.free_synth = bind('delete_fluid_synth', None, [ptr])
        self.load = bind('fluid_synth_sfload', num, [ptr, c.c_char_p, num])
        self.noteon = bind('fluid_synth_noteon', num, [ptr, num, num, num])
        self.noteoff = bind('fluid_synth_noteoff', num, [ptr, num, num])
        self.cc = bind('fluid_synth_cc', num, [ptr, num, num, num])
        self.program = bind('fluid_synth_program_change', num, [ptr, num, num])
        self.bend = bind('fluid_synth_pitch_bend', num, [ptr, num, num])
        self.pressure = bind('fluid_synth_channel_pressure', num, [ptr, num, num])
        self.key_pressure = bind('fluid_synth_key_pressure', num, [ptr, num, num, num])
        self.sysex = bind('fluid_synth_sysex', num, [ptr, c.c_void_p, num, ptr, ptr, c.POINTER(num), num])
        self.render = bind('fluid_synth_write_float', num, [ptr, num, ptr, num, num, ptr, num, num])
        self.quantum = bind('fluid_synth_get_internal_bufsize', num, [ptr])
        setting = self.settings()
        probe = self.synth(setting) if setting else None
        try:
            if not probe:
                raise ValueError('FluidSynth inspection allocation failed')
            control_frames = self.quantum(probe)
            if control_frames <= 0:
                raise ValueError('Invalid FluidSynth control quantum')
        finally:
            if probe:
                self.free_synth(probe)
            if setting:
                self.free_settings(setting)
        # A discovered absolute library can be hashed; a loader-resolved soname
        # is reported honestly rather than inventing its on-disk identity.
        self.identity = {'kind': 'fluidsynth', 'version': self.version, 'controlFrames': control_frames,
                         'library': library, 'librarySha256': digest(library) if Path(library).is_file() else None}

    def message(self, synth, data):
        if not isinstance(data, list) or not data:
            raise ValueError('Missing MIDI message')
        for byte in data:
            integer(byte, 'MIDI byte', 255)
        status, channel = data[0] & 240, data[0] & 15
        if 128 <= data[0] < 240:
            size = 2 if status in (192, 208) else 3
            if len(data) != size or any(byte > 127 for byte in data[1:]):
                raise ValueError('Invalid channel message')
            if status == 128 or status == 144 and data[2] == 0:
                # Public FluidSynth noteoff may return FAILED solely because
                # no voice matches (e.g. after AllSoundOff). The MIDI release
                # remains legal; channel/key were validated above.
                self.noteoff(synth, channel, data[1])
                result = 0
            elif status == 144:
                result = self.noteon(synth, channel, data[1], data[2])
            elif status == 160:
                result = self.key_pressure(synth, channel, data[1], data[2])
            elif status == 176:
                result = self.cc(synth, channel, data[1], data[2])
            elif status == 192:
                result = self.program(synth, channel, data[1])
            elif status == 208:
                result = self.pressure(synth, channel, data[1])
            else:
                result = self.bend(synth, channel, data[1] | data[2] << 7)
        elif data[0] == 240 and len(data) >= 3 and data[-1] == 247 and all(byte < 128 for byte in data[1:-1]):
            payload = bytes(data[1:-1]); handled = c.c_int(0)
            result = self.sysex(synth, c.c_char_p(payload), len(payload), None, None, c.byref(handled), 0)
            if not handled.value:
                raise ValueError('FluidSynth does not support this SysEx message')
        else:
            raise ValueError('Fragmented SysEx/system wire needs an explicit supported synthesis route')
        if result != 0:
            raise ValueError('FluidSynth rejected a MIDI event')


def render(engine, plan):
    if plan.get('schemaVersion') != 1 or plan.get('kind') != 'soundfont-render':
        raise ValueError('Invalid SoundFont render plan')
    if plan.get('engine') != {key: engine.identity[key] for key in ('kind', 'version', 'controlFrames')}:
        raise ValueError('Selected FluidSynth engine version is unavailable')
    rate = integer(plan['sampleRate'], 'sample rate', 0xffffffff)
    frames = integer(plan['frames'], 'render frames', (0xffffffff - 36) // 8)
    if not rate or not frames or rate * 8 > 0xffffffff:
        raise ValueError('Unrepresentable stereo float RIFF horizon/rate')
    font = plan['font']
    if digest(font['path']) != font['sha256']:
        raise ValueError('SoundFont content differs from its bound snapshot')
    if plan['bankStyle'] not in ('gm', 'gs', 'xg', 'mma'):
        raise ValueError('Invalid MIDI bank interpretation')
    synths, settings, events, ports = {}, [], [], set()
    quantum = engine.identity['controlFrames']
    timing = {'kind': 'control-block-ceil', 'quantumFrames': quantum, 'changedEvents': 0,
              'maxDelayFrames': 0, 'terminalEvents': 0, 'events': []}
    created = False
    try:
        for port in plan['ports']:
            identity = integer(port['port'], 'source port')
            if identity in ports:
                raise ValueError('Duplicate source port')
            ports.add(identity)
            setting = engine.settings()
            if not setting:
                raise ValueError('FluidSynth settings allocation failed')
            settings.append(setting)
            if (engine.setnum(setting, b'synth.sample-rate', rate) != 0
                    or engine.setint(setting, b'synth.min-note-length', 0) != 0
                    or engine.setstr(setting, b'synth.midi-bank-select', plan['bankStyle'].encode()) != 0):
                raise ValueError('FluidSynth rejected render settings')
            synth = engine.synth(setting)
            if not synth:
                raise ValueError('FluidSynth allocation failed')
            synths[identity] = synth
            if engine.quantum(synth) != quantum:
                raise ValueError('FluidSynth control quantum changed')
            if engine.load(synth, font['path'].encode(), 1) < 0:
                raise ValueError('FluidSynth rejected the bound SF2')
            previous = 0
            held = {}
            for event in port['events']:
                frame = integer(event['frame'], 'event frame', frames)
                if frame < previous:
                    raise ValueError('Unordered source events')
                previous = frame
                actual = ((frame + quantum - 1) // quantum) * quantum
                if frame == frames:
                    # These events are at the exclusive document end. Apply
                    # cleanup after output, without claiming audible tail.
                    timing['terminalEvents'] += 1
                    actual = frames
                elif actual >= frames:
                    raise ValueError('SoundFont control quantum moves an event beyond the finite source horizon; extend the source or choose another engine')
                else:
                    timing['maxDelayFrames'] = max(timing['maxDelayFrames'], actual - frame)
                    timing['changedEvents'] += int(actual != frame)
                timing['events'].append([identity, frame, actual if frame < frames else None])
                data = event['bytes']
                if data and 128 <= data[0] < 160 and len(data) == 3:
                    key = (data[0] & 15, data[1])
                    if data[0] & 240 == 144 and data[2]:
                        if key in held and frame > held[key][0] and actual == held[key][1]:
                            raise ValueError('SoundFont control quantum collapses distinct note retriggers; choose another engine')
                        # FluidSynth's retrigger owns the most recent key, not
                        # an independent FIFO of MIDI1 note identifiers.
                        held[key] = (frame, actual)
                    elif key in held:
                        start, sounding = held.pop(key)
                        if frame > start and actual == sounding:
                            raise ValueError('SoundFont control quantum collapses distinct note boundaries; choose another engine')
                elif data and data[0] & 240 == 176 and len(data) == 3 and data[1] in (120, 123, 124, 125, 126, 127):
                    channel = data[0] & 15
                    for key, (start, sounding) in list(held.items()):
                        if key[0] != channel:
                            continue
                        if frame > start and actual == sounding:
                            raise ValueError('SoundFont control quantum collapses a note and channel release; choose another engine')
                        del held[key]
                events.append((actual, identity, data))
        # Port states are independent; stable order survives equal engine
        # boundaries. Original sample positions remain separately in receipt.
        events.sort(key=lambda event: event[0])
        output = plan['output']
        peak, cursor, event_index = 0.0, 0, 0
        with open(output, 'xb') as stream:
            created = True
            os.chmod(output, 0o600)
            data_bytes = frames * 8
            stream.write(struct.pack('<4sI4s4sIHHIIHH4sI', b'RIFF', 36 + data_bytes, b'WAVE', b'fmt ', 16,
                                     3, 2, rate, rate * 8, 8, 32, b'data', data_bytes))
            while cursor < frames or event_index < len(events):
                while event_index < len(events) and events[event_index][0] == cursor:
                    _, port, data = events[event_index]
                    engine.message(synths[port], data)
                    event_index += 1
                after = min(frames, events[event_index][0] if event_index < len(events) else frames, cursor + 4096)
                count = after - cursor
                if not count:
                    break
                mixed = [0.0] * (count * 2)
                for synth in synths.values():
                    buffer = (c.c_float * (count * 2))()
                    if engine.render(synth, count, buffer, 0, 2, buffer, 1, 2) != 0:
                        raise ValueError('FluidSynth rendering failed')
                    for index, sample in enumerate(buffer):
                        mixed[index] += sample
                if any(not math.isfinite(sample) for sample in mixed):
                    raise ValueError('SoundFont renderer produced non-finite samples')
                peak = max(peak, max(map(abs, mixed), default=0))
                stream.write(struct.pack('<%df' % len(mixed), *mixed))
                cursor = after
            stream.flush(); os.fsync(stream.fileno())
        if digest(font['path']) != font['sha256']:
            raise ValueError('Bound SF2 changed during rendering')
        return {'path': output, 'frames': frames, 'sampleRate': rate, 'channels': 2, 'peak': peak,
                'wavSha256': digest(output), 'fontSha256': font['sha256'], 'engine': engine.identity,
                'ports': sorted(ports), 'events': len(events), 'bankStyle': plan['bankStyle'], 'timing': timing}
    except BaseException:
        if created:
            os.unlink(plan['output'])
        raise
    finally:
        for synth in synths.values():
            engine.free_synth(synth)
        for setting in settings:
            engine.free_settings(setting)


if __name__ == '__main__':
    try:
        request = json.load(sys.stdin)
        engine = Engine()
        if request.get('operation') == 'inspect':
            result = engine.identity
        elif request.get('operation') == 'render':
            result = render(engine, request['plan'])
        else:
            raise ValueError('Unknown SoundFont request')
        print(json.dumps({'ok': True, 'result': result}, allow_nan=False))
    except Exception as error:
        print(json.dumps({'ok': False, 'error': str(error)}))
        sys.exit(1)
