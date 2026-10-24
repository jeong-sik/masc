#!/usr/bin/env python3
"""Execute the actual direct-turn Goal capture with scripted source changes.

This is a bounded OCaml component probe, not a full Keeper or store test.
The production capture bindings, world builder, and summary producer are
extracted verbatim. Workspace I/O and nominal Goal data are fixture stand-ins.
"""
import argparse
import json
import pathlib
import subprocess
import tempfile


def between(source, start, end):
    left = source.index(start)
    return source[left:source.index(end, left)]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1])
    parser.add_argument("--source-ref")
    parser.add_argument("--output", type=pathlib.Path)
    args = parser.parse_args()

    def read(path):
        if args.source_ref:
            return subprocess.check_output(
                ["git", "show", f"{args.source_ref}:{path}"], cwd=args.repo,
                text=True)
        return (args.repo / path).read_text()

    turn = read("lib/keeper/keeper_turn.ml")
    world = read("lib/keeper/keeper_world_observation.ml")
    prompt = read("lib/keeper/keeper_unified_prompt.ml")
    helper = between(turn, "let direct_turn_observation", "\nlet direct_owner_conversation_context")
    marker = "observation snapshot. *)"
    capture = turn[turn.index(marker) + len(marker):]
    capture = capture[:capture.index("let {Keeper_turn_shared_inputs.")]
    summary = between(prompt, "let active_goal_summaries ~", "\n;;")
    ids = between(world, "let open_goal_ids ~", "\n;;")
    direct = between(world, "let observe_direct_keeper_msg ~", "\n;;")

    prelude = r'''
module Workspace = struct type config = { base_path : string } end
module Keeper_meta_contract = struct type keeper_meta = { name : string } end
type keeper_meta = Keeper_meta_contract.keeper_meta
module Goal_phase = struct
  type t = Open | Terminal
  let admits_self_directed_progress = function Open -> true | Terminal -> false
end
module Goal_store = struct
  type unavailable = Unreadable of string
  type goal = { id : string; title : string; phase : Goal_phase.t;
                last_review_note : string option }
  let script : (goal list, unavailable) result list ref = ref []
  let reads = ref 0
  let list_goals_result (_ : Workspace.config) () =
    incr reads;
    match !script with
    | head :: tail -> script := tail; head
    | [] -> failwith "unplanned Goal-store read"
  let criterion_of_goal _ = ()
end
module Workspace_backlog = struct let read_backlog_r _ = Ok () end
module Workspace_task = struct
  let active_owned_task_ids_for_agent _ ~agent_name:_ _ = []
end
module Workspace_goal_index = struct
  let read_goal_task_links_authoritative_r _ = Ok []
end
module Log = struct module Keeper = struct
  let warn fmt = Printf.ksprintf (fun _ -> ()) fmt
end end
module Goal_measurement = struct
  type t = unit
  let observation : (t list, string) result ref = ref (Ok [])
  let reads = ref 0
  let load _ = incr reads; !observation
  let latest_for_goal observations _ =
    Result.map (fun _ -> None) observations
end
module Keeper_unified_prompt = struct
  type held_task_link = Served_by_held_task | Not_served_by_held_task
                      | Held_task_link_unreadable
  type goal_summary = {
    summary_goal_id : string; summary_title : string;
    summary_phase : Goal_phase.t option; summary_criterion : unit option;
    summary_review_note : string option;
    summary_measurement : (Goal_measurement.t option, string) result;
    summary_held_task_link : held_task_link }
'''
    world_stubs = r'''
end
module Time_compat = struct let now () = 0. end
module Keeper_world_observation = struct
  type world_observation = {
    pending_messages : unit list; pending_board_events : unit list;
    idle_seconds : int;
    active_goals : (string list, Goal_store.unavailable) result;
    unclaimed_task_count : int; claimable_tasks : unit list;
    held_task_skills : unit list; failed_task_count : int;
    scheduled_automation : unit; approval_authority : unit;
    backlog_revision : int; running_keeper_fiber_count : int;
    connected_surfaces : unit list; connected_surface_failures : unit list;
    own_recent_board_posts : unit list; fleet_messages : unit list;
    own_recent_actions : (unit list, unit) result }
  type backlog = { unclaimed_count : int; claimable_tasks : unit list;
                   failed_count : int; revision : int; held_task_skills : unit list }
  let read_backlog_snapshot ~config:_ ~meta:_ =
    {unclaimed_count=0;claimable_tasks=[];failed_count=0;revision=0;held_task_skills=[]}
  let read_scheduled_automation_observation ~keeper_name:_ ~config:_ ~now:_ = ()
  let read_approval_authority_observation ~config:_ ~meta:_ = ()
  let compute_idle_seconds ~meta:_ = 0
  let count_running_keeper_fibers ~config:_ = 0
  let collect_own_recent_board_posts ~meta:_ = []
  module Gate_surface = struct
    type presence = {surfaces: unit list; failures: unit list}
    let connected_surfaces_for_keeper ~keeper_name:_ = {surfaces=[];failures=[]}
  end
'''
    checks = r'''
end
type context = {config : Workspace.config}
'''+helper+r'''
let capture ctx (meta : keeper_meta) =
'''+capture+r'''
  world_observation, active_goal_summaries
let failures = ref 0
let goal id = {Goal_store.id;title=id;phase=Goal_phase.Open;last_review_note=None}
let check label first next measurement =
  Goal_store.script := [first;next]; Goal_store.reads := 0;
  Goal_measurement.reads := 0; Goal_measurement.observation := measurement;
  let world,summaries = capture {config={base_path="fixture"}} {name="keeper"} in
  let ids = Result.map (List.map (fun (g:Keeper_unified_prompt.goal_summary) ->
      g.summary_goal_id)) summaries in
  let coherent = world.active_goals = ids in
  let one_read = !Goal_store.reads = 1 in
  let measurement_preserved = match summaries, measurement with
    | Ok (g::_), Error expected -> g.summary_measurement = Error expected
    | _ -> true in
  let expected_ids = Result.map
      (List.filter_map (fun (g:Goal_store.goal) ->
         if Goal_phase.admits_self_directed_progress g.phase then Some g.id else None)) first in
  let authoritative = world.active_goals = expected_ids in
  let pass = coherent && one_read && measurement_preserved && authoritative in
  Printf.printf "%s %s reads=%d coherent=%b authoritative=%b measurement_preserved=%b\n"
    (if pass then "PASS" else "FAIL") label !Goal_store.reads coherent authoritative measurement_preserved;
  if not pass then incr failures
let () =
  let a=goal "A" and b=goal "B" in
  let bad=Error (Goal_store.Unreadable "original-store-failure") in
  check "Goal-closes-after-capture" (Ok [a]) (Ok []) (Ok []);
  check "Goal-opens-after-empty-capture" (Ok []) (Ok [b]) (Ok []);
  check "Goal-replaced-after-capture" (Ok [a]) (Ok [b]) (Ok []);
  check "unreadable-is-not-empty" bad (Ok [b]) (Ok []);
  check "later-read-failure-cannot-replace-capture" (Ok [a]) bad (Ok []);
  check "authoritative-empty" (Ok []) (Ok []) (Ok []);
  check "measurement-failure-keeps-Goal" (Ok [a]) (Ok [a]) (Error "measurement-unavailable");
  check "terminal-is-filtered-once" (Ok [{a with phase=Goal_phase.Terminal}]) (Ok [a]) (Ok []);
  if !failures > 0 then exit 2;
  print_endline "8 exact-source direct Goal snapshot checks passed"
'''
    source = prelude+summary+world_stubs+ids+"\n"+direct+checks
    with tempfile.TemporaryDirectory(prefix="masc-direct-goal-snapshot-") as temp:
        temp = pathlib.Path(temp)
        (temp / "probe.ml").write_text(source)
        compiled = subprocess.run(["ocamlc", "-o", "probe", "probe.ml"], cwd=temp,
                                  text=True, capture_output=True)
        ran = subprocess.run([str(temp / "probe")], cwd=temp, text=True,
                             capture_output=True) if compiled.returncode == 0 else None
        result = {"source_ref": args.source_ref or "working-tree",
                  "compile_exit": compiled.returncode,
                  "compile_stderr": compiled.stderr,
                  "run_exit": ran.returncode if ran else None,
                  "stdout": ran.stdout if ran else "",
                  "stderr": ran.stderr if ran else "",
                  "scope": "Actual extracted capture bindings, direct helper/world builder, Goal summary producer/open-ID renderer; scripted store, nominal Goal types, measurement and other world I/O stand-ins. No full typecheck, persisted-store I/O, Keeper/Host, SDK, vendor or live execution."}
    if args.output:
        args.output.write_text(json.dumps(result, indent=2)+"\n")
    print(json.dumps(result, indent=2))
    return compiled.returncode if ran is None else ran.returncode


if __name__ == "__main__":
    raise SystemExit(main())
