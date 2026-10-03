"""Inject an alpha interrupt that arrives after the immediate beta-exit check.

Usage: DYLD_LIBRARY_PATH=<artifact>/lib python3 <this-file> <native-tui>
The request is a harness injection, not a product-originated interruption.
"""
from pathlib import Path
import http.client
import json, sys, threading
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "test"))
import test_tui_keyboard_input as h
import test_tui_remote_workspace_history_pty as authority

binary = str(Path(sys.argv[1]).resolve())
original_scenario = h.run_terminal_scenario
original_escape = h.escape_to_keeper_detail
release = threading.Event()
received = threading.Event()
workers = []
statuses = []
worker_errors = []
observed = {"primary_scenario_returned": False, "interaction_finished": False}

def scenario(*args, **kwargs):
    fixtures = kwargs["http_fixtures"]
    _, turns = fixtures["/api/v1/keepers/turns"]()
    alpha = next(row for row in turns["keepers"] if row["keeper_name"] == "alpha")
    injected = {"name": "alpha", "interrupt_token": alpha["turn"]["interrupt_token"]}
    route = fixtures["/api/v1/keepers/turn/interrupt"]
    def delayed(body):
        if json.loads(body) == injected:
            received.set()
            assert release.wait(timeout=30), "negative control never released its delayed ingress"
        return route.resolve(body)
    fixtures["/api/v1/keepers/turn/interrupt"] = h.RequestHttpResponse(delayed)
    interact = kwargs["interact"]
    def wrapped_interact(process, fd, slave, output, base):
        try:
            return interact(process, fd, slave, output, base)
        finally:
            # The original interact's finally has released AtomicChatFixture.
            # Its alpha interrupt handler now returns409 without its own ledger.
            observed["interaction_finished"] = True
            release.set()
    kwargs["interact"] = wrapped_interact
    def escape(process, fd, output, *, name, **options):
        result = original_escape(process, fd, output, name=name, **options)
        if name == b"beta" and not workers:
            port = int(process.args[process.args.index("--port") + 1])
            def inject():
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
                try:
                    connection.request("POST", "/api/v1/keepers/turn/interrupt",
                        body=json.dumps(injected), headers={"Content-Type": "application/json"})
                    response = connection.getresponse()
                    statuses.append(response.status)
                    response.read()
                except Exception as error:
                    worker_errors.append(repr(error))
                finally:
                    connection.close()
            worker = threading.Thread(target=inject)
            workers.append(worker)
            worker.start()
            assert h.wait_for_fixture_event(process, fd, output, received,
                timeout=authority.WAIT_SECONDS), "delayed alpha ingress was not held"
        return result
    h.escape_to_keeper_detail = escape
    try:
        result = original_scenario(*args, **kwargs)
        observed["primary_scenario_returned"] = True
        return result
    finally:
        release.set()
        h.escape_to_keeper_detail = original_escape

h.run_terminal_scenario = scenario
try:
    authority.staged_payload_workspace_inputs(binary)
    raise RuntimeError("negative control unexpectedly passed")
except AssertionError as error:
    assert "unexpected non-beta interrupt:" in str(error), str(error)[:1000]
    for worker in workers:
        worker.join(3)
    assert not any(worker.is_alive() for worker in workers)
    assert not worker_errors, worker_errors
    assert statuses == [409], statuses
    assert observed["primary_scenario_returned"] and observed["interaction_finished"], observed
    observed.update(status="PASS_EXPECTED_REJECTION", delayed_http_status=statuses,
        assertion="unexpected non-beta interrupt", scope="harness-injected valid alpha target, delayed until normal interaction cleanup and rejected after handler join")
    print("ALPHA_INTERRUPT_NEGATIVE_CONTROL " + json.dumps(observed, sort_keys=True))
finally:
    release.set()
    h.run_terminal_scenario = original_scenario
