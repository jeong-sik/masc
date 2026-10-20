import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import base64
from fractions import Fraction

import mido

from host import midi_timeline, snapshot, render


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


class NativeBoundaryTests(unittest.TestCase):
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
