"""Backend-only 1Password Agentic Autofill connection authority.

No function in this module returns tokens, integration keys or URLs to an
agent. Operator controls use begin/complete; the browser owner's private
execution path alone may use credentials. The provider's protocol limits
are not Keeper task lifetimes. See the package README for docking work.
"""
from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, field
from enum import StrEnum
import base64
import fcntl
import functools
import hashlib
from http.client import HTTPException
import json
import math
import os
from pathlib import Path
import platform
import secrets
import stat
import threading
import time
import uuid
from urllib import error, parse, request


SCOPES = "brokered-credentials:request-access brokered-credentials:read"
WEB_ORIGIN = "https://my.1password.com"
API_ORIGIN = "https://api.1password.com"
# Request-local socket inactivity limit while OAuth holds the connection lock.
# This does not set a total request, user approval, or Keeper task deadline.
OAUTH_SOCKET_TIMEOUT_S = 30.0


class ConnectionError(Exception):
    """A safe error code, never a provider body, URL or exception message."""


class Phase(StrEnum):
    DISCONNECTED = "disconnected"
    AUTHORIZING = "authorizing"
    EXCHANGING = "exchanging"
    CONNECTED = "connected"
    REFRESHING = "refreshing"
    REVOKING = "revoking"
    RECONNECT_REQUIRED = "reconnect_required"


def text(value, code: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ConnectionError(code)
    return value


def https_url(value: str) -> str:
    try:
        url = parse.urlsplit(text(value, "invalid_redirect_uri"))
        if (url.scheme != "https" or not url.hostname or url.username is not None
                or url.password is not None or url.fragment or url.query
                or url.hostname in {"localhost", "127.0.0.1", "::1"}):
            raise ConnectionError("invalid_redirect_uri")
        # Accessing port also rejects malformed authority syntax.
        url.port
    except ValueError:
        raise ConnectionError("invalid_redirect_uri") from None
    return value


@dataclass(frozen=True)
class Configuration:
    client_id: str
    client_secret: str = field(repr=False)
    redirect_uri: str

    def __post_init__(self):
        text(self.client_id, "invalid_client_id")
        text(self.client_secret, "invalid_client_secret")
        https_url(self.redirect_uri)

    @property
    def identity(self) -> str:
        """Bind storage to the OAuth client, not to its rotatable secret."""
        public = [self.client_id, self.redirect_uri, WEB_ORIGIN, API_ORIGIN, SCOPES]
        encoded = json.dumps(public, ensure_ascii=True, separators=(",", ":")).encode()
        return hashlib.sha256(b"masc.1password.oauth.configuration.v1\n" + encoded).hexdigest()


def positive_finite(value) -> bool:
    if type(value) not in {int, float}:
        return False
    try:
        return value > 0 and math.isfinite(value)
    except OverflowError:
        return False


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ConnectionError("invalid_connection_record")
        result[key] = value
    return result


def reject_constant(value):
    raise ConnectionError("invalid_connection_record")


def validate_record(value: dict):
    """Validate every retained field before any state or credential is used."""
    if not isinstance(value, dict) or not isinstance(value.get("phase"), str):
        raise ConnectionError("invalid_connection_record")
    try:
        phase = Phase(value["phase"])
    except ValueError:
        raise ConnectionError("invalid_connection_record") from None
    base = {"phase", "configuration_id"}
    pending = base | {"connection_id"}
    tokens = pending | {"integration_key", "access_token", "refresh_token", "expires_at"}
    fields = {
        Phase.DISCONNECTED: base | ({"declined_callback"} if "declined_callback" in value else set()),
        Phase.AUTHORIZING: pending | {"state", "verifier"},
        Phase.EXCHANGING: pending | {"integration_key"},
        Phase.CONNECTED: tokens,
        Phase.REFRESHING: tokens,
        Phase.REVOKING: tokens,
    }
    # RECONNECT_REQUIRED is a safe observation of an interrupted operation,
    # never a substitute persisted shape with missing recovery authority.
    if phase not in fields or set(value) != fields[phase]:
        raise ConnectionError("invalid_connection_record")
    identifier = text(value["configuration_id"], "invalid_connection_record")
    if len(identifier) != 64 or any(character not in "0123456789abcdef" for character in identifier):
        raise ConnectionError("invalid_connection_record")
    for key in fields[phase] - {"phase", "configuration_id", "expires_at", "declined_callback"}:
        text(value[key], "invalid_connection_record")
    connections = [value["connection_id"]] if "connection_id" in value else []
    if "declined_callback" in value:
        declined = value["declined_callback"]
        if (not isinstance(declined, dict) or set(declined) != {"kind", "connection_id", "state"}
                or declined["kind"] != "declined"):
            raise ConnectionError("invalid_connection_record")
        text(declined["state"], "invalid_connection_record")
        connections.append(text(declined["connection_id"], "invalid_connection_record"))
    for identity in connections:
        try:
            connection = uuid.UUID(identity)
        except ValueError:
            raise ConnectionError("invalid_connection_record") from None
        if str(connection) != identity or connection.version != 4:
            raise ConnectionError("invalid_connection_record")
    if "expires_at" in value and not positive_finite(value["expires_at"]):
        raise ConnectionError("invalid_connection_record")


_macos_interaction_lock = threading.RLock()


def _macos_record_operation(api, operation):
    """Suppress file-based Keychain UI only while this record call owns it."""
    from ctypes import POINTER, byref, c_ubyte

    # SecItem authentication options do not cover the file-based Keychain.
    # Its interaction policy belongs to the process, so connection and login
    # records share this lock through native work and restoration.
    with _macos_interaction_lock:
        get_allowed = api._sec.SecKeychainGetUserInteractionAllowed
        get_allowed.argtypes = [POINTER(c_ubyte)]
        get_allowed.restype = api.OS_status
        set_allowed = api._sec.SecKeychainSetUserInteractionAllowed
        set_allowed.argtypes = [c_ubyte]
        set_allowed.restype = api.OS_status
        previous = c_ubyte()
        if get_allowed(byref(previous)) != 0:
            raise ConnectionError("protected_store_unavailable")
        try:
            if set_allowed(False) != 0:
                raise ConnectionError("protected_store_unavailable")
            return operation()
        finally:
            if set_allowed(previous.value) != 0:
                raise ConnectionError("protected_store_unavailable")


class ProtectedRecords:
    """Only the OS credential store; never a discovered or plaintext backend."""

    def __init__(self, identity: str):
        self.service = "org.masc.onepassword." + identity
        self.backend = None

    @staticmethod
    @functools.cache
    def _backend_class():
        try:
            if platform.system() == "Darwin":
                from keyring.backends.macOS import Keyring, api

                class NativeKeyring(Keyring):
                    keychain = None

                    def set_properties_from_env(self):
                        pass

                    def get_password(self, service, username):
                        read = super().get_password
                        return _macos_record_operation(api, lambda: read(service, username))

                    def set_password(self, service, username, password):
                        write = super().set_password
                        return _macos_record_operation(api, lambda: write(service, username, password))
            elif platform.system() == "Linux":
                from keyring.backends.SecretService import Keyring, secretstorage
                from keyring.errors import KeyringLocked

                class NativeKeyring(Keyring):
                    def set_properties_from_env(self):
                        pass

                    def get_preferred_collection(self):
                        # Do not create a collection or prompt to unlock one.
                        bus = secretstorage.dbus_init()
                        try:
                            collection = secretstorage.get_collection_by_alias(bus, "default")
                            if collection.is_locked():
                                raise KeyringLocked()
                            return collection
                        except Exception:
                            bus.close()
                            raise

                    def unlock(self, item):
                        if item.is_locked():
                            raise KeyringLocked()
            else:
                raise ConnectionError("protected_store_unavailable")
            return NativeKeyring
        except Exception:
            raise ConnectionError("protected_store_unavailable") from None

    def _backend(self):
        if self.backend is None:
            self.backend = self._backend_class()()
        return self.backend

    def read(self, slot: int) -> str | None:
        try:
            return self._backend().get_password(self.service, str(slot))
        except Exception:
            raise ConnectionError("protected_store_unavailable") from None

    def write(self, slot: int, value: str):
        try:
            self._backend().set_password(self.service, str(slot), value)
        except Exception:
            raise ConnectionError("protected_store_unavailable") from None


class PrivateStore:
    """Encrypted records with a nonsecret, locked commit reference.

    All file operations are relative to the original directory descriptor.
    Symlinks, hard-linked files and a replaced directory are refused. This is
    backend storage under the operator's UID, not an OS isolation boundary.
    Provisioning is explicit; readers never create a missing directory.
    """
    _record_name = "connection.json"
    _reference_name = "connection.reference.json"
    _reference_schema = "masc.1password.protected.v1"
    _validate = staticmethod(validate_record)

    def __init__(self, directory: Path, *, records=None, provision: bool = False):
        if not directory.is_absolute():
            raise ConnectionError("store_path_not_absolute")
        self.directory = directory
        if provision:
            self.directory.mkdir(mode=0o700, exist_ok=True)
        self.identity = self._directory_identity()
        self.thread_lock = threading.RLock()
        namespace = json.dumps([self._reference_schema, self._record_name, os.getuid(),
                                str(directory.resolve()), *self.identity],
                               separators=(",", ":")).encode()
        self.records = records if records is not None else ProtectedRecords(hashlib.sha256(namespace).hexdigest())

    @staticmethod
    def _owned(info, *, directory=False):
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if (not expected(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != (0o700 if directory else 0o600)
                or (not directory and info.st_nlink != 1)):
            raise ConnectionError("unsafe_secret_store")

    def _directory_identity(self):
        info = self.directory.lstat()
        self._owned(info, directory=True)
        return info.st_dev, info.st_ino

    @contextmanager
    def locked(self, *, blocking=True):
        if not self.thread_lock.acquire(blocking=blocking):
            raise ConnectionError("secret_store_busy")
        try:
            if self._directory_identity() != self.identity:
                raise ConnectionError("secret_store_replaced")
            root = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            lock = None
            try:
                info = os.fstat(root)
                if (info.st_dev, info.st_ino) != self.identity:
                    raise ConnectionError("secret_store_replaced")
                lock = os.open("connection.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW
                               | os.O_NONBLOCK, 0o600, dir_fd=root)
                self._owned(os.fstat(lock))
                fcntl.flock(lock, fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB))
                yield root
                if self._directory_identity() != self.identity:
                    raise ConnectionError("secret_store_replaced")
            finally:
                if lock is not None:
                    os.close(lock)
                os.close(root)
        finally:
            self.thread_lock.release()

    def _reference(self, root: int) -> int | None:
        try:
            os.stat(self._record_name, dir_fd=root, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            # Old plaintext state needs explicit operator reconciliation. Never
            # silently adopt, copy, delete, or fall back to it.
            raise ConnectionError("plaintext_connection_reconciliation_required")
        try:
            fd = os.open(self._reference_name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=root)
        except FileNotFoundError:
            return None
        try:
            self._owned(os.fstat(fd))
            with os.fdopen(fd, "r", encoding="utf-8", closefd=False) as stream:
                value = json.load(stream, object_pairs_hook=unique_object,
                                  parse_constant=reject_constant)
        except (ValueError, UnicodeError):
            raise ConnectionError("invalid_connection_record") from None
        finally:
            os.close(fd)
        if (not isinstance(value, dict) or set(value) != {"schema", "slot"}
                or value["schema"] != self._reference_schema
                or type(value["slot"]) is not int or value["slot"] not in {0, 1}):
            raise ConnectionError("invalid_connection_reference")
        return value["slot"]

    def read(self, root: int) -> dict | None:
        slot = self._reference(root)
        # Even an empty directory must not disguise an unavailable/locked
        # backend as a disconnected account.
        raw = self.records.read(0 if slot is None else slot)
        if slot is None:
            return None
        if not isinstance(raw, str):
            raise ConnectionError("protected_connection_missing")
        try:
            value = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
        except (ValueError, UnicodeError):
            raise ConnectionError("invalid_connection_record") from None
        self._validate(value)
        return value

    def write(self, root: int, value: dict):
        self._validate(value)
        current = self._reference(root)
        slot = 0 if current is None else 1 - current
        raw = json.dumps(value, allow_nan=False, separators=(",", ":"))
        # keyring's macOS writer deletes before adding. Only replace the
        # inactive slot, then verify it before publishing the new reference.
        self.records.write(slot, raw)
        if self.records.read(slot) != raw:
            raise ConnectionError("protected_store_write_unconfirmed")
        temporary = ".connection-" + secrets.token_hex(16)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=root)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as stream:
                json.dump({"schema": self._reference_schema, "slot": slot}, stream,
                          separators=(",", ":"))
                stream.flush()
                os.fsync(fd)
            if self._directory_identity() != self.identity:
                raise ConnectionError("secret_store_replaced")
            os.replace(temporary, self._reference_name, src_dir_fd=root, dst_dir_fd=root)
            temporary = None
            os.fsync(root)
        finally:
            os.close(fd)
            if temporary is not None:
                os.unlink(temporary, dir_fd=root)


class NoRedirect(request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def post(path: str, fields: dict, configuration: Configuration) -> dict:
    """Fixed production origin; never forward Basic auth to a redirect."""
    basic = base64.b64encode((parse.quote(configuration.client_id, safe="") + ":"
                              + parse.quote(configuration.client_secret, safe="")).encode()).decode()
    req = request.Request(API_ORIGIN + path, data=parse.urlencode(fields).encode(),
                          headers={"Authorization": "Basic " + basic,
                                   "Content-Type": "application/x-www-form-urlencoded"},
                          method="POST")
    try:
        with request.build_opener(NoRedirect).open(req, timeout=OAUTH_SOCKET_TIMEOUT_S) as response:
            body = response.read()
        value = json.loads(body)
    except error.HTTPError as failure:
        failure.close()
        raise ConnectionError("oauth_http_failure") from None
    except (error.URLError, HTTPException, OSError, ValueError, UnicodeError):
        raise ConnectionError("oauth_transport_or_response_failure") from None
    if not isinstance(value, dict):
        raise ConnectionError("invalid_token_response")
    return value


class Connector:
    def __init__(self, configuration: Configuration, store: PrivateStore, *,
                 transport=post, now=time.time):
        self.configuration = configuration
        self.store = store
        self.transport = transport
        self.now = now

    def _disconnected(self) -> dict:
        return {"phase": Phase.DISCONNECTED.value,
                "configuration_id": self.configuration.identity}

    def _read(self, root: int) -> dict:
        record = self.store.read(root)
        if record is None:
            return self._disconnected()
        if record["configuration_id"] != self.configuration.identity:
            raise ConnectionError("connection_configuration_mismatch")
        return record

    def status(self, *, blocking=True) -> dict:
        with self.store.locked(blocking=blocking) as root:
            record = self._read(root)
            phase = Phase(record["phase"])
            # An interrupted one-use exchange/rotation is never replayed.
            if phase in {Phase.EXCHANGING, Phase.REFRESHING, Phase.REVOKING}:
                phase = Phase.RECONNECT_REQUIRED
            return {"phase": phase.value, "connected": phase is Phase.CONNECTED}

    def begin(self) -> dict:
        """Operator-only result: MUST NOT enter public MCP results or Lane rows."""
        with self.store.locked() as root:
            old = self._read(root)
            if Phase(old["phase"]) is not Phase.DISCONNECTED:
                raise ConnectionError("disconnect_before_connecting")
            state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(64)
            connection_id = str(uuid.uuid4())
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
            self.store.write(root, {"phase": Phase.AUTHORIZING.value,
                                    "configuration_id": self.configuration.identity,
                                    "connection_id": connection_id,
                                    "state": state, "verifier": verifier})
            parameters = {"response_type": "code", "client_id": self.configuration.client_id,
                          "redirect_uri": self.configuration.redirect_uri, "scope": SCOPES,
                          "state": state, "code_challenge": challenge,
                          "code_challenge_method": "S256"}
            return {"authorization_url": WEB_ORIGIN + "/oauth/authorize?" + parse.urlencode(parameters),
                    "connection_id": connection_id}

    def callback_receipt(self) -> dict | None:
        """Private observation of a durably captured key, never a use grant.

        Only post-capture records carry a key. A busy/unavailable store must
        not be replaced with an acknowledgement derived from UI state.
        """
        with self.store.locked(blocking=False) as root:
            record = self._read(root)
            if Phase(record["phase"]) in {Phase.EXCHANGING, Phase.CONNECTED, Phase.REFRESHING, Phase.REVOKING}:
                # write() verifies the protected payload before publishing its
                # reference. Confirm that reference even if the original
                # directory fsync failed and its response became uncertain.
                os.fsync(root)
                return {"kind": "captured", "connection_id": record["connection_id"]}
            return None

    def authorization_identity(self) -> dict:
        """Private operator continuation; never includes PKCE verifier/tokens."""
        with self.store.locked() as root:
            record = self._read(root)
            if Phase(record["phase"]) is not Phase.AUTHORIZING:
                raise ConnectionError("authorization_not_pending")
            return {"state": record["state"], "connection_id": record["connection_id"]}

    def cancel_authorization(self, *, expected_state: str, expected_connection_id: str) -> dict:
        """Cancel exactly the pending authorization the operator was shown.

        The authoritative phase and both identities are checked under the
        same lock as the write. A late UI request cannot cancel a later
        attempt or revoke an authorization whose callback has already begun.
        This private operation never sends a provider request.
        """
        with self.store.locked() as root:
            record = self._read(root)
            if (Phase(record["phase"]) is not Phase.AUTHORIZING
                    or not isinstance(expected_state, str)
                    or not isinstance(expected_connection_id, str)):
                raise ConnectionError("authorization_cancel_refused")
            try:
                matches_state = secrets.compare_digest(expected_state.encode(), record["state"].encode())
                matches_connection = secrets.compare_digest(expected_connection_id.encode(),
                                                              record["connection_id"].encode())
            except UnicodeError:
                raise ConnectionError("authorization_cancel_refused") from None
            if not matches_state or not matches_connection:
                raise ConnectionError("authorization_cancel_refused")
            self.store.write(root, self._disconnected())
            return {"phase": Phase.DISCONNECTED.value, "connected": False}

    def decline_authorization(self, *, expected_state: str, expected_connection_id: str) -> dict:
        """Commit the exact callback acknowledgement with its cancellation.

        Redelivery may recover only this same state/connection receipt. A new
        attempt replaces it, while ordinary cancellation and views do not
        manufacture a declined callback. The protected record alone owns it.
        """
        def matches(identity):
            if not isinstance(expected_state, str) or not isinstance(expected_connection_id, str):
                return False
            try:
                return (secrets.compare_digest(expected_state.encode(), identity["state"].encode())
                        and secrets.compare_digest(expected_connection_id.encode(),
                                                   identity["connection_id"].encode()))
            except UnicodeError:
                return False

        with self.store.locked() as root:
            record = self._read(root)
            phase = Phase(record["phase"])
            if phase is Phase.AUTHORIZING and matches(record):
                declined = {"kind": "declined", "connection_id": record["connection_id"],
                            "state": record["state"]}
                self.store.write(root, {**self._disconnected(), "declined_callback": declined})
            elif (phase is Phase.DISCONNECTED and "declined_callback" in record
                  and matches(record["declined_callback"])):
                declined = record["declined_callback"]
                # A prior reference rename can be visible after its directory
                # sync failed. Confirm that same commit before acknowledging it.
                os.fsync(root)
            else:
                raise ConnectionError("authorization_decline_refused")
            return {"kind": declined["kind"], "connection_id": declined["connection_id"]}

    def _tokens(self, value: dict) -> dict:
        if not isinstance(value, dict):
            raise ConnectionError("invalid_token_response")
        if text(value.get("token_type"), "invalid_token_type").lower() != "bearer":
            raise ConnectionError("invalid_token_type")
        expires = value.get("expires_in")
        if not positive_finite(expires):
            raise ConnectionError("invalid_token_expiry")
        if "scope" in value and set(text(value["scope"], "invalid_token_scope").split()) != set(SCOPES.split()):
            raise ConnectionError("invalid_token_scope")
        expires_at = self.now() + expires
        if not positive_finite(expires_at):
            raise ConnectionError("invalid_token_expiry")
        return {"access_token": text(value.get("access_token"), "missing_access_token"),
                "refresh_token": text(value.get("refresh_token"), "missing_refresh_token"),
                "expires_at": expires_at}

    def complete(self, *, state: str, code: str, integration_key: str) -> dict:
        """Called only by the authenticated operator callback after fragment capture."""
        with self.store.locked() as root:
            old = self._read(root)
            if (Phase(old["phase"]) is not Phase.AUTHORIZING
                    or not secrets.compare_digest(text(state, "invalid_state"), old["state"])):
                raise ConnectionError("oauth_state_mismatch")
            text(code, "missing_authorization_code")
            text(integration_key, "missing_integration_key")
            connection = {"configuration_id": old["configuration_id"],
                          "connection_id": old["connection_id"],
                          "integration_key": integration_key}
            self.store.write(root, {"phase": Phase.EXCHANGING.value, **connection})
            tokens = self._tokens(self.transport("/v1/oauth/token", {
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": self.configuration.redirect_uri,
                "code_verifier": old["verifier"]}, self.configuration))
            self.store.write(root, {"phase": Phase.CONNECTED.value, **connection, **tokens})
        return self.status()

    def _ready(self, root: int, record: dict) -> dict:
        if Phase(record["phase"]) is not Phase.CONNECTED:
            raise ConnectionError("connection_not_ready")
        if self.now() >= record["expires_at"]:
            # The durable marker fences reuse of the rotating refresh token
            # if dispatch or its response is lost. Never replay on restart.
            self.store.write(root, {**record, "phase": Phase.REFRESHING.value})
            tokens = self._tokens(self.transport("/v1/oauth/token", {
                "grant_type": "refresh_token", "refresh_token": record["refresh_token"],
                "scope": SCOPES}, self.configuration))
            record = {**record, **tokens}
            self.store.write(root, record)
        return record

    def connection_identity(self) -> str:
        """Private pin for a new browser operation; not an execution grant.

        A caller retains this identity with its operation and passes it back
        to credentials. Reconnecting creates a new identity, even under the
        same OAuth client, so an old operation cannot borrow its new account.
        """
        with self.store.locked() as root:
            record = self._read(root)
            if Phase(record["phase"]) is not Phase.CONNECTED:
                raise ConnectionError("connection_not_ready")
            return record["connection_id"]

    def credentials(self, use, *, expected_connection_id: str):
        """Private browser callback; never expose this as a tool or observation.

        Hold the connection lock through use so disconnect/rotation cannot
        interleave. The browser caller owns its session serialization and
        rejects stale owner generations before invoking this function. The
        required connection identity is checked before refreshing or using
        credentials, so reconnecting cannot retarget an existing operation.
        """
        with self.store.locked() as root:
            record = self._read(root)
            if record.get("connection_id") != text(expected_connection_id, "invalid_connection_identity"):
                raise ConnectionError("connection_identity_mismatch")
            record = self._ready(root, record)
            return use(record["access_token"], record["integration_key"])

    def disconnect(self, revoke):
        """Revoke via a backend callback before deleting local credentials.

        Interrupted revocation keeps the original tokens for operator recovery,
        while all browser use is fenced. It never claims remote revocation.
        """
        with self.store.locked() as root:
            record = self._read(root)
            phase = Phase(record["phase"])
            if phase is Phase.DISCONNECTED:
                return {"phase": phase.value, "connected": False}
            if phase is Phase.AUTHORIZING:
                raise ConnectionError("authorization_cancel_required")
            elif phase is Phase.CONNECTED:
                # Revocation also needs a current access token. Only a known
                # CONNECTED record can rotate; unknown refresh/revoke states
                # remain fenced for explicit remote reconciliation.
                record = self._ready(root, record)
                self.store.write(root, {**record, "phase": Phase.REVOKING.value})
                revoke(record["access_token"], record["integration_key"])
                self.store.write(root, self._disconnected())
            else:
                raise ConnectionError("remote_connection_reconciliation_required")
        return self.status()
