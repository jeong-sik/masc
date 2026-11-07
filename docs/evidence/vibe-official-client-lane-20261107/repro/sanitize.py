"""Copy the selected Vibe L0 captures into an evidence bundle, sanitized.

Usage: python3 -I sanitize.py <run-root> <first-call-dir> <bundle-dir>

- Local paths become <run>/<name> placeholders; the home directory becomes ~.
- export.json keeps every field except `config`, which is reduced to its key
  names (the effective config names local paths and is not part of the
  contract this bundle supports).
- E-mail addresses become <email>. Session journals (session/) and meta.json
  are not copied: they hold the account user name and local paths.
"""

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


def scrub_export(path: pathlib.Path, roots: list[tuple[str, str]]) -> str:
    data = json.loads(path.read_text())
    config = data.pop("config", None)
    if isinstance(config, dict):
        data["config_keys_only"] = sorted(config.keys())
    return scrub_text(json.dumps(data, ensure_ascii=False, indent=2), roots) + "\n"


SUMMARIZED = {"m9-whoami"}


def summarize_messages(path: pathlib.Path) -> str:
    """A derivative: message kinds, tool titles and states, no bodies."""
    rows = []
    for m in json.loads(path.read_text()):
        state = m.get("state") or {}
        rows.append(
            {
                "type": m.get("type"),
                "role": m.get("role"),
                "title": m.get("title"),
                "status": state.get("status") if isinstance(state, dict) else None,
                "generationStatus": m.get("generationStatus"),
            }
        )
    return json.dumps(rows, ensure_ascii=False, indent=2) + "\n"


def copy_run(src: pathlib.Path, dst: pathlib.Path, roots: list[tuple[str, str]]) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    if src.name in SUMMARIZED:
        (dst / "stdout.summary.json").write_text(summarize_messages(src / "stdout"))
    for name in ("stdout", "stderr", "stdout.json", "stderr.txt"):
        if src.name in SUMMARIZED and name == "stdout":
            continue
        f = src / name
        if f.exists():
            (dst / name).write_text(scrub_text(f.read_text(errors="replace"), roots))
    export = src / "out" / "export.json"
    if export.exists():
        (dst / "export.json").write_text(scrub_export(export, roots))


def main() -> None:
    run_root = pathlib.Path(sys.argv[1]).resolve()
    first_call = pathlib.Path(sys.argv[2]).resolve()
    bundle = pathlib.Path(sys.argv[3]).resolve()
    fixtures = bundle / "fixtures"
    if fixtures.exists():
        shutil.rmtree(fixtures)
    roots = [(str(first_call), "<run>/m0-first-call"), (str(run_root), "<run>")]
    copy_run(first_call, fixtures / "m0-first-call", roots)
    for run in sorted(p for p in run_root.iterdir() if p.is_dir() and p.name.startswith("m")):
        copy_run(run, fixtures / run.name, roots)
    shutil.copy(run_root / "summary.tsv", fixtures / "summary.tsv")


if __name__ == "__main__":
    main()
