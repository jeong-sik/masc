"""Private, submit-once login lifecycle on the original host companion.

No credential, approval link or provider reference is a public result. A
submitted fill is an observed extension result, never website authentication.
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field, replace
from contextlib import contextmanager
from enum import StrEnum
import fcntl
import math
import os
from pathlib import Path
import threading
import time
from urllib.parse import urlsplit
import uuid

from companion import BridgeError, Companion
from oauth import ConnectionError, PrivateStore


class LoginError(Exception):
    """Fixed public disposition; never wrap provider or OS error prose."""


class Phase(StrEnum):
    PREPARING = "preparing"
    REQUESTING = "requesting"
    APPROVAL_READY = "approval_ready"
    AWAITING_APPROVAL = "awaiting_approval"
    CHECKING = "checking"
    WAITING_USER = "waiting_user"
    FILLING = "filling"
    SETTLING = "settling"
    FILL_SUBMITTED = "fill_submitted"
    RELEASED = "released"
    DENIED = "denied"
    EXPIRED = "expired"
    FAILED = "failed"
    CANCELLED = "cancelled"
    NOT_STARTED = "not_started"
    OUTCOME_UNKNOWN = "outcome_unknown"


TERMINAL = frozenset({Phase.RELEASED, Phase.DENIED, Phase.EXPIRED,
                      Phase.FAILED, Phase.CANCELLED, Phase.NOT_STARTED, Phase.OUTCOME_UNKNOWN})


class _Lifecycle(StrEnum):
    OPEN = "open"
    CLOSING = "closing"
    CLOSED = "closed"


def _text(value):
    return isinstance(value, str) and bool(value) and value.strip() == value


def _uuid(value):
    try:
        return isinstance(value, str) and str(uuid.UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


def _caller(value):
    return (isinstance(value, dict) and
            (value == {"kind": "operator"} or
             (set(value) == {"kind", "name"} and isinstance(value["kind"], str)
              and value["kind"] in {"keeper", "agent", "host_actor"}
              and _text(value["name"]))))


def _website(value):
    if not _text(value) or any(ord(char) < 32 for char in value):
        return False
    try:
        url = urlsplit(value)
        return (url.scheme == "https" and bool(url.hostname) and not url.username
                and not url.password and not url.fragment and bool(url.port or 443))
    except ValueError:
        return False


def _app_link(value):
    if not _text(value) or any(ord(char) < 32 for char in value):
        return False
    try:
        url = urlsplit(value)
        return (url.scheme == "onepassword" and url.netloc == "grant-brokered-access"
                and not url.username and not url.password)
    except ValueError:
        return False


@dataclass(frozen=True)
class Extension:
    directory: Path
    extension_id: str

    def __post_init__(self):
        if (not isinstance(self.directory, Path) or not self.directory.is_absolute()
                or not isinstance(self.extension_id, str) or len(self.extension_id) != 32
                or any(c not in "abcdefghijklmnop" for c in self.extension_id)):
            raise LoginError("unavailable")


@dataclass(frozen=True)
class Record:
    operation_id: str
    caller: dict
    browser_instance_id: str
    tab_id: int
    connection_id: str
    website: str
    phase: Phase
    request_id: str | None = None
    entry_id: str | None = None
    app_link: str | None = field(default=None, repr=False)
    reference: str | None = field(default=None, repr=False)
    opened_at: float | None = None
    next_check_at: float | None = None
    fill_submitted: bool = False

    def public(self):
        return {"operation_id": self.operation_id, "phase": self.phase.value,
                "fill_submitted": self.fill_submitted, "website_login_verified": False}


def _decode(value):
    if not isinstance(value, dict) or set(value) != set(Record.__dataclass_fields__):
        raise ConnectionError("invalid_login_record")
    try:
        record = Record(**{**value, "phase": Phase(value["phase"])})
    except (ValueError, TypeError):
        raise ConnectionError("invalid_login_record") from None
    if (not all(_uuid(v) for v in [record.operation_id, record.browser_instance_id, record.connection_id])
            or not _caller(record.caller) or type(record.tab_id) is not int or record.tab_id < 0
            or not _website(record.website) or type(record.fill_submitted) is not bool
            or any(v is not None and not _text(v) for v in [record.request_id, record.entry_id, record.reference])
            or (record.app_link is not None and not _app_link(record.app_link))
            or any(v is not None and (type(v) not in {int, float} or not math.isfinite(v))
                   for v in [record.opened_at, record.next_check_at])):
        raise ConnectionError("invalid_login_record")
    if record.phase in {Phase.APPROVAL_READY, Phase.AWAITING_APPROVAL, Phase.CHECKING,
                        Phase.WAITING_USER, Phase.FILLING, Phase.FILL_SUBMITTED} and not all(
                            v is not None for v in [record.request_id, record.entry_id, record.app_link]):
        raise ConnectionError("invalid_login_record")
    if record.phase in {Phase.AWAITING_APPROVAL, Phase.CHECKING, Phase.WAITING_USER} and (
            record.opened_at is None or record.next_check_at is None):
        raise ConnectionError("invalid_login_record")
    if (record.phase in {Phase.FILLING, Phase.FILL_SUBMITTED} and record.reference is None
            or record.phase in {Phase.FILL_SUBMITTED, Phase.RELEASED} and not record.fill_submitted):
        raise ConnectionError("invalid_login_record")
    return record


class Journal(PrivateStore):
    """Separate private directory; shares the audited fd-relative store edge."""
    _record_name = "operations.json"

    @staticmethod
    def _validate(value):
        if (not isinstance(value, dict) or set(value) != {"version", "operations"}
                or type(value["version"]) is not int or value["version"] != 1
                or not isinstance(value["operations"], list)):
            raise ConnectionError("invalid_login_journal")
        records = [_decode(item) for item in value["operations"]]
        if len({record.operation_id for record in records}) != len(records):
            raise ConnectionError("duplicate_login_operation")


@dataclass
class _Live:
    bridge: Companion = field(repr=False)
    caller: dict
    cancelled: threading.Event = field(default_factory=threading.Event)


class Logins:
    def __init__(self, connector, journal: Journal, extension: Extension, *,
                 bridge=Companion, clock=time.time):
        self.connector, self.journal, self.extension = connector, journal, extension
        self._bridge, self._clock = bridge, clock
        self._lock, self._handles_lock = threading.RLock(), threading.Lock()
        self._lifecycle = _Lifecycle.OPEN
        self._live, self._lease = {}, None
        self._prepare = Path(__file__).with_name("prepare.js").read_text()
        self._program = Path(__file__).with_name("autofill.js").read_text()
        try:
            with journal.locked() as root:
                fd = os.open("engine.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                             0o600, dir_fd=root)
                try:
                    journal._owned(os.fstat(fd))
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BaseException:
                    os.close(fd)
                    raise
                self._lease = fd
                value = journal.read(root) or {"version": 1, "operations": []}
                records = [_decode(item) for item in value["operations"]]
                # No socket, provider owner or extension binding survives this
                # engine. Never rebind or replay a retained private operation.
                self._records = {r.operation_id: (replace(r, phase=Phase.OUTCOME_UNKNOWN,
                    app_link=None, reference=None) if r.phase not in TERMINAL else r) for r in records}
                if any(r.phase not in TERMINAL for r in records):
                    journal.write(root, self._value())
        except (OSError, ConnectionError, ValueError, TypeError):
            if self._lease is not None:
                os.close(self._lease)
                self._lease = None
            raise LoginError("unavailable") from None

    def _value(self):
        return {"version": 1, "operations": [asdict(record) for record in self._records.values()]}

    def _save(self, record):
        # Publish memory only after the private durable record is committed.
        records = {**self._records, record.operation_id: record}
        with self.journal.locked() as root:
            self.journal.write(root, {"version": 1, "operations": [asdict(r) for r in records.values()]})
        self._records = records
        return record

    def _owned(self, operation_id, caller):
        record = self._records.get(operation_id)
        if self._lease is None or record is None or not _caller(caller) or (
                caller != record.caller and caller != {"kind": "operator"}):
            raise LoginError("unavailable")
        return record

    def _invoke(self, record, live, **arguments):
        if live.cancelled.is_set():
            raise LoginError("outcome_unknown")
        result = self.connector.credentials(lambda token, key: live.bridge.invoke(program=self._program,
            arguments={**arguments, "access_token": token, "integration_key": key}),
            expected_connection_id=record.connection_id)
        if live.cancelled.is_set() or not isinstance(result, dict):
            raise LoginError("outcome_unknown")
        return result

    def _terminal(self, record, live, phase):
        record = self._save(replace(record, phase=Phase.SETTLING, app_link=None, reference=None))
        try:
            live.bridge.release()
        except (BridgeError, OSError, ValueError, TypeError):
            record = self._save(replace(record, phase=Phase.OUTCOME_UNKNOWN))
        else:
            record = self._save(replace(record, phase=phase))
        finally:
            live.bridge.cancel()
            with self._handles_lock:
                self._live.pop(record.operation_id, None)
        return record.public()

    @contextmanager
    def _admission(self):
        # MCP admission must remain available for cancellation while the owner
        # executes private IO on its background thread.
        if not self._lock.acquire(blocking=False):
            raise LoginError("unavailable")
        try:
            yield
        finally:
            self._lock.release()

    def reserve(self, *, descriptor, caller, browser_instance_id, tab_id, website, goal, reason):
        if (not _caller(caller) or not _uuid(browser_instance_id) or type(tab_id) is not int
                or tab_id < 0 or not _website(website) or not _text(goal) or not _text(reason)):
            raise LoginError("not_started")
        with self._admission():
            with self._handles_lock:
                if self._lifecycle is not _Lifecycle.OPEN:
                    raise LoginError("unavailable")
            if self._lease is None or any(r.browser_instance_id == browser_instance_id and r.tab_id == tab_id
                    and r.phase not in TERMINAL for r in self._records.values()):
                raise LoginError("unavailable")
            record, live = None, None
            try:
                connection_id = self.connector.connection_identity()
                live = _Live(self._bridge(descriptor), dict(caller))
                record = Record(str(uuid.uuid4()), dict(caller), browser_instance_id,
                                tab_id, connection_id, website, Phase.PREPARING)
                self._save(record)
                with self._handles_lock:
                    if self._lifecycle is not _Lifecycle.OPEN:
                        live.cancelled.set()
                        live.bridge.cancel()
                        raise LoginError("outcome_unknown")
                    self._live[record.operation_id] = live
                live.bridge.bind(browser_instance_id=browser_instance_id, tab_id=tab_id)
                return record.public(), True
            except (LoginError, BridgeError, ConnectionError, OSError, ValueError, TypeError):
                if record is not None:
                    live.bridge.cancel()
                    with self._handles_lock:
                        self._live.pop(record.operation_id, None)
                    return self._save(replace(record, phase=Phase.OUTCOME_UNKNOWN,
                                              app_link=None, reference=None)).public(), False
                raise LoginError("unavailable") from None

    def request(self, operation_id, caller, *, goal, reason):
        with self._lock:
            record = self._owned(operation_id, caller)
            if record.phase is not Phase.PREPARING:
                return record.public()
            live = self._live.get(operation_id)
            if live is None or not _text(goal) or not _text(reason):
                raise LoginError("unavailable")
            try:
                live.bridge.prepare(extension_id=self.extension.extension_id,
                    directory=str(self.extension.directory), program=self._prepare, arguments={})
                record = self._save(replace(record, phase=Phase.REQUESTING))
                result = self._invoke(record, live, kind="request", website=record.website, goal=goal, reason=reason)
                if (set(result) != {"request_id", "entry_id", "app_link"}
                        or not _text(result["request_id"]) or not _text(result["entry_id"])
                        or not _app_link(result["app_link"])):
                    raise LoginError("outcome_unknown")
                record = self._save(replace(record, phase=Phase.APPROVAL_READY, **result))
                return record.public()
            except (LoginError, BridgeError, ConnectionError, OSError, ValueError, TypeError):
                live.bridge.cancel()
                with self._handles_lock:
                    self._live.pop(record.operation_id, None)
                return self._save(replace(record, phase=Phase.OUTCOME_UNKNOWN,
                                          app_link=None, reference=None)).public()

    def status(self, operation_id, caller):
        # _save replaces the immutable committed map in one assignment. Readers
        # see its last durable snapshot without waiting behind extension IO.
        return self._owned(operation_id, caller).public()

    def operations(self, caller):
        if self._lease is None or not _caller(caller):
            raise LoginError("unavailable")
        records = self._records
        return [r.public() for r in records.values()
                if caller == r.caller or caller == {"kind": "operator"}]

    def pending_checks(self):
        """Private scheduler inputs from the last committed snapshot."""
        return [(r.operation_id, r.next_check_at) for r in self._records.values()
                if r.phase is Phase.AWAITING_APPROVAL]

    def approval(self, operation_id):
        """Redeliver the private approval link without starting its clock."""
        record = self._owned(operation_id, {"kind": "operator"})
        live = self._live.get(operation_id)
        if (record.phase not in {Phase.APPROVAL_READY, Phase.AWAITING_APPROVAL, Phase.WAITING_USER}
                or live is None or live.cancelled.is_set()):
            raise LoginError("unavailable")
        return {"open_url": record.app_link}

    def opened(self, operation_id, *, opened_at=None):
        """Private operator acknowledgement that the approval link opened."""
        with self._lock:
            record = self._owned(operation_id, {"kind": "operator"})
            live = self._live.get(operation_id)
            if (record.phase not in {Phase.APPROVAL_READY, Phase.AWAITING_APPROVAL, Phase.WAITING_USER}
                    or live is None or live.cancelled.is_set()):
                return record.public()
            if record.phase in {Phase.AWAITING_APPROVAL, Phase.WAITING_USER}:
                return record.public()
            now = self._clock() if opened_at is None else opened_at
            if type(now) not in {int, float} or not math.isfinite(now) or now > self._clock():
                raise LoginError("not_started")
            record = self._save(replace(record, phase=Phase.AWAITING_APPROVAL,
                                        opened_at=now, next_check_at=now + 5.))
            return record.public()

    def confirmation_time(self, operation_id):
        """Private operator checker may queue for the original rate-limit floor."""
        record = self._owned(operation_id, {"kind": "operator"})
        if record.phase not in {Phase.AWAITING_APPROVAL, Phase.WAITING_USER}:
            raise LoginError("unavailable")
        return record.next_check_at

    def advance(self, operation_id, caller, *, user_confirmed=False):
        with self._lock:
            record = self._owned(operation_id, caller)
            if record.phase not in {Phase.AWAITING_APPROVAL, Phase.WAITING_USER}:
                return record.public()
            now = self._clock()
            # Vendor's approval window and rate limit, not a task lifetime.
            if now < record.next_check_at:
                return record.public()
            if record.phase is Phase.WAITING_USER and not user_confirmed:
                return record.public()
            if now - record.opened_at >= 120. and not user_confirmed:
                return self._save(replace(record, phase=Phase.WAITING_USER)).public()
            live = self._live.get(operation_id)
            if live is None:
                return self._save(replace(record, phase=Phase.OUTCOME_UNKNOWN,
                                          app_link=None, reference=None)).public()
            try:
                record = self._save(replace(record, phase=Phase.CHECKING))
                result = self._invoke(record, live, kind="status", request_id=record.request_id,
                                      entry_id=record.entry_id)
                if set(result) == {"error"} and result["error"] in {"rateLimitExceeded", "timeout", "networkError"}:
                    delay = 60. if result["error"] == "rateLimitExceeded" else self._interval(record)
                    return self._save(replace(record, phase=Phase.AWAITING_APPROVAL,
                                              next_check_at=self._clock() + delay)).public()
                if result == {"state": "pending"}:
                    phase = Phase.WAITING_USER if user_confirmed else Phase.AWAITING_APPROVAL
                    return self._save(replace(record, phase=phase,
                        next_check_at=self._clock() + self._interval(record))).public()
                for state, phase in [("denied", Phase.DENIED), ("expired", Phase.EXPIRED), ("failed", Phase.FAILED)]:
                    if result == {"state": state}:
                        return self._terminal(record, live, phase)
                if (set(result) == {"state", "granted"} and result["state"] == "resolved"
                        and result["granted"] is False):
                    return self._terminal(record, live, Phase.DENIED)
                if (set(result) != {"state", "granted", "reference"} or result["state"] != "resolved"
                        or result["granted"] is not True or not _text(result["reference"])):
                    raise LoginError("outcome_unknown")
                return self._fill(replace(record, reference=result["reference"]), live)
            except (LoginError, BridgeError, ConnectionError, OSError, ValueError, TypeError):
                live.bridge.cancel()
                with self._handles_lock:
                    self._live.pop(operation_id, None)
                return self._save(replace(record, phase=Phase.OUTCOME_UNKNOWN,
                                          app_link=None, reference=None)).public()

    def _fill(self, record, live):
        record = self._save(replace(record, phase=Phase.FILLING))
        filled = self._invoke(record, live, kind="fill", website=record.website, reference=record.reference)
        if filled != {"status": "fill_submitted"}:
            raise LoginError("outcome_unknown")
        return self._save(replace(record, phase=Phase.FILL_SUBMITTED, fill_submitted=True)).public()

    def reserve_fill(self, operation_id, caller):
        with self._admission():
            record = self._owned(operation_id, caller)
            live = self._live.get(operation_id)
            if record.phase is not Phase.FILL_SUBMITTED or live is None or live.cancelled.is_set():
                raise LoginError("unavailable")
            return self._save(replace(record, phase=Phase.FILLING)).public()

    def fill(self, operation_id, caller):
        """Execute an admitted next username/password/OTP page once."""
        with self._lock:
            record = self._owned(operation_id, caller)
            if record.phase is not Phase.FILLING:
                return record.public()
            live = self._live.get(operation_id)
            if live is None:
                raise LoginError("unavailable")
            try:
                return self._fill(record, live)
            except (LoginError, BridgeError, ConnectionError, OSError, ValueError, TypeError):
                live.bridge.cancel()
                with self._handles_lock:
                    self._live.pop(operation_id, None)
                return self._save(replace(record, phase=Phase.OUTCOME_UNKNOWN,
                                          app_link=None, reference=None)).public()

    def reserve_finish(self, operation_id, caller):
        with self._admission():
            record = self._owned(operation_id, caller)
            live = self._live.get(operation_id)
            if record.phase is not Phase.FILL_SUBMITTED or live is None or live.cancelled.is_set():
                raise LoginError("unavailable")
            return self._save(replace(record, phase=Phase.SETTLING, app_link=None, reference=None)).public()

    def finish(self, operation_id, caller):
        """Release after the caller's site check; this does not certify that check."""
        with self._lock:
            record = self._owned(operation_id, caller)
            if record.phase is not Phase.SETTLING:
                return record.public()
            live = self._live.get(operation_id)
            if live is None:
                raise LoginError("unavailable")
            return self._terminal(record, live, Phase.RELEASED)

    def _interval(self, record):
        elapsed = self._clock() - record.opened_at
        return 2. if elapsed < 30. else 5. if elapsed < 60. else 10.

    def interrupt(self, operation_id, caller):
        """Cancel the original socket immediately; this is not settlement."""
        record = self._owned(operation_id, caller)
        with self._handles_lock:
            live = self._live.get(operation_id)
            if live is not None:
                if not _caller(caller) or caller not in [live.caller, {"kind": "operator"}]:
                    raise LoginError("unavailable")
                live.cancelled.set()
                live.bridge.cancel()
        return record.public()

    def cancel(self, operation_id, caller):
        self.interrupt(operation_id, caller)
        with self._lock:
            record = self._owned(operation_id, caller)
            if record.phase in TERMINAL:
                return record.public()
            phase = (Phase.CANCELLED if record.phase in {Phase.APPROVAL_READY, Phase.AWAITING_APPROVAL,
                      Phase.WAITING_USER, Phase.FILL_SUBMITTED} else Phase.OUTCOME_UNKNOWN)
            record = self._save(replace(record, phase=phase, app_link=None, reference=None))
            with self._handles_lock:
                self._live.pop(operation_id, None)
            return record.public()

    def close(self):
        with self._handles_lock:
            if self._lifecycle is _Lifecycle.OPEN:
                self._lifecycle = _Lifecycle.CLOSING
            for live in self._live.values():
                live.cancelled.set()
                live.bridge.cancel()
        with self._lock:
            if self._lease is not None:
                os.close(self._lease)
                self._lease = None
            with self._handles_lock:
                self._live.clear()
                self._lifecycle = _Lifecycle.CLOSED
