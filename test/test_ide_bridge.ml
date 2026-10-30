(** Canonical tool-result journal -> addressed IDE projection, with real files. *)
open Alcotest
module Calls = Masc.Keeper_tool_call_log
module Index = Keeper_tool_call_index
let get = function Ok value -> value | Error _ -> fail "canonical read failed"
let rec remove path =
  if Sys.file_exists path then
    if Sys.is_directory path then (Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path)
    else Sys.remove path
let with_store f =
  let base = Filename.temp_file "canonical-ide-" "" in
  Sys.remove base; Unix.mkdir base 0o700;
  Calls.reset_for_testing ();
  Fun.protect ~finally:(fun () -> Calls.reset_for_testing (); remove base)
    (fun () -> Calls.init ~base_path:base (); f base)
let observation ?(codebase = "github.com_owner_repo") () =
  let address = Agent_observation.Code_address.v ~codebase ~path:"lib/actual.ml" |> get in
  Tool_observation.{ attribution = File (Addressed { address; checkout = Some "/measured/checkout" });
    turn_ref = Ids.Turn_ref.make ~trace_id:"actual-trace" ~absolute_turn:19;
    declared_progress = Some Progress }
let write ?(keeper = "actual-keeper") ?(observation = observation ()) execution =
  Calls.log_call ~keeper_name:keeper ~tool_name:"Edit" ~input:(`Assoc [])
    ~output_text:"actual saved result" ~duration_ms:2. ~wire_outcome:Tool_result.Ok
    ~execution_id:execution ~tool_observation:observation ()
let events ?keeper_name ~base ~codebase ~limit ~offset () =
  Calls.read_addressed ~base_path:base ~codebase ?keeper_name ~limit ~offset ()
  |> get |> Ide_bridge.events_of_rows |> get
let id row = Yojson.Safe.Util.(row |> member "event_id" |> to_string)
let all ~base ~codebase =
  let rec read offset acc =
    let page = events ~base ~codebase ~limit:200 ~offset () in
    match page with [] -> List.rev acc | _ :: _ -> read (offset + List.length page) (List.rev_append page acc)
  in read 0 []
let test_new_facts_survive_without_derived_writer () =
  with_store (fun base ->
    (* The retired weaker store cannot accept any append. Canonical facts do
       not consult it, enqueue jobs, or wait for its writer. *)
    let channel = open_out (Filename.concat base ".masc-ide") in close_out channel;
    let ids = List.init 1100 (fun _ -> Ids.Execution_id.generate ()) in
    List.iter write ids;
    let expected = List.map Ids.Execution_id.to_string ids |> List.sort String.compare in
    let rows = all ~base ~codebase:"github.com_owner_repo" in
    check (list string) "every new fact beyond the former queue capacity" expected
      (List.map id rows |> List.sort String.compare);
    let store = Calls.store () |> Option.get in
    Index.forget_for_ledger ~ledger_dir:(Dated_jsonl.base_dir store);
    Sys.remove (Index.database_path ~ledger_dir:(Dated_jsonl.base_dir store));
    Calls.reset_for_testing (); Calls.init ~base_path:base ();
    let reopened = all ~base ~codebase:"github.com_owner_repo" in
    check (list string) "reopen and disposable-index rebuild retain exact identities"
      (List.map id rows) (List.map id reopened);
    check string "physical turn witness" "actual-trace#19"
      Yojson.Safe.Util.(List.hd reopened |> member "turn_id" |> to_string))
let test_filter_before_page_and_immutable_attribution () =
  with_store (fun base ->
    let retained = Ids.Execution_id.generate () in write retained;
    List.iter (fun _ -> write ~keeper:"different" ~observation:(observation ~codebase:"github.com_changed_origin" ()) (Ids.Execution_id.generate ())) (List.init 250 Fun.id);
    let rows = events ~base ~codebase:"github.com_owner_repo" ~keeper_name:"actual-keeper" ~limit:1 ~offset:0 () in
    check (list string) "no recent-tail cap before canonical scope filters"
      [Ids.Execution_id.to_string retained] (List.map id rows);
    check int "complete other scope" 250 (List.length (all ~base ~codebase:"github.com_changed_origin"));
    check int "explicit empty scope" 0
      (List.length (events ~base ~codebase:"github.com_no_matches" ~limit:1 ~offset:0 ())))
let test_ambiguous_identity_is_unavailable () =
  with_store (fun base ->
    let execution = Ids.Execution_id.generate () in write execution; write execution;
    match Calls.read_addressed ~base_path:base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 () with
    | Error _ -> () | Ok _ -> fail "duplicate canonical execution was rendered as successful activity")
let test_ambiguity_includes_unaddressed_and_legacy_rows () =
  List.iter (fun variant -> with_store (fun base ->
    let execution = Ids.Execution_id.generate () in
    write execution;
    (match variant with
     | `Pathless -> write ~observation:{(observation ()) with attribution=Agent_observation.Pathless} execution
     | `Unaddressed ->
       write ~observation:{(observation ()) with attribution=Agent_observation.File
         (Unaddressed {reason=Origin_missing;attempted_path="lib/actual.ml"})} execution
     | `Legacy -> Calls.log_call ~keeper_name:"actual-keeper" ~tool_name:"Edit"
         ~input:(`Assoc []) ~output_text:"legacy duplicate" ~duration_ms:1.
         ~wire_outcome:Tool_result.Ok ~execution_id:execution ~on_committed:ignore ());
    match Calls.read_addressed ~base_path:base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 () with
    | Error _ -> () | Ok _ -> fail "another canonical copy was excluded from identity integrity"))
    [`Pathless; `Unaddressed; `Legacy]
let test_identity_witness_tracks_rewrite_and_rebuild () =
  with_store (fun base ->
    let execution = Ids.Execution_id.generate () in
    write execution;
    let store = Calls.store () |> Option.get in
    let path = Calls.current_log_path () |> Option.get in
    let original = In_channel.with_open_text path input_line in
    check int "one initial identity" 1 (List.length (events ~base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 ()));
    Index.forget_for_ledger ~ledger_dir:(Dated_jsonl.base_dir store);
    let database = Sqlite3.db_open (Index.database_path ~ledger_dir:(Dated_jsonl.base_dir store)) in
    Fun.protect ~finally:(fun () -> ignore (Sqlite3.db_close database : bool))
      (fun () -> check bool "discard derived scan cursor" true
        (Sqlite3.Rc.is_success (Sqlite3.exec database "DELETE FROM cursors")));
    check int "replacing indexed locations never counts a row twice" 1
      (List.length (events ~base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 ()));
    write ~observation:{(observation ()) with attribution=Agent_observation.Pathless} execution;
    (match Calls.read_addressed ~base_path:base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 () with
     | Error _ -> () | Ok _ -> fail "appended duplicate did not update witness");
    Out_channel.with_open_text path (fun output -> output_string output (original ^ "\n"));
    check int "rewrite removes the retired duplicate witness" 1
      (List.length (events ~base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 ()));
    Index.forget_for_ledger ~ledger_dir:(Dated_jsonl.base_dir store);
    Sys.remove (Index.database_path ~ledger_dir:(Dated_jsonl.base_dir store));
    check int "index rebuild remints exactly one identity witness" 1
      (List.length (events ~base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 ())))
let test_invalid_metadata_is_unavailable () =
  with_store (fun base ->
    write (Ids.Execution_id.generate ());
    let path = Calls.current_log_path () |> Option.get in
    let channel = open_in path in let row = input_line channel |> Yojson.Safe.from_string in close_in channel;
    let broken = match row with
      | `Assoc fields -> `Assoc (("tool_observation", `Assoc []) :: List.remove_assoc "tool_observation" fields)
      | _ -> fail "canonical writer produced no object" in
    let channel = open_out path in output_string channel (Yojson.Safe.to_string broken ^ "\n"); close_out channel;
    match Calls.read_addressed ~base_path:base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 () with
    | Error _ -> () | Ok _ -> fail "malformed immutable observation was silently omitted")
let test_observed_row_without_primary_identity_is_unavailable () =
  List.iter (fun missing ->
    with_store (fun base ->
      write (Ids.Execution_id.generate ());
      let path = Calls.current_log_path () |> Option.get in
      let row = In_channel.with_open_text path (fun input -> input_line input |> Yojson.Safe.from_string) in
      let broken = match row with
        | `Assoc fields -> `Assoc (List.remove_assoc missing fields)
        | _ -> fail "canonical writer produced no object" in
      Out_channel.with_open_text path (fun output -> output_string output (Yojson.Safe.to_string broken ^ "\n"));
      match Calls.read_addressed ~base_path:base ~codebase:"github.com_owner_repo" ~limit:10 ~offset:0 () with
      | Error _ -> () | Ok _ -> failf "observed row without %s was silently omitted" missing))
    ["keeper"; "ts"; "execution_id"]
let () = run "canonical IDE facts"
  [ "journal to IDE",
    [ test_case "new facts survive unavailable duplicate writer and index reopen" `Quick test_new_facts_survive_without_derived_writer;
      test_case "immutable scope is filtered before paging" `Quick test_filter_before_page_and_immutable_attribution;
      test_case "ambiguous canonical identity rejects activity" `Quick test_ambiguous_identity_is_unavailable;
      test_case "canonical identity includes unaddressed and legacy rows" `Quick test_ambiguity_includes_unaddressed_and_legacy_rows;
      test_case "identity witness follows append rewrite and rebuild" `Quick test_identity_witness_tracks_rewrite_and_rebuild;
      test_case "invalid metadata rejects activity" `Quick test_invalid_metadata_is_unavailable;
      test_case "observed row requires primary identity" `Quick test_observed_row_without_primary_identity_is_unavailable ] ]
