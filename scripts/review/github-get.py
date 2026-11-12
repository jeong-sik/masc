"""Read GitHub JSON; only a server-timed quota response retries an HTTP GET.

Writes never pass through this transport. A pause invalidates an admission's
earlier reads; callers can compare ``pauses`` before committing a decision.
"""
from email.utils import parsedate_to_datetime
import json
import re
import subprocess
import time
from typing import NamedTuple
from urllib.parse import urlsplit


QUOTA_HEADERS = ('retry-after', 'x-ratelimit-remaining', 'x-ratelimit-reset')
# A wait that ends exactly at the server's reset second can still be answered
# with the old window: the 403 then carries the same reset time, now elapsed,
# which reads as no quota at all. After a wait of our own, that answer gets a
# few short retries before it is reported. Without a prior wait it stays a
# visible failure.
BOUNDARY_RETRIES = 3
BOUNDARY_PAUSE_SECONDS = 2


class ApiFailure(ValueError):
    def __init__(self, path, status, headers, message):
        self.path, self.status, self.headers = path, status, headers
        self.details = {'method': 'GET', 'path': path, 'http_status': status,
                        'headers': {k: headers[k] for k in QUOTA_HEADERS if k in headers},
                        'message': message}
        super().__init__(json.dumps(self.details, ensure_ascii=False))


class QuotaLimited(ApiFailure):
    def __init__(self, path, status, headers, message, retry_at):
        super().__init__(path, status, headers, message)
        self.retry_at = retry_at


class QuotaBoundaryExhausted(ApiFailure):
    """The post-wait retries at the reset second all met the old window.

    Its own type and ``quota_state`` mark it, so a measurement can tell this
    end from an ordinary refusal or a quota wait that was cut short.
    """
    STATE = 'boundary_retries_exhausted'

    def __init__(self, failure, retries):
        super().__init__(failure.path, failure.status, failure.headers,
                         f'{failure.details["message"]} (quota reset boundary: '
                         f'{retries} retries exhausted)')
        self.details = dict(self.details, quota_state=self.STATE, boundary_retries=retries)
        self.args = (json.dumps(self.details, ensure_ascii=False),)


class QuotaWaitCutShort(QuotaLimited):
    """A quota wait ended at the caller's deadline with retry_at still ahead.

    The server time was honored: no further GET went out after the quota was
    observed. The caller hands its receipt to a fresh run instead of waiting.
    """


class Response(NamedTuple):
    data: object
    status: int
    headers: dict[str, str]


def response_parts(raw):
    header, separator, body = raw.replace('\r\n', '\n').partition('\n\n')
    lines = header.splitlines()
    status = re.fullmatch(r'HTTP/\S+ ([0-9]{3})(?: .*)?', lines[0]) if lines else None
    if not separator or status is None:
        raise ValueError('gh api did not return HTTP status and headers')
    headers = {}
    for line in lines[1:]:
        key, colon, value = line.partition(':')
        if not colon or not key.strip():
            raise ValueError('gh api returned malformed HTTP headers')
        key, value = key.strip().lower(), value.strip()
        if key in headers:
            if key in QUOTA_HEADERS:
                if headers[key] != value:
                    raise ValueError('GitHub returned conflicting quota headers')
            else:
                headers[key] += ', ' + value
        else:
            headers[key] = value
    return int(status[1]), headers, body


def quota_retry_at(status, headers, now):
    if status not in (403, 429):
        return None
    deadlines = []
    retry = headers.get('retry-after')
    if retry is not None:
        try:
            if retry.isascii() and retry.isdecimal():
                deadlines.append(now + int(retry))
            else:
                date = parsedate_to_datetime(retry)
                if date.tzinfo is not None:
                    deadlines.append(date.timestamp())
        except (ValueError, TypeError, OverflowError):
            pass
    reset = headers.get('x-ratelimit-reset', '')
    if headers.get('x-ratelimit-remaining') == '0' and reset.isascii() and reset.isdecimal():
        deadlines.append(int(reset))
    # A missing, malformed or already elapsed time gives no useful pause.
    # Keep it visible instead of spinning on the same quota response.
    return max(deadlines) if deadlines and max(deadlines) > now else None


class Client:
    def __init__(self, *, run=None, clock=None, sleep=None, on_quota=None):
        self.run = run or subprocess.run
        self.clock = clock or time.time
        self.sleep = sleep or time.sleep
        self.on_quota = on_quota or (lambda failure: None)
        self.pauses = 0
        self.boundary_retries = 0
        # Latest client-clock time a quota wait may sleep until; None waits
        # out the server time. A caller with its own deadline (follow's wait)
        # sets this so a long quota cannot outlive the handoff.
        self.deadline = None

    def once(self, path):
        result = self.run(['gh', 'api', '--method', 'GET', '--include', '--', path],
                          capture_output=True, text=True, check=False)
        try:
            status, headers, body = response_parts(result.stdout)
        except ValueError as error:
            raise ApiFailure(path, None, {}, str(error)) from error
        try:
            data = json.loads(body)
        except ValueError:
            data = None
        message = (data.get('message') if isinstance(data, dict) else None)
        message = message or result.stderr.strip() or 'GitHub did not return valid JSON'
        if result.returncode or not 200 <= status < 300:
            retry_at = quota_retry_at(status, headers, self.clock())
            if retry_at is not None:
                raise QuotaLimited(path, status, headers, message, retry_at)
            raise ApiFailure(path, status, headers, message)
        if data is None:
            raise ApiFailure(path, status, headers, 'GitHub did not return valid JSON')
        return Response(data, status, headers)

    def get(self, path):
        waited, boundary = False, 0
        while True:
            try:
                return self.once(path)
            except QuotaLimited as failure:
                self.pauses += 1
                self.on_quota(failure)
                self.wait_for_quota(failure)
                waited = True
            except ApiFailure as failure:
                if not (waited and self.reset_just_elapsed(failure)):
                    raise
                if boundary >= BOUNDARY_RETRIES:
                    raise QuotaBoundaryExhausted(failure, boundary) from failure
                boundary += 1
                self.boundary_retries += 1
                self.sleep(BOUNDARY_PAUSE_SECONDS)

    def reset_just_elapsed(self, failure):
        """A 403/429 whose primary quota is spent and whose reset time has passed."""
        headers = failure.headers
        reset = headers.get('x-ratelimit-reset', '')
        return (failure.status in (403, 429) and headers.get('x-ratelimit-remaining') == '0'
                and reset.isascii() and reset.isdecimal() and int(reset) <= self.clock())

    def wait_for_quota(self, failure):
        """Honor an observed retry time, including one carried by a receipt."""
        while (remaining := failure.retry_at - self.clock()) > 0:
            budget = None if self.deadline is None else self.deadline - self.clock()
            if budget is not None and budget <= 0:
                raise QuotaWaitCutShort(
                    failure.path, failure.status, failure.headers,
                    f'{failure.details["message"]} (quota wait cut short; '
                    f'retry at {failure.retry_at})',
                    failure.retry_at) from failure
            self.sleep(min(remaining, budget) if budget is not None else remaining)

    def read(self, path):
        return self.get(path).data

    def pages(self, path):
        rows, seen = [], set()
        while path is not None:
            if path in seen:
                raise ApiFailure(path, None, {}, 'GitHub repeated a pagination link')
            seen.add(path)
            response = self.get(path)
            if not isinstance(response.data, list):
                raise ApiFailure(path, response.status, response.headers, 'expected a paginated array')
            rows.extend(response.data)
            path = None
            for part in response.headers.get('link', '').split(','):
                if not part.strip():
                    continue
                link = re.fullmatch(r'\s*<([^>]+)>;\s*rel="([^"]+)"\s*', part)
                if link is None:
                    raise ValueError('GitHub returned a malformed pagination link')
                if 'next' in link[2].split():
                    target = urlsplit(link[1])
                    following = target.path.lstrip('/') + ('?' + target.query if target.query else '')
                    if path is not None and path != following:
                        raise ValueError('GitHub returned conflicting next-page links')
                    path = following
        return rows
