"""Run the installed media CLI on three explicit original artifacts.

This records native parsing/rendering/decode evidence, not an LLM verdict or
Task/Goal approval. It never submits work, replaces a server, or installs tools.
"""
import argparse
import base64
import hashlib
import importlib.util
import io
import json
import math
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import zlib


CAPTURE_SCRIPT = Path(__file__).with_name('capture-collaboration-state.py')
SPEC = importlib.util.spec_from_file_location('collaboration_state', CAPTURE_SCRIPT)
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON field: ' + key)
        result[key] = value
    return result


def decode(raw):
    return json.loads(raw, object_pairs_hook=unique_fields)


def save(path, value):
    with path.open('x') as output:
        path.chmod(0o600)
        json.dump(value, output, ensure_ascii=False, indent=2, allow_nan=False)
        output.write('\n')


def count(value, label, positive=False):
    require(type(value) is int and value >= (1 if positive else 0), label + ' must be an integer count')
    return value


def identity_matches(actual, expected, label):
    require(type(actual) is dict, label + ' must be an object')
    require(actual.get('sha256') == expected['sha256'], label + ' SHA-256 mismatch')
    require(count(actual.get('bytes'), label + ' bytes') == expected['bytes'], label + ' byte count mismatch')


def png_dimensions(raw):
    require(raw[:8] == b'\x89PNG\r\n\x1a\n', 'invalid PNG signature')
    offset, dimensions, ended = 8, None, False
    while offset < len(raw):
        require(offset + 12 <= len(raw), 'truncated PNG chunk')
        length = struct.unpack('>I', raw[offset:offset + 4])[0]
        tag = raw[offset + 4:offset + 8]
        end = offset + 12 + length
        require(end <= len(raw), 'truncated PNG payload')
        require(zlib.crc32(raw[offset + 4:end - 4]) == struct.unpack('>I', raw[end - 4:end])[0], 'PNG chunk CRC mismatch')
        if dimensions is None:
            require(tag == b'IHDR' and length == 13, 'missing PNG IHDR')
            dimensions = struct.unpack('>II', raw[offset + 8:offset + 16])
            require(all(value > 0 for value in dimensions), 'empty rendered PNG')
        offset = end
        if tag == b'IEND':
            require(length == 0 and offset == len(raw), 'invalid PNG termination')
            ended = True
            break
    require(ended and dimensions is not None, 'incomplete PNG file')
    try:
        from PIL import Image
        with Image.open(io.BytesIO(raw)) as image:
            require(image.format == 'PNG', 'rendered content is not PNG')
            image.verify()
        with Image.open(io.BytesIO(raw)) as image:
            image.load()
            require(image.size == dimensions, 'decoded PNG geometry mismatch')
    except (OSError, SyntaxError) as error:
        raise ValueError('rendered PNG cannot be decoded: ' + str(error)) from error
    return dimensions


def validate_receipt(kind, payload, expected, base, output):
    """Validate typed CLI evidence against independently read source bytes.

    The caller separately proves the executed installed binary's identity.
    Validation alone cannot prove that an arbitrary JSON producer ran a decoder.
    """
    require(type(payload) is dict and payload.get('schema') == 'masc.operator_file_inspection.v1', 'wrong CLI schema')
    require(payload.get('base_path') == str(base), 'CLI selected a different workspace')
    require(payload.get('llm_verdict') == 'not_run', 'CLI must explicitly report no LLM verdict')
    source = payload.get('source')
    identity_matches(source, expected, 'original source')
    require(source.get('path') == expected['path'], 'CLI inspected another source path')
    result = payload.get('result')
    require(type(result) is dict and result.get('disposition') == 'completed',
            'native inspection did not complete: ' + json.dumps(result, ensure_ascii=False))
    require(result.get('tool_name') == 'inspect-file', 'unexpected operation result')
    data, content = result.get('data'), payload.get('content')
    require(type(data) is dict and type(content) is list and content, 'missing inspection data or content')
    require(all(type(item) is dict for item in content), 'invalid typed content item')
    require(content[0].get('type') == 'text' and decode(content[0]['text']) == data,
            'CLI content and structured inspection disagree')
    require(data.get('path') == expected['path'], 'inspection data source path mismatch')
    if kind == 'mp4':
        media = data.get('inspection')
        identity_matches(media, expected, 'decoded MP4')
        require(media.get('media_type') == 'video/mp4' and media.get('visual_input') is False,
                'MP4 decode must not claim visual inspection')
        streams = media.get('streams')
        require(type(streams) is list and streams and all(type(row) is dict for row in streams), 'missing parsed video streams')
        indices = [count(row.get('index'), 'stream index') for row in streams]
        require(len(set(indices)) == len(indices), 'duplicate stream index')
        kinds = {'video', 'audio', 'subtitle', 'data', 'attachment', 'unknown'}
        require(all(row.get('kind') in kinds for row in streams), 'invalid stream kind')
        decoded = [row['index'] for row in streams if row['kind'] in {'video', 'audio'}]
        other = [row['index'] for row in streams if row['kind'] not in {'video', 'audio'}]
        require(decoded and media.get('decoded_stream_indices') == decoded, 'not every audio/video stream was decoded')
        require(media.get('uninspected_stream_indices') == other, 'uninspected streams were hidden')
        require(media.get('audio_present') is any(row['kind'] == 'audio' for row in streams), 'audio presence mismatch')
        require(media.get('video_present') is any(row['kind'] == 'video' for row in streams), 'video presence mismatch')
        for key, program in [('probe', 'ffprobe'), ('full_decode', 'ffmpeg')]:
            command = media.get(key)
            require(type(command) is dict and command.get('program') == program, 'missing actual ' + program + ' result')
            require(type(command.get('exit_code')) is int and command['exit_code'] == 0, program + ' did not succeed')
            require(type(command.get('stdout')) is str and type(command.get('stderr')) is str, 'missing raw command output')
            arguments = command.get('arguments')
            require(type(arguments) is list and all(type(item) is str for item in arguments), 'invalid command arguments')
            for option, value in [('-protocol_whitelist', 'file'), ('-enable_drefs', '0'), ('-use_absolute_path', '0')]:
                require(arguments.count(option) == 1 and arguments[arguments.index(option) + 1] == value,
                        'unsafe or missing MP4 input option: ' + option)
            require(any(arguments[i:i + 2] == ['-f', 'mov'] for i in range(len(arguments) - 1)), 'missing fixed MP4 demuxer')
            (output / (program + '.stdout.txt')).write_text(command['stdout'])
            (output / (program + '.stderr.txt')).write_text(command['stderr'])
        probe_args = media['probe']['arguments']
        require(probe_args.count('-i') == 1, 'probe must have one captured input')
        capture_input = probe_args[probe_args.index('-i') + 1]
        require(bool(capture_input), 'empty captured input')
        common_input = ['-protocol_whitelist', 'file', '-f', 'mov', '-enable_drefs', '0',
                        '-use_absolute_path', '0', '-i', capture_input]
        require(probe_args == ['-v', 'error'] + common_input + [
            '-show_entries', 'format=format_name,duration:stream=index,codec_name,codec_type,width,height,channels,sample_rate,duration',
            '-of', 'json'], 'probe arguments differ from the complete original inspection contract')
        arguments = media['full_decode']['arguments']
        expected_decode = ['-hide_banner', '-nostdin', '-v', 'error', '-xerror',
                           '-err_detect', 'explode', '-abort_on', 'empty_output_stream']
        expected_decode += common_input
        expected_decode += [part for index in decoded for part in ['-map', '0:' + str(index)]]
        expected_decode += ['-f', 'null', '-']
        require(arguments == expected_decode, 'decode must consume every selected stream from the same single input without limits')
        require(arguments[-3:] == ['-f', 'null', '-'], 'decode did not consume the whole stream to the null sink')
        require('-xerror' in arguments and '-nostdin' in arguments, 'strict complete decoder flags missing')
        for option, value in [('-err_detect', 'explode'), ('-abort_on', 'empty_output_stream')]:
            require(arguments.count(option) == 1 and arguments[arguments.index(option) + 1] == value, 'decoder strictness missing')
        maps = [arguments[i + 1] for i, item in enumerate(arguments) if item == '-map']
        require(maps == ['0:' + str(index) for index in decoded], 'decoder maps do not match every selected stream')
        raw_probe = decode(media['probe']['stdout'])
        require(type(raw_probe) is dict and type(raw_probe.get('streams')) is list, 'invalid raw FFprobe output')
        require([row['index'] for row in raw_probe['streams']] == indices, 'raw probe and typed stream identity disagree')
        raw_kinds = [row.get('codec_type') if row.get('codec_type') in kinds else 'unknown' for row in raw_probe['streams']]
        require(raw_kinds == [row['kind'] for row in streams], 'raw probe and typed stream kinds disagree')
        versions = media.get('program_versions')
        require(type(versions) is list and all(type(row) is dict for row in versions)
                and sorted(row.get('program', '') for row in versions) == ['ffmpeg', 'ffprobe'], 'missing native program versions')
        for row in versions:
            require(type(row.get('exit_code')) is int and row['exit_code'] == 0 and
                    type(row.get('stdout')) is str and row['stdout'], 'native version probe failed')
            (output / (row['program'] + '.version.txt')).write_text(row['stdout'])
        require(type(media.get('inspection_scope')) is str and media['inspection_scope'], 'missing decode scope')
        require(all(item.get('type') == 'text' for item in content), 'MP4 result unexpectedly claimed rendered media')
        return {'source': source, 'decoded_stream_indices': decoded,
                'uninspected_stream_indices': other, 'inspection_scope': media['inspection_scope'], 'rendered_images': []}

    identity_matches(data, expected, 'inspected document')
    require(data.get('visual_input') is True, 'document did not provide rendered content')
    if kind == 'pdf':
        require(data.get('media_type') == 'application/pdf', 'wrong PDF type')
        size = count(data.get('page_count'), 'page count', positive=True)
        pages, ordinal = data.get('pages'), 'page'
    else:
        require(data.get('media_type') == 'application/vnd.openxmlformats-officedocument.presentationml.presentation', 'wrong PPTX type')
        size = count(data.get('slide_count'), 'slide count', positive=True)
        slides = data.get('slides')
        require(type(slides) is list and all(type(row) is dict for row in slides) and
                [row.get('slide') for row in slides] == list(range(1, size + 1)), 'source slide order/count mismatch')
        require(all(type(row.get('text')) is str and (row.get('speaker_notes') is None or type(row['speaker_notes']) is str)
                    for row in slides), 'missing source slide text or typed notes')
        require(type(data.get('not_inspected')) is list and
                {'animations', 'embedded audio/video playback', 'chart data', 'accessibility verdict'} <= set(data['not_inspected']),
                'presentation inspection limits were hidden')
        require(re.fullmatch('[0-9a-f]{64}', data.get('rendered_pdf_sha256', '')), 'missing rendered PDF identity')
        count(data.get('rendered_pdf_bytes'), 'rendered PDF bytes', positive=True)
        pages, ordinal = data.get('rendered_slides'), 'slide'
    require(type(pages) is list and all(type(page) is dict for page in pages) and
            [page.get(ordinal) for page in pages] == list(range(1, size + 1)), 'rendered page order/count mismatch')
    require(all(item.get('type') in {'text', 'image'} for item in content), 'unsupported rendered content block')
    images = [item for item in content if item.get('type') == 'image']
    require(len(images) == size, 'not every page was returned as actual image bytes')
    rendered = []
    for page, image in zip(pages, images):
        for dimension in ['width_points', 'height_points']:
            require(type(page.get(dimension)) in {int, float} and math.isfinite(page[dimension]) and page[dimension] > 0,
                    'invalid parsed page geometry')
        require(image.get('mimeType') == 'image/png', 'wrong rendered media type')
        raw = base64.b64decode(image['data'], validate=True)
        width, height = png_dimensions(raw)
        require(sha(raw) == page.get('rendered_sha256') and len(raw) == count(page.get('rendered_bytes'), 'rendered bytes'), 'rendered PNG hash/bytes mismatch')
        name = f'page-{page[ordinal]:03}.png'
        (output / name).write_bytes(raw)
        rendered.append({'file': name, 'sha256': sha(raw), 'bytes': len(raw), 'width': width, 'height': height})
    return {'source': source, 'pages': size, 'rendered_images': rendered,
            'not_inspected': data.get('not_inspected', []), 'inspection_scope': data.get('inspection')}


def verify_release(prefix, expected_commit):
    binary = (prefix / 'masc').resolve(strict=True)
    root = binary.parent
    manifest_path = root / 'release.json'
    manifest = decode(manifest_path.read_bytes())
    require(manifest.get('schema') == 'masc.installed-release.v2', 'unsupported installed release schema')
    require(manifest.get('source_commit') == expected_commit, 'installed release source mismatch')
    binary_identity = CAPTURE.read_identity(binary)
    require(binary_identity['sha256'] == manifest['binary_sha256'], 'installed binary SHA-256 mismatch')
    entries = [(root / name, {'sha256': digest}) for name, digest in manifest['companions'].items()]
    entries += [(root / 'assets/dashboard' / row['path'], row) for row in manifest['files']]
    entries += [(root / row['path'], row) for row in manifest['runtime']['files']]
    for path, row in entries:
        require(path.resolve(strict=True).is_relative_to(root), 'installed manifest path escaped its release')
        observed = CAPTURE.read_identity(path)
        require(observed['sha256'] == row['sha256'], 'installed release file hash mismatch: ' + str(path))
        if 'size' in row:
            require(observed['bytes'] == row['size'], 'installed release file size mismatch: ' + str(path))
    return binary, {'path': str(binary), **binary_identity, 'release_json_sha256': sha(manifest_path.read_bytes()),
                    'source_commit': expected_commit, 'verified_release_files': len(entries)}


def capture(args, output, previous=None):
    command = [sys.executable, str(CAPTURE_SCRIPT), '--base', str(args.base), '--output', str(output)]
    for keeper in args.keeper:
        command += ['--keeper', keeper]
    if previous:
        command += ['--compare', str(previous)]
    process = subprocess.run(command, capture_output=True)
    (output.with_suffix('.stdout.txt')).write_bytes(process.stdout)
    (output.with_suffix('.stderr.txt')).write_bytes(process.stderr)
    require(process.returncode == 0, 'canonical state capture failed; inspect ' + str(output.with_suffix('.stderr.txt')))
    return decode(output.read_bytes())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--prefix', type=Path, required=True)
    parser.add_argument('--source-commit', required=True)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--keeper', action='append', required=True)
    for kind in ['pptx', 'mp4', 'pdf']:
        parser.add_argument('--' + kind, type=Path, required=True)
    parser.add_argument('--soffice', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    require(re.fullmatch('[0-9a-f]{40}', args.source_commit), 'expected source commit must be a complete Git SHA')
    args.base = args.base.resolve(strict=True)
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    args.output.chmod(0o700)
    receipt = {'schema': 'masc.installed_media_inspection_probe.v1', 'status': 'failed', 'base_path': str(args.base),
               'source_commit': args.source_commit, 'llm_verdict': 'not_run', 'files': {}, 'errors': [],
               'scope': 'Installed CLI original-file parsing/rendering/decode; no LLM verdict, visual assessment, Task/Goal approval or runtime replacement.'}
    before = None
    verification_finished = False
    try:
        binary, release = verify_release(args.prefix, args.source_commit)
        receipt['binary'] = release
        soffice = args.soffice.resolve(strict=True)
        require(soffice.is_file() and os.access(soffice, os.X_OK), 'portable soffice is not executable')
        environment = dict(os.environ, PATH=str(soffice.parent) + os.pathsep + os.environ.get('PATH', ''))
        receipt['native_commands'] = {name: shutil.which(name, path=environment['PATH'])
                                      for name in ['soffice', 'ffmpeg', 'ffprobe', 'pdftotext', 'pdftoppm']}
        require(all(receipt['native_commands'].values()), 'native inspector dependency missing from PATH')
        require(Path(receipt['native_commands']['soffice']).resolve() == soffice, 'PATH does not select the requested portable soffice')
        managed = args.base / '.masc/runtime-tools/presentation/bin/python3'
        require(managed.is_file() and os.access(managed, os.X_OK), 'managed presentation interpreter missing')
        receipt['managed_parser'] = {'path': str(managed), **CAPTURE.read_identity(managed)}
        before = capture(args, args.output / 'state-before.json')
        sources = {}
        for kind in ['pptx', 'mp4', 'pdf']:
            path = getattr(args, kind).resolve(strict=True)
            require(path.is_relative_to(args.base / '.masc/playground'), 'original artifact is outside the selected workspace playground')
            require(path.suffix.lower() == '.' + kind, 'wrong explicit artifact format')
            sources[kind] = {'path': str(path), **CAPTURE.read_identity(path)}
        receipt['originals_before'] = sources
        embedded = subprocess.run([str(binary), 'build-commit'], capture_output=True, env=environment)
        (args.output / 'build-commit.stdout.txt').write_bytes(embedded.stdout)
        (args.output / 'build-commit.stderr.txt').write_bytes(embedded.stderr)
        require(embedded.returncode == 0 and embedded.stdout.decode().strip() == args.source_commit, 'executed binary embedded source mismatch')
        for kind, source in sources.items():
            output = args.output / kind
            output.mkdir()
            command = [str(binary), 'inspect-file', '--base-path', str(args.base), source['path']]
            process = subprocess.run(command, capture_output=True, env=environment)
            (output / 'stdout.json').write_bytes(process.stdout)
            (output / 'stderr.txt').write_bytes(process.stderr)
            attempt = {'command': command, 'exit_code': process.returncode, 'status': 'failed'}
            receipt['files'][kind] = attempt
            try:
                payload = decode(process.stdout)
                if type(payload) is dict and type(payload.get('result')) is dict:
                    attempt['typed_outcome'] = {key: payload['result'][key] for key in
                        ['disposition', 'failure_class', 'effect_disposition', 'message'] if key in payload['result']}
                require(process.returncode == 0, 'CLI inspection exited nonzero; see raw typed output')
                attempt['inspection'] = validate_receipt(kind, payload, source, args.base, output)
                attempt['status'] = 'passed'
            except (ValueError, TypeError, KeyError, IndexError, struct.error) as error:
                attempt['error'] = str(error)
                receipt['errors'].append(kind + ': ' + str(error))
        for kind, source in sources.items():
            identity_matches(CAPTURE.read_identity(Path(source['path'])), source, 'unchanged original ' + kind)
        current_binary, current_release = verify_release(args.prefix, args.source_commit)
        require(current_binary == binary and current_release == release, 'installed release changed during probe')
        verification_finished = True
    except (ValueError, TypeError, KeyError, OSError) as error:
        receipt['errors'].append(str(error))
    finally:
        if before is not None:
            try:
                after = capture(args, args.output / 'state-after.json', args.output / 'state-before.json')
                protected = set(before['required_paths']) | {name for name in before['files'] if name.startswith('config/') and name.endswith('.toml')}
                protected |= {name for name in after['files'] if name.startswith('config/') and name.endswith('.toml')}
                changed = [name for name in sorted(protected) if any(
                           before['files'].get(name, {}).get(field) != after['files'].get(name, {}).get(field)
                           for field in ['sha256', 'bytes'])]
                receipt['protected_state_paths'] = sorted(protected)
                receipt['protected_state_changed'] = changed
                receipt['broader_state_comparison'] = after['comparison']
                require(not changed, 'canonical Task/Goal/config bytes changed during observation; cause is not attributed to the CLI')
            except (ValueError, TypeError, KeyError, OSError) as error:
                receipt['errors'].append('state comparison: ' + str(error))
        receipt['post_inspection_identity_checks_completed'] = verification_finished
        if not verification_finished and not receipt['errors']:
            receipt['errors'].append('probe stopped before post-inspection source and release identity checks completed')
        if verification_finished and not receipt['errors'] and len(receipt['files']) == 3 and all(item['status'] == 'passed' for item in receipt['files'].values()):
            receipt['status'] = 'passed'
        save(args.output / 'receipt.json', receipt)
        files = {str(path.relative_to(args.output)): sha(path.read_bytes()) for path in args.output.rglob('*') if path.is_file()}
        save(args.output / 'sha256.json', files)
    print(json.dumps({'receipt': str(args.output / 'receipt.json'), 'status': receipt['status']}))
    return 0 if receipt['status'] == 'passed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
