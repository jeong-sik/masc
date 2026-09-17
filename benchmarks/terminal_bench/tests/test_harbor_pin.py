"""The harbor these tests run against is the release requirements.txt pins.

test_dataset_plan calls `DatasetConfig._filter_task_ids` and aggregate.py reads
the TrialResult layout of harbor 0.23.0; neither is a public contract, so a
different installed release fails here by name instead of somewhere else.
"""
from importlib.metadata import version
from pathlib import Path

import pytest

REQUIREMENTS = Path(__file__).resolve().parents[1] / "requirements.txt"


def pinned_version(requirements: str, name: str) -> str:
    """The `name==X` version in `requirements`; a missing or loose pin raises."""
    for raw in requirements.splitlines():
        line = raw.split("#", 1)[0].strip()
        package, sep, release = line.partition("==")
        if package.strip() == name:
            if not sep or not release.strip():
                raise ValueError(f"{name} is not pinned with ==: {raw!r}")
            return release.strip()
    raise ValueError(f"{name} is not in requirements")


def test_installed_harbor_is_the_pinned_release():
    assert version("harbor") == pinned_version(REQUIREMENTS.read_text(), "harbor")


@pytest.mark.parametrize("requirements", ["harbor>=0.23\n", "harbor\n", "pytest\n"])
def test_a_loose_or_missing_harbor_pin_is_refused(requirements):
    with pytest.raises(ValueError):
        pinned_version(requirements, "harbor")
