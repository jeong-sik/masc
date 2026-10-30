"""Frozen ordered effect chains: native boundary decisions, not audio-device tests."""
import base64
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
from pedalboard.io import AudioFile

import host
import test_host as fixtures


def frozen(data):
    return {"data": base64.b64encode(data).decode("ascii"), "sha256": host.digest(data)}


def binding(name):
    return {"kind": "vst-effect", "selection": {"plugin_path": "/" + name + ".vst3", "preset_path": "/gone.vstpreset"},
            "preset": frozen(name.encode()), "plugin": {"identifier": name, "version": "1"}}


class Effect(fixtures.Kept):
    is_instrument, is_effect, reported_latency_samples = False, True, 0

    def __init__(self, name, transform=lambda audio: audio):
        super().__init__()
        self.name = self.identifier = name
        self.transform, self.calls, self.resets = transform, [], 0

    def process(self, audio, *, sample_rate, reset):
        self.calls.append(reset)
        return self.transform(audio)

    def reset(self):
        self.resets += 1

    def show_editor(self):
        self.preset_data = b'edited'


class Instrument(fixtures.Kept):
    def reset(self):
        pass


class EffectTests(unittest.TestCase):
    def test_edit_checks_old_identity_before_loading_bytes_or_opening_editor(self):
        effect = Effect('delay')
        request = {**binding('delay')['selection'], 'preset': frozen(b'owned'), 'expected_plugin': {'identifier': 'delay', 'version': '1'}, 'edit': True}
        with patch('host.load_effect', return_value=effect):
            result = host.effect_snapshot(request)
            self.assertEqual(result['preset'], frozen(b'edited'))
            effect.preset_data = b'untouched'
            with self.assertRaisesRegex(ValueError, 'identity/version'):
                host.effect_snapshot({**request, 'expected_plugin': {'identifier': 'delay', 'version': '2'}})
            self.assertEqual(effect.preset_data, b'untouched')

    def test_instrument_cannot_be_loaded_as_an_effect(self):
        with patch('pedalboard.load_plugin', return_value=type('Synth', (), {'name': 'Synth', 'is_effect': False})()):
            with self.assertRaisesRegex(ValueError, 'MIDI instrument'):
                host.load_effect({'plugin_path': '/synth.vst3'})

    def test_frozen_preset_integrity_and_missing_or_changed_plugin_fail_before_admission(self):
        for change in ['preset', 'version', 'missing']:
            effect, saved = Effect('delay'), binding('delay')
            if change == 'preset':
                saved['preset']['sha256'] = '0' * 64
            if change == 'version':
                saved['plugin']['version'] = '2'
            with self.subTest(change=change), patch('host.load_effect', side_effect=FileNotFoundError('missing') if change == 'missing' else None, return_value=effect):
                with self.assertRaises((ValueError, FileNotFoundError)):
                    host.load_effect_chain([saved], 48000)

    def test_chain_preserves_order_and_uses_only_owned_preset_bytes(self):
        first, second = Effect('gain', lambda audio: audio * 2), Effect('offset', lambda audio: audio + .1)
        saved = [binding('gain'), binding('offset')]
        with patch('host.load_effect', side_effect=[first, second]):
            plugins, receipts = host.load_effect_chain(saved, 48000)
        self.assertEqual(first.preset_data, b'gain')
        self.assertEqual(second.preset_data, b'offset')
        self.assertEqual(receipts, [{**value['plugin'], 'preset_sha256': value['preset']['sha256']} for value in saved])
        for reset in [True, False]:
            result = host.process_effect_chain(plugins, np.full((2, 7), .125, dtype=np.float32), 48000, reset)
            np.testing.assert_allclose(result, .35)
        self.assertEqual(first.calls, [True, True, False])  # Admission probe, then two native blocks.

    def test_buffered_and_nonfinite_are_refused_before_stream_ready_or_offline_publication(self):
        for effect in [Effect('delay', lambda audio: audio[:, :-1]), Effect('delay', lambda audio: audio * np.nan)]:
            with self.subTest(effect=effect), patch('host.load_effect', return_value=effect), patch('host.load_instrument', return_value=Instrument()):
                commands = [{"kind": "open", "schemaVersion": 1, "sampleRate": 48000, "plugin_path": "/synth.vst3",
                             "instrument": {"identifier": "kept", "version": "1"}, "preset": frozen(b'synth'), "effects": [binding('delay')]}, {"kind": "stop"}]
                replies = []
                with self.assertRaises(ValueError):
                    host.stream_synthesis(io.StringIO(''.join(json.dumps(row) + '\n' for row in commands)), replies.append)
                self.assertEqual(replies, [])
                with tempfile.TemporaryDirectory() as folder:
                    request = fixtures.ServeTests().bound_render(folder, 'fail', b'synth')
                    request['effects'] = [binding('delay')]
                    with self.assertRaises(ValueError):
                        host.render(request)
                    self.assertFalse(Path(request['output_path']).exists())

    def test_offline_and_live_blocks_process_same_chain_and_preserve_histories_after_first_block(self):
        saved = [binding('gain'), binding('offset')]
        effects = lambda: [Effect('gain', lambda audio: audio * 2), Effect('offset', lambda audio: audio + .1)]
        offline = effects()
        offline[0].reported_latency_samples = 62  # Compensated full blocks remain admissible.
        with tempfile.TemporaryDirectory() as folder, patch('host.load_effect', side_effect=offline), patch('host.load_instrument', return_value=Instrument()):
            request = fixtures.ServeTests().bound_render(folder, 'wet', b'synth')
            receipt = host.render({**request, 'effects': saved})
            with AudioFile(request['output_path']) as wave:
                np.testing.assert_allclose(wave.read(wave.frames), .35)
            self.assertEqual(offline[0].calls, [True, True, False])
        live = effects()
        commands = [{"kind": "open", "schemaVersion": 1, "sampleRate": 48000, "plugin_path": "/synth.vst3",
                     "instrument": {"identifier": "kept", "version": "1"}, "preset": frozen(b'synth'), "effects": saved},
                    {"kind": "render", "id": 1, "frames": 7, "messages": [{"frame": 0, "bytes": [0x90, 60, 90]}]},
                    {"kind": "render", "id": 2, "frames": 11, "messages": []}, {"kind": "stop"}]
        replies = []
        with patch('host.load_effect', side_effect=live), patch('host.load_instrument', return_value=Instrument()):
            host.stream_synthesis(io.StringIO(''.join(json.dumps(row) + '\n' for row in commands)), replies.append)
        self.assertEqual(receipt['effects'], replies[0]['effects'])
        for block in replies[1:3]:
            np.testing.assert_allclose(np.frombuffer(base64.b64decode(block['pcm']), dtype='<f4'), .35)
        self.assertEqual(live[0].calls, [True, True, False])
        self.assertEqual(live[0].resets, 2)  # After probe and at stream close.
