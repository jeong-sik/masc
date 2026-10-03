"""Schedule metadata, wake/fence evidence and primary columns stay readable."""
import copy
import json
import os
import re
import sys
import urllib.parse
import test_tui_keyboard_input as h


SCHEDULE_ID = "schedule-" + "0123456789abcdef" * 10 + "SCHEDULEEND"
INSTANCE = "instance-" + "retained-" * 20 + "INSTANCEEND"
TARGET = "TARGETHEAD-" + "한" * 20 + "-keeper" * 18 + "-TARGETEND"
DIGEST = "digest-" + "0123456789abcdef" * 16 + "DIGESTEND"
CRON = " ".join(",".join(str(value) for value in values)
                for values in (range(60), range(24), range(1, 32), range(1, 13), range(7)))
RECURRENCE = "cron " + CRON + " Asia/Seoul"
SOURCE = "source-" + "requested-" * 18 + "SOURCEEND"
ACTOR = "actor-" + "delegated-" * 18 + "ACTOREND"
SUMMARY = "SUMMARYHEAD\n\n" + "한 " * 15 + "scheduled evidence " * 14 + "\nSUMMARYEND"
FENCE_OWNER = "fence-" + "shutdown-operation-" * 13 + "FENCEEND"
OCCURRENCE = "occurrence-" + "retained-" * 18 + "OCCURRENCEEND"
WAKE_ERROR = "WAKEERRORHEAD " + "wake refused because source changed " * 10 + "WAKEERROREND"
REASON = "REASONHEAD\n\n" + "reaction evidence " * 14 + "\nREASONEND"
CANCEL_ERROR = "CANCELREFUSED " + "cancel refusal source detail " * 14 + "CANCELERROREND"
STAMP = "2026-09-30T01:02:03Z"
WINDOW = re.compile(rb"\[lines (\d+)-(\d+)/(\d+)\]")

def screen(output):
    end = output.rfind(h.FRAME_END)
    rows = h.screen_rows(bytes(output[:end + len(h.FRAME_END)]) if end >= 0 else bytes(output))
    return b"\n".join(rows[key] for key in sorted(rows))


def compact(text):
    return b"".join(h.unwrapped(text).split())


def window(output):
    match = WINDOW.search(screen(output))
    if match is None:
        raise AssertionError(f"Task window missing: {screen(output)!r}")
    return tuple(int(group) for group in match.groups())




def run(executable):
    fixtures = copy.deepcopy(h.schedule_detail_http_fixtures())
    snapshot = fixtures[h.SCHEDULES_PATH][1]
    row = snapshot["requests"][0]
    row.update(schedule_id=SCHEDULE_ID, schedule_instance_id=INSTANCE,
               source=SOURCE, payload_target=TARGET, payload_digest=DIGEST,
               payload_summary=SUMMARY, recurrence_summary=RECURRENCE,
               requested_at_iso=STAMP, due_at_iso=STAMP, next_due_at_iso=STAMP,
               expires_at_iso=STAMP,
               recurrence={"kind": "cron", "expression": CRON, "timezone": "Asia/Seoul"})
    row["requested_by"]["display_name"] = ACTOR
    row["scheduled_by"]["display_name"] = ACTOR
    row["payload"]["body"] = {"keeper_name": TARGET, "title": SUMMARY}
    row["runner_hold"] = {"occurrence_id": OCCURRENCE, "due_at_iso": STAMP,
        "observed_at": 1790726523.0,
        "reason": {"kind": "target_intake_fenced", "target": TARGET, "fence_owner": FENCE_OWNER}}
    row["keeper_reaction_evidence"].update(keeper_name=TARGET, post_id=OCCURRENCE,
                                         stimulus_id=DIGEST, reason=REASON)
    fixtures[h.SCHEDULES_PATH + "?schedule_id=" + urllib.parse.quote(SCHEDULE_ID)] = (200, {
        "status": "found", "schedule_id": SCHEDULE_ID, "wake_retention_per_schedule": 32,
        "wakes": [{"status": "failed", "started_at_iso": STAMP, "finished_at_iso": STAMP,
                   "error": WAKE_ERROR}]})
    posted = []
    requests = []

    def cancel(body):
        posted.append(json.loads(body))
        return 503, {"error": CANCEL_ERROR if posted[-1]["schedule_id"] == SCHEDULE_ID else "CANCELREPLACEMENTREFUSED"}

    fixtures["/api/v1/tools/masc_schedule_cancel"] = h.RequestHttpResponse(cancel)

    def interact(process, fd, _slave, output, _base):
        h.palette_go(process, fd, output, b"go schedules", b"Requests: 1")
        h.drain_until_quiet(process, fd, output)
        for width in (30, 60, 80, 120):
            h.resize_and_wait(process, fd, output, rows=18, columns=width,
                              needle=b"Requests: 1", final_cursor=b"\x1b[?25l")
            h.drain_until_quiet(process, fd, output)
            listing = screen(output)
            for heading in (b"DUE", b"TARGET", b"RECURRENCE"):
                assert heading in listing, (width, heading, listing)
            assert any(line.lstrip().startswith(b">") for line in listing.splitlines()), listing
            h.send_and_wait(process, fd, output, b"\r", b"SCHEDULE")
            h.resize_and_wait(process, fd, output, rows=400, columns=width,
                              needle=b"SCHEDULE", final_cursor=b"\x1b[?25l")
            h.wait_for_output(process, fd, output, b"WAKEERROREND", start=0, timeout=10)
            h.drain_until_quiet(process, fd, output)
            full = compact(screen(output))
            for value in (SCHEDULE_ID, INSTANCE, TARGET, DIGEST, RECURRENCE, SOURCE,
                          ACTOR, SUMMARY, FENCE_OWNER, OCCURRENCE, WAKE_ERROR, REASON, STAMP):
                assert compact(value.encode()) in full, (width, value, full)
            for rows in (18, 24):
                h.resize_and_wait(process, fd, output, rows=rows, columns=width,
                                  needle=b"SCHEDULE", final_cursor=b"\x1b[?25l")
                h.drain_until_quiet(process, fd, output)
                painted = h.screen_rows(bytes(output))
                assert max(painted) <= rows, (width, rows, max(painted))
                for text in painted.values():
                    assert h.fixture_cell_width(text.decode("utf-8", "replace")) <= width, (width, rows, text)
                first, last, total = window(output)
                assert first == 1 and last < total, (width, rows, first, last, total)
                h.send_and_wait(process, fd, output, b"\x1b[6~", b"[lines ")
                h.drain_until_quiet(process, fd, output)
                assert window(output)[0] == first + max(1, last - first), (width, rows, window(output), last)
                h.send_and_wait(process, fd, output, b"\x1b[5~", b"SCHEDULE")
                h.send_and_wait(process, fd, output, b"j", b"[lines ")
                h.drain_until_quiet(process, fd, output)
                assert window(output)[0] == 2, window(output)
                h.send_and_wait(process, fd, output, b"k", b"SCHEDULE")
                h.send_and_wait(process, fd, output, b"\x1b[F", b"[lines ")
                h.drain_until_quiet(process, fd, output)
                start, end, count = window(output)
                assert start > 1 and end == count, (width, rows, start, end, count)
                print("SCHEDULE_DETAIL_VIEWPORT " + json.dumps({"width": width, "rows": rows,
                       "window": [start, end, count], "screen": screen(output).decode("utf-8", "replace")}), flush=True)
                h.send_and_wait(process, fd, output, b"\x1b[H", b"SCHEDULE")
            h.send_and_wait(process, fd, output, b"\x1b", b"Requests: 1")
        h.send_and_wait(process, fd, output, b"\r", b"SCHEDULE")
        # A retained snapshot's source warning qualifies every evidence row,
        # including while paged away from the full raw warning in the reader.
        fixtures[h.SCHEDULES_PATH] = (503, {"error": "schedule-source-unavailable"})
        h.resize_and_wait(process, fd, output, rows=24, columns=80,
                          needle=b"SCHEDULE", final_cursor=b"\x1b[?25l")
        h.send_and_wait(process, fd, output, b"r", b"HTTP 503")
        h.drain_until_quiet(process, fd, output)
        first, last, total = window(output)
        h.send_and_wait(process, fd, output, b"\x1b[6~", b"[lines ")
        h.drain_until_quiet(process, fd, output)
        assert window(output)[0] == first + max(1, last - first), (first, last, window(output))
        assert b"HTTP 503" in screen(output), screen(output)
        h.send_and_wait(process, fd, output, b"\x1b[F", b"[lines ")
        h.drain_until_quiet(process, fd, output)
        assert window(output)[1] == window(output)[2], window(output)
        assert b"HTTP 503" in screen(output), screen(output)
        print("SCHEDULE_RETAINED_SOURCE_VIEWPORT " + json.dumps({"window": window(output),
              "screen": screen(output).decode("utf-8", "replace")}), flush=True)
        snapshot["requests"][0]["status"] = "scheduled"
        fixtures[h.SCHEDULES_PATH] = (200, snapshot)
        h.send_and_wait(process, fd, output, b"r", b"[scheduled]")
        h.drain_until_quiet(process, fd, output)
        assert b"HTTP 503" not in screen(output), screen(output)
        for rows in (18, 24):
            # The document can still be at End, or begin with a long refusal.
            # Its viewport footer is visible at both positions after resize.
            h.resize_and_wait(process, fd, output, rows=rows, columns=80,
                              needle=b"[lines ", final_cursor=b"\x1b[?25l")
            h.send_and_wait(process, fd, output, b"\x1b[F", b"[lines ")
            h.drain_until_quiet(process, fd, output)
            assert window(output)[0] > 1 and window(output)[1] == window(output)[2], window(output)
            before = len(posted)
            h.press_and_settle(process, fd, output, b"x")
            assert len(posted) == before, posted
            assert window(output)[0] > 1, window(output)
            # Refusal must be visible immediately in this small frame, before
            # Home, resize, or another x can erase the action result.
            h.send_and_wait(process, fd, output, b"x", b"CANCELREFUSED")
            h.drain_until_quiet(process, fd, output)
            assert window(output)[0] == 1, window(output)
            assert b"Cancel error:" in screen(output) and b"CANCELREFUSED" in screen(output), screen(output)
            assert posted[-1] == {"schedule_id": SCHEDULE_ID, "reason": "cancelled from the TUI"}, posted
        assert posted == [{"schedule_id": SCHEDULE_ID, "reason": "cancelled from the TUI"}] * 2, posted
        h.resize_and_wait(process, fd, output, rows=400, columns=80,
                          needle=b"CANCELERROREND", final_cursor=b"\x1b[?25l")
        assert compact(CANCEL_ERROR.encode()) in compact(screen(output)), screen(output)
        # A retained detail id can point at a removed schedule while a new
        # visible list row owns the cursor. Its first x must arm that row.
        h.send_and_wait(process, fd, output, b"x", b"Armed: cancel")
        replacement_id = "schedule-replacement-visible"
        replacement = copy.deepcopy(row)
        replacement.update(schedule_id=replacement_id, schedule_instance_id="instance-replacement",
                           payload_target="alpha", recurrence_summary="every 1800s",
                           recurrence={"kind": "interval", "interval_sec": 1800})
        snapshot["requests"] = [replacement]
        h.send_and_wait(process, fd, output, b"r", b"Requests: 1")
        h.copy_reference(process, fd, output, ("masc://schedules/" + replacement_id).encode())
        h.send_and_wait(process, fd, output, b"x", b"armed: cancel " + replacement_id.encode())
        assert len(posted) == 2, posted
        h.send_and_wait(process, fd, output, b"x", b"CANCELREPLACEMENTREFUSED")
        assert posted[-1] == {"schedule_id": replacement_id, "reason": "cancelled from the TUI"}, posted
        h.send_and_wait(process, fd, output, b"\r", replacement_id.encode())
        h.send_and_wait(process, fd, output, b"\x1b", b"Requests: 1")
        snapshot["requests"] = []
        snapshot["request_count"] = 0
        h.send_and_wait(process, fd, output, b"r", b"no scheduled automation")
        h.drain_until_quiet(process, fd, output)
        os.write(fd, b"xx")
        h.drain_until_quiet(process, fd, output)
        assert len(posted) == 3, posted
        assert b"SCHEDULE" not in screen(output), screen(output)
        os.write(fd, b"q")

    h.run_terminal_scenario(executable, description="Schedule full metadata and wake/fence evidence stay reachable",
                            interact=interact, http_fixtures=fixtures, http_requests=requests)


if __name__ == "__main__":
    run(os.path.abspath(sys.argv[1]))
    print("Schedule detail physical-row viewport: PASS")
