"""The release freeze flag: one repository variable, one reader, two users.

The merge worker and the sweep must agree on the flag's name and its
precedence, so both load this module with `sibling(...)` instead of keeping
private copies (#54644 review). The release leader sets
`gh variable set MASC_RELEASE_FREEZE --body 1` while a freeze is on and sets
it back to '0' once publishing is over. Only the value '1' freezes: a
missing variable, an empty value, or anything else leaves the ordinary
behavior untouched.
"""
from __future__ import annotations

import os
import re
import sys

FREEZE_VARIABLE = 'MASC_RELEASE_FREEZE'
# task-4046: only this label opts a scope out of the freeze. The release
# leader attaches it to the top pull request of a P0/P1 repair scope; no
# other scope submits while the freeze is on, and a reservation on an
# exempt scope survives the sweep's reclaim.
FREEZE_LABEL = 'freeze-exempt'

# The sweep's gh wrapper reports a missing variable in GitHub's own words
# ("gh: Not Found (HTTP 404)"); the worker's REST client raises a typed 404
# instead, so each caller passes its own predicate to `freeze_flag`.
NOT_FOUND = re.compile(r'HTTP 404|404 Not Found')


def missing_from_gh(error):
    """Whether the sweep's ValueError names a variable that does not exist."""
    return NOT_FOUND.search(str(error)) is not None


def freeze_flag(repo, read, missing=None):
    """'1' in the MASC_RELEASE_FREEZE repository variable.

    The environment is read first, so the trusted workflow can pass the vars
    context for free and tests can pin the flag; without it the variable is
    read from the repository through `read`, which returns the JSON object
    of one REST path and raises on a refusal. `missing` recognizes the
    variable-is-absent failure: a variable that does not exist is the
    ordinary off state and stays quiet. Any other failed read prints one
    stderr line and still fails open — a fail-open gate must not fail open
    silently (#54644 review) — and every other admission hold keeps
    applying either way.
    """
    passed = os.environ.get(FREEZE_VARIABLE, '').strip()
    if passed:
        if passed not in ('0', '1'):
            # task-4046 review: a value the reader does not know ('true',
            # 'yes', a typo) is off like every other non-'1', but loudly:
            # a silent wrong value is how a freeze quietly stops working.
            print(f'release-freeze: the {FREEZE_VARIABLE} environment value '
                  f'is not 0 or 1 ({passed[:40]}); treating the release '
                  f'freeze as off', file=sys.stderr)
        return passed == '1'
    try:
        value = read(f'repos/{repo}/actions/variables/{FREEZE_VARIABLE}')['value']
    except (ValueError, KeyError, TypeError, OSError) as error:
        if missing is not None and missing(error):
            return False
        status = getattr(error, 'status', None)
        if status is not None:
            message = getattr(error, 'details', {}).get('message', '')
            detail = f'HTTP {status}: {message}'
        else:
            detail = f'{type(error).__name__}: {error}'
        print(f'release-freeze: the {FREEZE_VARIABLE} repository variable is '
              f'unreadable ({detail[:200]}); treating the release freeze as off',
              file=sys.stderr)
        return False
    if not isinstance(value, str):
        print(f'release-freeze: the {FREEZE_VARIABLE} repository variable '
              f'carries a non-string value ({type(value).__name__}); treating '
              f'the release freeze as off', file=sys.stderr)
        return False
    return value.strip() == '1'
