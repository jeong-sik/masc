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


class PublicationKind(StrEnum):
    ATTENTION_REQUIRED = "attention_required"
    EFFECT_SUBMITTED = "effect_submitted"
    TERMINAL = "terminal"


def _publication_kind(phase):
    if phase in {Phase.APPROVAL_READY, Phase.WAITING_USER}:
        return PublicationKind.ATTENTION_REQUIRED
    if phase is Phase.FILL_SUBMITTED:
        return PublicationKind.EFFECT_SUBMITTED
    if phase in TERMINAL:
        return PublicationKind.TERMINAL
    return None


@dataclass(frozen=True)
class Publication:
    publication_id: str
    kind: PublicationKind
    phase: Phase
    fill_submitted: bool
    host_accepted: bool = False

    def public(self, operation_id):
        return {"publication_id": self.publication_id, "kind": self.kind.value,
                "output": {"operation_id": operation_id, "phase": self.phase.value,
                           "fill_submitted": self.fill_submitted, "website_login_verified": False}}

    def matches(self, operation_id, envelope):
        expected = self.public(operation_id)
        if (not isinstance(envelope, dict) or set(envelope) != set(expected)
                or not isinstance(envelope["output"], dict) or set(envelope["output"]) != set(expected["output"])):
            return False
        return (all(type(envelope[key]) is str and envelope[key] == expected[key]
                    for key in ["publication_id", "kind"])
                and all(type(envelope["output"][key]) is type(value) and envelope["output"][key] == value
                        for key, value in expected["output"].items()))


@dataclass(frozen=True)
class PublicationSnapshot:
    phase: Phase
    pending: tuple[dict, ...]


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
                and not url.username and not url.password and not url.path and not url.fragment)
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
    publications: tuple[Publication, ...] = ()

    def public(self):
        return {"operation_id": self.operation_id, "phase": self.phase.value,
                "fill_submitted": self.fill_submitted, "website_login_verified": False}


def _decode_publication(value):
    if not isinstance(value, dict) or set(value) != set(Publication.__dataclass_fields__):
        raise ConnectionError("invalid_login_publication")
    try:
        publication = Publication(**{**value, "kind": PublicationKind(value["kind"]),
                                     "phase": Phase(value["phase"])})
    except (ValueError, TypeError):
        raise ConnectionError("invalid_login_publication") from None
    if (not _uuid(publication.publication_id) or type(publication.fill_submitted) is not bool
            or type(publication.host_accepted) is not bool
            or _publication_kind(publication.phase) is not publication.kind
            or publication.phase in {Phase.FILL_SUBMITTED, Phase.RELEASED} and not publication.fill_submitted):
        raise ConnectionError("invalid_login_publication")
    return publication


def _decode(value):
    if not isinstance(value, dict) or set(value) != set(Record.__dataclass_fields__):
        raise ConnectionError("invalid_login_record")
    try:
        if not isinstance(value["publications"], list):
            raise ConnectionError("invalid_login_publication")
        record = Record(**{**value, "phase": Phase(value["phase"]),
                           "publications": tuple(_decode_publication(p) for p in value["publications"])})
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
    if _publication_kind(record.phase) is not None and (
            not record.publications or record.publications[-1].phase is not record.phase
            or record.publications[-1].fill_submitted is not record.fill_submitted):
        raise ConnectionError("invalid_login_publication")
    if not record.fill_submitted and any(p.fill_submitted for p in record.publications):
        raise ConnectionError("invalid_login_publication")
    return record


def _encode(record):
    return {**asdict(record), "publications": [asdict(p) for p in record.publications]}


class Journal(PrivateStore):
    """Separate private directory; shares the audited fd-relative store edge."""
    _record_name = "operations.json"
    _reference_name = "operations.reference.json"
    _reference_schema = "masc.1password.protected-login.v1"

    @staticmethod
    def _validate(value):
        if (not isinstance(value, dict) or set(value) != {"version", "operations"}
                or type(value["version"]) is not int or value["version"] != 2
                or not isinstance(value["operations"], list)):
            raise ConnectionError("invalid_login_journal")
        records = [_decode(item) for item in value["operations"]]
        if len({record.operation_id for record in records}) != len(records):
            raise ConnectionError("duplicate_login_operation")
        publications = [p.publication_id for record in records for p in record.publications]
        if len(set(publications)) != len(publications):
            raise ConnectionError("duplicate_login_publication")


@dataclass
class _Live:
    bridge: Companion = field(repr=False)
    caller: dict
    cancelled: threading.Event = field(default_factory=threading.Event)
    authority_ended: bool = False


class Logins:
    def __init__(self, connector, journal: Journal, extension: Extension, *,
                 bridge=Companion, clock=time.time):
        self.connector, self.journal, self.extension = connector, journal, extension
        self._bridge, self._clock = bridge, clock
        self._lock, self._handles_lock = threading.RLock(), threading.Lock()
        self._lifecycle = _Lifecycle.OPEN
        self._cleanup_unconfirmed = False
        self._storage_failed = False
        self._publication_notify, self._publication_fence = None, None
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
                value = journal.read(root) or {"version": 2, "operations": []}
                records = [_decode(item) for item in value["operations"]]
                # No socket, provider owner or extension binding survives this
                # engine. Never rebind or replay a retained private operation.
                self._records = {r.operation_id: (self._changed(r, replace(r, phase=Phase.OUTCOME_UNKNOWN,
                    app_link=None, reference=None)) if r.phase not in TERMINAL else r) for r in records}
                if any(r.phase not in TERMINAL for r in records):
                    journal.write(root, self._value())
        except (OSError, ConnectionError, ValueError, TypeError):
            if self._lease is not None:
                os.close(self._lease)
                self._lease = None
            raise LoginError("unavailable") from None

    def _value(self):
        return {"version": 2, "operations": [_encode(record) for record in self._records.values()]}

    def attach_publication_delivery(self, *, notify, fence):
        """One original Service owns nonblocking notification and IO fencing."""
        with self._lock:
            if self._publication_notify is not None or self._lease is None or self._storage_failed:
                raise LoginError("unavailable")
            self._publication_notify, self._publication_fence = notify, fence

    @staticmethod
    def _changed(prior, record):
        publications = prior.publications if prior is not None else ()
        kind = _publication_kind(record.phase)
        if kind is not None and (prior is None or prior.phase is not record.phase):
            publications += (Publication(str(uuid.uuid4()), kind, record.phase, record.fill_submitted),)
        return replace(record, publications=publications)

    def _commit(self, record):
        # The state and immutable delivery intent share one atomic private
        # record. A failed replace/fsync cannot authorize another write from
        # the old in-memory snapshot: the committed result may already exist.
        if self._storage_failed:
            raise LoginError("outcome_unknown")
        records = {**self._records, record.operation_id: record}
        try:
            with self.journal.locked() as root:
                self.journal.write(root, {"version": 2, "operations": [_encode(r) for r in records.values()]})
        except (ConnectionError, OSError, ValueError, TypeError):
            self._storage_failed = True
            if self._publication_fence is not None:
                self._publication_fence()
            with self._handles_lock:
                for live in self._live.values():
                    live.cancelled.set()
                    try:
                        live.bridge.cancel()
                    except (BridgeError, OSError, ValueError, TypeError):
                        self._cleanup_unconfirmed = True
            raise LoginError("outcome_unknown") from None
        self._records = records
        if self._publication_notify is not None:
            self._publication_notify(record.operation_id)
        return record

    def _save(self, record):
        if self._storage_failed:
            raise LoginError("outcome_unknown")
        return self._commit(self._changed(self._records.get(record.operation_id), record))

    def _owned(self, operation_id, caller):
        record = self._records.get(operation_id)
        if self._lease is None or record is None or not _caller(caller) or (
                caller != record.caller and caller != {"kind": "operator"}):
            raise LoginError("unavailable")
        if self._storage_failed:
            raise LoginError("outcome_unknown")
        return record

    def pending_publications(self, operation_id, caller):
        """Private delivery inputs; no endpoint, approval link or reference.

        Re-read the same immutable envelopes after an uncertain host ACK.
        This read never allocates a replacement host/Browser binding.
        """
        return list(self.publication_snapshot(operation_id, caller).pending)

    def publication_snapshot(self, operation_id, caller):
        """Phase and pending envelopes from one committed immutable Record.

        Separate reads could observe an empty older outbox and a newer terminal
        phase, incorrectly retiring the owner before that final notice is sent.
        """
        record = self._owned(operation_id, caller)
        return PublicationSnapshot(record.phase, tuple(publication.public(operation_id)
            for publication in record.publications if not publication.host_accepted))

    def acknowledge_publication(self, operation_id, caller, envelope):
        """Commit an exact original sender's ACK without replaying its effect.

        Only the private delivery owner calls this after the host confirms
        durable admission. No public MCP tool exposes acknowledgement.
        """
        with self._lock:
            record = self._owned(operation_id, caller)
            if record.caller != caller or not isinstance(envelope, dict):
                raise LoginError("unavailable")
            publication = next((p for p in record.publications if p.matches(operation_id, envelope)), None)
            if publication is None:
                raise LoginError("unavailable")
            if not publication.host_accepted:
                self._commit(replace(record, publications=tuple(
                    replace(p, host_accepted=True) if p.publication_id == publication.publication_id else p
                    for p in record.publications)))

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
            self._dispose(live)
            record = self._save(replace(record, phase=Phase.OUTCOME_UNKNOWN))
        else:
            live.authority_ended = True
            record = self._save(replace(record, phase=phase))
        finally:
            live.bridge.close()
            with self._handles_lock:
                self._live.pop(record.operation_id, None)
        return record.public()

    def _dispose(self, live):
        """Withdraw even a not-yet-bound original nonce, then seal its client."""
        if live.authority_ended:
            live.bridge.close()
            return True
        live.bridge.cancel()
        try:
            live.bridge.withdraw()
            live.authority_ended = True
        except (BridgeError, OSError, ValueError, TypeError):
            self._cleanup_unconfirmed = True
            return False
        finally:
            live.bridge.close()
        return True

    @contextmanager
    def _admission(self):
        # MCP admission must remain available for cancellation while the owner
        # executes private IO on its background thread.
        if not self._lock.acquire(blocking=False):
            raise LoginError("unavailable")
        try:
            if self._storage_failed:
                raise LoginError("outcome_unknown")
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
                return record.public(), True
            except (LoginError, BridgeError, ConnectionError, OSError, ValueError, TypeError):
                if record is not None:
                    # This invocation has not returned acceptance yet. Its
                    # host withdraws the unused grant when admission fails.
                    live.bridge.close()
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
                if live.cancelled.is_set():
                    raise LoginError("outcome_unknown")
                live.bridge.bind(browser_instance_id=record.browser_instance_id, tab_id=record.tab_id)
                if live.cancelled.is_set():
                    raise LoginError("outcome_unknown")
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
                self._dispose(live)
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
        if self._storage_failed:
            raise LoginError("outcome_unknown")
        records = self._records
        return [r.public() for r in records.values()
                if caller == r.caller or caller == {"kind": "operator"}]

    def pending_checks(self):
        """Private scheduler inputs from the last committed snapshot."""
        if self._storage_failed:
            raise LoginError("outcome_unknown")
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
                self._dispose(live)
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
                self._dispose(live)
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
                live.bridge.interrupt()
        return record.public()

    def cancel(self, operation_id, caller):
        self.interrupt(operation_id, caller)
        with self._lock:
            record = self._owned(operation_id, caller)
            live = self._live.get(operation_id)
            withdrawn = live is None or self._dispose(live)
            if record.phase in TERMINAL:
                return record.public()
            phase = (Phase.CANCELLED if withdrawn and record.phase in {Phase.APPROVAL_READY, Phase.AWAITING_APPROVAL,
                      Phase.WAITING_USER, Phase.FILL_SUBMITTED} else Phase.OUTCOME_UNKNOWN)
            record = self._save(replace(record, phase=phase, app_link=None, reference=None))
            with self._handles_lock:
                self._live.pop(operation_id, None)
            return record.public()

    def close(self):
        with self._handles_lock:
            if self._lifecycle is _Lifecycle.OPEN:
                self._lifecycle = _Lifecycle.CLOSING
            original = tuple(self._live.values())
            for live in original:
                live.cancelled.set()
                live.bridge.cancel()
        with self._lock:
            withdrawn = all([self._dispose(live) for live in original])
            self._cleanup_unconfirmed = self._cleanup_unconfirmed or not withdrawn
            if self._lease is not None:
                os.close(self._lease)
                self._lease = None
            with self._handles_lock:
                self._live.clear()
                self._lifecycle = _Lifecycle.CLOSED
            if self._cleanup_unconfirmed or self._storage_failed:
                raise LoginError("outcome_unknown")
