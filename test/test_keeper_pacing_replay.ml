(** RFC-0313 W3 gate — storm replay over the 2026-07-06 fixture.

    Replays the highest-density 5-minute window of the 07-06 rotation storm
    (test/fixtures/pacing_storm_20260706/) against [Keeper_pacing] with the
    default policy and pins the contrast: the recorded ping-pong produced
    2,004 rotation attempts across two runtimes in ~300s; per-runtime
    revisit pacing admits a fixed, small schedule instead. W3 flips
    enforcement only with this gate green.

    The simulation passes [retry_after:None] (pure exponential widening).
    This is the conservative tighter bound: the storm's real
    capacity_backpressure retry_after hints were minutes-long, so honoring
    them would space attempts wider than the exponential schedule, never
    narrower ([Keeper_pacing.on_failure] hint replaces the computed delay
    and 30s is the smallest computed delay). *)

open Masc
module KP = Keeper_pacing

let source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root when root <> "" -> root
  | _ -> Sys.getcwd ()

let fixture_path () =
  Filename.concat
    (source_root ())
    "test/fixtures/pacing_storm_20260706/nick0cave-rotation-0500-0504.csv"

type event =
  { at_sec : float (* seconds since the window's first event *)
  ; failed_runtime : string
  }

(* Fixture rows are "<iso8601>Z,<failed runtime>,<rotation target>,<reason>".
   The format is pinned by the fixture README; a row that does not parse
   fails the test rather than being skipped. *)
let seconds_of_day ts =
  try Scanf.sscanf ts "%4d-%2d-%2dT%2d:%2d:%2dZ" (fun _ _ _ hh mm ss ->
    float_of_int ((hh * 3600) + (mm * 60) + ss))
  with Scanf.Scan_failure _ | Failure _ | End_of_file ->
    Alcotest.failf "unparseable fixture timestamp: %s" ts

let load_events () =
  let ic = open_in (fixture_path ()) in
  Fun.protect
    ~finally:(fun () -> try close_in ic with Sys_error _ -> ())
    (fun () ->
      let rec loop acc =
        match input_line ic with
        | exception End_of_file -> List.rev acc
        | line when String.equal (String.trim line) "" -> loop acc
        | line ->
          (match String.split_on_char ',' line with
           | [ ts; failed_runtime; _rotated_to; _reason ] ->
             loop ({ at_sec = seconds_of_day ts; failed_runtime } :: acc)
           | _ -> Alcotest.failf "unparseable fixture row: %s" line)
      in
      loop [])

let distinct_runtimes events =
  List.fold_left
    (fun acc ev ->
      if List.exists (String.equal ev.failed_runtime) acc then acc
      else ev.failed_runtime :: acc)
    []
    events
  |> List.sort String.compare

(* Enforced-pacing semantics (RFC-0313 §1-2): a failure widens only the
   failed runtime's revisit; the next attempt runs on the earliest-eligible
   runtime; when every runtime is paced the keeper waits until the minimum
   deadline. Every attempt in the storm window failed, so the replay marks
   every admitted attempt as a failure. *)
let simulate ~catalog ~policy ~window_sec =
  let eligible_at state runtime_id now =
    match KP.revisit_of ~runtime_id state with
    | None -> true
    | Some revisit -> revisit.KP.eligible_at <= now
  in
  let rec go now state admitted =
    let due = KP.next_turn_due ~catalog ~now state in
    let now = Float.max now due in
    if now >= window_sec then List.rev admitted
    else (
      match List.find_opt (fun r -> eligible_at state r now) catalog with
      | None ->
        (* next_turn_due returned a time inside the window, so some runtime
           is eligible; reaching here means the scheduling rule and the
           eligibility rule disagree. *)
        Alcotest.failf "no eligible runtime at t=%.1f despite due=%.1f" now due
      | Some runtime_id ->
        let state = KP.on_failure ~policy ~runtime_id ~retry_after:None ~now state in
        go now state ((now, runtime_id) :: admitted))
  in
  go 0.0 KP.empty []

let per_runtime_times admitted runtime_id =
  List.filter_map
    (fun (at, r) -> if String.equal r runtime_id then Some at else None)
    admitted

let test_fixture_integrity () =
  let events = load_events () in
  Alcotest.(check int) "recorded storm attempts" 2004 (List.length events);
  let runtimes = distinct_runtimes events in
  Alcotest.(check (list string))
    "two runtimes ping-ponging"
    [ "glm-coding.glm-5-turbo"; "runpod_rtxa6000.gemma4-coder-fable5-q4km" ]
    runtimes;
  let first = List.hd events in
  let last = List.nth events (List.length events - 1) in
  let span = last.at_sec -. first.at_sec in
  Alcotest.(check bool)
    "window spans under five minutes"
    true
    (span >= 0.0 && span < 300.0)

let test_pacing_bounds_storm_window () =
  let events = load_events () in
  let catalog = distinct_runtimes events in
  let admitted =
    simulate ~catalog ~policy:KP.default_policy ~window_sec:300.0
  in
  (* Deterministic schedule under base 30s x2: each runtime fails at
     t=0, 30, 90, 210; the next revisit (450) falls outside the window. *)
  List.iter
    (fun runtime_id ->
      Alcotest.(check (list (float 1e-6)))
        (Printf.sprintf "paced schedule for %s" runtime_id)
        [ 0.0; 30.0; 90.0; 210.0 ]
        (per_runtime_times admitted runtime_id))
    catalog;
  let recorded = List.length events in
  let paced = List.length admitted in
  Alcotest.(check bool)
    (Printf.sprintf
       "at least 100x reduction (recorded=%d paced=%d)"
       recorded
       paced)
    true
    (paced * 100 <= recorded)

let test_provider_hint_spaces_revisit () =
  (* The storm class carries provider hints; pin that a hint admits at most
     one attempt per hint interval and cannot go negative. *)
  let state =
    KP.on_failure
      ~policy:KP.default_policy
      ~runtime_id:"glm-coding.glm-5-turbo"
      ~retry_after:(Some 120.0)
      ~now:0.0
      KP.empty
  in
  match KP.revisit_of ~runtime_id:"glm-coding.glm-5-turbo" state with
  | None -> Alcotest.failf "expected a revisit entry after hinted failure"
  | Some revisit ->
    Alcotest.(check (float 1e-6))
      "provider hint spaces the revisit"
      120.0
      revisit.KP.eligible_at

let () =
  Alcotest.run
    "keeper_pacing_replay"
    [ ( "fixture"
      , [ Alcotest.test_case "integrity" `Quick test_fixture_integrity ] )
    ; ( "replay"
      , [ Alcotest.test_case
            "pacing bounds the storm window"
            `Quick
            test_pacing_bounds_storm_window
        ; Alcotest.test_case
            "hinted revisit spacing"
            `Quick
            test_provider_hint_spaces_revisit
        ] )
    ]
