open Alcotest
open Masc
module Watch = Schedule_run_watch
module Checks = Schedule_checks_watch

(* [until_github_run] at the tool boundary: what masc_schedule_create and
   masc_schedule_update store from it, what they refuse, and that the row they
   store is one [Schedule_run_watch.tick] can wake. *)

let runner_tick_sec = 1.0

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path)
    else Sys.remove path
;;

let wake_keeper = "schedule-keeper"

(* The wake-target check reads the keeper through its effective meta, which
   needs both the declared profile and a snapshot. *)
let register_wake_target config keeper_name =
  let profile_path =
    Keeper_sandbox_config.keeper_toml_path
      ~base_path:config.Workspace.base_path
      ~agent_name:keeper_name
  in
  Fs_compat.mkdir_p (Filename.dirname profile_path);
  Out_channel.with_open_text profile_path (fun channel ->
    Printf.fprintf
      channel
      "[keeper]\ninstructions = \"run watch test target\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n");
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String keeper_name; "trace_id", `String ("trace-" ^ keeper_name) ])
  with
  | Error msg -> fail ("keeper meta parse failed: " ^ msg)
  | Ok meta ->
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error detail -> fail ("keeper meta write failed: " ^ detail))
;;

let with_config f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_dir "schedule_tool_run_watch_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf path);
  let config = Workspace.default_config path in
  ignore (Workspace.init config ~agent_name:(Some "run-watch-tool-test"));
  Workspace_metric_hooks.install ();
  Atomic.set Workspace_hooks.schedule_wake_target_registered_fn (fun config keeper_name ->
    match Keeper_meta_store.read_effective_meta config keeper_name with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error detail -> Error detail);
  register_wake_target config wake_keeper;
  f config
;;

let schedule_ctx config : Tool_schedule.context =
  { config
  ; caller = Tool_schedule.Named_caller "scheduler-agent"
  ; stamp_keeper_wake_result_delivery =
      (fun ~payload ->
        Schedule_payload_projection.set_keeper_wake_result_delivery ~payload ~channel:None)
  ; admit_keeper_wake_creation = Keeper_schedule_creation_admission.run
  ; withdraw_queued_keeper_wakes = Keeper_schedule_cancel_withdrawal.run
  ; result_boundary = Tool_output.Sent_to_client
  }
;;

let dispatch config ~name fields =
  match Tool_schedule.dispatch (schedule_ctx config) ~name ~args:(`Assoc fields) with
  | Some result -> result
  | None -> fail ("schedule dispatch returned None: " ^ name)
;;

let create_name = "masc_schedule_create"
let update_name = "masc_schedule_update"

(* A tool call is dated by the dispatch clock and refuses a due time behind
   it, so these schedules are due in 2100. *)
let future_due_at = 4_102_444_800.0

let run_url = "https://github.com/jeong-sik/masc/actions/runs/41895911884"

let create_fields ?(schedule_id = "watched") ?(extra = []) ~message () =
  [ "schedule_id", `String schedule_id
  ; "due_at_unix", `Float future_due_at
  ; "keeper_name", `String wake_keeper
  ; "message", `String message
  ]
  @ extra
;;

let stored_exn config schedule_id =
  match Schedule_store.get_schedule config ~schedule_id with
  | Some request -> request
  | None -> fail ("no stored schedule " ^ schedule_id)
;;

let body_of (request : Schedule_domain.schedule_request) =
  match Schedule_domain.payload_to_yojson request.Schedule_domain.payload with
  | `Assoc fields ->
    (match List.assoc_opt "body" fields with
     | Some (`Assoc body) -> body
     | Some _ | None -> fail "stored payload has no body object")
  | _ -> fail "stored payload is not an object"
;;

let watch_of_row request =
  match Watch.watch_of_body (body_of request) with
  | Ok watch -> watch
  | Error detail -> fail detail
;;

let describe_watch = function
  | None -> "no watch"
  | Some target -> Watch.target_url target
;;

let message_of request =
  match List.assoc_opt "message" (body_of request) with
  | Some (`String message) -> message
  | Some _ | None -> fail "stored body has no message"
;;

let receipt_key_of request =
  match List.assoc_opt "receipt_key" (body_of request) with
  | Some (`String key) -> Some key
  | Some _ -> fail "stored receipt_key is not a string"
  | None -> None
;;

let check_success label result =
  if not (Tool_result.is_success result)
  then failf "%s: refused: %s" label (Tool_result.message result)
;;

let check_refused label ~mentioning result =
  check bool (label ^ ": refused") false (Tool_result.is_success result);
  List.iter
    (fun word ->
      check
        bool
        (Printf.sprintf "%s: the message names %s" label word)
        true
        (String_util.contains_substring (Tool_result.message result) word))
    mentioning
;;

(* --- Create --- *)

let test_create_stores_the_run_as_a_typed_field () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"merge if green"
          ~extra:[ "until_github_run", `String (run_url ^ "?pr=1#summary") ]
          ()));
  let stored = stored_exn config "watched" in
  check
    string
    "the stored field is the parsed run, not the URL"
    {|{"repo":"jeong-sik/masc","run_id":41895911884}|}
    (Yojson.Safe.to_string (List.assoc Watch.watch_field (body_of stored)));
  check string "the message is the Keeper's own" "merge if green" (message_of stored);
  check (float 0.0) "the due time is the fallback" future_due_at stored.Schedule_domain.due_at
;;

let test_create_keeps_a_named_attempt () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"check"
          ~extra:[ "until_github_run", `String (run_url ^ "/attempts/2") ]
          ()));
  check
    string
    "attempt"
    (run_url ^ "/attempts/2")
    (describe_watch (watch_of_row (stored_exn config "watched")))
;;

let test_create_stores_a_receipt_delivery () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"merge if green"
          ~extra:[ "until_github_run", `String run_url; "delivery", `String "receipt" ]
          ()));
  let stored = stored_exn config "watched" in
  check
    string
    "the delivery is stored as given"
    "receipt"
    (match List.assoc_opt "delivery" (body_of stored) with
     | Some (`String value) -> value
     | Some _ | None -> fail "stored body has no delivery string");
  check bool "the run is still watched" true (Option.is_some (watch_of_row stored));
  (match receipt_key_of stored with
   | None -> fail "a receipt delivery was stored without a receipt key"
   | Some key ->
     check bool "the key is not a valid request id" false
       (Keeper_msg_async.For_testing.is_safe_request_id key))
;;

let test_create_stores_no_receipt_key_for_a_queue_delivery () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields ~message:"m" ~extra:[ "delivery", `String "queue" ] ()));
  check
    (option string)
    "a queue delivery holds no key"
    None
    (receipt_key_of (stored_exn config "watched"))
;;

let test_two_receipt_schedules_hold_different_keys () =
  with_config
  @@ fun config ->
  let create schedule_id =
    check_success
      ("create " ^ schedule_id)
      (dispatch
         config
         ~name:create_name
         (create_fields ~schedule_id ~message:"m" ~extra:[ "delivery", `String "receipt" ] ()));
    receipt_key_of (stored_exn config schedule_id)
  in
  let first = create "first" in
  let second = create "second" in
  check bool "both hold a key" true (Option.is_some first && Option.is_some second);
  check bool "the keys differ" false (first = second)
;;

(* A wait is recorded under the key, so an edit of a schedule that has not
   ended must not issue a new one. *)
let test_update_keeps_the_receipt_key_of_a_pending_schedule () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields ~message:"first" ~extra:[ "delivery", `String "receipt" ] ()));
  let before = receipt_key_of (stored_exn config "watched") in
  check_success
    "update"
    (dispatch
       config
       ~name:update_name
       [ "schedule_id", `String "watched"
       ; "keeper_name", `String wake_keeper
       ; "message", `String "second"
       ; "delivery", `String "receipt"
       ]);
  let after = receipt_key_of (stored_exn config "watched") in
  check bool "the schedule holds a key" true (Option.is_some after);
  check (option string) "the key is the one the first write issued" before after
;;

let test_create_refuses_a_receipt_with_urgency_and_an_unknown_delivery () =
  with_config
  @@ fun config ->
  check_refused
    "a receipt takes no urgency"
    ~mentioning:[ "urgency" ]
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"m"
          ~extra:[ "delivery", `String "receipt"; "urgency", `String "low" ]
          ()));
  check_refused
    "an unknown delivery"
    ~mentioning:[ "delivery" ]
    (dispatch
       config
       ~name:create_name
       (create_fields ~message:"m" ~extra:[ "delivery", `String "pigeon" ] ()));
  check bool "nothing stored" true
    (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"watched"))
;;

let test_create_refuses_a_url_that_names_no_run () =
  with_config
  @@ fun config ->
  List.iter
    (fun url ->
      check_refused
        url
        ~mentioning:[ Watch.watch_field; "actions/runs" ]
        (dispatch
           config
           ~name:create_name
           (create_fields ~message:"check" ~extra:[ "until_github_run", `String url ] ()));
      check bool (url ^ ": nothing stored") true
        (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"watched")))
    [ "https://github.com/jeong-sik/masc/pull/12"
    ; "https://gitlab.com/jeong-sik/masc/actions/runs/1"
    ; "https://github.com/jeong-sik/masc/actions/runs/abc"
    ; "41895911884"
    ]
;;

let test_create_refuses_a_recurring_schedule () =
  with_config
  @@ fun config ->
  check_refused
    "interval"
    ~mentioning:[ Watch.watch_field; "one_shot" ]
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"check"
          ~extra:
            [ "until_github_run", `String run_url
            ; "recurrence_kind", `String "interval"
            ; "recurrence_interval_sec", `Int 3600
            ]
          ()));
  check bool "nothing stored" true
    (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"watched"))
;;

let test_create_refuses_a_recurring_receipt () =
  with_config
  @@ fun config ->
  check_refused
    "daily receipt"
    ~mentioning:[ "delivery"; "one_shot" ]
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"check"
          ~extra:
            [ "delivery", `String "receipt"
            ; "recurrence_kind", `String "interval"
            ; "recurrence_interval_sec", `Int 3600
            ]
          ()));
  check bool "nothing stored" true
    (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"watched"))
;;

let test_create_refuses_a_lane_action_with_a_run () =
  with_config
  @@ fun config ->
  let result =
    dispatch
      config
      ~name:create_name
      [ "schedule_id", `String "lane-watched"
      ; "due_at_unix", `Float future_due_at
      ; "installation_id", `String "inst-1"
      ; "action", `Assoc [ "kind", `String "compose" ]
      ; "until_github_run", `String run_url
      ]
  in
  check bool "refused" false (Tool_result.is_success result);
  check bool "nothing stored" true
    (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"lane-watched"))
;;

(* --- Update --- *)

let test_update_replaces_the_watch_with_what_it_is_given () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields ~message:"first" ~extra:[ "until_github_run", `String run_url ] ()));
  let update ~message extra =
    dispatch
      config
      ~name:update_name
      ([ "schedule_id", `String "watched"; "keeper_name", `String wake_keeper; "message", `String message ]
       @ extra)
  in
  check_success "update without the run" (update ~message:"second" []);
  let without = stored_exn config "watched" in
  check string "the watch is gone" "no watch" (describe_watch (watch_of_row without));
  check string "the message changed" "second" (message_of without);
  check_success
    "update with another run"
    (update
       ~message:"third"
       [ "until_github_run", `String "https://github.com/jeong-sik/wkbl/actions/runs/7" ]);
  check
    string
    "the new watch"
    "https://github.com/jeong-sik/wkbl/actions/runs/7"
    (describe_watch (watch_of_row (stored_exn config "watched")))
;;

let test_update_refuses_a_run_on_a_recurring_schedule () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"every hour"
          ~extra:[ "recurrence_kind", `String "interval"; "recurrence_interval_sec", `Int 3600 ]
          ()));
  check_refused
    "update"
    ~mentioning:[ Watch.watch_field; "one_shot" ]
    (dispatch
       config
       ~name:update_name
       [ "schedule_id", `String "watched"
       ; "keeper_name", `String wake_keeper
       ; "message", `String "every hour"
       ; "until_github_run", `String run_url
       ]);
  check string "the stored row has no watch" "no watch"
    (describe_watch (watch_of_row (stored_exn config "watched")))
;;

(* The injected admission runs after the tool has read and validated the
   original row. Commit another public update there, before the first write
   takes the schedule store lock, to make the interleaving deterministic. *)
let test_update_after_concurrent_recurrence_change ~with_watch ~due_fields () =
  with_config
  @@ fun config ->
  check_success "create one-shot"
    (dispatch config ~name:create_name (create_fields ~message:"original" ()));
  let original = stored_exn config "watched" in
  let replacement = ref None in
  let ordinary = schedule_ctx config in
  let ctx = { ordinary with
    admit_keeper_wake_creation = (fun config ~keeper_name write ->
      check_success "concurrent recurring update"
        (dispatch config ~name:update_name
          [ "schedule_id", `String "watched"
          ; "keeper_name", `String wake_keeper
          ; "message", `String "concurrent recurring message"
          ; "recurrence_kind", `String "interval"
          ; "recurrence_interval_sec", `Int 3600
          ; "due_at_unix", `Float future_due_at
          ]);
      replacement := Some (stored_exn config "watched");
      ordinary.admit_keeper_wake_creation config ~keeper_name write) } in
  let watch_fields = if with_watch then ["until_github_run", `String run_url] else [] in
  let result = match Tool_schedule.dispatch ctx ~name:update_name
      ~args:(`Assoc
        ([ "schedule_id", `String "watched"
         ; "keeper_name", `String wake_keeper
         ; "message", `String "first caller's message"
         ] @ watch_fields @ due_fields)) with
    | Some result -> result
    | None -> fail "schedule update dispatch returned None" in
  let replacement = match !replacement with
    | Some replacement -> replacement
    | None -> fail "the concurrent update did not run" in
  check bool "another instance was committed" false
    (String.equal original.schedule_instance_id replacement.schedule_instance_id);
  let final = stored_exn config "watched" in
  (match final.recurrence with
   | Schedule_domain.Interval { interval_sec } ->
     check int "the concurrent interval is retained" 3600 interval_sec
   | Schedule_domain.One_shot | Schedule_domain.Daily _ | Schedule_domain.Cron _ ->
     fail "the concurrent recurrence was replaced");
  check string "no inert run watch is stored" "no watch"
    (describe_watch (watch_of_row final));
  if with_watch then begin
    check_refused "watch update used a superseded instance"
      ~mentioning:["instance"] result;
    check string "the concurrent instance survives" replacement.schedule_instance_id
      final.schedule_instance_id;
    check string "the concurrent message survives" "concurrent recurring message"
      (message_of final)
  end else begin
    check_success "ordinary content update keeps latest timing" result;
    check string "ordinary content still changes" "first caller's message" (message_of final)
  end
;;

(* --- The tool schemas --- *)

let schema_of action =
  match
    List.find_opt
      (fun (definition : Tool_schemas_schedule.definition) -> definition.action = action)
      Tool_schemas_schedule.definitions
  with
  | Some definition ->
    let schema : Masc_domain.tool_schema = definition.schema in
    schema
  | None -> fail "schedule definition missing"
;;

let validate action args =
  let schema = schema_of action in
  Tool_input_validation.validate_args
    ~schema:schema.input_schema
    ~name:schema.name
    ~args:(`Assoc args)
    ()
;;

let test_schemas_declare_the_param () =
  List.iter
    (fun (label, action, extra) ->
      match
        validate
          action
          ([ "due_at_unix", `Float future_due_at
           ; "keeper_name", `String wake_keeper
           ; "message", `String "check"
           ; "until_github_run", `String run_url
           ]
           @ extra)
      with
      | Ok _ -> ()
      | Error rejection -> failf "%s: %s" label (Tool_result.message rejection))
    [ "create", Tool_schemas_schedule.Create_request, []
    ; "update", Tool_schemas_schedule.Update_request, [ "schedule_id", `String "watched" ]
    ]
;;

let test_schemas_keep_the_param_out_of_a_lane_action () =
  List.iter
    (fun (label, action, extra) ->
      let lane_action =
        [ "due_at_unix", `Float future_due_at
        ; "installation_id", `String "inst-1"
        ; "action", `Assoc [ "kind", `String "compose" ]
        ]
        @ extra
      in
      (match validate action lane_action with
       | Ok _ -> ()
       | Error rejection ->
         failf "%s: a Lane action alone was refused: %s" label (Tool_result.message rejection));
      match validate action (lane_action @ [ "until_github_run", `String run_url ]) with
      | Ok _ -> failf "%s: a Lane action with until_github_run was accepted" label
      | Error _ -> ())
    [ "create", Tool_schemas_schedule.Create_request, []
    ; "update", Tool_schemas_schedule.Update_request, [ "schedule_id", `String "watched" ]
    ]
;;

(* --- The payload contract --- *)

let keeper_wake_payload watch =
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc
          ([ "keeper_name", `String wake_keeper; "message", `String "m" ]
           @
           match watch with
           | None -> []
           | Some value -> [ Watch.watch_field, value ]) )
    ]
;;

let test_the_payload_contract_checks_the_watch () =
  let creation payload =
    Schedule_payload_projection.validate_request_payload_for_creation_detailed ~payload
  in
  check bool "no watch" true (Result.is_ok (creation (keeper_wake_payload None)));
  check bool "a well-formed watch" true
    (Result.is_ok
       (creation
          (keeper_wake_payload
             (Some (`Assoc [ "repo", `String "jeong-sik/masc"; "run_id", `Int 5 ])))));
  List.iter
    (fun (label, watch) ->
      check bool label true (Result.is_error (creation (keeper_wake_payload (Some watch)))))
    [ "the URL as a string", `String run_url
    ; "no run id", `Assoc [ "repo", `String "jeong-sik/masc" ]
    ; "a repository that is not owner/name", `Assoc [ "repo", `String "masc"; "run_id", `Int 5 ]
    ; ( "an unknown field"
      , `Assoc [ "repo", `String "jeong-sik/masc"; "run_id", `Int 5; "url", `String run_url ] )
    ; "a run id of zero", `Assoc [ "repo", `String "jeong-sik/masc"; "run_id", `Int 0 ]
    ]
;;

(* --- From the tool to the wake --- *)

let test_a_row_the_tool_created_is_woken_and_still_dispatchable () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"merge if green"
          ~extra:[ "until_github_run", `String run_url; "urgency", `String "low" ]
          ()));
  let now = future_due_at -. 3600.5 in
  let outcomes =
    match
      Watch.tick config ~now ~runner_tick_sec ~read:(fun _ ->
        Ok (Watch.Completed (Some Watch.Failure)))
    with
    | Ok outcomes -> outcomes
    | Error detail -> fail detail
  in
  check int "one watched row" 1 (List.length outcomes);
  (match outcomes with
   | [ { Watch.verdict = Watch.Woken (Watch.Run_completed (Some Watch.Failure)); _ } ] -> ()
   | _ -> fail "the row was not woken for a failed run");
  let woken = stored_exn config "watched" in
  check (float 0.0) "due at the current second" (Float.floor now) woken.Schedule_domain.due_at;
  check string "no watch left" "no watch" (describe_watch (watch_of_row woken));
  (match String.split_on_char '\n' (message_of woken) with
   | [ headline; url; ""; original ] ->
     check bool "the outcome leads" true (String_util.contains_substring headline "failure");
     check string "then the run URL" run_url url;
     check string "then the Keeper's own message" "merge if green" original
   | _ -> fail "the message is the outcome, the run URL, an empty line, then the Keeper's own");
  check string "urgency is kept" "low"
    (match List.assoc_opt "urgency" (body_of woken) with
     | Some (`String urgency) -> urgency
     | Some _ | None -> fail "urgency lost");
  check bool "the consumer still accepts the payload" true
    (Result.is_ok (Schedule_payload_projection.dispatch_view_detailed woken))
;;

(* --- The commit watch: [until_github_checks] --- *)

let commit_sha = "8b666a19e3455100528bb90b861374c56e563f82"
let commit_url = "https://github.com/jeong-sik/masc/commit/" ^ commit_sha

let checks_watch_of_row request =
  match Checks.watch_of_body (body_of request) with
  | Ok watch -> watch
  | Error detail -> fail detail
;;

let describe_checks_watch = function
  | None -> "no watch"
  | Some target -> Checks.target_url target
;;

let test_commit_create_stores_the_commit_as_a_typed_field () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"merge if green"
          ~extra:[ "until_github_checks", `String (commit_url ^ "?diff=split#diff-1") ]
          ()));
  let stored = stored_exn config "watched" in
  check
    string
    "the stored field is the parsed commit, not the URL"
    (Printf.sprintf {|{"repo":"jeong-sik/masc","sha":"%s"}|} commit_sha)
    (Yojson.Safe.to_string (List.assoc Checks.watch_field (body_of stored)));
  check bool "no run watch beside it" true (not (List.mem_assoc Watch.watch_field (body_of stored)));
  check (float 0.0) "the due time is the fallback" future_due_at stored.Schedule_domain.due_at
;;

let test_commit_create_refuses_a_url_that_is_not_a_full_commit () =
  with_config
  @@ fun config ->
  List.iter
    (fun url ->
      check_refused
        url
        ~mentioning:[ Checks.watch_field; "commit" ]
        (dispatch
           config
           ~name:create_name
           (create_fields ~message:"check" ~extra:[ "until_github_checks", `String url ] ()));
      check bool (url ^ ": nothing stored") true
        (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"watched")))
    [ "https://github.com/jeong-sik/masc/commit/8b666a19e345"
    ; "https://github.com/jeong-sik/masc/pull/51286"
    ; "https://gitlab.com/jeong-sik/masc/commit/" ^ commit_sha
    ; commit_sha
    ]
;;

let test_commit_create_refuses_a_recurring_schedule () =
  with_config
  @@ fun config ->
  check_refused
    "interval"
    ~mentioning:[ Checks.watch_field; "one_shot" ]
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"check"
          ~extra:
            [ "until_github_checks", `String commit_url
            ; "recurrence_kind", `String "interval"
            ; "recurrence_interval_sec", `Int 3600
            ]
          ()));
  check bool "nothing stored" true
    (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"watched"))
;;

let test_commit_create_refuses_both_watches () =
  with_config
  @@ fun config ->
  check_refused
    "both"
    ~mentioning:[ Checks.watch_field; Watch.watch_field ]
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"check"
          ~extra:[ "until_github_checks", `String commit_url; "until_github_run", `String run_url ]
          ()));
  check bool "nothing stored" true
    (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"watched"))
;;

let test_commit_create_refuses_a_lane_action_with_a_commit () =
  with_config
  @@ fun config ->
  let result =
    dispatch
      config
      ~name:create_name
      [ "schedule_id", `String "lane-watched"
      ; "due_at_unix", `Float future_due_at
      ; "installation_id", `String "inst-1"
      ; "action", `Assoc [ "kind", `String "compose" ]
      ; "until_github_checks", `String commit_url
      ]
  in
  check bool "refused" false (Tool_result.is_success result);
  check bool "nothing stored" true
    (Option.is_none (Schedule_store.get_schedule config ~schedule_id:"lane-watched"))
;;

let test_commit_update_replaces_the_watch_with_what_it_is_given () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields ~message:"first" ~extra:[ "until_github_checks", `String commit_url ] ()));
  let update ~message extra =
    dispatch
      config
      ~name:update_name
      ([ "schedule_id", `String "watched"; "keeper_name", `String wake_keeper; "message", `String message ]
       @ extra)
  in
  check_success "update without the commit" (update ~message:"second" []);
  check
    string
    "the watch is gone"
    "no watch"
    (describe_checks_watch (checks_watch_of_row (stored_exn config "watched")));
  let other = "https://github.com/jeong-sik/wkbl/commit/" ^ String.make 40 'c' in
  check_success "update with another commit" (update ~message:"third" [ "until_github_checks", `String other ]);
  check
    string
    "the new watch"
    other
    (describe_checks_watch (checks_watch_of_row (stored_exn config "watched")));
  check_success "update swaps the commit for a run" (update ~message:"fourth" [ "until_github_run", `String run_url ]);
  let swapped = stored_exn config "watched" in
  check string "no commit watch" "no watch" (describe_checks_watch (checks_watch_of_row swapped));
  check string "the run watch" run_url (describe_watch (watch_of_row swapped))
;;

let test_commit_update_refuses_a_commit_on_a_recurring_schedule () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"every hour"
          ~extra:[ "recurrence_kind", `String "interval"; "recurrence_interval_sec", `Int 3600 ]
          ()));
  check_refused
    "update"
    ~mentioning:[ Checks.watch_field; "one_shot" ]
    (dispatch
       config
       ~name:update_name
       [ "schedule_id", `String "watched"
       ; "keeper_name", `String wake_keeper
       ; "message", `String "every hour"
       ; "until_github_checks", `String commit_url
       ]);
  check string "the stored row has no watch" "no watch"
    (describe_checks_watch (checks_watch_of_row (stored_exn config "watched")))
;;

let test_commit_schemas_declare_the_param_and_keep_it_out_of_a_lane_action () =
  List.iter
    (fun (label, action, extra) ->
      (match
         validate
           action
           ([ "due_at_unix", `Float future_due_at
            ; "keeper_name", `String wake_keeper
            ; "message", `String "check"
            ; "until_github_checks", `String commit_url
            ]
            @ extra)
       with
       | Ok _ -> ()
       | Error rejection -> failf "%s: %s" label (Tool_result.message rejection));
      let lane_action =
        [ "due_at_unix", `Float future_due_at
        ; "installation_id", `String "inst-1"
        ; "action", `Assoc [ "kind", `String "compose" ]
        ]
        @ extra
      in
      match validate action (lane_action @ [ "until_github_checks", `String commit_url ]) with
      | Ok _ -> failf "%s: a Lane action with until_github_checks was accepted" label
      | Error _ -> ())
    [ "create", Tool_schemas_schedule.Create_request, []
    ; "update", Tool_schemas_schedule.Update_request, [ "schedule_id", `String "watched" ]
    ]
;;

let keeper_wake_payload_with fields =
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; "body", `Assoc ([ "keeper_name", `String wake_keeper; "message", `String "m" ] @ fields)
    ]
;;

let test_commit_payload_contract_checks_the_watch () =
  let creation payload =
    Schedule_payload_projection.validate_request_payload_for_creation_detailed ~payload
  in
  let well_formed = `Assoc [ "repo", `String "jeong-sik/masc"; "sha", `String commit_sha ] in
  check bool "a well-formed watch" true
    (Result.is_ok (creation (keeper_wake_payload_with [ Checks.watch_field, well_formed ])));
  List.iter
    (fun (label, fields) ->
      check bool label true (Result.is_error (creation (keeper_wake_payload_with fields))))
    [ "the URL as a string", [ Checks.watch_field, `String commit_url ]
    ; "a short sha", [ Checks.watch_field, `Assoc [ "repo", `String "jeong-sik/masc"; "sha", `String "8b666a1" ] ]
    ; "no sha", [ Checks.watch_field, `Assoc [ "repo", `String "jeong-sik/masc" ] ]
    ; ( "an unknown field"
      , [ Checks.watch_field
        , `Assoc [ "repo", `String "jeong-sik/masc"; "sha", `String commit_sha; "url", `String commit_url ]
        ] )
    ; ( "both watches"
      , [ Checks.watch_field, well_formed
        ; Watch.watch_field, `Assoc [ "repo", `String "jeong-sik/masc"; "run_id", `Int 5 ]
        ] )
    ]
;;

let test_a_commit_row_the_tool_created_is_woken_and_still_dispatchable () =
  with_config
  @@ fun config ->
  check_success
    "create"
    (dispatch
       config
       ~name:create_name
       (create_fields
          ~message:"merge if green"
          ~extra:[ "until_github_checks", `String commit_url; "urgency", `String "low" ]
          ()));
  let now = future_due_at -. 3600.5 in
  let runs =
    [ { Checks.workflow = "PR type-check"
      ; event = Checks.Pull_request
      ; conclusion = Some Watch.Failure
      }
    ]
  in
  let outcomes =
    match Checks.tick config ~now ~runner_tick_sec ~read:(fun _ -> Ok (Checks.Settled runs)) with
    | Ok outcomes -> outcomes
    | Error detail -> fail detail
  in
  check int "one watched row" 1 (List.length outcomes);
  (match outcomes with
   | [ { Checks.verdict = Checks.Woken (Checks.Checks_completed _); _ } ] -> ()
   | _ -> fail "the row was not woken for settled checks");
  let woken = stored_exn config "watched" in
  check (float 0.0) "due at the current second" (Float.floor now) woken.Schedule_domain.due_at;
  check string "no watch left" "no watch" (describe_checks_watch (checks_watch_of_row woken));
  (match String.split_on_char '\n' (message_of woken) with
   | [ headline; line; url; ""; original ] ->
     check bool "the outcome leads" true (String_util.contains_substring headline "1 check runs completed");
     check string "one line per check run" "- PR type-check (pull_request): failure" line;
     check string "then the commit URL" commit_url url;
     check string "then the Keeper's own message" "merge if green" original
   | _ -> fail "the message is the outcome, a line per run, the commit URL, an empty line, then the Keeper's own");
  check string "urgency is kept" "low"
    (match List.assoc_opt "urgency" (body_of woken) with
     | Some (`String urgency) -> urgency
     | Some _ | None -> fail "urgency lost");
  check bool "the consumer still accepts the payload" true
    (Result.is_ok (Schedule_payload_projection.dispatch_view_detailed woken))
;;

let () =
  run
    "schedule_tool_run_watch"
    [ ( "create"
      , [ test_case "stores the run as a typed field" `Quick test_create_stores_the_run_as_a_typed_field
        ; test_case "keeps a named attempt" `Quick test_create_keeps_a_named_attempt
        ; test_case "stores a receipt delivery" `Quick test_create_stores_a_receipt_delivery
        ; test_case "stores no receipt key for a queue delivery" `Quick test_create_stores_no_receipt_key_for_a_queue_delivery
        ; test_case "two receipt schedules hold different keys" `Quick test_two_receipt_schedules_hold_different_keys
        ; test_case "update keeps the receipt key of a pending schedule" `Quick test_update_keeps_the_receipt_key_of_a_pending_schedule
        ; test_case "refuses a recurring receipt" `Quick test_create_refuses_a_recurring_receipt
        ; test_case "refuses a receipt with urgency and an unknown delivery" `Quick test_create_refuses_a_receipt_with_urgency_and_an_unknown_delivery
        ; test_case "refuses a URL that names no run" `Quick test_create_refuses_a_url_that_names_no_run
        ; test_case "refuses a recurring schedule" `Quick test_create_refuses_a_recurring_schedule
        ; test_case "refuses a Lane action with a run" `Quick test_create_refuses_a_lane_action_with_a_run
        ] )
    ; ( "update"
      , [ test_case
            "replaces the watch with what it is given"
            `Quick
            test_update_replaces_the_watch_with_what_it_is_given
        ; test_case
            "refuses a run on a recurring schedule"
            `Quick
            test_update_refuses_a_run_on_a_recurring_schedule
        ; test_case "a watch rejects a concurrent recurrence change with retained timing"
            `Quick (test_update_after_concurrent_recurrence_change ~with_watch:true ~due_fields:[])
        ; test_case "a watch rejects a concurrent recurrence change with an explicit due"
            `Quick (test_update_after_concurrent_recurrence_change ~with_watch:true
              ~due_fields:["due_at_unix", `Float future_due_at])
        ; test_case "an ordinary edit keeps the concurrent recurrence"
            `Quick (test_update_after_concurrent_recurrence_change ~with_watch:false ~due_fields:[])
        ] )
    ; ( "schemas"
      , [ test_case "declare the param" `Quick test_schemas_declare_the_param
        ; test_case
            "keep the param out of a Lane action"
            `Quick
            test_schemas_keep_the_param_out_of_a_lane_action
        ] )
    ; ( "payload"
      , [ test_case "the contract checks the watch" `Quick test_the_payload_contract_checks_the_watch ] )
    ; ( "wake"
      , [ test_case
            "a row the tool created is woken and still dispatchable"
            `Quick
            test_a_row_the_tool_created_is_woken_and_still_dispatchable
        ] )
    ; ( "commit watch"
      , [ test_case "create stores the commit as a typed field" `Quick test_commit_create_stores_the_commit_as_a_typed_field
        ; test_case "create refuses a URL that is not a full commit" `Quick test_commit_create_refuses_a_url_that_is_not_a_full_commit
        ; test_case "create refuses a recurring schedule" `Quick test_commit_create_refuses_a_recurring_schedule
        ; test_case "create refuses both watches" `Quick test_commit_create_refuses_both_watches
        ; test_case "create refuses a Lane action with a commit" `Quick test_commit_create_refuses_a_lane_action_with_a_commit
        ; test_case "update replaces the watch with what it is given" `Quick test_commit_update_replaces_the_watch_with_what_it_is_given
        ; test_case "update refuses a commit on a recurring schedule" `Quick test_commit_update_refuses_a_commit_on_a_recurring_schedule
        ; test_case "schemas declare the param and keep it out of a Lane action" `Quick test_commit_schemas_declare_the_param_and_keep_it_out_of_a_lane_action
        ; test_case "the payload contract checks the watch" `Quick test_commit_payload_contract_checks_the_watch
        ; test_case "a row the tool created is woken and still dispatchable" `Quick test_a_commit_row_the_tool_created_is_woken_and_still_dispatchable
        ] )
    ]
;;
