module Lib = Masc

open Alcotest

(* build_timeline integration tests.

   Regression for the agent-timeline global-zero bug: a live keeper's
   keeper.turn_completed events are persisted with the FULL actor id
   ("keeper-<handle>-agent"), while the tool is queried by the SHORT handle.
   These tests drive the real read path end-to-end (Activity_graph.emit ->
   collect_event_files -> read_all_events -> list_events -> build_timeline
   summary) so the activity branch of [identity_matches] is exercised exactly
   as in production, and a turn for the queried keeper surfaces in the summary
   counts. *)

let test_dir () =
  let tmp = Filename.temp_file "masc_timeline_build" "" in
  Sys.remove tmp;
  Unix.mkdir tmp 0o755;
  tmp

let cleanup_dir dir =
  let rec rm path =
    if Sys.file_exists path then
      if Sys.is_directory path then begin
        Sys.readdir path |> Array.iter (fun name -> rm (Filename.concat path name));
        Unix.rmdir path
      end
      else Sys.remove path
  in
  rm dir

let with_config f =
  let dir = test_dir () in
  Fun.protect
    ~finally:(fun () -> cleanup_dir dir)
    (fun () -> f (Lib.Workspace.default_config dir))

let build config ~agent_name =
  Lib.Tool_agent_timeline.build_timeline config ~agent_name ~since_hours:24.0
    ~limit:50 ~include_tasks:true ~include_board:false ~include_tool_calls:true

let summary_int json key =
  let open Yojson.Safe.Util in
  json |> member "summary" |> member key |> to_int

(* A turn_completed event persisted with the FULL actor id must surface when
   the timeline is queried by the SHORT handle. The payload carries no
   identity field, so the only signal that can match is the actor.id full
   form — this isolates the dual-representation identity match and would fail
   if [identity_matches] regressed to a plain [String.equal] on the short
   handle. *)
let test_surfaces_turn_completed_for_short_handle () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"agent" "keeper-testkeeper-agent")
           ~subject:(Activity_graph.entity ~kind:"log" "turn-1")
           ~payload:(`Assoc [ ("model_used", `String "test-model") ])
           ());
      let json = build config ~agent_name:"testkeeper" in
      check int "turns_completed counts the keeper's turn" 1
        (summary_int json "turns_completed");
      check bool "total_events is non-zero" true
        (summary_int json "total_events" >= 1))

(* A turn whose actor id belongs to a different keeper must not surface for
   the queried handle. No identity field in the payload, so exclusion rests
   on the actor.id mismatch alone. *)
let test_excludes_other_keeper () =
  with_config (fun config ->
      ignore
        (Activity_graph.emit config ~kind:"keeper.turn_completed"
           ~actor:(Activity_graph.entity ~kind:"agent" "keeper-other-agent")
           ~payload:(`Assoc [ ("model_used", `String "test-model") ])
           ());
      let json = build config ~agent_name:"testkeeper" in
      check int "other keeper's turn is excluded" 0
        (summary_int json "turns_completed");
      check int "no events for the queried handle" 0
        (summary_int json "total_events"))

(* Regression for the per-source take-oldest bug (task-1647): each activity
   collector ([tool_call_events], [keeper_cdal_events], [turn_completed_events])
   fetched the source's newest window in seq-ascending order (oldest first) and
   then front-truncated to the per-source cap. Once a keeper produced more
   matching events than the cap, the front-take discarded the NEWEST matches —
   the opposite of the tool contract (period.to = now) and of build_timeline's
   own tail-keep on the merged list. These tests emit more than the cap and
   assert the newest event survives while the oldest is dropped. *)

(* Per-source cap pinned in build_timeline (message/tool/cdal/turn = 200). *)
let source_cap = 200
let overflow = 60

let marker i = Printf.sprintf "marker-%04d" i

(* Naive substring test — the markers are zero-padded so [marker 1] is never a
   substring of any other marker in the series. *)
let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  if nl = 0 then true
  else
    let rec loop i =
      if i + nl > hl then false
      else if String.equal (String.sub haystack i nl) needle then true
      else loop (i + 1)
    in
    loop 0

(* Emit [source_cap + overflow] events of [kind] for keeper "testkeeper", each
   tagged via [payload_of] with a per-index marker so the oldest (i = 1) and
   newest (i = source_cap + overflow) are individually identifiable. *)
let emit_capacity_series config ~kind ~payload_of =
  for i = 1 to source_cap + overflow do
    ignore
      (Activity_graph.emit config ~kind
         ~actor:
           (Activity_graph.entity ~kind:"agent" "keeper-testkeeper-agent")
         ~payload:(payload_of (marker i))
         ())
  done

(* Build with a limit above the per-source cap so the merged-list truncation is
   a no-op: presence/absence then reflects only the source-collector cap, and is
   independent of ts-collision ordering in build_timeline's final sort. *)
let build_all config ~agent_name =
  Lib.Tool_agent_timeline.build_timeline config ~agent_name ~since_hours:24.0
    ~limit:1000 ~include_tasks:true ~include_board:false ~include_tool_calls:true

let events_blob json =
  let open Yojson.Safe.Util in
  json |> member "events" |> Yojson.Safe.to_string

let newest_marker = marker (source_cap + overflow)
let oldest_marker = marker 1

let check_keeps_newest ~label config =
  let blob = events_blob (build_all config ~agent_name:"testkeeper") in
  check bool (label ^ ": newest event present") true
    (contains ~needle:newest_marker blob);
  check bool (label ^ ": oldest event dropped") false
    (contains ~needle:oldest_marker blob)

let test_tool_call_keeps_newest () =
  with_config (fun config ->
      emit_capacity_series config ~kind:"tool.called"
        ~payload_of:(fun s -> `Assoc [ ("tool_name", `String s) ]);
      check_keeps_newest ~label:"tool_call" config)

let test_cdal_keeps_newest () =
  with_config (fun config ->
      emit_capacity_series config ~kind:"keeper.contract_verdict"
        ~payload_of:(fun s -> `Assoc [ ("verdict", `String s) ]);
      check_keeps_newest ~label:"cdal" config)

let test_turn_completed_keeps_newest () =
  with_config (fun config ->
      emit_capacity_series config ~kind:"keeper.turn_completed"
        ~payload_of:(fun s -> `Assoc [ ("model_used", `String s) ]);
      check_keeps_newest ~label:"turn_completed" config)

let () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  run "Tool_agent_timeline build_timeline"
    [
      ( "activity-read",
        [
          test_case "turn_completed surfaces for short handle" `Quick
            test_surfaces_turn_completed_for_short_handle;
          test_case "other keeper excluded" `Quick test_excludes_other_keeper;
        ] );
      ( "per-source-cap-keeps-newest",
        [
          test_case "tool_call keeps newest" `Quick test_tool_call_keeps_newest;
          test_case "cdal keeps newest" `Quick test_cdal_keeps_newest;
          test_case "turn_completed keeps newest" `Quick
            test_turn_completed_keeps_newest;
        ] );
    ]
