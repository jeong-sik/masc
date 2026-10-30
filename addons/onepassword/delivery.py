"""Joined original-owner outbox delivery; never executes Browser work."""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
from enum import Enum, auto
import threading

from companion import BridgeError
from login import LoginError, TERMINAL


class _Phase(Enum):
    OPEN = auto()
    CLOSING = auto()
    CLOSED = auto()


@dataclass(frozen=True)
class _Owner:
    operation_id: str
    caller: dict
    publisher: object


class Delivery:
    def __init__(self, engine):
        self.engine = engine
        self._condition = threading.Condition()
        self._phase, self._failed = _Phase.OPEN, False
        self._owners, self._ready, self._queued = {}, deque(), set()
        self._thread = threading.Thread(target=self._run, name="onepassword-publications", daemon=True)
        engine.attach_publication_delivery(notify=self.notify, fence=self.retire)
        try:
            self._thread.start()
        except RuntimeError:
            self._phase = _Phase.CLOSED
            try:
                engine.close()
            except BaseException:
                raise LoginError("outcome_unknown") from None
            raise LoginError("unavailable") from None

    def register(self, operation_id, caller, publisher):
        with self._condition:
            if self._phase is not _Phase.OPEN or operation_id in self._owners:
                raise LoginError("unavailable")
            self._owners[operation_id] = _Owner(operation_id, dict(caller), publisher)
            self._queue(operation_id)

    def _queue(self, operation_id):
        if operation_id not in self._queued:
            self._queued.add(operation_id)
            self._ready.append(operation_id)
        self._condition.notify_all()

    def notify(self, operation_id=None):
        """Existing state/observation activity reconciles pending deliveries.

        There is no new polling clock, effect retry or persisted capability.
        A notification arriving during IO remains queued for the next drain.
        """
        with self._condition:
            if self._phase is _Phase.OPEN:
                for identity in tuple(self._owners) if operation_id is None else (operation_id,):
                    if identity in self._owners:
                        self._queue(identity)

    def _next(self):
        with self._condition:
            while self._phase is _Phase.OPEN:
                if self._ready:
                    identity = self._ready.popleft()
                    self._queued.remove(identity)
                    owner = self._owners.get(identity)
                    if owner is not None:
                        return owner
                else:
                    self._condition.wait()
            return None

    def _active(self, owner):
        with self._condition:
            return self._phase is _Phase.OPEN and self._owners.get(owner.operation_id) is owner

    def _deliver(self, owner):
        try:
            for envelope in self.engine.pending_publications(owner.operation_id, owner.caller):
                if not self._active(owner):
                    return
                # No engine/admission lock is held across connect/send/ACK.
                owner.publisher.publish(envelope)
                if not self._active(owner):
                    return
                self.engine.acknowledge_publication(owner.operation_id, owner.caller, envelope)
            snapshot = self.engine.publication_snapshot(owner.operation_id, owner.caller)
            if not snapshot.pending and snapshot.phase in TERMINAL:
                self.discard(owner.operation_id)
        except BridgeError:
            # Only the same durable envelopes may be tried on later activity.
            # A transport failure does not change the login operation's phase.
            return
        except LoginError:
            # Storage uncertainty, lease loss or original-source refusal must
            # also stop a cached batch and the independent publication socket.
            self.retire()

    def _run(self):
        try:
            while (owner := self._next()) is not None:
                self._deliver(owner)
        except BaseException:
            # Never emit a traceback containing private endpoint material.
            with self._condition:
                self._failed = True
        finally:
            self.retire()
            with self._condition:
                self._phase = _Phase.CLOSED
                self._condition.notify_all()

    def discard(self, operation_id):
        with self._condition:
            owner = self._owners.pop(operation_id, None)
        if owner is not None:
            try:
                owner.publisher.close()
            except BaseException:
                with self._condition:
                    self._failed = True

    def retire(self):
        with self._condition:
            if self._phase is not _Phase.OPEN:
                return
            self._phase = _Phase.CLOSING
            owners = tuple(self._owners.values())
            self._owners.clear()
            self._ready.clear()
            self._queued.clear()
            self._condition.notify_all()
        for owner in owners:
            try:
                owner.publisher.close()
            except BaseException:
                with self._condition:
                    self._failed = True

    def close(self):
        self.retire()
        if threading.current_thread() is self._thread:
            raise LoginError("outcome_unknown")
        self._thread.join()
        if self._failed:
            raise LoginError("outcome_unknown")
