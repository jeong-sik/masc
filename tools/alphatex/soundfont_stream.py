"""Demand-driven FluidSynth PCM. The caller owns the audio clock and drivers."""
import base64
import ctypes as c
import json
import math
import struct
import sys
from soundfont_host import Engine, digest, integer


def emit(value):
    print(json.dumps(value, allow_nan=False), flush=True)


def stream(request):
    if request.get('kind') != 'open' or request.get('schemaVersion') != 1:
        raise ValueError('Invalid SoundFont stream opening')
    rate = integer(request['sampleRate'], 'sample rate', 0xffffffff)
    if not rate or request['bankStyle'] not in ('gm', 'gs', 'xg', 'mma'):
        raise ValueError('Invalid SoundFont stream settings')
    engine = Engine()
    identity = {key: engine.identity[key] for key in ('kind', 'version', 'controlFrames')}
    if request['engine'] != identity:
        raise ValueError('Selected FluidSynth engine version is unavailable')
    font = request['font']
    if digest(font['path']) != font['sha256']:
        raise ValueError('SoundFont content differs from its bound snapshot')
    setting, synth = engine.settings(), None
    try:
        if not setting or (engine.setnum(setting, b'synth.sample-rate', rate) != 0
                or engine.setint(setting, b'synth.min-note-length', 0) != 0
                or engine.setstr(setting, b'synth.midi-bank-select', request['bankStyle'].encode()) != 0):
            raise ValueError('FluidSynth rejected stream settings')
        synth = engine.synth(setting)
        if not synth or engine.quantum(synth) != identity['controlFrames']:
            raise ValueError('FluidSynth stream allocation/control quantum mismatch')
        if engine.load(synth, font['path'].encode(), 1) < 0:
            raise ValueError('FluidSynth rejected the bound SF2')
        emit({'kind': 'ready', 'schemaVersion': 1, 'sampleRate': rate, 'channels': 2,
              'engine': identity, 'fontSha256': font['sha256'], 'bankStyle': request['bankStyle']})
        cursor, sequence, queued, held = 0, 0, [], {}
        quantum = identity['controlFrames']
        for line in sys.stdin:
            row = json.loads(line)
            if row.get('kind') == 'stop':
                if digest(font['path']) != font['sha256']:
                    raise ValueError('Bound SF2 changed during streaming')
                emit({'kind': 'stopped', 'frames': str(cursor)})
                return
            if row.get('kind') != 'render' or row.get('id') != sequence + 1:
                raise ValueError('Invalid SoundFont stream sequence')
            count = integer(row['frames'], 'stream frames', 2 ** 24)
            if not count or not isinstance(row['messages'], list):
                raise ValueError('Invalid SoundFont block request')
            pending, next_held, previous = [], dict(held), 0
            for event in row['messages']:
                offset = integer(event['frame'], 'message frame', count - 1)
                if offset < previous:
                    raise ValueError('Unordered SoundFont stream messages')
                previous = offset
                original = cursor + offset
                actual = ((original + quantum - 1) // quantum) * quantum
                data = event['bytes']
                if not isinstance(data, list) or not data:
                    raise ValueError('Missing MIDI stream message')
                for byte in data:
                    integer(byte, 'MIDI byte', 255)
                status, channel = data[0] & 240, data[0] & 15
                if not 128 <= data[0] < 240 or len(data) != (2 if status in (192, 208) else 3) or any(x > 127 for x in data[1:]):
                    raise ValueError('SoundFont input monitor requires MIDI1 channel messages')
                if status in (128, 144):
                    key = (channel, data[1])
                    if key in next_held:
                        start, sounding = next_held[key]
                        if original > start and actual == sounding:
                            raise ValueError('SoundFont control quantum collapses distinct live note boundaries')
                    if status == 144 and data[2]:
                        next_held[key] = (original, actual)
                    else:
                        next_held.pop(key, None)
                elif status == 176 and data[1] in (120, 123, 124, 125, 126, 127):
                    for key, (start, sounding) in list(next_held.items()):
                        if key[0] == channel:
                            if original > start and actual == sounding:
                                raise ValueError('SoundFont control quantum collapses a live note and channel release')
                            del next_held[key]
                pending.append((actual, data))
            held = next_held
            # Old deferred events precede newly arrived events at the same
            # absolute engine boundary. Never reset this queue at device cuts.
            queued.extend(pending)
            queued.sort(key=lambda event: event[0])
            end, chunks = cursor + count, []
            while cursor < end:
                while queued and queued[0][0] == cursor:
                    _, data = queued.pop(0)
                    engine.message(synth, data)
                after = min(end, queued[0][0] if queued else end)
                frames = after - cursor
                buffer = (c.c_float * (frames * 2))()
                if engine.render(synth, frames, buffer, 0, 2, buffer, 1, 2) != 0:
                    raise ValueError('FluidSynth stream rendering failed')
                if any(not math.isfinite(sample) for sample in buffer):
                    raise ValueError('Nonfinite SoundFont stream PCM')
                chunks.append(struct.pack('<%df' % len(buffer), *buffer))
                cursor = after
            sequence += 1
            emit({'kind': 'block', 'id': sequence, 'frames': count,
                  'pcm': base64.b64encode(b''.join(chunks)).decode('ascii')})
        raise ValueError('SoundFont stream closed without stop')
    finally:
        if synth:
            engine.free_synth(synth)
        if setting:
            engine.free_settings(setting)


if __name__ == '__main__':
    try:
        stream(json.loads(sys.stdin.readline()))
    except Exception as error:
        emit({'kind': 'error', 'message': str(error)})
        sys.exit(1)
