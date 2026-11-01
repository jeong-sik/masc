"""A total deadline for the standalone Goal confirmation CLI's HTTP work."""
from contextlib import contextmanager
import signal
import time

# Match the Dashboard's ordinary 35-second read deadline; a timed-out POST is
# an unknown outcome, never permission to resend it.
REQUEST_DEADLINE_SECONDS = 35.0


@contextmanager
def request_deadline(seconds=REQUEST_DEADLINE_SECONDS):
    def expired(_signum, _frame):
        raise TimeoutError('Goal confirmation HTTP request deadline elapsed')

    prior_handler = signal.getsignal(signal.SIGALRM)
    prior_delay, prior_interval = signal.setitimer(signal.ITIMER_REAL, 0)
    started = time.monotonic()
    signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, prior_handler)
        if prior_delay > 0:
            remaining = max(prior_delay - (time.monotonic() - started), 0.000001)
            signal.setitimer(signal.ITIMER_REAL, remaining, prior_interval)
