(* Verify the server projection of a Librarian run's list page and run detail. *)

open Masc
module Runs = Exact_lane_run_registry
module Projection = Server_standalone_lane_projection

let require = function
  | Ok value -> value
  | Error detail -> Alcotest.fail detail
;;

let json = Alcotest.testable Yojson.Safe.pp Yojson.Safe.equal

let check (run : Runs.run) =
  let open Yojson.Safe.Util in
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
  in
  let runs = page |> member "runs" |> to_list in
  Alcotest.(check (list string))
    "the run list holds this run"
    [ run.run_id ]
    (List.map (fun row -> row |> member "run_id" |> to_string) runs);
  Alcotest.(check (option int)) "the run list counts it as retained" (Some 1)
    (match member "total" page with `Int n -> Some n | _ -> None);
  let detail_json =
    match
      Projection.For_testing.run_detail_json_with
        ~run_id:run.run_id
        ~exact_runs:[ run ]
        ~verification_runs:[]
        ~goal_verification_runs:[]
    with
    | Projection.Detail_found detail -> detail
    | Detail_not_found | Detail_ambiguous -> Alcotest.fail "the run has no detail to open"
  in
  let row = member "run" detail_json in
  Alcotest.(check string) "the detail is this run" run.run_id (row |> member "run_id" |> to_string);
  Alcotest.(check string) "the detail is a Librarian run" "librarian_exact"
    (row |> member "lane" |> to_string);
  Alcotest.(check string)
    "the detail reports the recorded status"
    (Runs.status_label run.status)
    (row |> member "status" |> to_string);
  let recorded_output =
    match run.output_availability with
    | Some Runs.Available ->
      Some (member "output" (Runs.run_to_yojson run))
    | Some (Runs.Not_loaded | Runs.Unavailable _) | None -> None
  in
  let detail_output =
    match member "output" (member "payload_availability" row) with
    | `Null -> None
    | av ->
      (match Runs.availability_of_yojson av with
       | Ok Runs.Available -> Some (member "output" row)
       | Ok (Runs.Not_loaded | Runs.Unavailable _) -> None
       | Error err -> Alcotest.fail err)
  in
  Alcotest.(check (option json))
    "the detail holds the output the registry recorded"
    recorded_output
    detail_output
;;
