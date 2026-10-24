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
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import stat
import threading
import time
from urllib import error, parse, request


SCOPES = "brokered-credentials:request-access brokered-credentials:read"
WEB_ORIGIN = "https://my.1password.com"
API_ORIGIN = "https://api.1password.com"


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


class PrivateStore:
    """One backend's 0700 directory, 0600 records, locked across processes.

    All file operations are relative to the original directory descriptor.
    Symlinks, hard-linked files and a replaced directory are refused. This is
    backend storage under the operator's UID, not an OS isolation boundary.
    """
    def __init__(self, directory: Path):
        if not directory.is_absolute():
            raise ConnectionError("store_path_not_absolute")
        self.directory = directory
        self.directory.mkdir(mode=0o700, exist_ok=True)
        self.identity = self._directory_identity()
        self.thread_lock = threading.RLock()

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
    def locked(self):
        with self.thread_lock:
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
                fcntl.flock(lock, fcntl.LOCK_EX)
                yield root
                if self._directory_identity() != self.identity:
                    raise ConnectionError("secret_store_replaced")
            finally:
                if lock is not None:
                    os.close(lock)
                os.close(root)

    def read(self, root: int) -> dict:
        try:
            fd = os.open("connection.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                         dir_fd=root)
        except FileNotFoundError:
            return {"phase": Phase.DISCONNECTED.value}
        try:
            self._owned(os.fstat(fd))
            with os.fdopen(fd, "r", encoding="utf-8", closefd=False) as stream:
                value = json.load(stream)
        except (ValueError, UnicodeError):
            raise ConnectionError("invalid_connection_record") from None
        finally:
            os.close(fd)
        if not isinstance(value, dict):
            raise ConnectionError("invalid_connection_record")
        try:
            Phase(value.get("phase"))
        except ValueError:
            raise ConnectionError("invalid_connection_record") from None
        return value

    def write(self, root: int, value: dict):
        temporary = ".connection-" + secrets.token_hex(16)
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                     0o600, dir_fd=root)
        try:
            with os.fdopen(fd, "w", encoding="utf-8", closefd=False) as stream:
                json.dump(value, stream, allow_nan=False, separators=(",", ":"))
                stream.flush()
                os.fsync(fd)
            if self._directory_identity() != self.identity:
                raise ConnectionError("secret_store_replaced")
            os.replace(temporary, "connection.json", src_dir_fd=root, dst_dir_fd=root)
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
        with request.build_opener(NoRedirect).open(req) as response:
            body = response.read()
        value = json.loads(body)
    except error.HTTPError as failure:
        failure.close()
        raise ConnectionError("oauth_http_failure") from None
    except (error.URLError, OSError, ValueError, UnicodeError):
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

    def status(self) -> dict:
        with self.store.locked() as root:
            record = self.store.read(root)
            phase = Phase(record["phase"])
            # An interrupted one-use exchange/rotation is never replayed.
            if phase in {Phase.EXCHANGING, Phase.REFRESHING, Phase.REVOKING}:
                phase = Phase.RECONNECT_REQUIRED
            return {"phase": phase.value, "connected": phase is Phase.CONNECTED}

    def begin(self) -> dict:
        """Operator-only result: MUST NOT enter MCP results or Lane rows."""
        with self.store.locked() as root:
            old = self.store.read(root)
            if Phase(old["phase"]) is not Phase.DISCONNECTED:
                raise ConnectionError("disconnect_before_connecting")
            state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(64)
            challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
            self.store.write(root, {"phase": Phase.AUTHORIZING.value, "state": state,
                                    "verifier": verifier})
            parameters = {"response_type": "code", "client_id": self.configuration.client_id,
                          "redirect_uri": self.configuration.redirect_uri, "scope": SCOPES,
                          "state": state, "code_challenge": challenge,
                          "code_challenge_method": "S256"}
            return {"authorization_url": WEB_ORIGIN + "/oauth/authorize?" + parse.urlencode(parameters)}

    def _tokens(self, value: dict) -> dict:
        if value.get("token_type", "").lower() != "bearer":
            raise ConnectionError("invalid_token_type")
        expires = value.get("expires_in")
        if (type(expires) not in {int, float} or not math.isfinite(expires) or expires <= 0):
            raise ConnectionError("invalid_token_expiry")
        if "scope" in value and set(text(value["scope"], "invalid_token_scope").split()) != set(SCOPES.split()):
            raise ConnectionError("invalid_token_scope")
        return {"access_token": text(value.get("access_token"), "missing_access_token"),
                "refresh_token": text(value.get("refresh_token"), "missing_refresh_token"),
                "expires_at": self.now() + expires}

    def complete(self, *, state: str, code: str, integration_key: str) -> dict:
        """Called only by the authenticated operator callback after fragment capture."""
        with self.store.locked() as root:
            old = self.store.read(root)
            if (Phase(old["phase"]) is not Phase.AUTHORIZING
                    or not secrets.compare_digest(text(state, "invalid_state"), old["state"])):
                raise ConnectionError("oauth_state_mismatch")
            text(code, "missing_authorization_code")
            text(integration_key, "missing_integration_key")
            self.store.write(root, {"phase": Phase.EXCHANGING.value})
            tokens = self._tokens(self.transport("/v1/oauth/token", {
                "grant_type": "authorization_code", "code": code,
                "redirect_uri": self.configuration.redirect_uri,
                "code_verifier": old["verifier"]}, self.configuration))
            self.store.write(root, {"phase": Phase.CONNECTED.value,
                                    "integration_key": integration_key, **tokens})
        return self.status()

    def credentials(self, use):
        """Private browser callback; never expose this as a tool or observation.

        Hold the connection lock through use so disconnect/rotation cannot
        interleave. The browser caller owns its session serialization and
        rejects stale owner generations before invoking this function.
        """
        with self.store.locked() as root:
            record = self.store.read(root)
            if Phase(record["phase"]) is not Phase.CONNECTED:
                raise ConnectionError("connection_not_ready")
            if self.now() >= record["expires_at"]:
                # Retain revocation authority, but fence reuse of the rotating
                # refresh token before sending it. A lost response requires
                # reconnect; it never causes another refresh on restart.
                self.store.write(root, {**record, "phase": Phase.REFRESHING.value})
                tokens = self._tokens(self.transport("/v1/oauth/token", {
                    "grant_type": "refresh_token", "refresh_token": record["refresh_token"],
                    "scope": SCOPES}, self.configuration))
                record = {**record, **tokens}
                self.store.write(root, record)
            return use(record["access_token"], record["integration_key"])

    def disconnect(self, revoke):
        """Revoke via a backend callback before deleting local credentials.

        Interrupted revocation keeps the original tokens for operator recovery,
        while all browser use is fenced. It never claims remote revocation.
        """
        with self.store.locked() as root:
            record = self.store.read(root)
            phase = Phase(record["phase"])
            if phase is Phase.DISCONNECTED:
                return {"phase": phase.value, "connected": False}
            if phase is Phase.AUTHORIZING:
                self.store.write(root, {"phase": Phase.DISCONNECTED.value})
            elif "access_token" in record:
                self.store.write(root, {**record, "phase": Phase.REVOKING.value})
                revoke(record["access_token"], record["integration_key"])
                self.store.write(root, {"phase": Phase.DISCONNECTED.value})
            else:
                raise ConnectionError("remote_connection_reconciliation_required")
        return self.status()
