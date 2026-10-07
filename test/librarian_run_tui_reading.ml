(* What the Lanes screen holds for one Librarian run. The server projects a
   list page and a run detail; the TUI reads both with [Tui_decode] and draws
   what it decoded. A run the decoder refuses opens as a decode error instead
   of its evidence, so each runtime suite passes its recorded run through
   here. *)

open Masc
module Runs = Exact_lane_run_registry
module Projection = Server_standalone_lane_projection

let require = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let check (run : Runs.run) =
  let page =
    Projection.For_testing.recent_run_page_json_with
      ~limit:1
      ~before:None
      ~lane:(Some "librarian_exact")
      ~run_kind:None
      ~exact_runs:[ run ]
      ~verification_runs:[]
      ~goal_verification_runs:[]
    |> require
    |> Tui_decode.decode_lane_run_page ~lane:Standalone_lane.Librarian
    |> require
  in
  Alcotest.(check (list string))
    "the run list holds this run"
    [ run.run_id ]
    (List.map (fun (row : Tui_decode.lane_run_summary) -> row.lrs_run_id) page.lrpg_runs);
  Alcotest.(check (option int)) "the run list counts it as retained" (Some 1) page.lrpg_total;
  let detail =
    match
      Projection.For_testing.run_detail_json_with
        ~run_id:run.run_id
        ~exact_runs:[ run ]
        ~verification_runs:[]
        ~goal_verification_runs:[]
    with
    | Projection.Detail_found detail -> require (Tui_decode.decode_lane_run_detail detail)
    | Detail_not_found | Detail_ambiguous -> Alcotest.fail "the run has no detail to open"
  in
  Alcotest.(check string) "the detail is this run" run.run_id detail.lrd_run_id;
  Alcotest.(check bool) "the detail is a Librarian run" true
    (detail.lrd_lane = Standalone_lane.Librarian);
  Alcotest.(check string)
    "the detail reports the recorded status"
    (Runs.status_label run.status)
    (Tui_decode.lane_run_status_label detail.lrd_status);
  let recorded_output =
    match run.output_availability with
    | Some Runs.Available ->
      Some (Yojson.Safe.Util.member "output" (Runs.run_to_yojson run))
    | Some (Runs.Not_loaded | Runs.Unavailable _) | None -> None
  in
  Alcotest.(check (option json))
    "the detail holds the output the registry recorded"
    recorded_output
    detail.lrd_output;
  (* The pane folds a Librarian run's raw output behind its preflight reading. *)
  Alcotest.(check bool)
    "an available output carries the preflight reading"
    (Option.is_some recorded_output)
    (Option.is_some detail.lrd_librarian_preflight)
;;
