"""Own one unreaped session root; PID discovery never authorizes a signal.

The boundary contains an ordinary command session (including Dune's separate
action groups), not deliberate setsid/daemon escapes. Reconciliation observes
session emptiness; it is not a kernel containment or generic descendant proof.
"""

import ctypes
import errno
import os
import select
import signal
import subprocess
import sys
import time


def process_states():
    # Absolute ps avoids a diagnostic fixture or caller PATH becoming signal
    # authority. No argv or command text is inspected.
    rows = subprocess.check_output(
        ["/bin/ps", "-axo", "pid=,stat="], text=True
    ).splitlines()
    return {int(pid): state for pid, state in (row.split() for row in rows)}


class PidfdHandle:
    def __init__(self, pid):
        self.pid = pid
        self.fd = getattr(os, "pidfd_open")(pid)

    def same_process(self):
        # pidfds become readable at exit. poll also supports descriptors above
        # select's FD_SETSIZE when many action workers are held concurrently.
        poller = select.poll()
        poller.register(self.fd, select.POLLIN)
        events = poller.poll(0)
        if any(flags & select.POLLNVAL for _, flags in events):
            raise OSError(errno.EBADF, "invalid owned pidfd")
        return not events

    def send(self, signum):
        getattr(signal, "pidfd_send_signal")(self.fd, signum)

    def close(self):
        os.close(self.fd)


class DarwinSignals:
    def __init__(self):
        self.lib = ctypes.CDLL(None)
        u32 = ctypes.c_uint32
        self.lib.mach_task_self.restype = u32
        self.lib.task_name_for_pid.argtypes = [u32, ctypes.c_int, ctypes.POINTER(u32)]
        self.lib.task_info.argtypes = [
            u32,
            ctypes.c_int,
            ctypes.c_void_p,
            ctypes.POINTER(u32),
        ]
        self.lib.mach_port_deallocate.argtypes = [u32, u32]
        self.lib.proc_signal_with_audittoken.argtypes = [
            ctypes.POINTER(u32),
            ctypes.c_int,
        ]
        self.task = self.lib.mach_task_self()

    def token(self, pid):
        u32 = ctypes.c_uint32
        port = u32()
        code = self.lib.task_name_for_pid(self.task, pid, ctypes.byref(port))
        if code:
            # Mach returns KERN_FAILURE for both a vanished task and a policy
            # denial. A fresh read-only observation distinguishes zombies;
            # no numeric signal is used to recover from inspection failure.
            state = process_states().get(pid)
            if state is None or state.startswith("Z"):
                raise ProcessLookupError(errno.ESRCH, "task exited", pid)
            raise PermissionError(
                errno.EACCES, f"task_name_for_pid failed: {code}", pid
            )
        try:
            token = (u32 * 8)()
            count = u32(8)
            # TASK_AUDIT_TOKEN / TASK_AUDIT_TOKEN_COUNT: public mach/task_info.h.
            code = self.lib.task_info(port.value, 15, token, ctypes.byref(count))
            if code:
                state = process_states().get(pid)
                if state is None or state.startswith("Z"):
                    raise ProcessLookupError(errno.ESRCH, "task exited", pid)
            if code or count.value != 8 or token[5] != pid:
                raise OSError(errno.EIO, f"TASK_AUDIT_TOKEN failed: {code}", pid)
            return token
        finally:
            self.lib.mach_port_deallocate(self.task, port)

    def capture(self, pid):
        return AuditTokenHandle(self, pid, self.token(pid))


class AuditTokenHandle:
    def __init__(self, native, pid, token):
        self.native, self.pid, self.token = native, pid, token

    def same_process(self):
        return tuple(self.native.token(self.pid)) == tuple(self.token)

    def send(self, signum):
        # XNU validates the token's exact process identity inside the kernel
        # and re-acquires that identity before psignal. A stale token is ESRCH.
        code = self.native.lib.proc_signal_with_audittoken(self.token, signum)
        if code:
            raise OSError(code, os.strerror(code), self.pid)

    def close(self):
        pass


def native_capture():
    if not all(hasattr(os, name) for name in ("waitid", "WNOWAIT")):
        raise OSError(errno.ENOTSUP, "retained child ownership requires waitid WNOWAIT")
    if sys.platform == "darwin":
        try:
            return DarwinSignals().capture
        except AttributeError as error:
            raise OSError(
                errno.ENOTSUP, "Darwin audit-token signal API unavailable"
            ) from error
    if (
        sys.platform.startswith("linux")
        and hasattr(os, "pidfd_open")
        and hasattr(signal, "pidfd_send_signal")
    ):
        return PidfdHandle
    raise OSError(
        errno.ENOTSUP,
        "identity-bound process signals require Linux pidfd or Darwin audit tokens",
    )


class OwnedSession:
    def __init__(self, command, output, capture=None):
        self.capture = capture if capture is not None else native_capture()
        self.root = subprocess.Popen(
            ["bash", "-l", "-c", command],
            stdin=subprocess.DEVNULL,
            stdout=output,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        self.pid = self.root.pid
        self.handles = {}
        self.uncertainty = set()
        self.reaped = False
        self.signaling_ended = False

    def terminal_status(self):
        # Never Popen.poll(): observing exit must not release the root PID.
        result = os.waitid(os.P_PID, self.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if result is None:
            return None
        return (
            result.si_status
            if result.si_code == os.CLD_EXITED
            else 128 + result.si_status
        )

    def exited(self):
        return self.terminal_status() is not None

    def group_signal(self, signum):
        if self.signaling_ended:
            raise RuntimeError("session signaling ended before ownership release")
        if self.exited():
            # An exited root cannot propagate cancellation. Reconcile its
            # remaining workers through their captured handles instead. On
            # Darwin a zombie-only group answers EPERM, not ESRCH.
            return
        try:
            os.killpg(self.pid, signum)
        except ProcessLookupError:
            pass
        except OSError as error:
            # Root exit may race the group signal. This does not authorize a
            # claim that the group was empty: the handle sweep still runs.
            if error.errno != errno.EPERM or not self.exited():
                self.uncertainty.add(f"owned_group_signal: {error}")

    def observe(self):
        try:
            states = process_states()
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            self.uncertainty.add(f"process_inspection: {error}")
            return list(self.handles.values())
        for pid, handle in list(self.handles.items()):
            try:
                if (
                    pid not in states
                    or states[pid].startswith("Z")
                    or not handle.same_process()
                ):
                    handle.close()
                    del self.handles[pid]
                elif os.getsid(pid) != self.pid:
                    self.uncertainty.add("observed_session_escape")
            except ProcessLookupError:
                handle.close()
                del self.handles[pid]
            except OSError as error:
                self.uncertainty.add(f"owned_identity_inspection: {error}")
        for pid, state in states.items():
            if pid == self.pid or pid in self.handles or state.startswith("Z"):
                continue
            try:
                # Discovery prefilter only. Authorization is checked again
                # AFTER capture, against the still-unreaped session identity.
                if os.getsid(pid) != self.pid:
                    continue
                handle = self.capture(pid)
                try:
                    if os.getsid(pid) == self.pid:
                        self.handles[pid] = handle
                    else:
                        handle.close()
                except BaseException:
                    handle.close()
                    raise
            except ProcessLookupError:
                continue
            except OSError as error:
                self.uncertainty.add(f"owned_handle_acquisition: {error}")
        return list(self.handles.values())

    def signal_handles(self, handles, signum, sent):
        for handle in handles:
            if handle in sent:
                continue
            try:
                handle.send(signum)
                sent.add(handle)
            except ProcessLookupError:
                pass
            except OSError as error:
                self.uncertainty.add(f"owned_handle_signal: {error}")

    def finish(self, grace, tick=lambda: None):
        """Retain root ownership through signaling; reap only a terminal root.

        The existing observer has a configured TERM grace and a two-second
        post-KILL observation allowance. Preserve both rather than invent a
        new retry/TTL policy. Cancellation handlers must not raise in this phase.
        An unsettled root ends signaling and reports uncertainty without wait.
        """
        sent_term, sent_kill = set(), set()
        try:
            self.group_signal(signal.SIGTERM)
            deadline = time.monotonic() + grace
            while True:
                members = self.observe()
                root_exited = self.exited()
                if root_exited and not members:
                    break
                if root_exited:
                    # Dune's root has had its orderly signal opportunity.
                    self.signal_handles(members, signal.SIGTERM, sent_term)
                if time.monotonic() >= deadline:
                    break
                tick()
                time.sleep(0.1)
            self.group_signal(signal.SIGKILL)
            deadline = time.monotonic() + 2
            while True:
                members = self.observe()
                self.signal_handles(members, signal.SIGKILL, sent_kill)
                if self.exited() and not members:
                    break
                if time.monotonic() >= deadline:
                    self.uncertainty.add("session_members_unsettled")
                    break
                tick()
                time.sleep(0.1)
        finally:
            # Also covers inspection/tick failures and cancellation during
            # cleanup. No group signal may occur after this exact child wait.
            try:
                self.group_signal(signal.SIGKILL)
                # A failed monitor must still reach workers in Dune's other
                # process groups. Keep root ownership through this last sweep.
                self.signal_handles(
                    list(self.handles.values()), signal.SIGKILL, sent_kill
                )
                remaining = self.observe()
                self.signal_handles(remaining, signal.SIGKILL, sent_kill)
                if remaining:
                    self.uncertainty.add("final_sweep_members_not_reconciled")
            finally:
                try:
                    # End all numeric group signaling before releasing root
                    # ownership. A failed KILL must not turn the configured
                    # settlement allowance into an unbounded waitpid.
                    self.signaling_ended = True
                    if self.exited():
                        self.root.wait()
                        self.reaped = True
                    else:
                        self.uncertainty.add("root_unsettled")
                finally:
                    for handle in self.handles.values():
                        handle.close()
                    self.handles.clear()
        return self.root.returncode
