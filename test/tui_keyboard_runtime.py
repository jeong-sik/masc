from __future__ import annotations

import os
import re
import subprocess
import time

from tui_keyboard_harness import (
    CSI_RE,
    FRAME_END,
    FULL_REDRAW,
    RUNTIME_RESOLVED_PATH,
    GatedHttpResponse,
    HttpFixtures,
    HttpResponse,
    Interaction,
    SequencedHttpResponse,
    drain_until_quiet,
    kill_process_group,
    overview_event_http_fixtures,
    poll_for_output,
    read_available,
    resize_and_wait,
    run_terminal_scenario,
    screen_row_of,
    screen_rows,
    screen_text,
    send_and_wait,
    tab_until,
    wait_for_fixture_event,
    wait_for_fixture_served,
    wait_for_output,
)

RUNTIME_PROBE_PATH = "/api/v1/dashboard/runtime-probe"
RUNTIME_PROBE_FORCE_PATH = f"{RUNTIME_PROBE_PATH}?force=1"
RUNTIME_CONFIG_RAW_PATH = "/api/v1/runtime/config/raw"


def runtime_config_read_metadata() -> dict[str, object]:
    return {
        "ok": True,
        "source_revision": "fixture-read-revision",
        "validation": {
            "valid": True, "schema_version": 1, "current_schema_version": 1,
            "forward_schema": False, "issues": [],
        },
        "application": {
            "operation": "read",
            "routing": {"status": "active", "requires_restart": False},
            "keeper_overlay": {
                "status": "pending_restart", "configured_count": 1,
                "requires_restart": True, "pending_keys": ["keeper.pending"],
                "applied_keys": [], "preempted_keys": [],
            },
        },
    }


def config_navigation_source() -> str:
    lines = [
        "# operator notes stay visible",
        "first-value = 1",
        "# another note",
        "",
        "second-value = 2",
    ]
    lines.extend(f"# context row {index}" for index in range(5, 27))
    lines.extend(
        [
            "[models.alpha]",
            "temperature = 0.7",
            'reasoning-effort = "high"',
            "# model comment",
            "[ollama_cloud.alpha]",
            "max-tokens = 16384",
        ]
    )
    return "\n".join(lines)


def config_navigation_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        base_path: str,
    ) -> None:
        tab_until(process, master_fd, output, b"MASC System")
        wait_for_output(
            process,
            master_fd,
            output,
            b"first-value = ",
            start=0,
            timeout=3.0,
        )
        # The paths row keeps each path's tail and the binary age. #36354
        # named a nested masc root against the "masc" label beside it
        # ("<base>/.masc") instead of drawing the base path a second time,
        # so a fixture whose masc root sits under its base path -- this
        # one does -- reads the label, not the base path's own tail twice.
        drain_until_quiet(process, master_fd, output)
        rows = screen_rows(bytes(output[: output.rfind(FRAME_END) + len(FRAME_END)]))
        paths_row = rows.get(screen_row_of(rows, b"  base "), b"")
        # The random suffix of the harness directory is what tells two
        # workspaces apart; a whole basename can be longer than a path's
        # share of a 100-column row.
        suffix = os.path.basename(base_path)[-8:].encode()
        for needle in (suffix + b"   masc ", b"masc <base>/.masc", b"binary age"):
            if needle not in paths_row:
                raise AssertionError(
                    f"the Config paths row lost {needle!r}: {paths_row!r}"
                )

        status = send_and_wait(
            process, master_fd, output, b"v", b"Pending restart: keeper.pending"
        )
        status_plain = CSI_RE.sub(b"", status)
        for needle in (b"fixture-read-revision", b"Validation: valid", b"Keeper restart: required"):
            if needle not in status_plain:
                raise AssertionError(f"Config status omitted {needle!r}: {status_plain!r}")
        send_and_wait(
            process, master_fd, output, b"r", b"fixture-reloaded-revision"
        )
        # Source-only input must not open an editor or a hidden-source search.
        # If / stole focus, v would become search text instead of returning.
        # Nothing should happen, which is the whole point -- so there is no
        # new frame to wait for. A frame carries the rows that changed, and
        # inert keys change none; waiting for the title to arrive again
        # starves on a screen that is already correct. Read the screen.
        os.write(master_fd, b"e/")
        time.sleep(0.4)
        read_available(master_fd, output)
        if b"runtime.toml status" not in screen_text(bytes(output)):
            raise AssertionError(
                "e or / moved the Config status screen: "
                f"{screen_text(bytes(output))!r}"
            )
        reloaded_source = send_and_wait(process, master_fd, output, b"v", b"first-value = ")
        if b"first-value = 9" not in CSI_RE.sub(b"", reloaded_source):
            raise AssertionError("Config reload changed revision without its new source")

        next_field = send_and_wait(
            process, master_fd, output, b"j", b"second-value = "
        )
        if b"second-value = " not in CSI_RE.sub(b"", next_field):
            raise AssertionError("j did not skip comments and blank rows")

        page_down = send_and_wait(
            process, master_fd, output, b"\x1b[6~", b"temperature = "
        )
        if b"temperature = " not in CSI_RE.sub(b"", page_down):
            raise AssertionError("PgDn did not land on the next page's value")

        page_up = send_and_wait(
            process, master_fd, output, b"\x1b[5~", b"second-value = "
        )
        if b"second-value = " not in CSI_RE.sub(b"", page_up):
            raise AssertionError("PgUp did not return to the previous value")

        models = send_and_wait(process, master_fd, output, b"p", b"MASC Models")
        models_plain = CSI_RE.sub(b"", models)
        for needle in (b"temperature", b"0.7", b"high", b"16384"):
            if needle not in models_plain:
                raise AssertionError(
                    f"Models pane omitted {needle!r}: {models_plain!r}"
                )

        # The title row's note is the path of the file the pane reads, and a
        # workspace chooses how long that is; this fixture serves a thirty-cell
        # one and a real base path is longer. At eighty columns it ran the row
        # past the frame, and the frame takes its cells off the end, where
        # the clock and the connection badge are. They are the only things on
        # this surface that say the reading is live, and neither can say it
        # was shortened; the note can, so the note is what gives way.
        narrow = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=80,
            needle=b"MASC Models",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        title_row = next(
            (
                text
                for _, text in sorted(screen_rows(narrow).items())
                if b"MASC Models" in text
            ),
            None,
        )
        if title_row is None:
            raise AssertionError(
                f"the pane drew no title row at eighty columns: {narrow!r}"
            )
        # The badge whole -- "HTTP [con" is what a cut row leaves, and a
        # reader cannot tell that from a connection state -- and the path's
        # deciding end, which is the half [fit_middle] keeps.
        for needle in (b"HTTP [connected]", b".toml"):
            if needle not in title_row:
                raise AssertionError(
                    f"the pane title row lost {needle!r} at eighty columns: "
                    f"{title_row!r}"
                )
        os.write(master_fd, b"q")

    return interact


def runtime_probe_provider(
    runtime_id: str,
    *,
    status: str,
) -> dict[str, object]:
    cli = status == "skipped_cli"
    reachable = status == "reachable"
    failed = not cli and not reachable
    return {
        "runtime_id": runtime_id,
        "provider_id": f"probe-{runtime_id}",
        "provider_display_name": "Probe label must not render",
        "model_id": f"probe-model-{runtime_id}",
        "model_api_name": f"probe-api-{runtime_id}",
        "protocol": "openai",
        "runtime_kind": "cli" if cli else "http",
        "transport": "cli" if cli else "http",
        "auth_kind": "none",
        "credential_required": False,
        "auth_present": False,
        "status": status,
        "reachable": None if cli else reachable,
        "http_status": 200 if reachable else None,
        "latency_ms": None if cli else (18.0 if reachable else 41.0),
        "model_count": 4 if reachable else None,
        "content_type": "application/json" if reachable else None,
        "downloaded_bytes": 256 if reachable else None,
        "endpoint_url": None if cli else "https://runtime.invalid/v1",
        "probe_url": None if cli else "https://runtime.invalid/v1/models",
        "error": (
            "CLI runtimes do not expose an HTTP reachability endpoint"
            if cli
            else ("connection refused" if failed else None)
        ),
        "checked_at": "2026-08-24T10:20:00Z",
    }


def runtime_probe_response(*, fresh: bool) -> HttpResponse:
    providers = [
        runtime_probe_provider("runtime-a", status="reachable"),
        runtime_probe_provider("runtime-b", status="skipped_cli"),
        runtime_probe_provider(
            "runtime-c",
            status="reachable" if fresh else "network_error",
        ),
    ]
    failed = 0 if fresh else 1
    return (
        200,
        {
            "generated_at": "2026-08-24T10:20:01Z",
            "refreshed_at_unix": 1787566800.0,
            "cache_ttl_sec": 15.0,
            "cache_age_sec": 1.0 if fresh else 16.0,
            "cache_hit": fresh,
            "refresh_state": "fresh" if fresh else "served_stale",
            "probe": {
                "source": "runtime.toml",
                # The overall probe status is written from Health_status, which
                # spells the healthy reading "ok". "reachable" belongs to the
                # per-provider vocabulary a few lines below and is not a word
                # this field can carry, so a fixture using it here fails the
                # snapshot decode -- and that failure is an inner result, so
                # the surface keeps the previous reading and only marks the
                # header "read failed" rather than saying what broke.
                "status": "ok" if fresh else "degraded",
                "probe_ok": fresh,
                "checked_at": "2026-08-24T10:20:00Z",
                "summary": {
                    "runtimes": 3,
                    "probed": 2,
                    "reachable": 2 if fresh else 1,
                    "failed": failed,
                    "skipped": 1,
                    "default_runtime_id": "runtime-a",
                },
                "providers": providers,
                "errors": [] if fresh else ["runtime-c: network_error"],
                "observations": ["provider metadata endpoints only"],
                "limitations": ["no completion request", "CLI execution skipped"],
            },
        },
    )


def runtime_resolved_runtime(
    runtime_id: str,
    provider: str,
    model: str,
    *,
    provider_id: str = "fixture-provider",
) -> dict[str, object]:
    return {
        "id": runtime_id,
        "provider": provider,
        # The [providers.<id>] table key; "provider" is its display name.
        "provider_id": provider_id,
        "model": model,
        "exact_slot_group": "slots",
        "effective_max_context": 200_000,
        "max_context_source": "capability",
        "max_output_tokens": 8192,
        "declared_reasoning_effort": None,
        "is_local": False,
        # This binding flag is independent of the fleet's top-level default.
        "is_default": False,
        "rate_limited": False,
        "rate_limit_resets_at": None,
    }


def runtime_resolved_response(*, runtime_a_in_two_lanes: bool = False) -> HttpResponse:
    runtime_a = runtime_resolved_runtime("runtime-a", "Resolved A", "model-a")
    return (
        200,
        {
            "generated_at_iso": "2026-08-24T10:20:02Z",
            "source": RUNTIME_RESOLVED_PATH,
            "config_path": "/workspace/config/runtime.toml",
            "default_runtime": runtime_a,
            # The two routes that are not lanes. Both lists are required by
            # the decoder; empty is a configuration (no vision runtimes), and
            # the declared list is what the editor writes back.
            "media_failover": [],
            "media_failover_declared": [],
            # The Overview's Providers section decodes these two strictly.
            "provider_usage_windows_since": 1790179140.2,
            "provider_usage_windows": [],
            "runtimes": [
                runtime_a,
                runtime_resolved_runtime("runtime-b", "Resolved B", "model-b"),
                runtime_resolved_runtime("runtime-c", "Resolved C", "model-c"),
                runtime_resolved_runtime("runtime-d", "Resolved D", "model-d"),
                runtime_resolved_runtime("runtime-e", "Resolved E", "model-e"),
            ],
            "lanes": [
                {
                    "id": "primary",
                    "runtime_ids": ["runtime-a", "runtime-b"],
                    "declared": True,
                },
                {
                    "id": "degraded",
                    # Off by default. With it on, runtime-a is here as well as
                    # in "primary", which is what gives the two doors into the
                    # runtime detail -- a lane's candidate row and the catalog
                    # row -- something to disagree about. It adds a row to the
                    # lane listing, and other scripts walk that listing by row:
                    # test_tui_runtime_lane_editor.py and
                    # test_tui_selection_visibility.py both call this function
                    # and count on its shape. The only caller that turns it on
                    # is runtime_http_fixtures, which feeds nothing but
                    # runtime_surface_interaction -- the interaction that makes
                    # the comparison. Two runners register that interaction,
                    # run_keyboard_regression and run_runtime_regression, and
                    # both want the extra lane.
                    "runtime_ids": (
                        ["runtime-c", "runtime-a"]
                        if runtime_a_in_two_lanes
                        else ["runtime-c"]
                    ),
                    "declared": True,
                },
                {
                    "id": "unobserved",
                    "runtime_ids": ["runtime-d"],
                    "declared": True,
                },
            ],
            "assignments": [
                {
                    "keeper": "sangsu",
                    "assignment_source": "default",
                    "resolved": {"kind": "lane", "id": "primary"},
                }
            ],
        },
    )


def runtime_http_fixtures() -> tuple[
    HttpFixtures,
    GatedHttpResponse,
    SequencedHttpResponse,
]:
    fixtures = overview_event_http_fixtures()
    initial_probe = GatedHttpResponse(
        runtime_probe_response(fresh=False),
        subsequent_response=runtime_probe_response(fresh=True),
    )
    force_probe = SequencedHttpResponse(
        [(503, {"error": "forced probe refresh failed"})]
    )
    fixtures[RUNTIME_PROBE_PATH] = initial_probe
    fixtures[RUNTIME_PROBE_FORCE_PATH] = force_probe
    fixtures[RUNTIME_RESOLVED_PATH] = runtime_resolved_response(
        runtime_a_in_two_lanes=True
    )
    return fixtures, initial_probe, force_probe


def runtime_surface_interaction(
    fixtures: HttpFixtures,
    initial_probe: GatedHttpResponse,
    force_probe: SequencedHttpResponse,
) -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        completed = False
        try:
            # Runtime is a Config child. Verify the parent before opening it;
            # keep [9] bare so the probe request is observed after [start].
            tab_until(process, master_fd, output, b"MASC System")
            # DETAIL is what is left of the row after the five fixed columns,
            # and at the harness's hundred that is eighteen cells -- enough
            # for "[unassigned] \xc2\xb7 si\xe2\x80\xa6" and no more. #36120 put the
            # keeper assignment in front of the lane fact, so the words this
            # scenario reads (head, single candidate, the active timestamp)
            # stopped fitting. Give the row the width its facts need: 131
            # keeps the acting pane off the screen
            # (Masc_tui_acting_pane.threshold_cols = 158), so the surface
            # keeps the whole frame. The later resize back to a
            # hundred columns is what proves the listing survives narrowing.
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=131,
                needle=b"MASC System",
                controls=(FULL_REDRAW,),
            )
            read_available(master_fd, output)
            start = len(output)
            os.write(master_fd, b"9")  # Config -> Runtime
            if not wait_for_fixture_event(
                process, master_fd, output, initial_probe.requested, timeout=10.0
            ):
                raise AssertionError("Runtime did not request provider probe")
            # Several 50 ms ticks pass while the authenticated probe is held.
            # The resolved request may finish, but the joined generation must
            # remain single-flight until both authorities settle.
            time.sleep(0.2)
            if initial_probe.calls != 1:
                raise AssertionError(
                    "Runtime stacked probe reads while one was in flight: "
                    f"{initial_probe.calls} calls"
                )
            initial_probe.release.set()
            wait_for_output(
                process,
                master_fd,
                output,
                b"network_error",
                start=start,
                timeout=3.0,
            )
            stale_end = output.find(b"network_error", start) + len(b"network_error")
            wait_for_output(
                process,
                master_fd,
                output,
                FRAME_END,
                start=stale_end,
                timeout=3.0,
            )
            stale_frame_end = output.find(FRAME_END, stale_end) + len(FRAME_END)
            stale_plain = CSI_RE.sub(b"", bytes(output[start:stale_frame_end])).decode(
                "utf-8"
            )
            for needle in (
                "MASC System / Runtime",
                "LANE",
                "CANDIDATE",
                "PROVIDER / MODEL",
                "ROUTE / PROBE",
                "primary",
                "1/2 runtime-a",
                "Resolved A / model-a",
                "ready / reachable",
                "CLI not probed",
                # The lane fact says why this candidate is the one the lane
                # walks: head, fallback #n, or single candidate.
                "fallback #1",
                "unobserved",
                "single candidate",
                # A fallback row's lane cell is a word this renderer wrote,
                # not a name the workspace chose, so it is cut from the tail
                # and its head survives. Held to the head rather than the
                # whole label: the column is ten cells at a hundred and
                # eighteen at a hundred and forty, and this is true at every
                # one of those widths.
                "\u2514\u2500 fal",
            ):
                if needle not in stale_plain:
                    raise AssertionError(
                        f"Runtime did not draw {needle!r}: {stale_plain!r}"
                    )
            if "Probe label must not render" in stale_plain:
                raise AssertionError(
                    f"Runtime used probe identity instead of resolved SSOT: {stale_plain!r}"
                )
            # Cut from the middle, the cell kept the half that says nothing:
            # "\u2514\u2026ack #1". A lane id is told apart by its tail and keeps the
            # middle cut; a label is told apart by its head. The detail column
            # spells "fallback #1" whole, so only the ellipsis-led form is the
            # cut one.
            if "\u2026ack #" in stale_plain:
                raise AssertionError(
                    f"Runtime cut a fallback label from its middle: {stale_plain!r}"
                )

            # The next ordinary poll carries the refreshed cache value. This
            # proves served_stale is a state, not a local health inference.
            fresh_start = stale_frame_end
            wait_for_output(
                process,
                master_fd,
                output,
                b"fresh",
                start=fresh_start,
                timeout=3.0,
            )
            wait_for_output(
                process,
                master_fd,
                output,
                # The header writes the overall reading back with the word the
                # producer sent -- Health_status spells the healthy one "ok".
                # "reachable" is the per-provider word and never appears here.
                re.compile(
                    rb"ok(?:\x1b\[[0-9;]*m)* / "
                    rb"(?:\x1b\[[0-9;]*m)*fresh"
                ),
                start=fresh_start,
                timeout=3.0,
            )

            lane_detail = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"MASC System / Runtime detail",
            )
            lane_detail_plain = CSI_RE.sub(b"", lane_detail)
            for needle in (
                b"primary / runtime-a",
                b"Runtime ID: runtime-a",
                b"Provider: Resolved A",
                b"Model: model-a",
                b"Effective context: 200000 tokens",
                b"Context source: capability",
                b"Max output: 8192 tokens",
                b"Local runtime: no",
                b"Used by lanes: primary, degraded",
                b"Lane position: 1 of 2 in primary",
                b"Probe status: reachable",
                b"Probe transport: http",
                # The terminal's clock, not the wire's: the scenario runs
                # under TZ=UTC so the expected reading is the same on every
                # machine.
                b"Checked at: 2026-08-24 10:20:00",
                # No "Reachable: yes" row: the decoder keeps reachable and
                # status in agreement, so the row said the status twice.
                b"HTTP status: 200",
                b"Latency: 18ms",
                b"Probe limitation: no completion request",
                b"Probe limitation: CLI execution skipped",
            ):
                if needle not in lane_detail_plain:
                    raise AssertionError(
                        f"Runtime lane detail omitted {needle!r}: "
                        f"{lane_detail_plain!r}"
                    )

            send_and_wait(
                process,
                master_fd,
                output,
                b"\x1b[D",
                b"CANDIDATE",
            )
            # Candidate identity also appears in the detail. Wait for the
            # list-only column header, then inspect the replayed screen.
            lane_screen = screen_text(bytes(output))
            if b"1/2 runtime-a" not in lane_screen:
                raise AssertionError("Runtime list lost the selected lane candidate")
            if b"MASC System / Runtime detail" in lane_screen:
                raise AssertionError("Runtime left arrow did not return to the lane list")

            send_and_wait(
                process,
                master_fd,
                output,
                b"p",
                b"All runtimes (5)",
            )
            # Read off the screen, the way the lane list above is read: only
            # the rows that changed are repainted, so a row the catalog kept
            # unchanged carries no bytes in the frames that press drew and
            # cannot be found in them.
            all_list = screen_text(bytes(output))
            if b"runtime-a" not in all_list:
                raise AssertionError("Runtime catalog did not keep the selected runtime")
            if b"Runtime lanes (3 lanes, 5 slots)" not in all_list:
                raise AssertionError("Runtime catalog counted runtimes as lane slots")
            if b"ready / reachable" not in all_list:
                raise AssertionError("Runtime catalog omitted independent probe status")
            catalog_detail = send_and_wait(
                process,
                master_fd,
                output,
                b"\r",
                b"MASC System / Runtime detail",
            )
            catalog_detail_plain = CSI_RE.sub(b"", catalog_detail)
            for needle in (
                b"Runtime ID: runtime-a",
                b"Provider: Resolved A",
                b"Model: model-a",
                b"Used by lanes: primary, degraded",
                b"Probe status: reachable",
            ):
                if needle not in catalog_detail_plain:
                    raise AssertionError(
                        f"Runtime catalog detail omitted {needle!r}: "
                        f"{catalog_detail_plain!r}"
                    )
            send_and_wait(process, master_fd, output, b"\x1b", b"All runtimes (5)")
            # b10d25cc12 turned [p] into a three-stop circuit: lanes tab,
            # catalog, then the standalone Lanes surface ("off the ring"),
            # and [p] there returns to the lanes tab. The old two-stop step
            # waited for the tab header right after leaving the catalog and
            # starved on the standalone surface instead, whose header stays
            # "(not loaded)" because this fixture serves no
            # /api/v1/dashboard/standalone-lanes body. Walk the full circuit
            # so the return leg is what gets asserted.
            send_and_wait(process, master_fd, output, b"p", b"MASC Lanes")
            send_and_wait(process, master_fd, output, b"p", b"Runtime lanes (3 lanes, 5 slots)")

            # The overflow scroll hint is unreachable with this fixture: it
            # renders only when candidates exceed the listing height, but the
            # compact-frame gate (minimum_fixed_chrome_rows = 14) replaces any
            # viewport short enough for 4 candidates to overflow. A hint
            # assertion would need a 6+ candidate fixture at a viable height.
            # A shorter-but-viable pass proves the listing survives resize.
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=20,
                columns=100,
                needle=b"MASC System / Runtime",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=100,
                needle=b"MASC System / Runtime",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )

            fixtures[RUNTIME_PROBE_PATH] = (503, {"error": "probe refresh failed"})
            read_available(master_fd, output)
            refresh_start = len(output)
            os.write(master_fd, b"r")
            # Prove the key reached Runtime's forced-probe endpoint. A
            # generic listing refresh used to intercept lowercase r, leaving
            # only ordinary polls and never reaching this request.
            wait_for_fixture_served(
                process,
                master_fd,
                output,
                force_probe,
                after=0,
                description="Runtime r forced provider probe",
            )
            # The next ordinary poll can replace the force failure's wording;
            # both must leave the failed reading visible with the prior rows.
            wait_for_output(
                process, master_fd, output, b"runtime probe load failed",
                start=refresh_start, timeout=3.0,
            )
            if force_probe.served != 1:
                raise AssertionError(
                    "Runtime did not coalesce manual refresh into one force request: "
                    f"{force_probe.served} calls"
                )
            preserved = resize_and_wait(
                process,
                master_fd,
                output,
                rows=30,
                columns=99,
                needle=b"runtime-a",
                controls=(FULL_REDRAW,),
                final_cursor=b"\x1b[?25l",
            )
            preserved_plain = CSI_RE.sub(b"", preserved)
            for needle in (b"runtime probe load failed", b"runtime-a", b"runtime-d"):
                if needle not in preserved_plain:
                    raise AssertionError(
                        f"Runtime discarded its prior rows after failure: {preserved_plain!r}"
                    )
            # Verify the selected parent pane and its Runtime entry remain
            # visible at 99 columns, even when later pane names are clipped.
            config_start = len(output)
            send_and_wait(
                process, master_fd, output, b"\x1b", "▸runtime.toml".encode()
            )
            if b"9:Runtime" not in CSI_RE.sub(b"", bytes(output[config_start:])):
                raise AssertionError("Config hides its Runtime entry at 99 columns")
            os.write(master_fd, b"q")
            completed = True
        finally:
            initial_probe.release.set()
            if not completed and process.poll() is None:
                kill_process_group(process)

    return interact


def run_config_regression(executable: str) -> None:
    fixtures = overview_event_http_fixtures()
    initial = {
        **runtime_config_read_metadata(),
        "path": "/workspace/config/runtime.toml",
        "source_text": config_navigation_source(),
    }
    reloaded = {
        **initial,
        "source_revision": "fixture-reloaded-revision",
        "source_text": config_navigation_source().replace("first-value = 1", "first-value = 9"),
    }
    fixtures[RUNTIME_CONFIG_RAW_PATH] = SequencedHttpResponse([(200, initial), (200, reloaded)])
    run_terminal_scenario(
        executable,
        description="Config value navigation, paging, and model temperature",
        interact=config_navigation_interaction(),
        http_fixtures=fixtures,
    )


def run_runtime_regression(executable: str) -> None:
    fixtures, initial_probe, force_probe = runtime_http_fixtures()
    run_terminal_scenario(
        executable,
        description="Runtime lane and catalog exact detail",
        interact=runtime_surface_interaction(fixtures, initial_probe, force_probe),
        refresh=0.05,
        http_fixtures=fixtures,
        # Same reading, same clock: the detail draws the probe's checked-at in
        # the terminal's zone, so without this the expected "10:20:00" only
        # matches on a machine that already runs UTC.
        extra_env={"TZ": "UTC"},
    )


def held_back_prompts_http_fixtures() -> HttpFixtures:
    """One prompt whose override the registry declined to restore.

    The registry keeps a rejected override on disk and reports it under
    `held_back`. The row itself still reads from its file, so without a mark
    of its own it renders exactly like a prompt nobody ever customized -- and
    an operator loses an override without learning they lost it.
    """
    fixtures = overview_event_http_fixtures()
    fixtures["/api/v1/prompts"] = (
        200,
        {
            "prompts": [
                {
                    "key": "keeper",
                    "category": "keeper",
                    "operator_surface": "primary",
                    "description": "the keeper turn prompt",
                    "effective": "You are a keeper.",
                    "file_path": "config/prompts/keeper.md",
                    "source": "file",
                    "template_variables": [],
                }
            ],
            "held_back": [
                {
                    "key": "keeper",
                    "bytes": 1240,
                    "reason": "Unknown template variables: facts_json",
                }
            ],
        },
    )
    return fixtures


# The prompts title row carries the pane name, its reading, and the held-back
# count, and the frame gives the row up from its tail -- the held-back count
# goes first. At the harness default of a hundred columns it is already gone:
# the row reads "적용 …". A scenario that asserts the count has to give the row
# the width its reading needs, the way the keeper-runtime scenario names its
# own. A hundred and twenty leaves the whole count in the row.
HELD_BACK_TITLE_COLUMNS = 120


def run_held_back_override_regression(executable: str) -> None:
    """A held-back override is visible on the prompts screen.

    Before this the screen drew the row from its file with a blank mark, the
    same as an untouched prompt. The wire had carried `held_back` the whole
    time and the TUI snapshot dropped the field.
    """

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=HELD_BACK_TITLE_COLUMNS,
            needle=b"MASC Dashboard",
        )
        tab_until(process, master_fd, output, b"MASC System")
        for _ in range(8):
            if b"MASC \xed\x94\x84\xeb\xa1\xac\xed\x94\x84\xed\x8a\xb8" in bytes(output):
                break
            send_and_wait(process, master_fd, output, b"p", b"MASC ")
        else:
            raise AssertionError("[p] never reached the prompts pane")

        # The pane title draws on the frame the switch lands on; the header
        # that counts the held-back override draws only once the registry
        # has answered (Masc_tui_render.render_prompt_registry: "A count
        # only once the registry has answered"). The loop above breaks on
        # the title, not the answer, so judging the frame it landed on
        # reads the pane before its data can have arrived. Wait for the
        # answer instead of the title.
        if not poll_for_output(
            process,
            master_fd,
            output,
            "적용 안 된 오버라이드 1개".encode(),
            start=0,
            timeout=3.0,
        ):
            raise AssertionError(
                "the header does not count the held-back override, so a reader "
                "cannot see it without landing on the row"
            )

        screen = screen_text(bytes(output))
        if "\u2298".encode() not in screen:
            raise AssertionError("the held-back row carries no mark of its own")
        if b"Unknown template variables: facts_json" not in screen:
            raise AssertionError("the rejected variable is not visible beside recovery guidance")
        if b"You are a keeper." not in screen:
            raise AssertionError("override notices hid the effective template body")
        if "다시 저장하면".encode() not in screen:
            raise AssertionError(
                "the screen says the override is not applied and does not say "
                "how to put it back"
            )

        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        send_and_wait(
            process, master_fd, output, b"q", b"q: press again to quit"
        )

    run_terminal_scenario(
        executable,
        description="a held-back override is visible",
        interact=interact,
        http_fixtures=held_back_prompts_http_fixtures(),
    )


def run_prompts_refresh_failure_keeps_catalog_regression(executable: str) -> None:
    """A failed refresh keeps the prompt catalog it read last.

    The catalog is a [Masc_tui_fetched] view, and a refresh that fails after a
    good read settles as [Stale (catalog, error)]. The prompts screen, its
    count and its cursor read only [Ready], so that refresh emptied the list:
    the rows and the held-back override warning disappeared and the selection
    went to nothing, with the error drawn in their place. Success, a failed
    refresh, then a retry that succeeds: the rows and the warning stay through
    the failure, the failure is said above them, and the retry clears it.
    """
    fixtures = held_back_prompts_http_fixtures()
    catalog = fixtures["/api/v1/prompts"]
    fixtures["/api/v1/prompts"] = SequencedHttpResponse(
        [
            catalog,
            (503, {"error": "synthetic prompt registry offline"}),
            catalog,
        ]
    )
    stale_line = "새로고침 실패".encode()

    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=HELD_BACK_TITLE_COLUMNS,
            needle=b"MASC Dashboard",
        )
        tab_until(process, master_fd, output, b"MASC System")
        for _ in range(8):
            if b"MASC \xed\x94\x84\xeb\xa1\xac\xed\x94\x84\xed\x8a\xb8" in bytes(output):
                break
            send_and_wait(process, master_fd, output, b"p", b"MASC ")
        else:
            raise AssertionError("[p] never reached the prompts pane")
        if not poll_for_output(
            process,
            master_fd,
            output,
            "적용 안 된 오버라이드 1개".encode(),
            start=0,
            timeout=3.0,
        ):
            raise AssertionError("the first catalog read never landed")

        # The refresh that fails.
        failed_from = len(output)
        os.write(master_fd, b"r")
        if not poll_for_output(
            process, master_fd, output, stale_line, start=failed_from, timeout=5.0
        ):
            raise AssertionError(
                f"a failed refresh does not say so: {screen_text(bytes(output))!r}"
            )
        drain_until_quiet(process, master_fd, output)
        screen = screen_text(bytes(output))
        if b"synthetic prompt registry offline" not in screen:
            raise AssertionError(f"the failed refresh lost its cause: {screen!r}")
        if b"You are a keeper." not in screen:
            raise AssertionError(
                f"a failed refresh emptied the prompt the cursor was on: {screen!r}"
            )
        if "적용 안 된 오버라이드 1개".encode() not in screen:
            raise AssertionError(
                f"a failed refresh dropped the held-back override warning: {screen!r}"
            )
        if "\u2298".encode() not in screen:
            raise AssertionError(f"a failed refresh dropped the held-back row's mark: {screen!r}")

        # The retry that succeeds clears the stale line and keeps the rows.
        os.write(master_fd, b"r")
        drain_until_quiet(process, master_fd, output, cap=5.0)
        screen = screen_text(bytes(output))
        if stale_line in screen:
            raise AssertionError(f"a successful retry still says the list is stale: {screen!r}")
        if b"You are a keeper." not in screen:
            raise AssertionError(f"the retry lost the catalog: {screen!r}")

        send_and_wait(process, master_fd, output, b"\x1b", b"MASC Dashboard")
        send_and_wait(
            process, master_fd, output, b"q", b"q: press again to quit"
        )

    run_terminal_scenario(
        executable,
        description="a failed prompt refresh keeps the catalog",
        interact=interact,
        http_fixtures=fixtures,
    )
