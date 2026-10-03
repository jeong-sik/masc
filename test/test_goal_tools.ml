module Types = Masc_domain

(** Goal tool coverage — shared Goal Store surface through Tool_workspace. *)

open Alcotest
open Masc
open Workspace_types
open Tool_workspace

let temp_dir () =
  let path = Filename.temp_file "goal_tool_test" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rm_rf dir =
  let rec rm path =
    if Sys.file_exists path
    then
      if Sys.is_directory path
      then (
        Sys.readdir path |> Array.iter (fun entry -> rm (Filename.concat path entry));
        Unix.rmdir path)
      else Sys.remove path
  in
  try rm dir with
  | _ -> ()
;;

let with_workspace f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let dir = temp_dir () in
  let previous_delivery = Goal_delivery.For_testing.replace_backend
    (Some Server_bootstrap_loops.For_testing.goal_notification_backend) in
  Fun.protect
    ~finally:(fun () ->
      ignore (Goal_delivery.For_testing.replace_backend previous_delivery);
      rm_rf dir)
    (fun () ->
       let config = Workspace.default_config dir in
       ignore (Workspace.init config ~agent_name:(Some "planner"));
       f config)
;;

let workspace_ctx ?(agent_name = "planner") config : Tool_workspace.context =
  { Tool_workspace.config; agent_name }
;;

let parse_json_result (result : Tool_result.result) =
  if (Tool_result.is_success result)
  then Yojson.Safe.from_string ((Tool_result.message result))
  else Alcotest.fail ((Tool_result.message result))
;;

let get_string_field json field =
  match Yojson.Safe.Util.member field json with
  | `String value -> value
  | _ -> fail (field ^ " missing")
;;

;;

let expect_error (result : Tool_result.result option) =
  match result with
  | Some r when not (Tool_result.is_success r) -> Yojson.Safe.from_string ((Tool_result.message r))
  | Some r ->
    fail (Printf.sprintf "expected tool error, got success: %s" ((Tool_result.message r)))
  | None -> fail "tool not handled"
;;

(* {1 RFC-0444 PR-2: the typed Unavailable envelope}

   A store this build cannot read answers
   [{ok:false, error_code:"goal_store_unavailable", reason, field, file,
   mirror:{status, goal_count}, reset_step}] on every goal tool, with failure
   class [Dependency_unavailable], and never a [goals] member. *)

let confirmation_error_to_string =
  Server_routes_http_routes_verification.For_testing.confirmation_error_to_string
;;

let expect_unavailable (result : Tool_result.result option) =
  match result with
  | Some ((Tool_result.Failed { class_ = Tool_result.Dependency_unavailable; message; _ }) as failure) ->
    let data = Tool_result.data failure in
    check string "message is the serialized envelope" (Yojson.Safe.to_string data) message;
    data
  | Some (Tool_result.Failed { class_; message; _ }) ->
    fail (Printf.sprintf "expected Dependency_unavailable, got %s: %s"
            (Tool_result.tool_failure_class_to_string class_) message)
  | Some (Tool_result.Completed _ | Tool_result.Deferred _ as result) ->
    fail ("expected tool error, got success: " ^ Tool_result.message result)
  | None -> fail "tool not handled"
;;

let has_substring ~needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec at i = i + n <= h && (String.sub haystack i n = needle || at (i + 1)) in
  at 0
;;

let check_unavailable_envelope config ~reason ~field ~mirror_status ~mirror_goal_count
    ~reset_step (envelope : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  let json_string json = Yojson.Safe.to_string json in
  check string "ok" "false" (json_string (member "ok" envelope));
  check string "error_code" "goal_store_unavailable" (get_string_field envelope "error_code");
  check string "reason" reason (get_string_field envelope "reason");
  check string "field" (json_string field) (json_string (member "field" envelope));
  check string "file" (Goal_store.goals_path config) (get_string_field envelope "file");
  check string "mirror.status" mirror_status
    (get_string_field (member "mirror" envelope) "status");
  check string "mirror.goal_count" (json_string mirror_goal_count)
    (json_string (member "goal_count" (member "mirror" envelope)));
  check string "reset_step" reset_step (get_string_field envelope "reset_step");
  check string "no goals member" "null" (json_string (member "goals" envelope))
;;

let goal_files config =
  let path = Goal_store.goals_path config in
  Fs_compat.load_file path, Fs_compat.load_file (path ^ ".last-good")
;;

(* The #34459 shape: every row without [criterion_revision], in both the
   primary and its mirror. Written raw so no writer of the store plants it.
   Returns the id the rows carry. *)
let seed_rows_without_criterion_revision config =
  let goal, _ = match Goal_store.upsert_goal config ~title:"Goal before the hard cut"
      ~metric:"goals" ~target_value:"1" () with
    | Ok value -> value | Error error -> fail (Goal_store.write_error_to_string error) in
  let row = match Goal_store.goal_to_yojson goal with
    | `Assoc fields -> `Assoc (List.remove_assoc "criterion_revision" fields)
    | _ -> fail "goal serializer returned non-object" in
  let bytes = Yojson.Safe.to_string
      (`Assoc [ "version", `Int 1; "updated_at", `String goal.updated_at; "goals", `List [ row ] ]) in
  let path = Goal_store.goals_path config in
  Fs_compat.save_file path bytes;
  Fs_compat.save_file (path ^ ".last-good") bytes;
  goal.id
;;

let test_goal_list_preserves_source_failure () =
  with_workspace @@ fun config ->
  let list () = Tool_workspace.dispatch (workspace_ctx config)
    ~name:"masc_goal_list" ~args:(`Assoc []) in
  let _goal, _ = match Goal_store.upsert_goal config ~title:"Visible source"
      ~metric:"goals" ~target_value:"1" () with
    | Ok value -> value | Error error -> fail (Goal_store.write_error_to_string error)
  in
  let path = Goal_store.goals_path config in
  let mirror = Fs_compat.load_file (path ^ ".last-good") in
  Fs_compat.save_file path "unreadable primary";
  (* The mirror still decodes one goal: reported as evidence, never served. *)
  check_unavailable_envelope config ~reason:"not_json" ~field:`Null
    ~mirror_status:"mirror_decodes" ~mirror_goal_count:(`Int 1)
    ~reset_step:"reset_goal_store" (expect_unavailable (list ()));
  check string "listing preserves the primary bytes" "unreadable primary"
    (Fs_compat.load_file path);
  check string "listing preserves recovery bytes" mirror
    (Fs_compat.load_file (path ^ ".last-good"))
;;

(* RFC-0444 criterion 1. *)
let test_goal_list_schema_rejected_envelope () =
  with_workspace @@ fun config ->
  ignore (seed_rows_without_criterion_revision config);
  let before = goal_files config in
  let listed = Tool_workspace.dispatch (workspace_ctx config)
      ~name:"masc_goal_list" ~args:(`Assoc []) in
  check_unavailable_envelope config ~reason:"schema_rejected"
    ~field:(`String "criterion_revision") ~mirror_status:"mirror_rejected"
    ~mirror_goal_count:`Null ~reset_step:"repair_field" (expect_unavailable listed);
  (match listed with
   | Some result ->
     let message = Tool_result.message result in
     check bool "no response carries goals:[]" false
       (has_substring ~needle:"\"goals\":[]" message)
   | None -> fail "masc_goal_list not handled");
  check bool "listing moves no bytes" true (before = goal_files config)
;;

(* RFC-0444 criterion 4, first half: a store this build cannot read is the
   Unavailable code, never "goal not found". *)
let test_goal_transition_unavailable_store () =
  with_workspace @@ fun config ->
  let goal_id = seed_rows_without_criterion_revision config in
  let before = goal_files config in
  let result = Tool_workspace.dispatch (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:(`Assoc [ "goal_id", `String goal_id; "action", `String "drop" ]) in
  check_unavailable_envelope config ~reason:"schema_rejected"
    ~field:(`String "criterion_revision") ~mirror_status:"mirror_rejected"
    ~mirror_goal_count:`Null ~reset_step:"repair_field" (expect_unavailable result);
  check bool "refused transition moves no bytes" true (before = goal_files config)
;;

(* RFC-0444 criterion 4, second half: a healthy store with no such id is
   [not_found]. *)
let test_goal_transition_unknown_goal_not_found () =
  with_workspace @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Present goal" ~metric:"goals"
           ~target_value:"1" () with
   | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error));
  let error = expect_error (Tool_workspace.dispatch (workspace_ctx config)
      ~name:"masc_goal_transition"
      ~args:(`Assoc [ "goal_id", `String "goal-does-not-exist"; "action", `String "drop" ])) in
  check string "unknown id on a readable store" "not_found" (get_string_field error "error_code");
  check string "no envelope fields on not_found" "null"
    (Yojson.Safe.to_string (Yojson.Safe.Util.member "reason" error))
;;

let test_goal_upsert_unavailable_store () =
  with_workspace @@ fun config ->
  ignore (seed_rows_without_criterion_revision config);
  let before = goal_files config in
  let result = Tool_workspace.dispatch (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc [ "title", `String "New goal on a broken store"
                    ; "metric", `String "goals"; "target_value", `String "1" ]) in
  check_unavailable_envelope config ~reason:"schema_rejected"
    ~field:(`String "criterion_revision") ~mirror_status:"mirror_rejected"
    ~mirror_goal_count:`Null ~reset_step:"repair_field" (expect_unavailable result);
  check bool "refused upsert moves no bytes" true (before = goal_files config)
;;

let test_goal_upsert_and_list () =
  with_workspace
  @@ fun config ->
  let created =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:
        (`Assoc
            [ "title", `String "Ship Goal Surface"
            ; "metric", `String "deploys shipped"
            ; "target_value", `String "1"
            ; "priority", `Int 2
            ])
  in
  let created_json =
    match created with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_upsert not handled"
  in
  let goal_id =
    match Yojson.Safe.Util.member "goal_id" created_json with
    | `String id when id <> "" -> id
    | _ -> fail "goal_id missing from upsert response"
  in
  check bool "goal_id populated" true (String.length goal_id > 0);
  let task_link_field =
    match Yojson.Safe.Util.member "task_link_field" created_json with
    | `String field -> field
    | _ -> fail "task_link_field missing from upsert response"
  in
  check string "structured link field" "goal_id" task_link_field;
  check string "structured link mode" "structured_goal_id"
    (Yojson.Safe.Util.member "task_link_mode" created_json
     |> Yojson.Safe.Util.to_string);
  check bool "title marker omitted" true
    (Yojson.Safe.Util.member "task_title_marker" created_json = `Null);
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  let count =
    match Yojson.Safe.Util.member "count" listed_json with
    | `Int n -> n
    | _ -> fail "count missing from goal list response"
  in
  check int "one listed goal" 1 count;
  let goals = Yojson.Safe.Util.member "goals" listed_json |> Yojson.Safe.Util.to_list in
  match goals with
  | [ goal_json ] -> check string "listed goal id" goal_id (get_string_field goal_json "id")
  | _ -> fail "expected one listed goal"
;;

(* A goal in [phase], for fixtures. upsert_goal only creates Executing goals;
   the phase is then moved with the store's compare-and-update, the same
   primitive the lifecycle handlers write through. *)
let upsert_goal_in_phase config ~title phase =
  match Goal_store.upsert_goal config ~title ~metric:"m" ~target_value:"1" () with
  | Error error -> Error error
  | Ok (goal, _) when goal.Goal_store.phase = phase -> Ok goal
  | Ok (goal, _) ->
    (match
       Goal_store.update_goal_if_phase config ~goal_id:goal.Goal_store.id
         ~expected_phase:goal.Goal_store.phase
         (fun current -> { current with Goal_store.phase })
     with
     | Ok (Goal_store.Goal_updated goal) -> Ok goal
     | Ok (Goal_store.Goal_phase_mismatch actual) ->
       failwith ("fixture goal moved to " ^ Goal_phase.to_string actual)
     | Error error -> Error error)
;;

let test_goal_list_filters_by_phase () =
  with_workspace
  @@ fun config ->
  let create ~title ~phase =
    let phase =
      match Goal_phase.parse phase with
      | Some phase -> phase
      | None -> fail ("invalid phase fixture: " ^ phase)
    in
    match upsert_goal_in_phase config ~title phase with
    | Ok _ -> ()
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  create ~title:"Executing goal" ~phase:"executing";
  create ~title:"Dropped goal" ~phase:"dropped";
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [ "phase", `String "dropped" ])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  let goals = Yojson.Safe.Util.member "goals" listed_json |> Yojson.Safe.Util.to_list in
  check int "one listed goal by phase" 1 (List.length goals);
  match goals with
  | [ goal_json ] ->
    check string "phase filter honored" "dropped" (get_string_field goal_json "phase")
  | _ -> fail "expected one filtered goal"
;;

let test_goal_list_includes_rollup () =
  with_workspace
  @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Executing goal" ~metric:"m"
           ~target_value:"1" () with
   | Ok _ -> ()
   | Error error -> fail (Goal_store.write_error_to_string error));
  (match upsert_goal_in_phase config ~title:"Verifying goal" Goal_phase.Verifying with
   | Ok _ -> ()
   | Error error -> fail (Goal_store.write_error_to_string error));
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  let rollup = Yojson.Safe.Util.member "rollup" listed_json in
  check int "active goal is counted" 1
    (Yojson.Safe.Util.member "active_count" rollup |> Yojson.Safe.Util.to_int);
  check int "verifying goal is counted" 1
    (Yojson.Safe.Util.member "verifying_count" rollup |> Yojson.Safe.Util.to_int)
;;
let test_goal_list_ignores_blank_optional_filters () =
  with_workspace
  @@ fun config ->
  (match Goal_store.upsert_goal config ~title:"Blank filter goal" ~metric:"m"
           ~target_value:"1" () with
   | Ok _ -> ()
   | Error error -> fail (Goal_store.write_error_to_string error));
  let listed =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [ "phase", `String "" ])
  in
  let listed_json =
    match listed with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_list not handled"
  in
  check
    int
    "blank filters are ignored"
    1
    (Yojson.Safe.Util.member "count" listed_json |> Yojson.Safe.Util.to_int)
;;

let test_goal_list_rejects_status_filter () =
  with_workspace
  @@ fun config ->
  let rejected =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_list"
      ~args:(`Assoc [ "status", `String "active" ])
  in
  let error_json = expect_error rejected in
  check
    string
    "status filter blocked"
    "validation_error"
    (get_string_field error_json "error_code");
  check
    bool
    "error points to removed status"
    true
    (String_util.contains_substring (Yojson.Safe.to_string error_json) "status filter was removed");
  let field_errors =
    Yojson.Safe.Util.member "field_errors" error_json |> Yojson.Safe.Util.to_list
  in
  match field_errors with
  | field_error :: _ ->
    check string "field" "status" (get_string_field field_error "field")
  | [] -> fail "expected status field error"
;;

let test_goal_creation_emits_an_event () =
  with_workspace
  @@ fun config ->
  let events_path =
    Filename.concat
      (Filename.dirname (Goal_store.goals_path config))
      "goal_events.jsonl"
  in
  let events () =
    if Sys.file_exists events_path
    then
      Fs_compat.load_file events_path
      |> String.split_on_char '\n'
      |> List.filter (fun line -> String.trim line <> "")
    else []
  in
  check int "no goal has been opened yet" 0 (List.length (events ()));
  let upsert ?(agent_name = "planner") args =
    Tool_workspace.dispatch
      (workspace_ctx ~agent_name config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc args)
  in
  let created =
    match
      upsert
        [ "title", `String "Close the goal ledger"
        ; "metric", `String "goals counted"
        ; "target_value", `String "1"
        ]
    with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_upsert not handled"
  in
  let goal_id = get_string_field created "goal_id" in
  let lines = events () in
  check int "opening a goal records one event" 1 (List.length lines);
  let event = Yojson.Safe.from_string (List.hd lines) in
  check string "the event names creation" "goal_created"
    (get_string_field event "event_type");
  check string "the event names its goal" goal_id (get_string_field event "goal_id");
  (* The title has to outlive the goal's row in goals.json, which holds only the
     current set, so it travels in the payload rather than only in the store. *)
  check string "the payload carries the title as created" "Close the goal ledger"
    (get_string_field (Yojson.Safe.Util.member "payload" event) "title");
  check string "creation records who acted" "planner"
    (get_string_field (Yojson.Safe.Util.member "payload" event) "actor");
  let created_version = Yojson.Safe.Util.(event |> member "payload" |> member "store_version" |> to_int) in
  let committed_version () = match Goal_store.load_source config with
    | Goal_store.Available state -> state.version
    | Goal_store.Uninitialized | Goal_store.Unavailable _ -> fail "upsert must commit a readable Goal state" in
  check int "creation snapshot precedes its outbox acknowledgement"
    (created_version + 1) (committed_version ());
  (match upsert ~agent_name:"editor"
       [ "id", `String goal_id; "title", `String "Renamed after the fact" ] with
   | Some result -> ignore (parse_json_result result)
   | None -> fail "masc_goal_upsert not handled on update");
  let history = List.map Yojson.Safe.from_string (events ()) in
  let of_kind kind = List.filter (fun event -> get_string_field event "event_type" = kind) history in
  (match of_kind "goal_created" with
   | [ created_event ] ->
     check string "editing preserves the one original creation event"
       (Yojson.Safe.to_string event) (Yojson.Safe.to_string created_event)
   | _ -> fail "a Goal must have exactly one creation event after editing");
  (match of_kind "goal_updated" with
   | [ updated_event ] ->
     check string "the update names the same Goal" goal_id (get_string_field updated_event "goal_id");
     let payload = Yojson.Safe.Util.member "payload" updated_event in
     check string "the update keeps its own actor" "editor" (get_string_field payload "actor");
     check string "the update keeps the title as edited" "Renamed after the fact"
       (get_string_field payload "title");
     let version = Yojson.Safe.Util.(payload |> member "store_version" |> to_int) in
     check int "updated snapshot precedes its own outbox acknowledgement"
       (version + 1) (committed_version ());
     check bool "update revision orders the snapshots independently of append" true (version > created_version)
   | _ -> fail "the edit must record exactly one separate update event")
;;

let block_goal_event_path config =
  let path = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl" in
  let before = Fs_compat.load_file path in
  let saved = path ^ ".before-failure" in
  Fs_compat.invalidate_cached_writer path;
  Unix.rename path saved;
  Unix.mkdir path 0o700;
  path, saved, before
;;

let event_recordings receipt =
  Yojson.Safe.Util.(receipt |> member "event_recordings" |> to_list)
;;

let check_event_recordings label expected receipt =
  let actual = event_recordings receipt
    |> List.map (fun row -> get_string_field row "event_type", get_string_field row "status") in
  check (list (pair string string)) label expected actual
;;

let test_goal_creation_survives_event_recording_failure () =
  with_workspace @@ fun config ->
  let call_goal_tool config name args =
    match Tool_workspace.dispatch (workspace_ctx config) ~name ~args:(`Assoc args) with
    | Some result -> parse_json_result result
    | None -> fail (name ^ " not handled") in
  let path = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl" in
  Unix.mkdir path 0o700;
  let created = call_goal_tool config "masc_goal_upsert"
      [ "title", `String "Committed shared Goal"; "metric", `String "artifacts"
      ; "target_value", `String "1" ] in
  check_event_recordings "the missing creation is explicit"
    [ "goal_created", "failed" ] created;
  let recording = List.hd (event_recordings created) in
  check bool "the append error is retained" true
    (String.length (get_string_field recording "error") > 0);
  let goal_id = get_string_field created "goal_id" in
  let payload = Yojson.Safe.Util.member "payload" recording in
  check string "the failed creation retains its Goal id" goal_id (get_string_field payload "id");
  check string "the failed creation retains its actor" "planner" (get_string_field payload "actor");
  let listed = call_goal_tool config "masc_goal_list" []
      |> Yojson.Safe.Util.member "goals" |> Yojson.Safe.Util.to_list in
  (match listed with
   | [ goal ] ->
     check string "the Goal committed despite append failure" goal_id (get_string_field goal "id");
     check bool "the stored Goal has no owner" false
       (Yojson.Safe.Util.member "owner" goal <> `Null)
   | _ -> fail "one committed Goal must remain readable");
  check bool "the failed append did not overwrite its directory" true (Sys.is_directory path)
;;

let test_metadata_edit_survives_event_recording_failure () =
  List.iter (fun phase ->
    with_workspace @@ fun config ->
    let call name args =
      match Tool_workspace.dispatch (workspace_ctx config) ~name ~args:(`Assoc args) with
      | Some result -> parse_json_result result
      | None -> fail (name ^ " not handled") in
    let created = call "masc_goal_upsert"
        [ "title", `String "Overdue shared Goal"; "metric", `String "artifacts"
        ; "target_value", `String "1"; "due_date", `String "2000-01-01" ] in
    check_event_recordings "creation reports its actual append"
      [ "goal_created", "recorded" ] created;
    let goal_id = get_string_field created "goal_id" in
    (match phase with
     | `Executing -> ()
     | `Dropped -> ignore (call "masc_goal_transition"
         [ "goal_id", `String goal_id; "action", `String "drop" ]));
    let expected_phase = match phase with `Executing -> "executing" | `Dropped -> "dropped" in
    let path, saved, before = block_goal_event_path config in
    let updated = call "masc_goal_upsert"
        [ "id", `String goal_id; "due_date", `String "2099-01-01"; "priority", `Int 1 ] in
    let goal = Yojson.Safe.Util.member "goal" updated in
    check string "metadata edit keeps the Goal phase" expected_phase (get_string_field goal "phase");
    check_event_recordings "failed projection is explicit after the committed edit"
      [ "goal_updated", "failed"; "goal_edited", "failed" ] updated;
    let recording = List.hd (event_recordings updated) in
    check bool "the receipt retains the append error" true
      (String.length (get_string_field recording "error") > 0);
    let payload = Yojson.Safe.Util.member "payload" recording in
    check string "the missing row retains the caller" "planner" (get_string_field payload "actor");
    check string "the missing row retains the committed due date" "2099-01-01"
      (get_string_field payload "due_date");
    let edit_recording = List.nth (event_recordings updated) 1 in
    check bool "the exact edit retains its own append error" true
      (String.length (get_string_field edit_recording "error") > 0);
    let edit_payload = Yojson.Safe.Util.member "payload" edit_recording in
    let json = testable Yojson.Safe.pp Yojson.Safe.equal in
    check json "the failed edit retains only its actor and exact stored changes"
      (`Assoc
        [ "actor", `String "planner"
        ; "due_date", `Assoc [ "from", `String "2000-01-01"; "to", `String "2099-01-01" ]
        ; "priority", `Assoc [ "from", `Int 3; "to", `Int 1 ] ])
      edit_payload;
    let listed = call "masc_goal_list" [] |> Yojson.Safe.Util.member "goals" |> Yojson.Safe.Util.to_list in
    (match listed with
     | [ stored ] ->
       check string "the successful edit is readable" "2099-01-01" (get_string_field stored "due_date");
       check int "priority was committed" 1 Yojson.Safe.Util.(stored |> member "priority" |> to_int);
       check string "the stored phase is unchanged" expected_phase (get_string_field stored "phase")
     | _ -> fail "the shared Goal must remain readable");
    check bool "the failure fixture is still a directory" true (Sys.is_directory path);
    check string "no append leaked into the displaced history" before (Fs_compat.load_file saved))
    [ `Executing; `Dropped ]
;;

let test_criterion_edit_reports_each_failed_event () =
  with_workspace @@ fun config ->
  let call name args =
    match Tool_workspace.dispatch (workspace_ctx config) ~name ~args:(`Assoc args) with
    | Some result -> parse_json_result result
    | None -> fail (name ^ " not handled") in
  let created = call "masc_goal_upsert"
      [ "title", `String "Revise a pending criterion"; "metric", `String "artifacts"
      ; "target_value", `String "1" ] in
  let goal_id = get_string_field created "goal_id" in
  ignore (call "masc_goal_transition"
    [ "goal_id", `String goal_id; "action", `String "request_complete" ]);
  let path, saved, before = block_goal_event_path config in
  let updated = call "masc_goal_upsert"
      [ "id", `String goal_id; "target_value", `String "2"; "due_date", `String "2099-01-01" ] in
  check_event_recordings "each missing row is reported after the criterion changed"
    [ "goal_updated", "failed"; "goal_phase", "failed"; "goal_edited", "failed" ] updated;
  List.iter (fun row ->
    check bool "every failed append retains its error" true
      (String.length (get_string_field row "error") > 0)) (event_recordings updated);
  let phase_payload = List.nth (event_recordings updated) 1 |> Yojson.Safe.Util.member "payload" in
  check string "the missing phase event remembers the old phase" "verifying"
    (get_string_field phase_payload "previous_phase");
  check string "the missing phase event remembers the committed phase" "executing"
    (get_string_field phase_payload "phase");
  check string "the missing phase event keeps its cause" "criterion_edit"
    (get_string_field phase_payload "cause");
  let edit_payload = List.nth (event_recordings updated) 2 |> Yojson.Safe.Util.member "payload" in
  check (testable Yojson.Safe.pp Yojson.Safe.equal)
    "one combined edit retains the exact due-date change alongside the phase"
    (`Assoc [ "actor", `String "planner"
            ; "due_date", `Assoc [ "from", `Null; "to", `String "2099-01-01" ] ])
    edit_payload;
  let primary, mirror = goal_files config in
  List.iter (fun bytes ->
    match Yojson.Safe.Util.(Yojson.Safe.from_string bytes |> member "goals" |> to_list) with
    | [ goal ] ->
      check string "the criterion was committed" "2" (get_string_field goal "target_value");
      check string "the due date was committed" "2099-01-01" (get_string_field goal "due_date");
      check string "the phase was committed" "executing" (get_string_field goal "phase")
    | _ -> fail "both stores must retain the Goal") [ primary; mirror ];
  check string "failed appends preserved prior history" before (Fs_compat.load_file saved);
  Unix.rmdir path;
  Unix.rename saved path;
  let repeated = call "masc_goal_upsert" [ "id", `String goal_id; "target_value", `String "2" ] in
  check_event_recordings "the later receipt describes its own snapshot while replaying older intents"
    [ "goal_updated", "recorded" ] repeated;
  let replayed = Fs_compat.load_file path |> String.split_on_char '\n'
    |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string in
  check bool "recovery replays the previously failed criterion phase" true
    (List.exists (fun row ->
       get_string_field row "event_type" = "goal_phase"
       && Json_util.get_string (Yojson.Safe.Util.member "payload" row) "cause"
            = Some "criterion_edit") replayed)
;;

(* A due date or priority edit moves no phase, so it records a row of its own
   with the value it replaced (#39878). Only the fields that changed are in it. *)
let test_goal_due_date_and_priority_edits_are_recorded () =
  with_workspace
  @@ fun config ->
  let events_path =
    Filename.concat
      (Filename.dirname (Goal_store.goals_path config))
      "goal_events.jsonl"
  in
  let edits () =
    if Sys.file_exists events_path
    then
      Fs_compat.load_file events_path
      |> String.split_on_char '\n'
      |> List.filter (fun line -> String.trim line <> "")
      |> List.map Yojson.Safe.from_string
      |> List.filter (fun event ->
        String.equal (get_string_field event "event_type") "goal_edited")
    else []
  in
  let upsert ?(agent_name = "planner") args =
    match
      Tool_workspace.dispatch
        (workspace_ctx ~agent_name config)
        ~name:"masc_goal_upsert"
        ~args:(`Assoc args)
    with
    | Some result -> parse_json_result result
    | None -> fail "masc_goal_upsert not handled"
  in
  let created =
    upsert
      [ "title", `String "Dated later"
      ; "metric", `String "goals counted"
      ; "target_value", `String "1"
      ]
  in
  let goal_id = get_string_field created "goal_id" in
  let edit_of = function
    | [ event ] -> Yojson.Safe.Util.member "payload" event
    | events -> fail (Printf.sprintf "expected one new edit, got %d" (List.length events))
  in
  let newest_edit ~already =
    edit_of (List.filteri (fun index _ -> index >= already) (edits ()))
  in
  let change payload field =
    let change = Yojson.Safe.Util.member field payload in
    Yojson.Safe.Util.member "from" change, Yojson.Safe.Util.member "to" change
  in
  let json = testable Yojson.Safe.pp Yojson.Safe.equal in
  let json_pair = pair json json in
  check_event_recordings "creation only records its snapshot"
    [ "goal_created", "recorded" ] created;
  check int "creating a goal records no edit" 0 (List.length (edits ()));
  (* A due date that was not set comes from null. *)
  let first_receipt = upsert [ "id", `String goal_id; "due_date", `String "2026-10-15" ] in
  check_event_recordings "a due-date edit records the snapshot and one exact change"
    [ "goal_updated", "recorded"; "goal_edited", "recorded" ] first_receipt;
  let first = newest_edit ~already:0 in
  check json_pair "due date set" (`Null, `String "2026-10-15") (change first "due_date");
  check json "the priority did not change" `Null (Yojson.Safe.Util.member "priority" first);
  check string "the editor is named" "planner" (get_string_field first "actor");
  ignore (upsert ~agent_name:"reviewer" [ "id", `String goal_id; "priority", `Int 1 ]);
  let second = newest_edit ~already:1 in
  check json_pair "priority moved" (`Int 3, `Int 1) (change second "priority");
  check json "the due date did not change" `Null (Yojson.Safe.Util.member "due_date" second);
  check string "each exact edit names its own caller" "reviewer" (get_string_field second "actor");
  ignore
    (upsert [ "id", `String goal_id; "due_date", `String "2026-11-01"; "priority", `Int 5 ]);
  let third = newest_edit ~already:2 in
  check json_pair "due date moved" (`String "2026-10-15", `String "2026-11-01") (change third "due_date");
  check json_pair "priority moved again" (`Int 1, `Int 5) (change third "priority");
  (* The dashboard reads what the handler wrote. Each side of this contract is
     also pinned by hand-written rows in test_goal_timeline_projection, and a
     renamed key would keep both green without this. *)
  let projected = Dashboard_goals_types.goal_event_timeline_json (List.nth (edits ()) 2) in
  check
    string
    "the timeline reads the row the handler wrote"
    "due_date 2026-10-15 -> 2026-11-01, priority 1 -> 5 by planner"
    (get_string_field projected "summary");
  check string "and does not flag it" "ok" (get_string_field projected "severity");
  (* The same values again, and an edit to something else, record snapshots
     but no further exact due-date/priority edit. *)
  let repeated =
    upsert [ "id", `String goal_id; "due_date", `String "2026-11-01"; "priority", `Int 5 ] in
  check_event_recordings "repeated metadata records no invented exact edit"
    [ "goal_updated", "recorded" ] repeated;
  ignore (upsert [ "id", `String goal_id; "title", `String "Renamed" ]);
  check int "an edit that changes neither field records nothing" 3 (List.length (edits ()))
;;

(* The edit is stored before its row is appended. A row that cannot be appended
   (here the events path is a directory) must not turn a stored edit into a
   failure: the caller would retry, see no difference, and record nothing. *)
let test_a_goal_edit_whose_row_cannot_be_appended_still_succeeds () =
  with_workspace
  @@ fun config ->
  (* Made without the tool, so nothing has opened the events file yet and no
     cached handle can hide the failure. *)
  let goal, _ =
    match
      Goal_store.upsert_goal
        config
        ~title:"Dated later"
        ~metric:"goals counted"
        ~target_value:"1"
        ()
    with
    | Ok created -> created
    | Error error -> failf "%s" (Goal_store.write_error_to_string error)
  in
  let events_path =
    Filename.concat
      (Filename.dirname (Goal_store.goals_path config))
      "goal_events.jsonl"
  in
  Unix.mkdir events_path 0o755;
  match
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc [ "id", `String goal.id; "due_date", `String "2026-10-15" ])
  with
  | None -> fail "masc_goal_upsert not handled"
  | Some result ->
    let json = parse_json_result result in
    check_event_recordings "both failed appends are visible after the stored edit"
      [ "goal_updated", "failed"; "goal_edited", "failed" ] json;
    check string "the edit is reported as stored" goal.id (get_string_field json "goal_id");
    check
      string
      "with the new due date"
      "2026-10-15"
      (get_string_field (Yojson.Safe.Util.member "goal" json) "due_date")
;;

let test_goal_upsert_rejects_lifecycle_fields () =
  with_workspace
  @@ fun config ->
  let rejected_phase =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc [ "title", `String "Bypass block"; "phase", `String "blocked" ])
  in
  let phase_error = expect_error rejected_phase in
  check
    string
    "phase blocked"
    "validation_error"
    (get_string_field phase_error "error_code");
  check
    bool
    "phase error points at transition"
    true
    (String_util.contains_substring (Yojson.Safe.to_string phase_error) "masc_goal_transition");
  let goal, _kind =
    match Goal_store.upsert_goal config ~title:"Existing goal" ~metric:"m"
            ~target_value:"1" () with
    | Ok payload -> payload
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  let rejected_status =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_upsert"
      ~args:(`Assoc [ "id", `String goal.id; "status", `String "dropped" ])
  in
  let status_error = expect_error rejected_status in
  check
    string
    "terminal status blocked"
    "validation_error"
    (get_string_field status_error "error_code");
  let saved_goal =
    match Goal_store.find_goal config ~goal_id:goal.id with
    | Goal_store.Goal_found goal -> goal
    | Goal_store.Goal_absent -> fail "goal missing after rejected upsert"
    | Goal_store.Store_unavailable u -> fail (Goal_store.unavailable_to_string u)
  in
  check
    string
    "phase unchanged after rejected status"
    "executing"
    (Goal_phase.to_string saved_goal.phase)
;;

let test_goal_review_removed_from_dispatch () =
  with_workspace
  @@ fun config ->
  let result =
    Tool_workspace.dispatch
      (workspace_ctx config)
      ~name:"masc_goal_review"
      ~args:(`Assoc [ "goal_id", `String "goal-legacy"; "outcome", `String "done" ])
  in
  check bool "masc_goal_review removed" true (Option.is_none result)
;;

let transition_phase result =
  match result with
  | Some result ->
    parse_json_result result
    |> Yojson.Safe.Util.member "goal"
    |> fun json -> get_string_field json "phase"
  | None -> fail "masc_goal_transition not handled"
;;

let request_complete config goal_id =
  Tool_workspace.dispatch
    (workspace_ctx config)
    ~name:"masc_goal_transition"
    ~args:
      (`Assoc
         [ "goal_id", `String goal_id
         ; "action", `String "request_complete"
         ])
;;

(* RFC-0387 stage 2: [request_complete] enters [Verifying]; [Completed] is
   reached only through the verifier's proof. *)
let prove_complete config goal_id =
  let request_id, criterion =
    match Goal_verification.get_record_authoritative config ~goal_id with
    | Ok (Some { Goal_verification.completion = Goal_verification.Proof_pending pending; _ }) ->
      pending.request_id, pending.criterion
    | _ -> fail "proof requires a durable pending request"
  in
  Some
    (Workspace_goals.commit_verifier_decision
       ~tool_name:"goal_verifier_commit"
       ~start_time:(Tool_timing.start ())
       config
       ~goal_id
       ~request_id
       ~criterion
       ~verification_run_id:"goal-verifier-test-run"
       ~decision:Workspace_goals.Proof_proven
       ~evidence:"observed by the test verifier")
;;

(* A Goal belongs to the workspace. Different callers can work on the same
   criterion; their actions and the verifier's verdict keep their provenance. *)
let test_callers_share_a_goal_without_private_delivery () =
  with_workspace @@ fun config ->
  let open Yojson.Safe.Util in
  let creator = workspace_ctx config in
  let collaborator = workspace_ctx ~agent_name:"reviewer" config in
  (* A real Keeper created it: lack of a receiving Keeper must not be what
     prevents a private notice after the refuted proof. *)
  let meta = match Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String creator.agent_name ]) with
    | Ok meta -> meta | Error detail -> fail detail in
  (match Keeper_fs.save_json_atomic
      (Keeper_types_profile.keeper_meta_path config creator.agent_name)
      (Keeper_meta_json.meta_to_json meta) with
   | Ok () -> () | Error detail -> fail detail);
  let call ctx name args =
    match Tool_workspace.dispatch ctx ~name ~args:(`Assoc args) with
    | Some result -> parse_json_result result
    | None -> fail (name ^ " not handled") in
  let shared_row label row =
    let fields = to_assoc row in
    List.iter (fun field ->
      check bool (label ^ ": no " ^ field) false (List.mem_assoc field fields))
      [ "owner"; "notified_refuted_key"; "notified_overdue_key" ];
    row in
  let listed ctx =
    match member "goals" (call ctx "masc_goal_list" []) |> to_list with
    | [ row ] -> shared_row "listed Goal" row
    | _ -> fail "the workspace must contain one shared Goal" in
  let incomplete = expect_error (Tool_workspace.dispatch creator
      ~name:"masc_goal_upsert" ~args:(`Assoc [ "title", `String "Missing criterion" ])) in
  check string "shared creation still requires a measurable criterion" "validation_error"
    (get_string_field incomplete "error_code");
  let created = call creator "masc_goal_upsert"
      [ "title", `String "Ship together"; "metric", `String "verified artifacts"
      ; "target_value", `String "1"; "due_date", `String "2000-01-01" ] in
  let goal_id = get_string_field created "goal_id" in
  let initial = shared_row "created Goal" (member "goal" created) in
  check string "a new shared Goal is executing" "executing"
    (get_string_field initial "phase");
  check string "another caller sees the same Goal" goal_id
    (get_string_field (listed collaborator) "id");
  let rejected = expect_error (Tool_workspace.dispatch collaborator
      ~name:"masc_goal_upsert" ~args:(`Assoc
        [ "id", `String goal_id; "phase", `String "completed" ])) in
  check string "sharing cannot bypass the lifecycle" "validation_error"
    (get_string_field rejected "error_code");
  let edited = call collaborator "masc_goal_upsert"
      [ "id", `String goal_id; "title", `String "Ship verified artifacts together"
      ; "metric", `String "independently verified artifacts"; "target_value", `String "2" ]
    |> member "goal" |> shared_row "edited Goal" in
  check string "another caller edits the same Goal" goal_id (get_string_field edited "id");
  check string "metadata edit preserves execution" "executing" (get_string_field edited "phase");
  check bool "the new criterion has its own revision" true
    (get_string_field initial "criterion_revision" <> get_string_field edited "criterion_revision");
  let visible = listed creator in
  List.iter (fun field -> check string ("creator sees shared " ^ field)
      (get_string_field edited field) (get_string_field visible field))
    [ "title"; "metric"; "target_value"; "due_date" ];
  let requested = call collaborator "masc_goal_transition"
      [ "goal_id", `String goal_id; "action", `String "request_complete" ] in
  check string "another caller requests verification" "verifying"
    (get_string_field (shared_row "verification request" (member "goal" requested)) "phase");
  let request_id, criterion =
    match Goal_verification.get_record_authoritative config ~goal_id with
    | Ok (Some { completion = Goal_verification.Proof_pending pending; _ }) ->
      pending.request_id, pending.criterion
    | _ -> fail "verification must retain its exact pending criterion" in
  let evidence = "Only one of the two required artifacts was verified" in
  let refuted = Workspace_goals.commit_verifier_decision
      ~tool_name:"goal_verifier_commit" ~start_time:(Tool_timing.start ()) config
      ~goal_id ~request_id ~criterion ~verification_run_id:"shared-goal-proof"
      ~decision:(Workspace_goals.Proof_refuted { reason = "target not reached" }) ~evidence
    |> parse_json_result in
  check string "refutation returns the shared Goal to execution" "executing"
    (get_string_field (shared_row "refuted Goal" (member "goal" refuted)) "phase");
  let completion = listed creator |> member "verification" |> member "completion" in
  check string "refutation stays visible in the public list" "proof_refuted"
    (get_string_field completion "state");
  let verdict = member "verdict" completion in
  check string "the verifier's evidence is retained" evidence (get_string_field verdict "evidence");
  check string "verifier identity is independent of either caller" "verifier_exact"
    (get_string_field (member "authority" verdict) "actor");
  check string "proof authority stays in the verifier lane" "system_llm_agent"
    (get_string_field (member "authority" verdict) "kind");
  let history = Fs_compat.load_file
      (Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl")
    |> String.split_on_char '\n' |> List.filter (fun line -> line <> "")
    |> List.map Yojson.Safe.from_string in
  let event_payload kind =
    match List.filter (fun event -> get_string_field event "event_type" = kind) history with
    | [ event ] ->
      check string (kind ^ " names the shared Goal") goal_id (get_string_field event "goal_id");
      shared_row kind (member "payload" event)
    | _ -> fail ("expected exactly one " ^ kind ^ " event") in
  let creation_payload = event_payload "goal_created" in
  check string "creation credits the caller without assigning ownership" "planner"
    (get_string_field creation_payload "actor");
  let update_payload = event_payload "goal_updated" in
  check string "the shared edit credits its caller" "reviewer"
    (get_string_field update_payload "actor");
  List.iter (fun field -> check string ("update event retains edited " ^ field)
      (get_string_field edited field) (get_string_field update_payload field))
    [ "title"; "metric"; "target_value"; "criterion_revision" ];
  let phases = history
    |> List.filter (fun event -> get_string_field event "event_type" = "goal_phase")
    |> List.map (fun event -> let payload = member "payload" event in
        get_string_field payload "phase", get_string_field payload "actor") in
  check (list (pair string string)) "phase events retain each acting identity"
    [ "verifying", "reviewer"; "executing", "verifier_exact" ] phases;
  let announcements = Workspace.get_all_messages_raw config ~since_seq:0
    |> List.filter (fun (message : Masc_domain.message) ->
        has_substring ~needle:"[goal_verdict]" message.content
        && has_substring ~needle:goal_id message.content) in
  (match announcements with
   | [ message ] ->
     check string "the verifier announces to the workspace" "verifier_exact" message.from_agent;
     check bool "the shared announcement carries the evidence" true
       (has_substring ~needle:evidence message.content)
   | _ -> fail "the workspace must receive one proof verdict announcement");
  let primary, mirror = goal_files config in
  List.iter (fun (label, bytes) ->
    match Yojson.Safe.from_string bytes |> member "goals" |> to_list with
    | [ row ] -> ignore (shared_row label row)
    | _ -> fail (label ^ " must retain the one shared Goal"))
    [ "primary", primary; "mirror", mirror ];
  List.iter (fun (ctx : Tool_workspace.context) ->
    check bool (ctx.agent_name ^ " has no private Goal transcript") false
      (Sys.file_exists (Keeper_chat_store.chat_path
         ~base_dir:config.base_path ~keeper_name:ctx.agent_name)))
    [ creator; collaborator ]
;;

let test_goal_completion_accepts_goal_without_tasks () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match
      Goal_store.upsert_goal config ~title:"Direct completion" ~metric:"m"
        ~target_value:"1" ()
    with
    | Ok payload -> payload
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  check string "completion request enters verifying" "verifying"
    (transition_phase (request_complete config goal.id));
  check string "proof completes the goal" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id))
;;

let test_goal_completion_ignores_open_task_count () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match
      Goal_store.upsert_goal config ~title:"Open task completion" ~metric:"m"
        ~target_value:"1" ()
    with
    | Ok payload -> payload
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  ignore
    (Workspace_task.add_task
       ~goal_id:goal.id
       config
       ~title:"Still open"
       ~priority:3
       ~description:"open");
  check string "open task does not gate the completion request" "verifying"
    (transition_phase (request_complete config goal.id));
  check string "proof completes the goal" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id))
;;

let test_goal_completion_ignores_metric_text () =
  with_workspace
  @@ fun config ->
  let goal, _ =
    match
      Goal_store.upsert_goal
        config
        ~title:"Metric completion"
        ~metric:"coverage %"
        ~target_value:"80%"
        ()
    with
    | Ok payload -> payload
    | Error error -> fail (Goal_store.write_error_to_string error)
  in
  check string "metric text does not gate the completion request" "verifying"
    (transition_phase (request_complete config goal.id));
  check string "proof completes the goal" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id))
;;
let test_confirmation_uses_token_bound_operator () =
  with_workspace @@ fun config ->
  Auth.save_auth_config config.base_path
    {Types.default_auth_config with enabled = true; require_token = true};
  let token role name = match Auth.create_token config.base_path ~agent_name:name ~role with
    | Ok (token, _) -> token | Error error -> fail (Types.masc_error_to_string error) in
  let worker = token Types.Worker "worker" and operator = token Types.Admin "operator" in
  let authorize token =
    let request = Httpun.Request.create ~headers:(Httpun.Headers.of_list
      ["authorization", "Bearer " ^ token; "x-agent-name", "pretend-human"])
      `POST "/api/v1/goals/confirmation" in
    Server_auth.authorize_token_bound_permission_request ~base_path:config.base_path
      ~permission:Types.CanAdmin request in
  (match authorize worker with Error _ -> () | Ok _ -> fail "Worker token became operator");
  (match authorize operator with
   | Ok actor -> check string "actor comes from credential, never header" "operator" actor
   | Error error -> fail (Types.masc_error_to_string error))
;;

let test_operator_confirmation_binds_current_proof () =
  with_workspace @@ fun config ->
  let goal, _ = match Goal_store.upsert_goal config ~title:"Human confirmed goal"
    ~metric:"observed artifacts" ~target_value:"1" () with
    | Ok value -> value | Error error -> fail (Goal_store.write_error_to_string error) in
  ignore (request_complete config goal.id);
  check string "verifier cannot complete" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id));
  let verdict = match Goal_verification.get_record_authoritative config ~goal_id:goal.id with
    | Ok (Some {completion = Goal_verification.Proof_proven verdict; _}) -> verdict
    | _ -> fail "missing current proof" in
  let confirm ?(request_id=verdict.request_id) ?(run_id=verdict.verification_run_id)
      ?(operator_id="authenticated-operator") () =
    Server_routes_http_routes_verification.For_testing.commit_goal_confirmation_json
      ~config ~operator_id (`Assoc ["goal_id", `String goal.id;
        "criterion_revision", `String goal.criterion_revision; "request_id", `String request_id;
        "verification_run_id", `String run_id]) in
  (match confirm ~request_id:"another-request" () with
   | Error _ -> () | Ok _ -> fail "stale request accepted");
  (match confirm ~run_id:"another-run" () with
   | Error _ -> () | Ok _ -> fail "wrong verifier run accepted");
  (* Simulate the narrow crash boundary after durable confirmation but before
     the goal phase write, then retry the actual application operation. *)
  (match Goal_verification.record_human_confirmation config ~goal_id:goal.id verdict
      ~operator_id:"authenticated-operator" with
   | Ok _ -> () | Error detail -> fail detail);
  let first = match confirm ~operator_id:"another-operator" () with
    | Ok json -> json | Error detail -> fail (confirmation_error_to_string detail) in
  check string "operator confirmation completes" "completed"
    Yojson.Safe.Util.(member "goal" first |> member "phase" |> to_string);
  let history_path = Filename.concat (Workspace_utils.masc_dir config) "goal_events.jsonl" in
  let history = Fs_compat.load_file history_path in
  let completion_events = String.split_on_char '\n' history
    |> List.filter (fun line -> line <> "") |> List.map Yojson.Safe.from_string
    |> List.filter (fun json -> Yojson.Safe.Util.(member "payload" json |> member "phase") = `String "completed") in
  (match completion_events with
   | [event] -> check string "crash retry event credits persisted first operator" "authenticated-operator"
       Yojson.Safe.Util.(member "payload" event |> member "actor" |> to_string)
   | _ -> fail "expected one completion event");
  let second_operator = Workspace_goals.confirm_completion config ~goal_id:goal.id
    ~operator_id:"another-operator" ~criterion_revision:goal.criterion_revision
    ~request_id:verdict.request_id ~verification_run_id:verdict.verification_run_id in
  (match second_operator with
   | Ok json -> check bool "retry never rewrites original operator attribution" true (first = json)
   | Error error -> fail (Goal_store.write_error_to_string error));
  (match Server_routes_http_routes_verification.For_testing.commit_goal_confirmation_json
    ~config ~operator_id:"credential-owner" (`Assoc ["actor", `String "human"] ) with
   | Error _ -> () | Ok _ -> fail "body actor impersonation accepted");
  let second = match confirm () with
    | Ok json -> json | Error detail -> fail (confirmation_error_to_string detail) in
  check bool "exact confirmation replay preserves timestamp and identity" true (first = second);
  check string "retries emit no duplicate confirmation event" history (Fs_compat.load_file history_path);
  (match Goal_verification.reopen_goal config ~goal_id:goal.id ~actor:"operator" ~note:None with
   | Ok _ -> () | Error detail -> fail detail);
  (match confirm () with Error _ -> () | Ok _ -> fail "reopen retained old confirmation authority");
  ignore (request_complete config goal.id);
  ignore (prove_complete config goal.id);
  (match confirm () with Error _ -> () | Ok _ -> fail "new request accepted old confirmation binding");
  (match Goal_store.upsert_goal config ~id:goal.id ~title:"Changed criterion"
     ~metric:"observed artifacts" ~target_value:"2" () with
   | Ok _ -> () | Error error -> fail (Goal_store.write_error_to_string error));
  (match confirm () with Error _ -> () | Ok _ -> fail "changed criterion accepted stale proof")
;;


(* {1 The caller's step after a confirmation is recorded} *)

let goal_awaiting_confirmation config title =
  let goal, _ = match Goal_store.upsert_goal config ~title
    ~metric:"observed artifacts" ~target_value:"1" () with
    | Ok value -> value | Error error -> fail (Goal_store.write_error_to_string error) in
  ignore (request_complete config goal.id);
  check string "the verifier proves it" "awaiting_confirmation"
    (transition_phase (prove_complete config goal.id));
  let verdict = match Goal_verification.get_record_authoritative config ~goal_id:goal.id with
    | Ok (Some {completion = Goal_verification.Proof_proven verdict; _}) -> verdict
    | _ -> fail "missing current proof" in
  goal, verdict
;;

let confirm_with ?after_confirmation config (goal : Goal_store.goal)
    (verdict : Goal_verification.verdict) =
  Workspace_goals.confirm_completion ?after_confirmation config ~goal_id:goal.id
    ~operator_id:"operator-a" ~criterion_revision:goal.criterion_revision
    ~request_id:verdict.request_id ~verification_run_id:verdict.verification_run_id
;;

let phase_of_confirmation = function
  | Ok json -> Yojson.Safe.Util.(member "goal" json |> member "phase" |> to_string)
  | Error error -> fail (Goal_store.write_error_to_string error)
;;

let test_confirmation_step_runs_once_the_confirmation_is_recorded () =
  with_workspace @@ fun config ->
  let goal, verdict = goal_awaiting_confirmation config "Step after confirmation" in
  let seen = ref [] in
  let step (g : Goal_store.goal) (v : Goal_verification.verdict)
      (c : Goal_verification.confirmation) =
    let recorded = match Goal_verification.get_record_authoritative config ~goal_id:g.Goal_store.id with
      | Ok (Some {completion = Goal_verification.Human_confirmed _; _}) -> true
      | _ -> false in
    seen := (g.Goal_store.id, v.Goal_verification.request_id,
             c.Goal_verification.operator_id, recorded,
             Goal_phase.to_string g.Goal_store.phase) :: !seen;
    Ok () in
  check string "the confirmation completes the goal" "completed"
    (phase_of_confirmation (confirm_with ~after_confirmation:step config goal verdict));
  (match !seen with
   | [ (id, request_id, operator, recorded, phase) ] ->
     check string "names the Goal" goal.id id;
     check string "names the confirmed request" verdict.request_id request_id;
     check string "names the operator" "operator-a" operator;
     check bool "the confirmation is already in the ledger" true recorded;
     check string "the phase is not written yet" "awaiting_confirmation" phase
   | calls -> fail (Printf.sprintf "expected one call, got %d" (List.length calls)));
  (* A repeated confirmation of a Completed Goal runs the step again. *)
  check string "a repeat answers the same" "completed"
    (phase_of_confirmation (confirm_with ~after_confirmation:step config goal verdict));
  check int "the repeat ran the step again" 2 (List.length !seen)
;;

let test_a_refusing_confirmation_step_keeps_the_confirmation_retryable () =
  with_workspace @@ fun config ->
  let goal, verdict = goal_awaiting_confirmation config "Step refuses confirmation" in
  (match confirm_with ~after_confirmation:(fun _ _ _ -> Error "candle ledger unavailable")
           config goal verdict with
   | Error (Goal_store.Rejected message) ->
     check string "the refusal reaches the caller" "candle ledger unavailable" message
   | Error other -> fail ("expected Rejected, got " ^ Goal_store.write_error_to_string other)
   | Ok _ -> fail "a refusing step did not stop the confirmation");
  (match Goal_store.find_goal config ~goal_id:goal.id with
   | Goal_store.Goal_found stored ->
     check string "the phase did not move" "awaiting_confirmation"
       (Goal_phase.to_string stored.Goal_store.phase)
   | Goal_store.Goal_absent | Goal_store.Store_unavailable _ -> fail "goal not readable");
  (match Goal_verification.get_record_authoritative config ~goal_id:goal.id with
   | Ok (Some {completion = Goal_verification.Human_confirmed (_, confirmation); _}) ->
     check string "the confirmation stays recorded" "operator-a"
       confirmation.Goal_verification.operator_id
   | _ -> fail "the confirmation was not kept");
  check string "confirming again completes it" "completed"
    (phase_of_confirmation (confirm_with config goal verdict))
;;

let () =
  run
    "goal_tools"
    [ ( "tool_workspace"
      , [ test_case "confirmation requires token-bound operator" `Quick test_confirmation_uses_token_bound_operator
        ; test_case "operator confirms exact current proof" `Quick test_operator_confirmation_binds_current_proof
        ; test_case "a confirmation step runs once the confirmation is recorded" `Quick
            test_confirmation_step_runs_once_the_confirmation_is_recorded
        ; test_case "a refusing confirmation step keeps the confirmation retryable" `Quick
            test_a_refusing_confirmation_step_keeps_the_confirmation_retryable
        ; test_case "upsert and list" `Quick test_goal_upsert_and_list
        ; test_case "different callers share a Goal without private delivery" `Quick
            test_callers_share_a_goal_without_private_delivery
        ; test_case "list preserves source failure" `Quick test_goal_list_preserves_source_failure
        ; test_case "list answers the Unavailable envelope on #34459 rows" `Quick
            test_goal_list_schema_rejected_envelope
        ; test_case "transition answers Unavailable on an unreadable store" `Quick
            test_goal_transition_unavailable_store
        ; test_case "transition answers not_found for an unknown id" `Quick
            test_goal_transition_unknown_goal_not_found
        ; test_case "upsert answers the Unavailable envelope" `Quick
            test_goal_upsert_unavailable_store
        ; test_case "list filters by phase" `Quick test_goal_list_filters_by_phase
        ; test_case "list includes rollup" `Quick test_goal_list_includes_rollup
        ; test_case
            "list ignores blank optional filters"
            `Quick
            test_goal_list_ignores_blank_optional_filters
        ; test_case
            "list rejects status filter"
            `Quick
            test_goal_list_rejects_status_filter
        ; test_case
            "upsert rejects lifecycle fields"
            `Quick
            test_goal_upsert_rejects_lifecycle_fields
        ; test_case
            "creating a goal emits an event"
            `Quick
            test_goal_creation_emits_an_event
        ; test_case
            "committed creation retains its failed event receipt"
            `Quick
            test_goal_creation_survives_event_recording_failure
        ; test_case
            "metadata edit survives event recording failure"
            `Quick
            test_metadata_edit_survives_event_recording_failure
        ; test_case
            "criterion edit reports each failed event"
            `Quick
            test_criterion_edit_reports_each_failed_event
        ; test_case
            "due date and priority edits are recorded"
            `Quick
            test_goal_due_date_and_priority_edits_are_recorded
        ; test_case
            "a goal edit whose row cannot be appended still succeeds"
            `Quick
            test_a_goal_edit_whose_row_cannot_be_appended_still_succeeds
        ; test_case
            "goal review removed from dispatch"
            `Quick
            test_goal_review_removed_from_dispatch
        ; test_case
            "completion accepts no linked tasks"
            `Quick
            test_goal_completion_accepts_goal_without_tasks
        ; test_case
            "completion ignores open task count"
            `Quick
            test_goal_completion_ignores_open_task_count
        ; test_case
            "completion ignores metric text"
            `Quick
            test_goal_completion_ignores_metric_text
        ] )
    ]
;;
