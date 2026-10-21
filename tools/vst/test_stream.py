import base64
import io
import json
import unittest
from unittest.mock import patch
from pathlib import Path
import numpy as np

from host import stream_synthesis, digest


class Instrument:
    name = 'Fixture'
    identifier = 'fixture-id'
    manufacturer_name = 'Fixture'
    version = '1'
    is_instrument = True

    def __init__(self):
        self.calls, self.held, self.resets = [], set(), 0

    def load_preset(self, path):
        self.path = path
        self.preset = Path(path).read_bytes()

    def reset(self):
        self.resets += 1
        self.held.clear()

    def __call__(self, events, *, duration, sample_rate, num_channels, reset):
        if reset:
            self.reset()
        count = int(np.float32(duration) * np.float32(sample_rate))
        positions = [int(np.float32(time) * np.float32(sample_rate)) for _, time in events]
        self.calls.append((count, positions, [bytes(msg) for msg, _ in events], reset))
        audio = np.zeros((2, count), dtype=np.float32)
        cursor = 0
        for (message, _), offset in zip(events, positions):
            audio[0, cursor:offset] = .25 if self.held else 0
            audio[1, cursor:offset] = -.125 if self.held else 0
            if message[0] & 0xf0 == 0x90 and message[2]:
                self.held.add(message[1])
            elif message[0] & 0xf0 == 0x80 or (message[0] & 0xf0 == 0x90 and not message[2]):
                self.held.discard(message[1])
            cursor = offset
        audio[0, cursor:] = .25 if self.held else 0
        audio[1, cursor:] = -.125 if self.held else 0
        return audio


def opening(**overrides):
    data = b'owned sound'
    return {'kind': 'open', 'schemaVersion': 1, 'sampleRate': 44100,
            'instrument': {'identifier': 'fixture-id', 'version': '1'},
            'preset': {'data': base64.b64encode(data).decode(), 'sha256': digest(data)}, **overrides}


def block(identifier, frames, *messages):
    return {'kind': 'render', 'id': identifier, 'frames': frames,
            'messages': [{'frame': offset, 'bytes': values} for offset, values in messages]}


class StreamTests(unittest.TestCase):
    def run_stream(self, commands, plugin=None):
        plugin = plugin or Instrument()
        replies = []
        with patch('host.load_instrument', return_value=plugin):
            stream_synthesis(io.StringIO(''.join(json.dumps(row) + '\n' for row in commands)), replies.append)
        return plugin, replies

    def test_held_key_and_release_cross_blocks_with_exact_stereo_sample_offsets(self):
        plugin, replies = self.run_stream([opening(),
            block(1, 7, (6, [0x90, 60, 100])), block(2, 13),
            block(3, 9, (0, [0xb0, 11, 80]), (7, [0x80, 60, 20])), {'kind': 'stop'}])
        audio = [np.frombuffer(base64.b64decode(row['pcm']), dtype='<f4').reshape(-1, 2)
                 for row in replies if row['kind'] == 'block']
        self.assertEqual([row.shape for row in audio], [(7, 2), (13, 2), (9, 2)])
        np.testing.assert_array_equal(audio[0][:6], 0)
        np.testing.assert_array_equal(audio[0][6], [.25, -.125])
        np.testing.assert_array_equal(audio[1], np.tile([.25, -.125], (13, 1)))
        np.testing.assert_array_equal(audio[2][:7], np.tile([.25, -.125], (7, 1)))
        np.testing.assert_array_equal(audio[2][7:], 0)
        self.assertEqual([row[3] for row in plugin.calls], [True, False, False])
        self.assertEqual(replies[-1], {'kind': 'stopped', 'frames': '29'})
        self.assertEqual(plugin.preset, b'owned sound')
        self.assertFalse(Path(plugin.path).exists())
        self.assertEqual(plugin.held, set())

    def test_preset_bank_program_exclusion_retains_expression_and_order(self):
        values = [[0xb0, 0, 1], [0xb0, 32, 2], [0xc0, 10],
                  [0xb0, 64, 127], [0xe0, 1, 65], [0xd0, 80], [0xa0, 60, 30], [0x90, 60, 90]]
        plugin, _ = self.run_stream([opening(), block(1, 8, *[(0, row) for row in values]), {'kind': 'stop'}])
        self.assertEqual(plugin.calls[0][2], [bytes(row) for row in values[3:]])

    def test_malformed_block_is_refused_before_any_partial_processing(self):
        for bad in [block(1, 8, (0, [0x90, 60, 90]), (8, [0x80, 60, 0])),
                    block(1, 8, (3, [0x90, 60, 90]), (2, [0x80, 60, 0])),
                    block(1, 8, (0, [0x90, 60, 90, 0])), block(1, 0), block(2, 8),
                    block(1, 8, (0, [0x90, 128, 90])), block(1, 8, (False, [0x90, 60, 90]))]:
            with self.subTest(bad=bad):
                plugin = Instrument()
                with self.assertRaises(ValueError):
                    self.run_stream([opening(), bad], plugin)
                self.assertEqual(plugin.calls, [])

    def test_identity_and_corrupt_preset_are_refused_before_pcm(self):
        for request in [opening(instrument={'identifier': 'other', 'version': '1'}),
                        opening(preset={'data': 'YQ==', 'sha256': 'changed'}),
                        opening(sampleRate=44100.5), opening(sampleRate=True), opening(schemaVersion=True)]:
            plugin = Instrument()
            with self.assertRaises(ValueError):
                self.run_stream([request, block(1, 7)], plugin)
            self.assertEqual(plugin.calls, [])

    def test_unexpected_eof_and_invalid_audio_fail_and_release_owned_state(self):
        plugin = Instrument()
        with self.assertRaisesRegex(ValueError, 'without stop'):
            self.run_stream([opening(), block(1, 7, (0, [0x90, 60, 90]))], plugin)
        self.assertEqual(plugin.held, set())
        class Invalid(Instrument):
            def __call__(self, *args, **kwargs):
                return np.full((2, 7), np.nan)
        with self.assertRaisesRegex(ValueError, 'invalid streaming audio'):
            self.run_stream([opening(), block(1, 7)], Invalid())


if __name__ == '__main__':
    unittest.main()
