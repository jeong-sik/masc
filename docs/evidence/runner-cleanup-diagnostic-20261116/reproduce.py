#!/usr/bin/env python3
"""Replay extracted production cleanup reporting with installed, actual Eio.

No Dune build, provider request, or process/global formatter redirection occurs.
Each new run owns an output directory; previous captures are never overwritten.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[3])
    parser.add_argument("--before", default="e11f6e704d10dbe2bff12fcbbbf966bb28c589d4")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    repo = args.repo.resolve()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=False)
    ocaml = shutil.which("ocaml")
    if ocaml is None:
        raise RuntimeError("OCaml interpreter is unavailable")
    runner = "packages/agent_core/lib/agent/agent_execution_runner.ml"
    reserved_path = "packages/agent_core/lib/llm_provider/reserved_exn.ml"
    reserved = (repo / reserved_path).read_text()
    before = subprocess.check_output(
        ["git", "show", args.before + ":" + runner], cwd=repo, text=True)
    after = (repo / runner).read_text()
    (out / "reserved_exn.ml").write_text(reserved)
    eio_libraries = []
    for package, name in [("eio.core", "eio__core.cma"), ("eio_main", "eio_main.cma")]:
        package_dir = Path(subprocess.check_output(
            ["ocamlfind", "query", package], text=True).strip())
        eio_libraries.append({"package": package, "file": name,
                              "sha256": sha((package_dir / name).read_bytes())})
    results = []
    command = [ocaml, "-noinit", "-noprompt", "-I", "+unix", "unix.cma"]
    for label, source in [("before", before), ("after", after)]:
        scope = out / label
        scope.mkdir()
        (scope / "agent_execution_runner.ml").write_text(source)
        start = source.find("let report_cleanup_failure report =")
        if start < 0:
            start = source.index("let reraise_after_abort_failure exn backtrace abort_detail =")
        end = source.index("\n;;", source.index(
            "let reraise_after_abort_failure exn backtrace abort_detail =")) + 3
        helper = source[start:end]
        exception = re.search(r"^exception Abort_failed_after_exception.*$", source, re.M).group(0)
        code = ('#use "topfind";;\n#require "eio_main";;\n'
                + "module Reserved_exn = struct\n" + reserved + "\nend;;\n"
                + "module Llm_provider = struct module Reserved_exn = Reserved_exn end;;\n"
                + exception + ";;\n" + helper + "\n" + REPLAY)
        (scope / "replay.stdin.ml").write_text(code)
        proc = subprocess.run(command, input=code, capture_output=True, text=True, cwd=repo)
        (scope / "stdout.txt").write_text(proc.stdout)
        (scope / "stderr.txt").write_text(proc.stderr)
        lines = [line for line in proc.stdout.splitlines() if line.startswith("PROBE ")]
        expected = expected_lines(label)
        results.append({
            "label": label, "source_sha256": sha(source.encode()),
            "extracted_helper_sha256": sha(helper.encode()),
            "command": command, "process_exit": proc.returncode,
            "probe_lines": lines, "matches_expected": proc.returncode == 0 and lines == expected,
            "raw_capture_digests": {
                name: sha((scope / name).read_bytes())
                for name in ["agent_execution_runner.ml", "replay.stdin.ml", "stdout.txt", "stderr.txt"]},
        })
    summary = {
        "captured_at_utc": datetime.now(timezone.utc).isoformat(),
        "evidence_kind": "extracted_production_helper_with_actual_eio",
        "before_head": args.before,
        "working_checkout_head": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
        "working_tree_candidate": True, "runner_path": runner,
        "reserved_source_path": reserved_path, "reserved_source_sha256": sha(reserved.encode()),
        "ocaml_version": subprocess.check_output([ocaml, "-version"], text=True).strip(),
        "eio_version": subprocess.check_output(
            ["ocamlfind", "query", "-format", "%v", "eio"], text=True).strip(),
        "eio_libraries_at_run": eio_libraries,
        "reproduction_script_sha256": sha(Path(__file__).read_bytes()),
        "source_files_unchanged_after_run": (repo / runner).read_text() == after
            and (repo / reserved_path).read_text() == reserved,
        "public_agent_regressions_executed": False,
        "results": results,
    }
    (out / "results.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2))
    if not all(row["matches_expected"] for row in results):
        raise SystemExit("source replay did not match the expected behavior")


def expected_lines(label):
    lines = []
    for name in ["break", "cancel", "mixed_reserved"]:
        for broken in [False, True]:
            preserved = not broken or label == "after"
            lines.append(f"PROBE {name} broken={str(broken).lower()} "
                         f"original={str(preserved).lower()} io_failed={str(broken).lower()}")
    for name in ["out_of_memory", "cancel", "mixed_reserved"]:
        lines.append(f"PROBE logger_{name} propagated=true")
    return lines


REPLAY = r'''
let () = Eio_main.run (fun env ->
  let bt = Printexc.get_callstack 8 in
  let mixed = Eio.Exn.Multiple [Failure "ordinary member",bt;Eio.Cancel.Cancelled Exit,bt] in
  let same observed primary = match observed with Some exn -> exn == primary | None -> false in
  let capture primary = match reraise_after_abort_failure primary bt "receipt sink unavailable" with
    | () -> None | exception exn -> Some exn in
  List.iter (fun (name,primary) ->
    List.iter (fun broken ->
      let channel = Unix.out_channel_of_descr (Unix.dup Unix.stderr) in
      close_out channel;
      let io_failed = ref false in
      let sink = { Eio.Debug.traceln = (fun ?__POS__:_ format ->
        Format.kasprintf (fun message -> if broken then
          try output_string channel message; flush channel with
          | Sys_error _ as exn -> io_failed := true; raise exn) format) } in
      let observed = Eio.Fiber.with_binding (Eio.Stdenv.debug env)#traceln sink
        (fun () -> capture primary) in
      Printf.printf "PROBE %s broken=%b original=%b io_failed=%b\n%!"
        name broken (same observed primary) !io_failed
    ) [false;true]
  ) ["break",Sys.Break;"cancel",Eio.Cancel.Cancelled Exit;"mixed_reserved",mixed];
  List.iter (fun (name,logger_exn) ->
    let sink = { Eio.Debug.traceln = (fun ?__POS__:_ format ->
      Format.kasprintf (fun _ -> raise logger_exn) format) } in
    let observed = Eio.Fiber.with_binding (Eio.Stdenv.debug env)#traceln sink
      (fun () -> capture Sys.Break) in
    Printf.printf "PROBE logger_%s propagated=%b\n%!" name (same observed logger_exn)
  ) ["out_of_memory",Out_of_memory;"cancel",Eio.Cancel.Cancelled Exit;"mixed_reserved",mixed]);;
'''


if __name__ == "__main__":
    main()
