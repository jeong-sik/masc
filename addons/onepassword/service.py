"""Owned background executor; MCP handlers only admit, observe or cancel.

This module carries no model messages and creates no replacement Browser.
Its waits are the vendor's approval schedule, never a Keeper task deadline.
"""
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum, auto
import heapq
import itertools
import threading
import time

from login import LoginError, Logins
from companion import BridgeError, Publisher
from delivery import Delivery


class _Phase(Enum):
    OPEN = auto()
    CLOSING = auto()
    CLOSED = auto()
    FAILED = auto()


class _Kind(Enum):
    REQUEST = auto()
    FILL = auto()
    FINISH = auto()
    OPENED = auto()
    CHECK = auto()
    CONFIRMED = auto()
    CANCEL = auto()


@dataclass(frozen=True)
class _Job:
    kind: _Kind
    operation_id: str
    caller: dict
    goal: str | None = None
    reason: str | None = None
    opened_at: float | None = None


OPERATOR = {"kind": "operator"}


class Service:
    def __init__(self, engine: Logins, *, clock=time.time, publisher=Publisher.optional):
        self.engine, self.clock = engine, clock
        self._publisher = publisher
        self._condition = threading.Condition()
        self._phase, self._cleanup_failed = _Phase.OPEN, False
        self._jobs, self._opened, self._confirmed, self._cancels = [], set(), set(), set()
        # Tie-breaking preserves admitted FIFO order; it never limits work.
        self._sequence = itertools.count()
        self._delivery = Delivery(engine)
        self._thread = threading.Thread(target=self._run, name="onepassword-login", daemon=True)
        try:
            self._thread.start()
        except RuntimeError:
            self._phase = _Phase.FAILED
            try:
                self._delivery.close()
            finally:
                try:
                    engine.close()
                except BaseException:
                    raise LoginError("outcome_unknown") from None
            raise LoginError("unavailable") from None

    def _available(self):
        with self._condition:
            if self._phase is not _Phase.OPEN:
                raise LoginError("unavailable")

    def notify(self):
        """Wake after an external clock/activity change; grants no authority."""
        self._delivery.notify()
        with self._condition:
            self._condition.notify_all()

    def _enqueue(self, job, *, due=None):
        with self._condition:
            if self._phase is not _Phase.OPEN:
                raise LoginError("unavailable")
            if job.kind is _Kind.OPENED:
                if job.operation_id in self._opened:
                    return
                self._opened.add(job.operation_id)
            elif job.kind is _Kind.CONFIRMED:
                if job.operation_id in self._confirmed:
                    return
                self._confirmed.add(job.operation_id)
            heapq.heappush(self._jobs, (self.clock() if due is None else due,
                                       next(self._sequence), job))
            self._condition.notify_all()

    def submit(self, **arguments):
        self._available()
        try:
            publisher = self._publisher(arguments["descriptor"])
        except BridgeError:
            raise LoginError("unavailable") from None
        try:
            result, reserved = self.engine.reserve(**arguments)
        except BaseException:
            if publisher is not None:
                publisher.close()
            raise
        if not reserved:
            if publisher is not None:
                publisher.close()
            raise LoginError("outcome_unknown")
        try:
            if publisher is not None:
                self._delivery.register(result["operation_id"], arguments["caller"], publisher)
            self._enqueue(_Job(_Kind.REQUEST, result["operation_id"], dict(arguments["caller"]),
                               goal=arguments["goal"], reason=arguments["reason"]))
        except LoginError:
            self._delivery.discard(result["operation_id"])
            if publisher is not None:
                publisher.close()
            try:
                self.engine.cancel(result["operation_id"], arguments["caller"])
            except LoginError:
                pass
            raise
        return result

    def status(self, operation_id, caller):
        self._available()
        result = self.engine.status(operation_id, caller)
        self._delivery.notify(operation_id)
        return result

    def operations(self, caller):
        self._available()
        result = self.engine.operations(caller)
        self._delivery.notify()
        return result

    def approval(self, operation_id):
        self._available()
        return self.engine.approval(operation_id)

    def opened(self, operation_id):
        self._available()
        # Validate the original pending operation before queuing; return only
        # its existing committed state, not a fabricated opened receipt.
        self.engine.approval(operation_id)
        result = self.engine.status(operation_id, OPERATOR)
        self._enqueue(_Job(_Kind.OPENED, operation_id, OPERATOR, opened_at=self.clock()))
        return result

    def confirmed(self, operation_id):
        self._available()
        due = self.engine.confirmation_time(operation_id)
        result = self.engine.status(operation_id, OPERATOR)
        self._enqueue(_Job(_Kind.CONFIRMED, operation_id, OPERATOR), due=due)
        return result

    def fill_next(self, operation_id, caller):
        self._available()
        result = self.engine.reserve_fill(operation_id, caller)
        self._enqueue(_Job(_Kind.FILL, operation_id, dict(caller)))
        return result

    def finish(self, operation_id, caller):
        self._available()
        result = self.engine.reserve_finish(operation_id, caller)
        self._enqueue(_Job(_Kind.FINISH, operation_id, dict(caller)))
        return result

    def cancel(self, operation_id, caller):
        with self._condition:
            if self._phase is not _Phase.OPEN:
                raise LoginError("unavailable")
            # This committed-snapshot read verifies the original caller even
            # for a repeated receipt, without waiting behind private IO.
            self.engine.status(operation_id, caller)
            if operation_id in self._cancels:
                return {"operation_id": operation_id, "cancel_requested": True}
            self._cancels.add(operation_id)
            try:
                # Hold admission through interruption and enqueue. A duplicate
                # or owner close cannot enter the gap and interrupt disposal.
                self.engine.interrupt(operation_id, caller)
                heapq.heappush(self._jobs, (self.clock(), next(self._sequence),
                    _Job(_Kind.CANCEL, operation_id, dict(caller))))
            except BaseException:
                self._cancels.discard(operation_id)
                self._condition.notify_all()
                raise
            self._condition.notify_all()
        return {"operation_id": operation_id, "cancel_requested": True}

    def _next(self):
        with self._condition:
            while self._phase is _Phase.OPEN:
                now = self.clock()
                checks = [(due, operation) for operation, due in self.engine.pending_checks()
                          if operation not in self._confirmed]
                automatic = min(checks, default=None)
                queued = self._jobs[0] if self._jobs else None
                if queued is not None and (automatic is None or queued[0] <= automatic[0]):
                    delay = queued[0] - now
                    if delay <= 0:
                        return heapq.heappop(self._jobs)
                elif automatic is not None:
                    delay = automatic[0] - now
                    if delay <= 0:
                        return (automatic[0], next(self._sequence), _Job(_Kind.CHECK, automatic[1], OPERATOR))
                else:
                    self._condition.wait()
                    continue
                self._condition.wait(delay)
            return None

    def _run(self):
        try:
            while True:
                selected = self._next()
                if selected is None:
                    return
                _, order, job = selected
                if job.kind is _Kind.REQUEST:
                    self.engine.request(job.operation_id, job.caller, goal=job.goal, reason=job.reason)
                elif job.kind is _Kind.FILL:
                    self.engine.fill(job.operation_id, job.caller)
                elif job.kind is _Kind.FINISH:
                    self.engine.finish(job.operation_id, job.caller)
                elif job.kind is _Kind.OPENED:
                    self.engine.opened(job.operation_id, opened_at=job.opened_at)
                elif job.kind is _Kind.CHECK:
                    self.engine.advance(job.operation_id, job.caller, user_confirmed=False)
                elif job.kind is _Kind.CONFIRMED:
                    try:
                        due = self.engine.confirmation_time(job.operation_id)
                    except LoginError:
                        # The original pending operation ended before dispatch.
                        # No confirmation can restart a terminal operation.
                        pass
                    else:
                        if due > self.clock():
                            with self._condition:
                                if self._phase is _Phase.OPEN:
                                    # An earlier in-flight check can extend the
                                    # vendor floor after this intent was queued.
                                    # Retain its identity, FIFO order and dedup
                                    # admission until it can actually execute.
                                    heapq.heappush(self._jobs, (due, order, job))
                                    self._condition.notify_all()
                                    continue
                        else:
                            self.engine.advance(job.operation_id, job.caller, user_confirmed=True)
                elif job.kind is _Kind.CANCEL:
                    self.engine.cancel(job.operation_id, job.caller)
                with self._condition:
                    if job.kind is _Kind.OPENED:
                        self._opened.discard(job.operation_id)
                    elif job.kind is _Kind.CONFIRMED:
                        self._confirmed.discard(job.operation_id)
                    elif job.kind is _Kind.CANCEL:
                        self._cancels.discard(job.operation_id)
                    self._condition.notify_all()
        except BaseException:
            # A background traceback can contain private programs/arguments.
            # Fence the owner and expose only a fixed unavailable disposition.
            with self._condition:
                self._phase = _Phase.FAILED
                self._condition.notify_all()
        finally:
            try:
                self._delivery.close()
            except BaseException:
                with self._condition:
                    self._cleanup_failed = True
                    self._phase = _Phase.FAILED
                    self._condition.notify_all()
            try:
                self.engine.close()
            except BaseException:
                with self._condition:
                    self._cleanup_failed = True
                    self._phase = _Phase.FAILED
                    self._condition.notify_all()

    def retire(self):
        """End admission and original IO; the owned thread settles disposal."""
        with self._condition:
            if self._phase is not _Phase.OPEN:
                return
            self._phase = _Phase.CLOSING
            self._delivery.retire()
            try:
                operations = self.engine.operations(OPERATOR)
            except LoginError:
                # The engine may already have closed its original lease.
                operations = []
            for operation in operations:
                try:
                    self.engine.interrupt(operation["operation_id"], OPERATOR)
                except LoginError:
                    pass
                except BaseException:
                    # Still interrupt the remaining original handles. Only a
                    # fixed uncertain cleanup result may leave this boundary.
                    self._cleanup_failed = True
            self._condition.notify_all()

    def close(self):
        self.retire()
        if threading.current_thread() is self._thread:
            # Retirement is accepted, but this thread cannot claim its own
            # cleanup has joined. Its finally block retains that ownership.
            raise LoginError("outcome_unknown")
        self._thread.join()
        with self._condition:
            self._jobs.clear()
            self._opened.clear()
            self._confirmed.clear()
            self._cancels.clear()
            self._phase = _Phase.CLOSED
            if self._cleanup_failed:
                raise LoginError("outcome_unknown")
