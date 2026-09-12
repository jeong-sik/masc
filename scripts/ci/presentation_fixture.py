"""CI-only descriptor shared by presentation fixture preparation and consumers.

RUNNER_TEMP locates the descriptor, not the workspace. Dune may replace TMPDIR
for child processes after the workspace and its managed parser were prepared.
"""
import json
import os
from pathlib import Path
import tempfile


SCHEMA = 'masc.presentation_fixture.v1'
DESCRIPTOR_NAME = 'masc-presentation-verifier.json'


def descriptor_path():
    raw = os.environ.get('RUNNER_TEMP')
    if not raw or not Path(raw).is_absolute() or not Path(raw).is_dir():
        raise ValueError('presentation fixtures require an absolute RUNNER_TEMP directory containing the prepared descriptor')
    return Path(raw) / DESCRIPTOR_NAME


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate presentation fixture descriptor field: ' + key)
        result[key] = value
    return result


def validate(value):
    if not isinstance(value, dict) or set(value) != {'schema', 'base_path'} or value['schema'] != SCHEMA:
        raise ValueError('invalid presentation fixture descriptor schema or fields')
    raw = value['base_path']
    if not isinstance(raw, str) or not raw or not Path(raw).is_absolute():
        raise ValueError('presentation fixture base_path must be absolute')
    base = Path(raw).resolve(strict=True)
    if str(base) != raw or not base.is_dir():
        raise ValueError('presentation fixture base_path must name its canonical existing directory')
    if base.is_relative_to(Path.home().resolve()):
        raise ValueError('presentation fixture workspace must be outside HOME')
    return base


def read_base():
    value = json.loads(descriptor_path().read_text(), object_pairs_hook=unique_fields)
    return validate(value)


def publish(base):
    value = {'schema': SCHEMA, 'base_path': str(Path(base).resolve(strict=True))}
    validate(value)
    destination = descriptor_path()
    # Publication follows successful fixture generation. Readers never see a
    # partially written descriptor or a new descriptor for an unfinished setup.
    with tempfile.NamedTemporaryFile(mode='w', dir=destination.parent, delete=False) as output:
        staged = Path(output.name)
        try:
            json.dump(value, output)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
            os.replace(staged, destination)
        finally:
            staged.unlink(missing_ok=True)
