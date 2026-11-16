#!/usr/bin/env python3
"""Run unchanged production trace orchestration against explicit boundary doubles.

This is a source-extracted replay, not an Agent.run integration test. Eio,
lifecycle storage and trace writes below are doubles. The regression in
packages/agent_core/test/test_pipeline.ml exercises the actual Agent.run path.
"""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess


STUBS = r'''
module Error = struct
  type t = Internal of string
  let to_string (Internal s) = s
  let of_raised_exn exn = Internal (Printexc.to_string exn)
end
module Eio = struct
  module Cancel = struct exception Cancelled of exn end
  module Mutex = struct let use_rw ~protect:_ () f = f () end
end
module Llm_provider = struct
  module Reserved_exn = struct
    let reraise_if_reserved = function
      | (Sys.Break | Out_of_memory | Stack_overflow | Eio.Cancel.Cancelled _) as exn -> raise exn
      | _ -> ()
  end
  module Reasoning_effort = struct let to_string s = s end
end
module Log = struct
  type field = S of string * string | I of string * int
  let create ~module_name:_ () = ()
  let reporter = ref (fun () -> ())
  let warn () _ _ = !reporter ()
  let error = warn
end
module Raw_trace = struct
  type t = { start_fails:bool; finish_fails:bool; mutable finishes:int }
  type active_run = { sink:t }
  let active_run_id _ = "replay-run"
  let start_run sink ~agent_name:_ ~prompt:_ ~model:_ ?tool_choice:_
      ?enable_thinking:_ ?preserve_thinking:_ ?reasoning_effort:_ () =
    if sink.start_fails then Error (Error.Internal "injected trace start refusal")
    else Ok {sink}
  let finish_run active ~final_text:_ ~stop_reason:_ ~error:_ =
    active.sink.finishes <- active.sink.finishes + 1;
    if active.sink.finish_fails then Error (Error.Internal "injected trace finish refusal")
    else Ok ()
end
module Agent_types = struct
  type status = Accepted | Completed | Ready | Failed
  type snapshot = { status:status }
  type config = { name:string; model:string; tool_choice:unit option;
    enable_thinking:bool option; preserve_thinking:bool option;
    reasoning_effort:string option }
  type state = { config:config }
  type options = { raw_trace:Raw_trace.t option; on_run_complete:(bool -> unit) option }
  type t = { mu:unit; state:state; options:options; mutable lifecycle:snapshot option }
  let set_lifecycle agent ?current_run_id:_ ?accepted_at:_ ?started_at:_
      ?finished_at:_ ?ready_at:_ ?last_error:_ status =
    agent.lifecycle <- Some {status}
end
open Agent_types
let _log = ()
'''

DRIVER = r'''
type execution = Succeed | Refuse | Raise | Cancel | Yield
type diagnostic = Reports | Reporter_raises | Reporter_cancels
let status = function Accepted->"accepted" | Completed->"completed" | Ready->"ready" | Failed->"failed"
let cases = [
  "no_trace_success",false,false,false,Succeed,Reports,false;
  "traced_success",true,false,false,Succeed,Reports,false;
  "start_refused_success",true,true,false,Succeed,Reports,false;
  "start_refused_original_error",true,true,false,Refuse,Reports,false;
  "start_refused_exception",true,true,false,Raise,Reports,false;
  "start_refused_cancel",true,true,false,Cancel,Reports,false;
  "no_trace_exception",false,false,false,Raise,Reports,false;
  "traced_exception",true,false,false,Raise,Reports,false;
  "no_trace_original_error",false,false,false,Refuse,Reports,false;
  "traced_original_error",true,false,false,Refuse,Reports,false;
  "no_trace_cancel",false,false,false,Cancel,Reports,false;
  "traced_cancel",true,false,false,Cancel,Reports,false;
  "no_trace_yield",false,false,false,Yield,Reports,false;
  "traced_yield",true,false,false,Yield,Reports,false;
  "start_refused_yield",true,true,false,Yield,Reports,false;
  "start_refused_reporter_raises",true,true,false,Succeed,Reporter_raises,false;
  "start_refused_reporter_cancels",true,true,false,Succeed,Reporter_cancels,false;
  "finish_refused_success",true,false,true,Succeed,Reports,false;
  "finish_refused_original_error",true,false,true,Refuse,Reports,false;
  "finish_refused_exception",true,false,true,Raise,Reports,false;
  "no_trace_callback_cancel",false,false,false,Succeed,Reports,true;
  "traced_callback_cancel",true,false,false,Succeed,Reports,true;
  "start_refused_callback_cancel",true,true,false,Succeed,Reports,true;
]
let () = List.iter (fun (name,enabled,start_fails,finish_fails,execution,diagnostic,callback_cancel) ->
  let trace : Raw_trace.t = { start_fails;finish_fails;finishes=0 } in
  let calls=ref 0 and active=ref false and callback=ref "none" and callback_status=ref "none" in
  let agent_ref = ref None in
  Log.reporter := (fun () -> match diagnostic with Reports->()
    | Reporter_raises->raise (Failure "diagnostic failure") | Reporter_cancels->raise Sys.Break);
  let agent = {mu=();state={config={name="agent";model="model";tool_choice=None;
      enable_thinking=None;preserve_thinking=None;reasoning_effort=None}};
    options={raw_trace=(if enabled then Some trace else None);on_run_complete=Some (fun ok ->
      callback := string_of_bool ok;
      callback_status := (match !agent_ref with Some a -> (match a.lifecycle with
        Some s->status s.status | None->"none") | None->"none");
      if callback_cancel then raise Sys.Break)};lifecycle=None} in
  agent_ref := Some agent;
  let run () = RUN_CALL
    ~error_to_string:Error.to_string
    ~classify_success:(fun text -> match execution with
      | Yield -> Run_yielded {stop_reason="yield"}
      | Succeed | Refuse | Raise | Cancel -> Run_completed {final_text=Some text;stop_reason=Some "end"})
    agent "prompt" (fun raw -> incr calls;active:=Option.is_some raw;
      match execution with Succeed | Yield -> Ok "answer"
      | Refuse -> Error (Error.Internal "provider refused")
      | Raise -> raise (Failure "original execution failure")
      | Cancel -> raise (Eio.Cancel.Cancelled Exit)) in
  let result = match run () with
    | Ok _ -> "ok" | Error (Error.Internal e) -> "error:"^e
    | exception Failure s -> "raised:"^s
    | exception Eio.Cancel.Cancelled Exit -> "cancelled"
    | exception Sys.Break -> "reserved" in
  Printf.printf "%s|%s|%s|%d|%b|%s|%s|%d\n" name result
    (match agent.lifecycle with None->"none" | Some s->status s.status)
    !calls !active !callback !callback_status trace.finishes) cases
'''


def section(source, start, end):
    return source[source.index(start):source.index(end, source.index(start))]


def replay(source, output, label):
    output.mkdir(parents=True, exist_ok=True)
    production = "\n".join([
        section(source, "let report_observer_failure", "let record_hook_invocation"),
        section(source, "let invoke_on_run_complete", "let final_text_of_response"),
        section(source, "type trace_success =", 'let%test "raw trace final_text'),
        section(source, "let with_raw_trace_run_classified_result", "let with_raw_trace_run_result"),
    ])
    call = "with_raw_trace_run_classified_result"
    if "~of_core_error" in production:
        call += " ~of_core_error:Fun.id"
    ml = output / f"{label}.ml"
    ml.write_text(STUBS + production + DRIVER.replace("RUN_CALL", call))
    exe = output / label
    compile_result = subprocess.run(["ocamlc", "-I", "+unix", "unix.cma", "-o", str(exe), str(ml)],
                                    capture_output=True, text=True)
    if compile_result.returncode:
        raise RuntimeError(compile_result.stderr)
    result = subprocess.run([str(exe)], check=True, capture_output=True, text=True)
    rows = [line.split("|") for line in result.stdout.splitlines()]
    return {"production_source_sha256": hashlib.sha256(source.encode()).hexdigest(), "cases": rows}


def expected(row):
    name = row[0]
    traced = name.startswith("traced_") or name.startswith("finish_")
    if name == "start_refused_reporter_cancels":
        return [name, "reserved", "none", "0", "false", "none", "none", "0"]
    outcome, lifecycle, callback = "ok", "completed", "true"
    if name.endswith("original_error"):
        outcome, lifecycle, callback = "error:provider refused", "failed", "false"
    elif name.endswith("exception"):
        outcome, lifecycle, callback = "raised:original execution failure", "failed", "none"
    elif name in ("start_refused_cancel", "no_trace_cancel", "traced_cancel"):
        outcome, lifecycle, callback = "cancelled", "failed", "none"
    elif name.endswith("yield"):
        lifecycle, callback = "ready", "none"
    elif name.endswith("callback_cancel"):
        outcome = "reserved"
    return [name, outcome, lifecycle, "1", str(traced).lower(), callback,
            "accepted" if callback != "none" else "none", "1" if traced else "0"]


def replay_references(source, output, label):
    production = section(source, "let last_raw_trace_run agent =", "let lifecycle_snapshot agent =")
    stubs = r'''
module Raw_trace = struct
  type run_ref = {worker_run_id:string}
  type t = {last:run_ref option}
  let last_run sink = sink.last
end
type lifecycle = {current_run_id:string option}
type options = {raw_trace:Raw_trace.t option}
type agent = {lifecycle:lifecycle option;options:options}
'''
    driver = r'''
let () = List.iter (fun (name,lifecycle,raw_trace) ->
  let result = last_raw_trace_run {lifecycle;options={raw_trace}} in
  Printf.printf "%s|%s\n" name (match result with None->"missing" | Some run->run.worker_run_id))
  ["matching",Some {current_run_id=Some "current"},Some {Raw_trace.last=Some {worker_run_id="current"}};
   "previous_after_start_refusal",Some {current_run_id=None},Some {Raw_trace.last=Some {worker_run_id="previous"}};
   "previous_after_finish_refusal",Some {current_run_id=Some "current"},Some {Raw_trace.last=Some {worker_run_id="previous"}};
   "not_started",None,Some {Raw_trace.last=Some {worker_run_id="previous"}};
   "no_trace",Some {current_run_id=None},None]
'''
    ml = output / f"{label}.ml"
    ml.write_text(stubs + production + driver)
    exe = output / label
    compiled = subprocess.run(["ocamlc", "-o", str(exe), str(ml)], capture_output=True, text=True)
    if compiled.returncode:
        raise RuntimeError(compiled.stderr)
    rows = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stdout.splitlines()
    expected_rows = ["matching|current", "previous_after_start_refusal|missing",
                     "previous_after_finish_refusal|missing", "not_started|missing", "no_trace|missing"]
    return {"production_source_sha256": hashlib.sha256(source.encode()).hexdigest(),
            "cases": rows, "expected": expected_rows,
            "mismatches": [row for row, wanted in zip(rows, expected_rows, strict=True) if row != wanted]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", default="dd34bc2515c2782d644b5be53e2c602ee0729b9f")
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    path = "packages/agent_core/lib/agent/agent_trace.ml"
    before = subprocess.run(["git", "show", f"{args.baseline}:{path}"], cwd=root,
                            check=True, capture_output=True, text=True).stdout
    result = {"kind": "production-function replay with dependency doubles",
              "baseline_head": args.baseline,
              "compiler": subprocess.run(["ocamlc", "-version"], check=True,
                                         capture_output=True, text=True).stdout.strip(),
              "baseline": replay(before, args.out / "baseline", "trace_before"),
              "candidate": replay((root / path).read_text(), args.out / "candidate", "trace_after")}
    for version in ("baseline", "candidate"):
        result[version]["mismatches"] = [
            {"actual": row, "expected": expected(row)}
            for row in result[version]["cases"] if row != expected(row)]
    reference_path = "packages/agent_core/lib/agent/agent_types.ml"
    old_references = subprocess.run(["git", "show", f"{args.baseline}:{reference_path}"], cwd=root,
                                   check=True, capture_output=True, text=True).stdout
    result["reference_identity"] = {
        "baseline": replay_references(old_references, args.out / "baseline", "reference_before"),
        "candidate": replay_references((root / reference_path).read_text(), args.out / "candidate", "reference_after")}
    (args.out / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    assert result["baseline"]["mismatches"], "negative control no longer reproduces"
    assert not result["candidate"]["mismatches"], result["candidate"]["mismatches"]
    assert result["reference_identity"]["baseline"]["mismatches"], "stale-reference control no longer reproduces"
    assert not result["reference_identity"]["candidate"]["mismatches"]
    print(json.dumps({"baseline_mismatches": len(result["baseline"]["mismatches"]),
                      "candidate_cases": len(result["candidate"]["cases"]),
                      "candidate_mismatches": 0,
                      "reference_identity_cases": len(result["reference_identity"]["candidate"]["cases"])}))


if __name__ == "__main__":
    main()
