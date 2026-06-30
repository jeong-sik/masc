(** test_keeper_turn_fsm_wired_sites — turn FSM wiring markers.

    [test_keeper_turn_fsm_emit] pins the [Keeper_turn_fsm.emit_transition]
    *type surface*: a future signature drift fails compile.

    These markers read the source files that own the scheduled-turn
    transitions. They catch accidental deletion and the subtler case where
    success completion is emitted in both the caller and the success handler,
    which would double-count completed turns in observability data.

    Cross-reference: [docs/observability/keeper-turn-fsm-metrics.md]
    "Wiring sites" table lists every emit call with its PR. *)

open Masc

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

let locate_repo_file rel =
  match find_repo_root (Sys.getcwd ()) with
  | Some root -> Filename.concat root rel
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

(** Documented floor for the scheduled-turn source files that still emit
    directly after the 2026 extraction pass:

    - [keeper_unified_turn.ml] owns entry, routing, pre-dispatch, streaming
      failure/cancellation, and pre-provider transitions.
    - [keeper_unified_turn_success.ml] owns runtime-success terminal
      transitions: [Streaming -> Completing -> Done] for satisfied completion
      contracts, and [Streaming -> Completing -> Failed] for typed
      completion-contract attention results.

    Other extracted handlers may emit their own terminal transitions; this test
    intentionally does not count those modules. *)
let documented_floor = 7

let test_emit_call_count_floor () =
  let unified_path = locate_repo_file "lib/keeper/keeper_unified_turn.ml" in
  let success_path =
    locate_repo_file "lib/keeper/keeper_unified_turn_success.ml"
  in
  let n =
    count_substring (read_file unified_path) "Keeper_turn_fsm.emit_transition"
    + count_substring (read_file success_path) "Keeper_turn_fsm.emit_transition"
  in
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

let test_success_completion_transitions_owned_once () =
  let unified =
    read_file (locate_repo_file "lib/keeper/keeper_unified_turn.ml")
  in
  let success =
    read_file (locate_repo_file "lib/keeper/keeper_unified_turn_success.ml")
  in
  Alcotest.(check int)
    "success completion transitions not emitted by caller" 0
    (count_substring unified "Keeper_turn_fsm.Completing");
  Alcotest.(check int)
    "success handler owns three completion-state references" 3
    (count_substring success "Keeper_turn_fsm.Completing");
  Alcotest.(check int)
    "success handler owns one done transition" 1
    (count_substring success "Keeper_turn_fsm.Done");
  Alcotest.(check int)
    "success handler owns one typed failed transition" 1
    (count_substring success "Keeper_turn_fsm.Failed")

let () =
  Alcotest.run "keeper_turn_fsm_wired_sites"
    [
      ( "wiring",
        [
          Alcotest.test_case
            "emit_transition call count meets documented floor"
            `Quick test_emit_call_count_floor;
          Alcotest.test_case
            "success completion transitions are single-owned"
            `Quick test_success_completion_transitions_owned_once;
        ] );
    ]
