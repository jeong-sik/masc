import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import base64
import hashlib
import math
from fractions import Fraction

import mido

from host import midi_timeline, frame_timeline, snapshot, render, digest, mix, ProjectedMidi


def encode(midi):
    buffer = io.BytesIO()
    midi.save(file=buffer)
    return buffer.getvalue()


class MidiPhraseTests(unittest.TestCase):
    def test_nonintegral_tempo_boundaries_keep_original_rational_horizon(self):
        midi = mido.MidiFile(type=1, ticks_per_beat=997)
        midi.tracks.append(mido.MidiTrack([
            mido.MetaMessage('set_tempo', tempo=437956),
            mido.Message('note_on', note=60, velocity=90),
            mido.MetaMessage('set_tempo', tempo=500003, time=123),
            mido.Message('control_change', control=11, value=80, time=101),
            mido.Message('note_off', note=60, time=773)]))
        events, duration = midi_timeline(encode(midi))
        self.assertEqual(events[1][1], Fraction(123 * 437956 + 101 * 500003, 997000000))
        self.assertEqual(duration, Fraction(123 * 437956 + 874 * 500003, 997000000))

    def test_tempo_tracks_and_note_positions_survive(self):
        midi = mido.MidiFile(type=1, ticks_per_beat=480)
        tempo = mido.MidiTrack([
            mido.MetaMessage("set_tempo", tempo=500000),
            mido.MetaMessage("set_tempo", tempo=1000000, time=480)])
        notes = mido.MidiTrack([
            mido.Message("note_on", note=36, velocity=80),
            mido.Message("note_off", note=36, time=240),
            mido.Message("note_on", note=37, velocity=80),
            mido.Message("note_off", note=37, time=240),
            mido.Message("note_on", note=38, velocity=80),
            mido.Message("note_off", note=38, time=480)])
        midi.tracks.extend([tempo, notes])
        events, duration = midi_timeline(encode(midi))
        self.assertEqual([time for _, time in events], [0, .25, .25, .5, .5, 1.5])
        self.assertEqual([message[1] for message, _ in events], [36, 36, 37, 37, 38, 38])
        self.assertEqual(duration, 1.5)

    def test_soundfont_program_does_not_replace_selected_vst_preset(self):
        midi = mido.MidiFile()
        midi.tracks.append(mido.MidiTrack([
            mido.Message("control_change", control=0, value=2),
            mido.Message("control_change", control=32, value=3),
            mido.Message("program_change", program=34),
            mido.Message("control_change", control=11, value=100),
            mido.Message("pitchwheel", pitch=1024),
            mido.Message("note_on", note=36, velocity=80),
            mido.Message("note_off", note=36, time=480)]))
        events, _ = midi_timeline(encode(midi))
        self.assertEqual([message[0] & 0xF0 for message, _ in events], [0xB0, 0xE0, 0x90, 0x80])
        self.assertEqual(events[0][0][1], 11)

    def test_empty_and_asynchronous_phrases_are_refused(self):
        for kind in (1, 2):
            midi = mido.MidiFile(type=kind)
            midi.tracks.append(mido.MidiTrack())
            with self.assertRaises(ValueError):
                midi_timeline(encode(midi))


class ProjectedArrangementTests(unittest.TestCase):
    def projection(self, folder, rows=None, duration=1.25):
        rows = rows if rows is not None else [
            {"seconds": 0, "bytes": [0xC0, 34]},
            {"seconds": 0, "bytes": [0xB0, 0, 2]},
            {"seconds": 0, "bytes": [0xB0, 64, 127]},
            {"seconds": 0, "bytes": [0x90, 48, 91]},
            {"seconds": 0, "bytes": [0x80, 48, 77]},
            {"seconds": 1.125, "bytes": [0xE0, 3, 65]},
            {"seconds": duration, "bytes": [0xB0, 64, 0]}]
        data = b''.join((json.dumps(row) + '\n').encode() for row in [
            {"schemaVersion": 1, "kind": "vst-midi-part", "duration": duration}, *rows])
        path = Path(folder) / 'part.jsonl'
        path.write_bytes(data)
        return {"timeline_path": str(path), "timeline_duration": duration,
                "timeline_event_count": len(rows), "timeline_sha256": hashlib.sha256(data).hexdigest()}

    def test_stream_preserves_expression_release_velocity_and_zero_length_order(self):
        with tempfile.TemporaryDirectory() as folder:
            request = self.projection(folder)
            with open(request['timeline_path'], 'rb') as stream:
                projected = ProjectedMidi(stream, request)
                self.assertEqual(list(projected), [
                    (bytes([0xB0, 64, 127]), 0), (bytes([0x90, 48, 91]), 0),
                    (bytes([0x80, 48, 77]), 0), (bytes([0xE0, 3, 65]), 1.125),
                    (bytes([0xB0, 64, 0]), 1.25)])
                self.assertTrue(projected.verified)

    def test_invalid_wire_time_count_and_bytes_are_refused(self):
        with tempfile.TemporaryDirectory() as folder:
            for rows in ([{"seconds": 0, "bytes": [0x90, 48]}],
                         [{"seconds": 0, "bytes": [0xF0, 1, 0xF8, 2, 0xF7]}],
                         [{"seconds": 0, "bytes": [True]}],
                         [{"seconds": 2, "bytes": [0xF8]}],
                         [{"seconds": 1, "bytes": [0xF8]}, {"seconds": 0, "bytes": [0xF8]}]):
                request = self.projection(folder, rows)
                with open(request['timeline_path'], 'rb') as stream:
                    with self.assertRaises(ValueError):
                        list(ProjectedMidi(stream, request))
            for key, value in [('timeline_sha256', '0' * 64), ('timeline_event_count', 99), ('timeline_duration', 2)]:
                request = {**self.projection(folder), key: value}
                with open(request['timeline_path'], 'rb') as stream:
                    with self.assertRaises(ValueError):
                        list(ProjectedMidi(stream, request))

    def test_render_uses_common_sample_grid_and_verifies_last_exclusive_cleanup(self):
        import numpy as np
        from pedalboard.io import AudioFile

        class Instrument:
            name, identifier, manufacturer_name, version, is_instrument = 'Test', 'test', 'Test', '1', True
            raw_state = b'state'

            def __init__(self):
                self.calls = []

            def __call__(self, events, **clock):
                self.calls.append((events, clock))
                return np.full((2, int(np.float32(clock['duration']) * np.float32(clock['sample_rate']))), .125, dtype=np.float32)

        with tempfile.TemporaryDirectory() as folder:
            request = {**self.projection(folder), 'output_path': str(Path(folder) / 'result.wav'),
                       'tail_seconds': 0, 'origin_seconds': .000123}
            instrument = Instrument()
            with patch('host.load_instrument', return_value=instrument):
                result = render(request)
            expected_origin = math.floor(Fraction(.000123) * 44100)
            self.assertEqual(result['frame_origin'], expected_origin)
            self.assertEqual(result['frames'], math.ceil((Fraction(.000123) + Fraction(1.25)) * 44100) - expected_origin)
            emitted = [event for events, _ in instrument.calls for event in events]
            self.assertEqual([list(data) for data, _ in emitted][:3], [[0xB0, 64, 127], [0x90, 48, 91], [0x80, 48, 77]])
            # Assert the sample frame decoded by the actual Float32 host ABI.
            native_frame = lambda value: int(np.float32(np.float32(value) * np.float32(44100)))
            self.assertEqual(native_frame(emitted[0][1]), math.ceil(Fraction(.000123) * 44100) - expected_origin)
            self.assertEqual(native_frame(emitted[3][1]), math.ceil((Fraction(.000123) + Fraction(1.125)) * 44100) - expected_origin - 44100)
            self.assertTrue(instrument.calls[0][1]['reset'])
            self.assertFalse(instrument.calls[1][1]['reset'])
            with AudioFile(request['output_path']) as audio:
                self.assertEqual(audio.frames, result['frames'])
            # A bad final digest may be discovered after rendering. No output
            # becomes visible and the private staging WAV is removed.
            target = Path(folder) / 'rejected.wav'
            with patch('host.load_instrument', return_value=Instrument()):
                with self.assertRaises(ValueError):
                    render({**request, 'output_path': str(target), 'timeline_sha256': '0' * 64})
            self.assertFalse(target.exists())
            self.assertFalse(list(Path(folder).glob('.vst-*.wav')))

    def test_mix_retains_overlaps_silence_and_clock_without_normalizing(self):
        import numpy as np
        from pedalboard.io import AudioFile

        with tempfile.TemporaryDirectory() as folder:
            parts = []
            for index, (origin, value) in enumerate([(2, .25), (4, .5)]):
                path = Path(folder) / f'part-{index}.wav'
                with AudioFile(str(path), 'w', 8, 2, bit_depth=32) as audio:
                    audio.write(np.full((2, 4), value, dtype=np.float32))
                parts.append({'output_path': str(path), 'wav_sha256': hashlib.sha256(path.read_bytes()).hexdigest(),
                              'frames': 4, 'frame_origin': origin})
            target = Path(folder) / 'mixed.wav'
            request = {'parts': parts, 'sample_rate': 8, 'frames': 10, 'output_path': str(target)}
            result = mix(request)
            self.assertEqual(result['peak'], .75)
            with AudioFile(str(target)) as audio:
                np.testing.assert_array_equal(audio.read(10), np.array([[0, 0, .25, .25, .75, .75, .5, .5, 0, 0]] * 2))
            parts[0]['wav_sha256'] = '0' * 64
            rejected = Path(folder) / 'rejected.wav'
            with self.assertRaises(ValueError):
                mix({**request, 'output_path': str(rejected)})
            self.assertFalse(rejected.exists())

    def test_silent_note_instance_fails_independently_but_control_only_instance_is_valid(self):
        import numpy as np

        class Silent:
            name, identifier, manufacturer_name, version, is_instrument = 'Silent', 'silent', 'Test', '1', True
            raw_state = b'state'

            def __call__(self, events, **clock):
                return np.zeros((2, int(np.float32(clock['duration']) * np.float32(clock['sample_rate']))), dtype=np.float32)

        with tempfile.TemporaryDirectory() as folder:
            # This last block previously became26890 frames after the native
            # float32 API conversion although the admitted PCM clock needs26891.
            duration = math.nextafter(26891 / 44100, 0)
            for note in (False, True):
                rows = [{'seconds': 0, 'bytes': [0x90, 60, 90] if note else [0xB0, 11, 90]}]
                request = {**self.projection(folder, rows, duration), 'tail_seconds': 0,
                           'output_path': str(Path(folder) / f'{note}.wav')}
                with patch('host.load_instrument', return_value=Silent()):
                    if note:
                        with self.assertRaisesRegex(ValueError, 'produced silence'):
                            render(request)
                        self.assertFalse(Path(request['output_path']).exists())
                    else:
                        result = render(request)
                        self.assertEqual(result['frames'], 26891)
                        self.assertEqual(result['peak'], 0)


class NativeBoundaryTests(unittest.TestCase):
    def test_private_frame_timeline_preserves_equal_time_order_and_block_edge_samples(self):
        import numpy as np
        from pedalboard.io import AudioFile
        class Plugin:
            name = 'Fixture'
            identifier = 'FixtureID'
            manufacturer_name = 'Fixture'
            version = '1'
            is_instrument = True
            raw_state = b'fixture'
            def __init__(self):
                self.calls = []
            def __call__(self, events, *, duration, sample_rate, num_channels, reset):
                count = int(np.float32(duration) * np.float32(sample_rate))
                positions = [int(np.float32(time) * np.float32(sample_rate)) for _, time in events]
                self.calls.append((count, positions, [bytes(message) for message, _ in events], reset))
                return np.ones((num_channels, count), dtype=np.float32) * .01
        value = {"schemaVersion": 1, "kind": "practice-vst", "sampleRate": 44100, "frames": "44107", "events": [
            {"frame": "0", "bytes": [0x92, 60, 90]}, {"frame": "7", "bytes": [0xb2, 74, 85]},
            {"frame": "7", "bytes": [0xe2, 0, 64]}, {"frame": "44100", "bytes": [0xb2, 74, 86]},
            {"frame": "44106", "bytes": [0x82, 60, 9]}]}
        data, plugin = json.dumps(value).encode(), Plugin()
        with tempfile.TemporaryDirectory() as folder, patch('host.load_instrument', return_value=plugin):
            source, target = Path(folder) / 'frames.json', Path(folder) / 'render.wav'
            source.write_bytes(data)
            result = render({'frames_path': str(source), 'expected_timeline_sha256': digest(data),
                             'output_path': str(target), 'sample_rate': 44100, 'tail_seconds': 0})
            self.assertEqual([call[:2] for call in plugin.calls], [(44100, [0, 7, 7]), (7, [0, 6])])
            self.assertEqual([call[3] for call in plugin.calls], [True, False])
            self.assertEqual(result['timeline_sha256'], digest(data))
            self.assertNotIn('midi_sha256', result)
            with AudioFile(str(target)) as audio:
                self.assertEqual(audio.frames, 44107)

    def test_bad_frame_timeline_is_refused_before_plugin_load_or_output_publication(self):
        base = {"schemaVersion": 1, "kind": "practice-vst", "sampleRate": 48000, "frames": "2",
                "events": [{"frame": "0", "bytes": [0x92, 60, 90]}, {"frame": "1", "bytes": [0x82, 60, 0]}]}
        cases = [
            {**base, 'frames': '0'}, {**base, 'frames': '02'}, {**base, 'frames': '18446744073709551616'},
            {**base, 'schemaVersion': True}, {**base, 'sampleRate': 44100}, {**base, 'events': []},
            {**base, 'events': [base['events'][1], base['events'][0]]},
            *[{**base, 'events': [{'frame': frame, 'bytes': message}]} for frame, message in [
                ('-1', [0x92, 60, 90]), ('2', [0x92, 60, 90]), ('０', [0x92, 60, 90]),
                ('0', [0xc2, 2]), ('0', [0xb2, 0, 2]), ('0', [0xb2, 32, 2]),
                ('0', [0x92, 128, 90]), ('0', [0x92, 60, True]), ('0', [0x92, 60])]]]
        with tempfile.TemporaryDirectory() as folder, patch('host.load_instrument') as load:
            source, target = Path(folder) / 'frames.json', Path(folder) / 'render.wav'
            for value in cases:
                data = json.dumps(value).encode(); source.write_bytes(data)
                with self.subTest(value=value), self.assertRaises(ValueError):
                    render({'frames_path': str(source), 'expected_timeline_sha256': digest(data),
                            'output_path': str(target), 'sample_rate': 48000, 'tail_seconds': 0})
                self.assertFalse(target.exists())
            data = json.dumps(base).encode(); source.write_bytes(data)
            with self.assertRaises(ValueError):
                frame_timeline(data, digest(b'changed'), 48000)
            load.assert_not_called()

    def test_render_crosses_blocks_without_losing_event_or_final_output_samples(self):
        # Pinned Pedalboard accepts Float32 timestamp, duration and sampleRate,
        # then truncates their Float32 product. Exercise the full host render
        # through that ABI seam and its actual AudioFile streaming/publishing.
        import numpy as np
        from pedalboard.io import AudioFile
        class Plugin:
            name = 'Fixture'
            identifier = 'FixtureID'
            manufacturer_name = 'Fixture'
            version = '1'
            is_instrument = True
            raw_state = b'fixture'
            calls = []

            def __call__(self, events, *, duration, sample_rate, num_channels, reset):
                count = int(np.float32(duration) * np.float32(sample_rate))
                positions = [int(np.float32(time) * np.float32(sample_rate)) for _, time in events]
                self.calls.append((count, positions, [bytes(message) for message, _ in events], reset))
                return np.ones((num_channels, count), dtype=np.float32) * .01

        midi = mido.MidiFile(type=0, ticks_per_beat=22050)
        midi.tracks.append(mido.MidiTrack([
            mido.Message('note_on', note=60, velocity=90),
            mido.Message('control_change', control=11, value=80, time=7),
            mido.Message('pitchwheel', pitch=10),
            mido.Message('control_change', control=11, value=81, time=44093),
            mido.Message('note_off', note=60, time=6),
            mido.MetaMessage('end_of_track', time=1)]))
        plugin = Plugin()
        with tempfile.TemporaryDirectory() as folder, patch('host.load_instrument', return_value=plugin):
            source, target = Path(folder) / 'source.mid', Path(folder) / 'render.wav'
            source.write_bytes(encode(midi))
            result = render({'midi_path': str(source), 'output_path': str(target), 'sample_rate': 44100, 'tail_seconds': 0})
            self.assertEqual([call[:2] for call in plugin.calls], [(44100, [0, 7, 7]), (7, [0, 6])])
            self.assertEqual([call[3] for call in plugin.calls], [True, False])
            self.assertEqual(result['frames'], 44107)
            self.assertEqual(plugin.calls[0][2][1][0], 0xb0)
            self.assertEqual(plugin.calls[0][2][2][0], 0xe0)
            with AudioFile(str(target)) as audio:
                self.assertEqual(audio.frames, 44107)
                self.assertTrue(np.all(audio.read(audio.frames) > 0))

    def test_default_and_external_preset_are_captured_without_editor_or_mutable_path(self):
        class Plugin:
            name = 'Bass'
            identifier = 'BassID'
            manufacturer_name = 'Test'
            version = '1.2'
            is_instrument = True
            preset_data = b'captured default'

            def load_preset(self, path):
                self.loaded_path = path
                self.preset_data = Path(path).read_bytes()

        plugin = Plugin()
        with patch('host.load_instrument', return_value=plugin):
            default = snapshot({})
            self.assertEqual(base64.b64decode(default['preset']['data']), b'captured default')
            self.assertEqual(default['instrument']['identifier'], 'BassID')
            with tempfile.TemporaryDirectory() as folder:
                source = Path(folder) / 'external.vstpreset'
                source.write_bytes(b'external state')
                result = snapshot({'preset_path': str(source)})
                source.write_bytes(b'replaced state')
                self.assertEqual(base64.b64decode(result['preset']['data']), b'external state')
                self.assertNotEqual(plugin.loaded_path, str(source))
                self.assertFalse(Path(plugin.loaded_path).exists())

    def job(self, request):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("host.py"))],
                                input=json.dumps(request), capture_output=True, text=True)
        return result.returncode, json.loads(result.stdout)

    def test_invalid_instrument_reports_failure_without_an_audio_file(self):
        with tempfile.TemporaryDirectory() as directory:
            midi = mido.MidiFile()
            midi.tracks.append(mido.MidiTrack([
                mido.Message("note_on", note=36, velocity=80),
                mido.Message("note_off", note=36, time=480)]))
            source = Path(directory, "phrase.mid")
            source.write_bytes(encode(midi))
            target = Path(directory, "phrase.wav")
            code, reply = self.job({"operation": "render", "midi_path": str(source),
                                    "output_path": str(target), "plugin_path": str(Path(directory, "absent.vst3"))})
            self.assertNotEqual(code, 0)
            self.assertFalse(reply["ok"])
            self.assertFalse(target.exists())

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory, "existing.wav")
            target.write_bytes(b"keep")
            code, reply = self.job({"operation": "render", "midi_path": "absent.mid",
                                    "output_path": str(target)})
            self.assertNotEqual(code, 0)
            self.assertFalse(reply["ok"])
            self.assertEqual(target.read_bytes(), b"keep")

    def test_unknown_operation_is_a_single_machine_readable_refusal(self):
        code, reply = self.job({"operation": "unknown"})
        self.assertNotEqual(code, 0)
        self.assertFalse(reply["ok"])


if __name__ == "__main__":
    unittest.main()
