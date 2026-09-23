"""Tools creates the name decoded from the authored SKILL.md, preserving its bytes."""

import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

import test_tui_keyboard_input as h

SOURCE_MODULES = (
    "bin/masc_tui.ml",
    "bin/masc_tui_editor.ml",
    "bin/masc_tui_http.ml",
    "bin/masc_tui_footer.ml",
    "bin/masc_tui_render_prim.ml",
    "packages/agent_core/lib/skill_document.ml",
    "packages/agent_core/lib/skill_document.mli",
    "lib/keeper/keeper_skill_catalog.ml",
    "lib/keeper/keeper_skill_catalog.mli",
    "lib/keeper/keeper_tool_composition_catalog.ml",
    "lib/keeper/keeper_tool_composition_catalog.mli",
)

CREATE_PATH = "/api/v1/skills/editor/create"
SOURCE_ID = "workspace"
PACKAGE_ID = "reviewed-skill"
MISSING_DESCRIPTION = (
    b"SKILL.md frontmatter is missing required non-empty field description"
)


def run_case(
    executable: str,
    *,
    description: str,
    source: bytes,
    diagnostic: bytes | None = None,
    diagnostic_preview: bytes | None = None,
    composition: bool = False,
) -> None:
    fixtures = h.overview_event_http_fixtures()
    fixtures["/api/v1/skills/editor/sources"] = (
        200,
        {"sources": [{"source_id": SOURCE_ID}]},
    )
    received: list[bytes] = []
    requests: h.HttpRequests = []

    def create(body: bytes) -> h.HttpResponse:
        received.append(body)
        return 200, {"status": "created_and_published"}

    fixtures[CREATE_PATH] = h.RequestHttpResponse(create)

    def interact(
        process: subprocess.Popen[bytes],
        fd: int,
        _slave: int,
        output: bytearray,
        _base: str,
    ) -> None:
        h.tab_until(process, fd, output, b"MASC Config")
        h.send_and_wait(process, fd, output, b"t", b"MASC Config / Tools")
        key = b"C" if composition else b"c"
        if diagnostic is None:
            os.write(fd, key)
            # The harness records a POST only after sending its response.
            # An editor exit or a catalog refresh alone cannot satisfy this.
            h.wait_for_http_request(process, fd, output, requests, path=CREATE_PATH)
        else:
            visible = (
                diagnostic_preview if diagnostic_preview is not None else diagnostic
            )
            h.send_and_wait(process, fd, output, key, visible)
            rows = [
                row for row in h.screen_rows(bytes(output)).values() if visible in row
            ]
            if len(rows) != 1:
                raise AssertionError(f"expected one diagnostic footer: {rows!r}")
            for pinned in (b"Esc:config", b"q:quit"):
                if pinned not in rows[0]:
                    raise AssertionError(f"diagnostic hid {pinned!r}: {rows[0]!r}")
            if diagnostic_preview is not None:
                if not diagnostic.startswith(diagnostic_preview):
                    raise AssertionError(
                        "preview must preserve the canonical diagnostic prefix"
                    )
                if "…".encode() not in rows[0]:
                    raise AssertionError(
                        f"clipped diagnostic has no marker: {rows[0]!r}"
                    )
        os.write(fd, b"q")

    with tempfile.TemporaryDirectory(prefix="masc-tui-skill-editor-") as directory:
        source_path = Path(directory, "authored.md")
        source_path.write_bytes(source)
        editor = Path(directory, "editor.sh")
        editor.write_text(
            f'#!/bin/sh\nexec /bin/cp {shlex.quote(str(source_path))} "$1"\n',
            encoding="utf-8",
        )
        editor.chmod(0o755)
        h.run_terminal_scenario(
            executable,
            description=description,
            interact=interact,
            http_fixtures=fixtures,
            http_requests=requests,
            extra_env={"EDITOR": shlex.quote(str(editor))},
        )

    if diagnostic is not None:
        if received:
            raise AssertionError(f"invalid Skill reached the create API: {received!r}")
        return
    completed = [body for path, body in requests if path == CREATE_PATH]
    if len(received) != 1 or completed != received:
        raise AssertionError(
            f"expected one completed create POST: received={received!r}, "
            f"completed={completed!r}"
        )
    payload = json.loads(received[0])
    expected = {
        "source_id": SOURCE_ID,
        "package_id": PACKAGE_ID,
        "source_text": source.decode("utf-8"),
    }
    if payload != expected:
        raise AssertionError(f"create POST: {payload!r}, expected {expected!r}")
    if payload["source_text"].encode("utf-8") != source:
        raise AssertionError("create POST changed the authored SKILL.md bytes")


def run(executable: str) -> None:
    for description, name_line in (
        ("quoted YAML Skill name", 'name: "reviewed-skill"'),
        ("YAML Skill name with a comment", "name: reviewed-skill # operator note"),
    ):
        source = (
            f"---\n{name_line}\ndescription: Inspect a reviewed procedure.\n---\n"
            "\n# Reviewed procedure\n\nKeep operator notes: 확인.  \n"
        ).encode("utf-8")
        run_case(executable, description=description, source=source)
    run_case(
        executable,
        description="invalid authored Skill is rejected before create",
        source=b"---\nname: reviewed-skill\n---\n\n# Missing description\n",
        diagnostic=MISSING_DESCRIPTION,
    )
    for name, diagnostic in (
        (PACKAGE_ID, None),
        (
            "new-skill",
            b'skill "reviewed-skill": composition name "new-skill" must equal the skill name',
        ),
    ):
        source = (
            '---\nname: "reviewed-skill"\n'
            "description: Inspect a reviewed composition.\n---\n\n"
            "# Reviewed composition\n\nKeep operator notes: 확인.  \n\n"
            "```toml composition\n[[compositions]]\n"
            f'name = "{name}"\nexecution = "inline"\n\n'
            '[[compositions.nodes]]\nid = "lane"\ntool = "keeper_lane_status"\n'
            '[compositions.nodes.input]\nkind = "literal"\nvalue = {}\n```\n'
        ).encode("utf-8")
        run_case(
            executable,
            description=(
                "C creates a composition with matching names"
                if diagnostic is None
                else "C rejects mismatched composition names before create"
            ),
            source=source,
            diagnostic=diagnostic,
            diagnostic_preview=(
                b'skill "reviewed-skill": composition name "new-skill" must equal'
                if diagnostic is not None
                else None
            ),
            composition=True,
        )


if __name__ == "__main__":
    run(h.tui_executable(sys.argv[1]))
    print("Tools validates authored Skills and preserves valid source bytes: PASS")
