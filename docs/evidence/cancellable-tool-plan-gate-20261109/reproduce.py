#!/usr/bin/env python3
"""Exercise the extracted production gate without building the MASC tree.

The two wrappers mirror the old and new acquire/release call sites. This is
gate evidence, not execution of the complete composition executor.
"""

from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
SOURCE = "lib/keeper/keeper_tool_plan_executor.ml"
BASE = "419f2a843ed727a69c5c36a307ba28d51da04dce"

SCENARIO = r"""
let () =
  Eio_main.run @@ fun _ ->
  Eio.Switch.run @@ fun sw ->
  let gate = Exclusive_gate.create () in
  let context, publish_context = Eio.Promise.create () in
  let active, publish_active = Eio.Promise.create () in
  let finish_active, release_active = Eio.Promise.create () in
  let queued_dispatched = ref 0 in
  let worker = Eio.Fiber.fork_promise ~sw (fun () ->
    Eio.Cancel.sub (fun cancel ->
      Eio.Promise.resolve publish_context cancel;
      Eio.Fiber.all
        [ (fun () -> with_shared gate (fun () -> Eio.Cancel.protect (fun () ->
              Eio.Promise.resolve publish_active ();
              Eio.Promise.await finish_active)))
        ; (fun () -> with_exclusive gate (fun () -> incr queued_dispatched)) ]))
  in
  Eio.Promise.await active;
  Eio.Fiber.yield ();
  Eio.Cancel.cancel (Eio.Promise.await context) Exit;
  Eio.Promise.resolve release_active ();
  let cancelled = match Eio.Promise.await worker with
    | Error (Eio.Cancel.Cancelled _) -> true
    | Error ex -> raise ex
    | Ok () -> false in
  Printf.printf "queued_dispatched=%d cancellation_propagated=%b\n%!"
    !queued_dispatched cancelled
"""


def gate(source: str) -> str:
    start = source.index("module Exclusive_gate = struct")
    end = source.index("\nend\n", start) + len("\nend\n")
    return source[start:end]


def run(*argv: str, cwd: Path = ROOT) -> str:
    return subprocess.check_output(argv, cwd=cwd, text=True)


def main() -> None:
    output = ROOT / "artifacts" / "cancellable-tool-plan-gate" / str(time.time_ns())
    output.mkdir(parents=True)
    baseline = run("git", "show", f"{BASE}:{SOURCE}")
    candidate = (ROOT / SOURCE).read_text()
    print(f"compiler={run('ocamlc', '-version').strip()}", flush=True)
    for name, source in (("before", baseline), ("after", candidate)):
        wrappers = []
        for side in ("shared", "exclusive"):
            acquire = f"Exclusive_gate.acquire_{side} gate"
            release = f"Exclusive_gate.release_{side} gate"
            body = (
                f"Fun.protect ~finally:(fun () -> {release}) (fun () -> {acquire}; work ())"
                if name == "before"
                else f"{acquire}; Fun.protect ~finally:(fun () -> {release}) work"
            )
            wrappers.append(f"let with_{side} gate work = {body}\n")
        (output / f"{name}.ml").write_text(gate(source) + "\n" + "".join(wrappers) + SCENARIO)
        run("ocamlfind", "ocamlopt", "-linkpkg", "-package", "eio_main",
            "-o", name, f"{name}.ml", cwd=output)
        result = run(str(output / name)).strip()
        print(f"{name}: {result}", flush=True)
        (output / f"{name}.txt").write_text(result + "\n")
    print(f"output={output}")


if __name__ == "__main__":
    main()
