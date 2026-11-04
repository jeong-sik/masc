open Alcotest
open Masc
open Yojson.Safe.Util
module Persistence = Keeper_event_queue_persistence
module State = Keeper_event_queue_state
module Ledger = Keeper_reaction_ledger
module Manifest = Keeper_runtime_manifest

(* The production loader with the pure first-ready selection. *)
let select_queue_entry ~base_path ~keeper_name ~now ~ready =
  Keeper_event_queue_persistence.load_state_result ~base_path ~keeper_name
  |> Result.map (Keeper_event_queue_state.select_when ~now ~ready)
;;

let ok = function Ok value -> value | Error detail -> fail detail
let keeper_name = "source-outcome-reviewer"
let trace_id = "source-outcome-trace"

let with_source run =
  let rec remove path =
    if Sys.is_directory path then (
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Sys.rmdir path)
    else Sys.remove path in
  let base_path = Filename.temp_dir "keeper-source-outcomes-" "" in
  Fun.protect ~finally:(fun () -> remove base_path) (fun () -> Eio_main.run (fun env ->
    Fs_compat.set_fs (Eio.Stdenv.fs env);
    run (Workspace.default_config base_path)))

let source : Keeper_event_queue.stimulus =
  { post_id="outcome-source"; arrived_at=1234.; urgency=Normal
  ; payload=Bootstrap }

let select config =
  match select_queue_entry ~base_path:config.Workspace.base_path ~keeper_name
    ~now:(Unix.gettimeofday ()) ~ready:(fun _ -> true) |> ok with
  | Some selection -> selection
  | None -> fail "source was not selected"

let enqueue config =
  ignore (Persistence.enqueue_stimulus_if_absent_result
    ~base_path:config.Workspace.base_path ~keeper_name source |> ok);
  select config

let start config turn selection =
  Manifest.make ~keeper_name ~trace_id ~keeper_turn_id:turn ~event:Turn_started
    ~decision:(`Assoc ["intake_sources", Keeper_heartbeat_source_batch.(observed_sources_to_yojson (of_selections [selection]))]) ()
  |> Manifest.append_best_effort config

let project config ?(turn=7) () =
  let status, response = Server_dashboard_http_keeper_api.keeper_runtime_trace_json
    config keeper_name ~trace_id ~turn_id:turn () in
  check bool "runtime-trace owner responds" true (status=`OK);
  member "source_outcomes" response

let receipts json = json |> member "sources" |> to_list |> List.hd |> member "receipts" |> to_list

let project_transition config = function
  | Persistence.Transition_applied receipt | Transition_already_applied receipt ->
    Ledger.project_event_queue_transition_outbox_result
      ~base_path:config.Workspace.base_path ~keeper_name
      ~expected_transition_id:receipt.State.transition_id |> ok
  | Transition_committed_followup_failed {detail;_} -> fail detail

let terminalize config selection =
  match
    Persistence.terminalize_pending_turn_completed_result ~base_path:config.Workspace.base_path
      ~keeper_name ~applied_at:(Unix.gettimeofday ()) ~selection ()
    |> ok
  with
  | Persistence.Turn_terminal_committed transition -> project_transition config transition
  | Turn_selection_withdrawn -> fail "selected source was withdrawn"

let exact_source_incarnation () = with_source (fun config ->
  let original = enqueue config in
  start config 7 original;
  check int "selection is not an invented terminal receipt" 0 (List.length (receipts (project config ())));
  terminalize config original;
  let first = receipts (project config ()) in
  check int "actual durable terminal projects exactly once" 1 (List.length first);
  check string "typed completed receipt" "ack_turn_completed" (List.hd first |> member "kind" |> to_string);
  let store = Dated_jsonl.open_store (Ledger.location ~base_path:config.base_path ~keeper_name) in
  let row = Dated_jsonl.read_recent store 1 |> List.hd in
  Dated_jsonl.append store row;
  check int "outbox replay coalesces the same canonical receipt" 1 (List.length (receipts (project config ())));
  let replacement = enqueue config in
  check bool "reinsertion changes the exact incarnation" false
    (Int64.equal original.admitted_revision replacement.admitted_revision);
  start config 8 replacement;
  check int "same id and payload cannot inherit a prior incarnation ACK" 0
    (List.length (receipts (project config ~turn:8 ())));
  ignore (Persistence.reprioritize_pending_result ~base_path:config.base_path ~keeper_name
    ~selection:replacement ~urgency:Immediate () |> ok);
  let reprioritized = select config in
  start config 9 reprioritized;
  terminalize config reprioritized;
  check int "changed priority and revision cannot settle the earlier selection" 0
    (List.length (receipts (project config ~turn:8 ())));
  check string "the changed incarnation projects its own receipt" "ack_turn_completed"
    (receipts (project config ~turn:9 ()) |> List.hd |> member "kind" |> to_string);
  check (list string) "only public terminal reference fields are returned"
    ["applied_at";"event_id";"kind";"transition_id"]
    (receipts (project config ~turn:9 ()) |> List.hd |> to_assoc |> List.map fst |> List.sort String.compare);
  check int "later incarnations do not erase the original observed receipt" 1
    (List.length (receipts (project config ()))))

let partial_ledger_and_manifest () = with_source (fun config ->
  let selection = enqueue config in
  start config 7 selection;
  terminalize config selection;
  let store = Dated_jsonl.open_store (Ledger.location ~base_path:config.base_path ~keeper_name) in
  Dated_jsonl.append store (`Assoc []);
  let month = Dated_jsonl.month_dir_paths_newest_first_result store |> Result.get_ok |> List.hd in
  let ledger_path = Dated_jsonl.day_file_paths_newest_first_result month |> Result.get_ok |> List.hd in
  Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0o600 ledger_path
    (fun channel -> output_string channel "{not-json}\n");
  let partial = project config () in
  check string "damage is explicit" "partial" (partial |> member "coverage" |> member "state" |> to_string);
  check int "damage does not erase a validated exact receipt" 1 (List.length (receipts partial));
  check int "invalid current-row envelope counted" 1
    (partial |> member "coverage" |> member "invalid_ledger_rows" |> to_int);
  check int "invalid JSON counted independently" 1
    (partial |> member "coverage" |> member "invalid_json_rows" |> to_int);
  start config 7 selection;
  check string "repeated starts cannot assign a receipt to a guessed attempt"
    "ambiguous_turn_start" (project config () |> member "reason" |> to_string);
  let _, unscoped = Server_dashboard_http_keeper_api.keeper_runtime_trace_json config keeper_name ~trace_id () in
  check string "trace-only reads do not scan source outcomes" "exact_turn_required"
    (unscoped |> member "source_outcomes" |> member "reason" |> to_string))

let cancelled_source () = with_source (fun config ->
  let selection = enqueue config in
  start config 7 selection;
  Persistence.cancel_pending_accepted_result ~base_path:config.base_path ~keeper_name
    ~applied_at:(Unix.gettimeofday ())
    ~cancellation:{ source=selection.source; source_incarnation=selection.admitted_revision
                  ; operator_operation_id="cancel-operation"; reason="private cancellation reason" } ()
  |> ok |> project_transition config;
  check string "operator cancellation remains distinct from turn completion" "cancelled"
    (receipts (project config ()) |> List.hd |> member "kind" |> to_string))

let storage_and_manifest_gaps () = with_source (fun config ->
  let selection = enqueue config in
  start config 7 selection;
  let ledger_dir = Ledger.store_dir ~base_path:config.base_path ~keeper_name in
  Fs_compat.mkdir_p ledger_dir;
  Out_channel.with_open_bin (Filename.concat ledger_dir "unexpected-layout") (fun out ->
    output_string out "not a month directory");
  let unavailable = project config () in
  check string "storage damage is not an empty successful read" "unavailable"
    (unavailable |> member "coverage" |> member "state" |> to_string);
  check bool "storage failure remains explicit" true
    (unavailable |> member "coverage" |> member "storage_error" |> to_bool);
  let manifest_path = Manifest.path_for_trace config ~keeper_name ~trace_id in
  Out_channel.with_open_gen [Open_wronly;Open_append;Open_binary] 0o600 manifest_path
    (fun out -> output_string out "{not-json}\n");
  check string "damaged manifest cannot authorize a unique intake join" "incomplete_manifest"
    (project config () |> member "reason" |> to_string))

let () = run "keeper turn source outcomes"
  [ "exact source lifecycle",
      [ test_case "reinsertion and reprioritization retain exact selection fences" `Quick exact_source_incarnation
      ; test_case "partial reads preserve positives and repeated starts remain ambiguous" `Quick partial_ledger_and_manifest
      ; test_case "cancelled source is not a completed turn" `Quick cancelled_source
      ; test_case "storage and manifest gaps remain unavailable" `Quick storage_and_manifest_gaps
      ]
  ]
