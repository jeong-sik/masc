(** test_keeper_turn_fsm_wired_sites — Step 4 wiring sentinel.

    [test_keeper_turn_fsm_emit] pins the [Keeper_turn_fsm.emit_transition]
    *type surface*: a future signature drift fails compile.

    But a future PR could *delete* one of the 11 wired
    [emit_transition] call sites in [keeper_unified_turn.ml]
    without breaking the build -- the build doesn't care if a
    function is called.  Result: the fleet observability stack
    silently regresses (Prometheus counter loses a series, the
    Grafana dashboard's panel goes flat, [bin/masc-trace]
    timeline jumps over a state).

    This sentinel reads [lib/keeper/keeper_unified_turn.ml]
    and asserts that the [Keeper_turn_fsm.emit_transition] call
    count meets the documented floor.  A delete fails this
    test with a clear message; an add (more emits) is a no-op
    on this test (the floor is a >=, not an =).

    Cross-reference: [docs/observability/keeper-turn-fsm-metrics.md]
    "Wiring sites" table lists every emit call with its PR. *)

open Masc_mcp

let read_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let n = in_channel_length ic in
      let buf = Bytes.create n in
      really_input ic buf 0 n;
      Bytes.unsafe_to_string buf)

let rec find_repo_root dir =
  if Sys.file_exists (Filename.concat dir "dune-project") then Some dir
  else
    let parent = Filename.dirname dir in
    if String.equal parent dir then None else find_repo_root parent

let locate_keeper_unified_turn () =
  match find_repo_root (Sys.getcwd ()) with
  | Some root ->
      Filename.concat root "lib/keeper/keeper_unified_turn.ml"
  | None ->
      Alcotest.fail "could not locate dune-project ancestor of cwd"

(** Naive non-overlapping substring counter. *)
let count_substring haystack needle =
  let lens = String.length haystack in
  let lensub = String.length needle in
  if lensub = 0 || lensub > lens then 0
  else
    let rec loop i acc =
      if i > lens - lensub then acc
      else if String.sub haystack i lensub = needle then
        loop (i + lensub) (acc + 1)
      else loop (i + 1) acc
    in
    loop 0 0

(** Documented floor: 11 wired sites in [keeper_unified_turn.ml]
    after Steps 4b/4c/4d/4g/4i/4j.  Composition:

    | Step | site                                                  | count |
    |------|-------------------------------------------------------|-------|
    | 4c   | run_keeper_cycle entry [Idle -> Phase_gating]         | 1     |
    | 4b   | phase-gate skip [Phase_gating -> Cancelled]           | 1     |
    | 4g   | phase pass [Phase_gating -> Cascade_routing]          | 1     |
    | 4b   | ollama saturated skip                                 | 1     |
    | 4b   | cascade build error                                   | 1     |
    | 4g   | livelock Started [Cascade_routing -> Awaiting_provider] | 1   |
    | 4b   | livelock Blocked                                      | 1     |
    | 4i   | run_turn pre-call [Awaiting_provider -> Streaming]    | 1     |
    | 4j   | retry_loop exhaustion [Streaming -> Failed]           | 1     |
    | 4d   | stop_reason [Streaming -> Completing]                 | 1     |
    | 4c   | success exit [Completing -> Done]                     | 1     |
    *)
let documented_floor = 11

let test_emit_call_count_floor () =
  let path = locate_keeper_unified_turn () in
  let body = read_file path in
  let n = count_substring body "Keeper_turn_fsm.emit_transition" in
  if n < documented_floor then
    Alcotest.failf
      "Keeper_turn_fsm.emit_transition call count regressed: \
       found=%d, floor=%d.  See docs/observability/\
       keeper-turn-fsm-metrics.md \"Wiring sites\" table for \
       the documented sites.  If a deletion is intentional, \
       update [documented_floor] in this test and the table \
       in the doc together."
      n documented_floor;
  Alcotest.(check bool)
    (Printf.sprintf
       "Keeper_turn_fsm.emit_transition call count >= %d (found %d)"
       documented_floor n)
    true (n >= documented_floor)

let () =
  Alcotest.run "keeper_turn_fsm_wired_sites"
    [
      ( "wiring",
        [
          Alcotest.test_case
            "emit_transition call count meets documented floor"
            `Quick test_emit_call_count_floor;
        ] );
    ]
