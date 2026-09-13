"""Synthetic receipt-validator checks; these never run installed inspection."""
import base64
import copy
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('verify-installed-media-inspection.py')
SPEC = importlib.util.spec_from_file_location('media_probe', SCRIPT)
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)
PNG = (SCRIPT.parent.parent / 'test/fixtures/verifier-image-lookup.png').read_bytes()


class TypedReceiptValidation(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.base = Path(temporary.name)
        self.source = {'path': str(self.base / 'original'), 'bytes': 7, 'sha256': PROBE.sha(b'fixture')}
        self.sequence = 0

    def document(self, kind='pdf'):
        page = {'page' if kind == 'pdf' else 'slide': 1, 'width_points': 10., 'height_points': 10.,
                'rendered_sha256': PROBE.sha(PNG), 'rendered_bytes': len(PNG)}
        data = dict(self.source, visual_input=True, inspection='synthetic fixture, not executed')
        if kind == 'pdf':
            data.update(media_type='application/pdf', page_count=1, pages=[page])
        else:
            data.update(media_type='application/vnd.openxmlformats-officedocument.presentationml.presentation',
                        slide_count=1, slides=[{'slide': 1, 'text': 'synthetic', 'speaker_notes': None}],
                        rendered_slides=[page], rendered_pdf_sha256='0' * 64, rendered_pdf_bytes=1,
                        not_inspected=['animations', 'embedded audio/video playback', 'chart data', 'accessibility verdict'])
        return self.envelope(data, [{'type': 'image', 'mimeType': 'image/png', 'data': base64.b64encode(PNG).decode()}])

    def envelope(self, data, content):
        return {'schema': 'masc.operator_file_inspection.v1', 'base_path': str(self.base),
                'source': self.source.copy(), 'llm_verdict': 'not_run',
                'result': {'disposition': 'completed', 'tool_name': 'inspect-file', 'data': data},
                'content': [{'type': 'text', 'text': json.dumps(data)}] + content}

    def video(self):
        inputs = ['-protocol_whitelist', 'file', '-f', 'mov', '-enable_drefs', '0', '-use_absolute_path', '0', '-i', 'capture.mp4']
        streams = [{'index': 0, 'kind': 'video'}, {'index': 1, 'kind': 'audio'}]
        media = dict(self.source, media_type='video/mp4', visual_input=False, streams=streams,
                     decoded_stream_indices=[0, 1], uninspected_stream_indices=[], audio_present=True, video_present=True,
                     inspection_scope='Synthetic decode fixture. No actual command executed.')
        media['probe'] = {'program': 'ffprobe', 'exit_code': 0, 'arguments': ['-v', 'error'] + inputs + ['-show_entries', 'format=format_name,duration:stream=index,codec_name,codec_type,width,height,channels,sample_rate,duration', '-of', 'json'],
                          'stdout': json.dumps({'streams': [{'index': 0, 'codec_type': 'video'}, {'index': 1, 'codec_type': 'audio'}]}), 'stderr': ''}
        media['full_decode'] = {'program': 'ffmpeg', 'exit_code': 0, 'arguments':
            ['-hide_banner', '-nostdin', '-v', 'error', '-xerror', '-err_detect', 'explode', '-abort_on', 'empty_output_stream'] + inputs
            + ['-map', '0:0', '-map', '0:1', '-f', 'null', '-'], 'stdout': '', 'stderr': ''}
        media['program_versions'] = [{'program': name, 'exit_code': 0, 'stdout': name + ' synthetic version'} for name in ['ffprobe', 'ffmpeg']]
        return self.envelope({'path': self.source['path'], 'inspection': media}, [])

    def validate(self, kind, payload):
        self.sequence += 1
        output = self.base / str(self.sequence)
        output.mkdir()
        return PROBE.validate_receipt(kind, payload, self.source, self.base, output)

    def reject(self, kind, payload, mutation):
        bad = copy.deepcopy(payload)
        mutation(bad)
        if bad.get('content') and isinstance(bad['content'][0], dict):
            bad['content'][0]['text'] = json.dumps(bad['result']['data'])
        with self.assertRaises((ValueError, TypeError, KeyError, IndexError)):
            self.validate(kind, bad)

    def test_required_typed_source_and_outcome_fields(self):
        payload = self.document()
        for mutation in [lambda p: p.pop('llm_verdict'), lambda p: p.update(llm_verdict='approved'),
                         lambda p: p['result'].update(disposition='failed'),
                         lambda p: p['source'].update(bytes=True), lambda p: p['source'].update(sha256='1' * 64),
                         lambda p: p.update(base_path='/another/workspace')]:
            self.reject('pdf', payload, mutation)

    def test_actual_png_bytes_are_saved_with_independent_identity(self):
        result = self.validate('pdf', self.document())
        self.assertEqual(result['rendered_images'][0]['sha256'], PROBE.sha(PNG))
        self.assertEqual((self.base / '1/page-001.png').read_bytes(), PNG)

    def test_missing_and_hash_consistent_but_truncated_png_are_rejected(self):
        payload = self.document()
        self.reject('pdf', payload, lambda p: p['content'].pop())
        def truncate(p):
            raw = PNG[:-12]
            p['content'][1]['data'] = base64.b64encode(raw).decode()
            p['result']['data']['pages'][0].update(rendered_bytes=len(raw), rendered_sha256=PROBE.sha(raw))
        self.reject('pdf', payload, truncate)

    def test_full_video_stream_maps_and_native_exit_are_required(self):
        payload = self.video()
        self.assertEqual(self.validate('mp4', payload)['decoded_stream_indices'], [0, 1])
        for mutation in [lambda p: p['result']['data']['inspection'].update(decoded_stream_indices=[0]),
                         lambda p: p['result']['data']['inspection']['full_decode'].update(exit_code=1),
                         lambda p: p['result']['data']['inspection']['full_decode'].update(exit_code=False),
                         lambda p: p['result']['data']['inspection'].update(visual_input=True),
                         lambda p: p['result']['data']['inspection'].pop('program_versions')]:
            self.reject('mp4', payload, mutation)

    def test_presentation_source_count_and_limits_are_required(self):
        payload = self.document('pptx')
        self.assertEqual(self.validate('pptx', payload)['pages'], 1)
        self.reject('pptx', payload, lambda p: p['result']['data'].update(slide_count=2))
        self.reject('pptx', payload, lambda p: p['result']['data'].update(not_inspected=[]))

    def test_png_without_pixel_data_is_rejected_even_with_matching_hash(self):
        def remove_pixels(payload):
            raw = PNG[:33] + PNG[-12:]
            payload['content'][1]['data'] = base64.b64encode(raw).decode()
            payload['result']['data']['pages'][0].update(rendered_bytes=len(raw), rendered_sha256=PROBE.sha(raw))
        self.reject('pdf', self.document(), remove_pixels)

    def test_partial_or_different_input_decode_is_rejected(self):
        payload = self.video()
        for option in [['-t', '0.01'], ['-frames:v', '1'], ['-ss', '1']]:
            self.reject('mp4', payload, lambda p: p['result']['data']['inspection']['full_decode']['arguments'].extend(option))
        def different_input(p):
            args = p['result']['data']['inspection']['full_decode']['arguments']
            args[args.index('-i') + 1] = 'another.mp4'
        self.reject('mp4', payload, different_input)

    def test_raw_audio_cannot_be_reclassified_to_skip_decoding(self):
        def omit_audio(p):
            media = p['result']['data']['inspection']
            media['streams'][1]['kind'] = 'unknown'
            media.update(decoded_stream_indices=[0], uninspected_stream_indices=[1], audio_present=False)
            args = media['full_decode']['arguments']
            index = args.index('0:1')
            del args[index - 1:index + 1]
        self.reject('mp4', self.video(), omit_audio)

    def test_duplicate_fields_are_not_silently_accepted(self):
        with self.assertRaises(ValueError):
            PROBE.decode('{"llm_verdict":"not_run","llm_verdict":"approved"}')


if __name__ == '__main__':
    unittest.main()
