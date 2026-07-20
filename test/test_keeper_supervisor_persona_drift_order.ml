(** Structural guard for issue #25491.

    [log_persona_drift_if_missing] used to run before
    [register_offline_if_admitted] inside [supervise_keepalive]. Registration
    can be rejected (a shutdown operation owning admission, a lifecycle
    reservation, a validation error), and the supervisor retries roughly every
    30s while the rejection persists. Every rejected attempt therefore emitted
    a persona-drift warning whose stated remediation ("add persona profile if
    persona assets are required") cannot lift the rejection: measured on a live
    fleet on 2026-07-20, one blocked keeper produced ~120 such warnings per
    hour against 20 server boots, while the drift condition itself was static.

    This test pins the fix: the drift report must come after the registration
    call, so it describes a keeper that actually joined the fleet.

    Structural (source offsets) rather than behavioural, following the
    precedent in [test_keeper_supervisor_write_meta_source.ml]: the call site
    is inside [supervise_keepalive], which needs a full Workspace /
    Keeper_registry fixture to exercise, and the repository has no log-capture
    harness to assert on emitted lines. The risk guarded against is exactly
    that a future refactor hoists the drift report back above the registration
    call. *)

open Alcotest

let target_file = "lib/keeper/keeper_supervisor_supervise_keepalive.ml"

let load_source rel =
  let source_root =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root -> root
    | None -> Sys.getcwd ()
  in
  let path = Filename.concat source_root rel in
  if not (Sys.file_exists path) then
    failwith (Printf.sprintf "source file not found: %s" path)
  else
    let ic = open_in path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () -> In_channel.input_all ic)

let find_offset haystack needle =
  try Some (Str.search_forward (Str.regexp_string needle) haystack 0)
  with Not_found -> None

let count_occurrences haystack needle =
  let re = Str.regexp_string needle in
  let rec go from acc =
    match Str.search_forward re haystack from with
    | pos -> go (pos + 1) (acc + 1)
    | exception Not_found -> acc
  in
  go 0 0

let drift_call = "log_persona_drift_if_missing"
let register_call = "register_offline_if_admitted"

let test_drift_reported_once () =
  let src = load_source target_file in
  check int
    "supervise_keepalive must call log_persona_drift_if_missing exactly once"
    1
    (count_occurrences src drift_call)

let test_drift_follows_registration () =
  let src = load_source target_file in
  match find_offset src register_call, find_offset src drift_call with
  | None, _ ->
    fail (Printf.sprintf "%s not found in %s" register_call target_file)
  | _, None ->
    fail (Printf.sprintf "%s not found in %s" drift_call target_file)
  | Some register_at, Some drift_at ->
    check bool
      "persona drift must be reported after register_offline_if_admitted, not \
       before it (issue #25491: rejected registrations must not narrate an \
       unrelated remediation)"
      true
      (drift_at > register_at)

let () =
  run "keeper_supervisor_persona_drift_order" [
    "drift_report_ordering", [
      test_case "drift reported exactly once" `Quick test_drift_reported_once;
      test_case "drift reported after registration" `Quick
        test_drift_follows_registration;
    ];
  ]
