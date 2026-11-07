"""Copy the selected Vibe L0 captures into an evidence bundle, sanitized.

Usage: python3 -I sanitize.py <run-root> <first-call-dir> <bundle-dir>

- Local paths become <run>/<name> placeholders; the home directory becomes ~.
- export.json keeps every field except `config`. Of the effective config it
  keeps the key names and the path-free values in KEPT_CONFIG; the rest names
  local paths and is not part of the contract this bundle supports.
- E-mail addresses become <email>. Session journals (session/) and meta.json
  are not copied: they hold the account user name and local paths.
"""

import datetime
import json
import pathlib
import re
import shutil
import sys

EMAIL = re.compile(r"[\w.+-]+@[\w-]+\.[\w.]+")


def scrub_text(text: str, roots: list[tuple[str, str]]) -> str:
    for raw, placeholder in roots:
        text = text.replace(raw, placeholder)
    text = text.replace(str(pathlib.Path.home()), "~")
    text = re.sub(rf"\b{re.escape(pathlib.Path.home().name)}\b", "<user>", text)
    return EMAIL.sub("<email>", text)


KEPT_CONFIG = ("routed_default_model", "default_agent", "enabled_tools", "disabled_tools", "tools")


def scrub_export(path: pathlib.Path, roots: list[tuple[str, str]]) -> str:
    data = json.loads(path.read_text())
    config = data.pop("config", None)
    if isinstance(config, dict):
        data["config_keys_only"] = sorted(config.keys())
        data["config_kept_values"] = {k: config.get(k) for k in KEPT_CONFIG}
    return scrub_text(json.dumps(data, ensure_ascii=False, indent=2), roots) + "\n"


SUMMARIZED = {"m9-whoami"}


def summarize_messages(path: pathlib.Path) -> str:
    """A derivative: message kinds, tool titles, inputs and approval states;
    no message, reasoning or tool output bodies."""
    rows = []
    for m in json.loads(path.read_text()):
        state = m.get("state") if isinstance(m.get("state"), dict) else {}
        detail = m.get("detail") if isinstance(m.get("detail"), dict) else {}
        rows.append(
            {
                "type": m.get("type"),
                "role": m.get("role"),
                "title": m.get("title"),
                "input": detail.get("input"),
                "status": state.get("status"),
                "decision": state.get("decision"),
                "approvalType": state.get("approvalType"),
                "approvalSource": state.get("approvalSource"),
                "generationStatus": m.get("generationStatus"),
            }
        )
    return json.dumps(rows, ensure_ascii=False, indent=2) + "\n"


def copy_run(src: pathlib.Path, dst: pathlib.Path, roots: list[tuple[str, str]]) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    if src.name in SUMMARIZED:
        (dst / "stdout.summary.json").write_text(
            scrub_text(summarize_messages(src / "stdout"), roots)
        )
    for name in ("stdout", "stderr", "stdout.json", "stderr.txt", "work.ls"):
        if src.name in SUMMARIZED and name == "stdout":
            continue
        f = src / name
        if f.exists():
            (dst / name).write_text(scrub_text(f.read_text(errors="replace"), roots))
    export = src / "out" / "export.json"
    if export.exists():
        (dst / "export.json").write_text(scrub_export(export, roots))


def main() -> None:
    run_root = pathlib.Path(sys.argv[1]).absolute()
    first_call = pathlib.Path(sys.argv[2]).absolute()
    bundle = pathlib.Path(sys.argv[3]).absolute()
    fixtures = bundle / "fixtures"
    if fixtures.exists():
        shutil.rmtree(fixtures)
    # Vibe reports the path it was given; macOS may also report the resolved
    # one (/tmp -> /private/tmp). Replace both, longest first.
    roots = [
        (str(p), placeholder)
        for base, placeholder in ((first_call, "<run>/m0-first-call"), (run_root, "<run>"))
        for p in {base, base.resolve()}
    ]
    roots.sort(key=lambda pair: len(pair[0]), reverse=True)
    copy_run(first_call, fixtures / "m0-first-call", roots)
    for run in sorted(p for p in run_root.iterdir() if p.is_dir() and p.name.startswith("m")):
        copy_run(run, fixtures / run.name, roots)
    write_summary(run_root / "summary.tsv", fixtures)


def export_seconds(export: pathlib.Path) -> str:
    """Vibe's own run time (ended_at - started_at); n/a when no export was written."""
    if not export.exists():
        return "n/a"
    data = json.loads(export.read_text())
    started = datetime.datetime.fromisoformat(data["started_at"])
    ended = datetime.datetime.fromisoformat(data["ended_at"])
    return f"{(ended - started).total_seconds():.1f}"


def write_summary(raw: pathlib.Path, fixtures: pathlib.Path) -> None:
    """Copy run-l0.sh's wall-clock table and add the export's own run time.

    `seconds` is the wall clock run-l0.sh measured around each call, so runs
    made by hand have n/a there; `export_seconds` comes from export.json.
    """
    header, *rows = raw.read_text().splitlines()
    lines = [header + "\texport_seconds"]
    for row in rows:
        run = row.split("\t", 1)[0]
        lines.append(row + "\t" + export_seconds(fixtures / run / "export.json"))
    (fixtures / "summary.tsv").write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
