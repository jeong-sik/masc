from __future__ import annotations

import json
import os
import re
import subprocess

from tui_keyboard_harness import (
    CSI_RE,
    FULL_REDRAW,
    HttpFixtures,
    Interaction,
    RawHttpResponse,
    RequestHttpResponse,
    assert_pane_surface_title_over_gap,
    drain_until_quiet,
    overview_event_http_fixtures,
    resize_and_wait,
    run_terminal_scenario,
    send_and_wait,
    tab_until,
)


def resources_mcp_fixture() -> HttpFixtures:
    events = {"status": "ok", "count": 2}
    for index in range(32):
        events[f"event_{index:02d}"] = f"event value {index:02d}"
    events["tail_marker"] = "visible after scrolling"
    handbook_lines = "\n".join(
        f"- handbook evidence line {index:02d}" for index in range(28)
    )
    handbook = (
        "# Operator handbook\n\n"
        "- Read the description before the payload.\n\n"
        "```toml\nslots = 4\n```\n\n"
        f"{handbook_lines}\n\n"
        "```json\n{\n  \"nested\": true,\n  \"proof\": 42\n}\n```\n\n"
        "markdown_tail_marker"
    )

    def answer(body: bytes) -> RawHttpResponse:
        request = json.loads(body)
        request_id = request.get("id")
        method = request.get("method")
        headers: tuple[tuple[str, str], ...] = ()
        if method == "initialize":
            result: object = {}
            headers = (("Mcp-Session-Id", "resource_fixture_session"),)
        elif method == "resources/list":
            result = {
                "resources": [
                    {
                        "uri": "masc://events.json?limit=50",
                        "name": "Recent Events (JSON)",
                        "title": "Event Log (JSON)",
                        "description": "Recent event log snapshot as JSON",
                        "mimeType": "application/json",
                        "size": 321,
                    },
                    {
                        "uri": "masc://operator-handbook.md",
                        "name": "Operator Handbook",
                        "title": "Operator Handbook",
                        "description": "How an operator reads MCP resources",
                        "mimeType": "text/markdown",
                        "size": 96,
                    },
                ]
            }
        elif method == "resources/read":
            uri = request.get("params", {}).get("uri")
            if uri == "masc://events.json?limit=50":
                result = {
                    "contents": [
                        {
                            "uri": uri,
                            "mimeType": "application/json",
                            "text": json.dumps(events, separators=(",", ":")),
                        }
                    ]
                }
            elif uri == "masc://operator-handbook.md":
                result = {
                    "contents": [
                        {
                            "uri": uri,
                            "mimeType": "text/markdown",
                            "text": handbook,
                        }
                    ]
                }
            else:
                result = {"contents": []}
        else:
            result = {}
        payload = {"jsonrpc": "2.0", "id": request_id, "result": result}
        return RawHttpResponse(
            200,
            json.dumps(payload).encode(),
            content_type="application/json",
            headers=headers,
        )

    fixtures = overview_event_http_fixtures()
    fixtures["/mcp"] = RequestHttpResponse(
        answer, get_response=(405, {"error": "fixture does not offer an SSE stream"})
    )
    return fixtures



def resources_detail_interaction() -> Interaction:
    def interact(
        process: subprocess.Popen[bytes],
        master_fd: int,
        _slave_fd: int,
        output: bytearray,
        _base_path: str,
    ) -> None:
        # Resources hangs off Config under [s]; the listing row proves
        # the surface arrived loaded through the hop.
        tab_until(process, master_fd, output, b"MASC System")
        send_and_wait(process, master_fd, output, b"s", b"Event Log (JSON)")
        drain_until_quiet(process, master_fd, output)
        assert_pane_surface_title_over_gap(
            bytes(output),
            b"MASC System / Resources",
            b"\xe2\x96\xb8 Resources",
        )
        detail = send_and_wait(
            process, master_fd, output, b"\r", b'"status"'
        )
        plain = CSI_RE.sub(b"", detail)
        for needle in (
            b"MCP resource",
            b"read-only data exposed by this server",
            b"masc://events.json?limit=50",
            b"application/json",
            b"321 bytes",
            b'"status": "ok"',
        ):
            if needle not in plain:
                raise AssertionError(
                    f"Resources JSON detail omitted {needle!r}: {plain!r}"
                )
        lexed_key = re.compile(
            rb"\x1b\[[0-9;]*m" + re.escape(b'"status"') + rb"\x1b\[0m"
        )
        if lexed_key.search(detail) is None:
            raise AssertionError(
                f"Resources JSON was pretty but not syntax-highlighted: {detail!r}"
            )

        narrow = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=80,
            needle=b"MCP resource",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        narrow_plain = CSI_RE.sub(b"", narrow)
        for needle in (b"Recent event log snapshot", b"application/json"):
            if needle not in narrow_plain:
                raise AssertionError(
                    f"80-column Resources detail omitted {needle!r}: {narrow_plain!r}"
                )

        # Eighty columns is under the split threshold, so the frame draws one
        # pane and the focus chooses which. h goes back to the listing with
        # the detail still read, l opens it again. Both keys were refused
        # under the threshold until #39017, on a screen already drawing their
        # answer.
        listing = send_and_wait(
            process, master_fd, output, b"h", b"Event Log (JSON)"
        )
        if b"read-only data exposed by this server" in CSI_RE.sub(b"", listing):
            raise AssertionError(
                f"h left the detail drawn instead of the listing: {listing!r}"
            )
        send_and_wait(
            process, master_fd, output, b"l", b"read-only data exposed by this server"
        )

        wide = resize_and_wait(
            process,
            master_fd,
            output,
            rows=30,
            columns=140,
            needle=b"masc://events.json?limit=50",
            controls=(FULL_REDRAW,),
            final_cursor=b"\x1b[?25l",
        )
        if b'"status": "ok"' not in CSI_RE.sub(b"", wide):
            raise AssertionError(f"140-column JSON detail lost its payload: {wide!r}")

        markdown = send_and_wait(
            process, master_fd, output, b"]", b"Operator handbook"
        )
        markdown_plain = CSI_RE.sub(b"", markdown)
        for needle in (b"Operator handbook", b"slots = 4", b"96 bytes"):
            if needle not in markdown_plain:
                raise AssertionError(
                    f"] did not open the next resource detail ({needle!r}): "
                    f"{markdown_plain!r}"
                )
        markdown_tail = send_and_wait(
            process,
            master_fd,
            output,
            b"j" * 48,
            b"markdown_tail_marker",
        )
        markdown_tail_plain = CSI_RE.sub(b"", markdown_tail)
        for needle in (b'"nested": true', b"markdown_tail_marker"):
            if needle not in markdown_tail_plain:
                raise AssertionError(
                    f"Markdown fenced-code scrolling omitted {needle!r}: "
                    f"{markdown_tail_plain!r}"
                )

        previous = send_and_wait(
            process, master_fd, output, b"[", b'"status"'
        )
        if b"Event Log (JSON)" not in CSI_RE.sub(b"", previous):
            raise AssertionError(f"[ did not reopen the previous resource: {previous!r}")
        tail = send_and_wait(
            process,
            master_fd,
            output,
            b"j" * 48,
            b"visible after scrolling",
        )
        if b"tail_marker" not in CSI_RE.sub(b"", tail):
            raise AssertionError(f"long JSON could not be scrolled to its tail: {tail!r}")
        os.write(master_fd, b"q")

    return interact


def run_resources_regression(executable: str) -> None:
    run_terminal_scenario(
        executable,
        description="Resources metadata, pretty payload, and detail stepping",
        interact=resources_detail_interaction(),
        http_fixtures=resources_mcp_fixture(),
    )
