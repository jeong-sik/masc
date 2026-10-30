open Alcotest
open Masc

(* Fixture tick for create and modify: the runner's floor tick, below every
   interval these fixtures declare, so the runner-tick check never refuses one
   of them. *)
let runner_tick_sec = 1.0

let rec rm_rf path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun entry -> rm_rf (Filename.concat path entry));
      Unix.rmdir path
    end else
      Sys.remove path
;;

(* A snapshot alone does not make a keeper readable. [read_effective_meta]
   merges the snapshot with the keeper's declared profile, and since #32078 a
   keeper with no declared sandbox_profile has no effective meta at all --
   [effective_meta_of_profile_defaults] returns an error rather than assuming
   one. The wake-target check reads through that path, so a registration
   without the TOML registers a keeper the scheduler cannot see. *)
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
      "[keeper]\ninstructions = \"schedule wiring test target\"\nsandbox_profile = \"docker\"\nsandbox_image = \"base\"\n");
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
        [ "name", `String keeper_name
        ; "trace_id", `String ("trace-" ^ keeper_name)
        ])
  with
  | Error msg -> fail ("keeper meta parse failed: " ^ msg)
  | Ok meta ->
    (match Keeper_meta_store.replace_snapshot config meta with
     | Ok () -> ()
     | Error detail -> fail ("keeper meta write failed: " ^ detail))
;;

let with_config ?(strict_executor = false) f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let path = Filename.temp_dir "schedule_tool_wiring_test" "" in
  Eio.Switch.run
  @@ fun sw ->
  Eio.Switch.on_release sw (fun () -> rm_rf path);
  let config = Workspace.default_config path in
  ignore (Workspace.init config ~agent_name:(Some "schedule-test"));
  Workspace_metric_hooks.install ();
  Atomic.set Workspace_hooks.schedule_wake_target_registered_fn (fun config keeper_name ->
    match Keeper_meta_store.read_effective_meta config keeper_name with
    | Ok (Some _) -> Ok true
    | Ok None -> Ok false
    | Error detail -> Error detail);
  register_wake_target config "schedule-keeper";
  if strict_executor then
    Eio_context.with_test_env ~sw ~net:(Eio.Stdenv.net env)
      ~clock:(Eio.Stdenv.clock env) ~mono_clock:(Eio.Stdenv.mono_clock env)
      (fun () ->
         let pool = Domain_pool.create ~sw ~domain_count:1 (Eio.Stdenv.domain_mgr env) in
         Executor_pool_ref.For_testing.with_pool (Domain_pool.executor_pool pool) (fun () -> f config))
  else f config
;;

let human id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Human_operator; display_name = None }
;;

let automated id : Schedule_domain.actor =
  { id; kind = Schedule_domain.Automated_actor; display_name = None }
;;

let keeper_wake_payload message =
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc
          [ "keeper_name", `String "schedule-keeper"
          ; "message", `String message
          ] )
    ]
;;

let schedule_definition action =
  match
    List.find_opt
      (fun (definition : Tool_schemas_schedule.definition) ->
         definition.action = action)
      Tool_schemas_schedule.definitions
  with
  | Some definition -> definition
  | None -> fail "schedule definition missing"
;;

let schedule_tool_name action =
  let schema : Masc_domain.tool_schema = (schedule_definition action).schema in
  schema.name
;;

let schedule_ctx
      ?continuation_channel
      ?(caller = Tool_schedule.Named_caller "scheduler-agent")
      config
  : Tool_schedule.context
  =
  { config
  ; caller
  ; stamp_keeper_wake_result_delivery =
      (fun ~payload ->
         Schedule_payload_projection.set_keeper_wake_result_delivery
           ~payload
           ~channel:continuation_channel)
  ; admit_keeper_wake_creation = Keeper_schedule_creation_admission.run
  ; withdraw_queued_keeper_wakes = Keeper_schedule_cancel_withdrawal.run
  }
;;

let dispatch_exn ?continuation_channel ?caller config action args =
  let name = schedule_tool_name action in
  match
    Tool_schedule.dispatch
      (schedule_ctx ?continuation_channel ?caller config)
      ~name
      ~args
  with
  | Some result -> result
  | None -> fail ("schedule dispatch returned None: " ^ name)
;;

(* Creation reads the dispatch clock and refuses a due time behind it, so a
   schedule created through the tool is due in 2100 (2100-01-01T00:00:00Z).
   Tests that drive the runner create through the service, where [now] is an
   argument. *)
let future_due_at = 4_102_444_800.0

let create_args
      ?schedule_id
      ?recurrence_kind
      ?(allow_unregistered_keeper = false)
      ?(message = "scheduled keeper wake")
      ()
  =
  `Assoc
    ([ "due_at_unix", `Float future_due_at
     ; "keeper_name", `String "schedule-keeper"
     ; "message", `String message
     ]
     @ (if allow_unregistered_keeper
        then [ "allow_unregistered_keeper", `Bool true ]
        else [])
     @ (match recurrence_kind with
        | None -> []
        | Some value -> [ "recurrence_kind", `String value ])
     @
     match schedule_id with
     | None -> []
     | Some value -> [ "schedule_id", `String value ])
;;

(* The typed refusal a result carries, decoded through its owner so a test
   compares variants rather than the wire spelling. *)
let refusal_kind result =
  let open Yojson.Safe.Util in
  match Tool_result.data result |> member "error_kind" with
  | `String wire ->
    (match Schedule_contract_values.refusal_kind_of_string wire with
     | Ok kind -> Some kind
     | Error error -> fail (Schedule_contract_values.decode_error_to_string error))
  | _ -> None
;;

let check_refusal label expected result =
  check bool (label ^ ": refused") false (Tool_result.is_success result);
  match refusal_kind result with
  | Some kind when kind = expected -> ()
  | Some kind ->
    failf "%s: error_kind %s, expected %s" label
      (Schedule_contract_values.refusal_kind_to_string kind)
      (Schedule_contract_values.refusal_kind_to_string expected)
  | None ->
    failf "%s: no error_kind, expected %s (message: %s)" label
      (Schedule_contract_values.refusal_kind_to_string expected)
      (Tool_result.message result)
;;

let create_service_exn config ~schedule_id ~due_at ~payload ?recurrence ?expires_at () =
  match
    Schedule_service.create config ~runner_tick_sec ~now:100.0 ~schedule_id ~requested_at:100.0
      ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent")
      ~due_at ~payload ~source:Schedule_domain.Operator_request ?recurrence ?expires_at ()
  with
  | Ok request -> request
  | Error err -> fail (Schedule_service.service_error_to_string err)
;;

(* [required] is absent when nothing is mandatory and a list otherwise, so
   read both shapes into the one fact the callers below want. *)
let required_names (schema : Yojson.Safe.t) =
  let open Yojson.Safe.Util in
  match schema |> member "required" with
  | `Null -> []
  | value -> value |> to_list |> List.map to_string
;;

let test_flat_tool_surface () =
  let names =
    Tool_schemas_schedule.definitions
    |> List.map (fun (definition : Tool_schemas_schedule.definition) ->
      let schema : Masc_domain.tool_schema = definition.schema in
      schema.name)
  in
  check (list string) "schedule tools"
    [ "masc_schedule_create"
    ; "masc_schedule_update"
    ; "masc_schedule_list"
    ; "masc_schedule_get"
    ; "masc_schedule_cancel"
    ; "masc_schedule_note_add"
    ; "masc_schedule_notes_list"
    ]
    names;
  check (list string) "public schedule surface" names
    Tool_catalog_surfaces.public_schedule_surface_tools;
  let keeper_schedule_tools =
    Keeper_tool_descriptor.model_visible_descriptors ()
    |> List.concat_map Keeper_tool_descriptor.keeper_model_names
    |> List.filter (String.starts_with ~prefix:"masc_schedule_")
  in
  check (list string) "descriptor-projected keeper schedule surface" names
    keeper_schedule_tools;
  List.iter
    (fun name ->
       check bool ("tool_inventory includes: " ^ name) true
         (List.exists
            (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
            Config.raw_all_tool_schemas);
       check bool ("schema registered: " ^ name) true
         (List.exists
            (fun (schema : Masc_domain.tool_schema) -> String.equal schema.name name)
            Config.raw_all_tool_schemas);
       check bool ("tag registered: " ^ name) true
         (Tool_dispatch.lookup_tag name = Some Tool_dispatch.Mod_schedule))
    names;
  let create_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Create_request).schema
  in
  let open Yojson.Safe.Util in
  check bool "create schema is closed" false
    (create_schema.input_schema |> member "additionalProperties" |> to_bool);
  (* Assert the fact -- which fields the schema makes mandatory -- rather than
     the JSON shape it uses to say it. The pre-TOML builder always emitted
     [required] and defaulted it to [[]]; the TOML builder omits the key when
     nothing is required. Both are legal JSON Schema, so this test should not
     be the thing that decides between them.

     The schema once said nothing was mandatory while the runtime rejected a
     call missing keeper_name or message, so a caller reading the declaration
     and sending [{}] was following it and still refused. A Lane action now
     needs installation_id and action instead (RFC operator-quiz §4.7), so
     each call shape is one [oneOf] alternative with the fields the runtime
     needs for it. *)
  let shapes schema =
    match member "oneOf" schema with
    | `List alternatives -> List.map required_names alternatives
    | _ -> []
  in
  let wake_or_lane = [ [ "keeper_name"; "message" ]; [ "installation_id"; "action" ] ] in
  check (list string) "create requires no field outside a shape" []
    (required_names create_schema.input_schema);
  check (list (list string)) "create schema names each shape the runtime accepts" wake_or_lane
    (shapes create_schema.input_schema);
  let update_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Update_request).schema
  in
  (* The migration accepts omission after loading the schedule so it can keep
     the stored recurrence and warn before the next version requires it. *)
  check (list string) "update schema requires the stable identity"
    [ "schedule_id" ]
    (required_names update_schema.input_schema);
  check (list (list string)) "update schema names the same shapes" wake_or_lane
    (shapes update_schema.input_schema);
  let get_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Get_request).schema
  in
  check (list string) "get requires the durable schedule pointer"
    [ "schedule_id" ]
    (required_names get_schema.input_schema);
  let list_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.List_requests).schema
  in
  (* 521 of the listing calls in September sent no arguments and read every
     row. Whose rows is now a choice the call has to make. *)
  check (list string) "list requires the owner selector"
    [ "owner" ]
    (required_names list_schema.input_schema)
;;

let test_create_list_get_cancel () =
  with_config
  @@ fun config ->
  let create =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (create_args ~schedule_id:"sched-tools" ())
  in
  check bool "create succeeds" true (Tool_result.is_success create);
  let open Yojson.Safe.Util in
  check string "created status" "scheduled"
    (Tool_result.data create |> member "status" |> to_string);
  check string "created payload support" "supported"
    (Tool_result.data create |> member "payload_support" |> to_string);
  check string "no continuation stamps an explicit no-delivery policy" "none"
    (Tool_result.data create
     |> member "payload"
     |> member "body"
     |> member "result_delivery"
     |> member "policy"
     |> to_string);
  let list_result =
    dispatch_exn config Tool_schemas_schedule.List_requests
      (`Assoc [ "owner", `String "all"; "limit", `Int 10 ])
  in
  check bool "list succeeds" true (Tool_result.is_success list_result);
  check int "one schedule listed" 1
    (Tool_result.data list_result |> member "schedules" |> to_list |> List.length);
  let get_result =
    dispatch_exn config Tool_schemas_schedule.Get_request
      (`Assoc [ "schedule_id", `String "sched-tools" ])
  in
  check bool "get succeeds" true (Tool_result.is_success get_result);
  check string "get id" "sched-tools"
    (Tool_result.data get_result |> member "schedule_id" |> to_string);
  let cancel_result =
    dispatch_exn config Tool_schemas_schedule.Cancel_request
      (`Assoc
        [ "schedule_id", `String "sched-tools"
        ; "reason", `String "superseded"
        ])
  in
  check bool "cancel succeeds" true (Tool_result.is_success cancel_result);
  check string "cancelled status" "cancelled"
    (Tool_result.data cancel_result
     |> member "schedule"
     |> member "status"
     |> to_string)
;;

let test_update_keeps_public_id_and_replaces_instance () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-modify" in
  let created =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (create_args ~schedule_id ~message:"before" ())
  in
  let open Yojson.Safe.Util in
  let first_instance =
    Tool_result.data created |> member "schedule_instance_id" |> to_string
  in
  let updated =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (`Assoc
        [ "schedule_id", `String schedule_id
        ; "due_at_unix", `Float (future_due_at +. 300.0)
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "after"
        ; "recurrence_kind", `String "one_shot"
        ])
  in
  check bool "update succeeds" true (Tool_result.is_success updated);
  check string "public id remains stable" schedule_id
    (Tool_result.data updated |> member "schedule_id" |> to_string);
  check bool "definition receives a fresh instance" false
    (String.equal first_instance
       (Tool_result.data updated |> member "schedule_instance_id" |> to_string));
  let stored =
    match Schedule_store.get_schedule config ~schedule_id with
    | Some request -> request
    | None -> fail "updated schedule missing"
  in
  check (float 0.0) "new due time persisted" (future_due_at +. 300.0) stored.due_at;
  check string "new message persisted" "after"
    (Schedule_domain.payload_to_yojson stored.payload
     |> member "body"
     |> member "message"
     |> to_string);
  check int "replace does not duplicate the row" 1
    (List.length (Schedule_store.read_state config).schedules)
;;

let test_update_omitted_kind_preserves_daily () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-daily-edit" in
  let original =
    create_service_exn config ~schedule_id ~due_at:future_due_at
      ~payload:(keeper_wake_payload "daily wake")
      ~recurrence:(Schedule_domain.Daily
        { hour = 9; minute = 0; second = 0; timezone = "UTC" }) ()
  in
  let update extra =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (`Assoc
        ([ "schedule_id", `String schedule_id
         ; "due_at_unix", `Float (future_due_at +. 300.0)
         ; "keeper_name", `String "schedule-keeper"
         ; "message", `String "edited wake"
         ] @ extra))
  in
  let stored () =
    match Schedule_store.get_schedule config ~schedule_id with
    | Some request -> request
    | None -> fail "daily schedule missing"
  in
  let omitted = update [] in
  check bool "omitting kind updates the daily schedule" true (Tool_result.is_success omitted);
  let retained = stored () in
  check bool "replacement gets a new instance" false
    (String.equal original.schedule_instance_id retained.schedule_instance_id);
  check string "omission retains the stored recurrence" "daily"
    (Schedule_domain.recurrence_kind_to_string retained.recurrence);
  let explicit = update [ "recurrence_kind", `String "one_shot" ] in
  check bool "explicit one-shot replacement succeeds" true
    (Tool_result.is_success explicit);
  check string "explicit replacement is one-shot" "one_shot"
    (Schedule_domain.recurrence_kind_to_string
       (stored ()).recurrence)
;;

let test_update_omitted_kind_preserves_one_shot () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-one-shot-edit" in
  let created =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (create_args ~schedule_id ())
  in
  check bool "one-shot fixture created" true (Tool_result.is_success created);
  let updated =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (create_args ~schedule_id ~message:"edited one-shot" ())
  in
  check bool "omission updates the one-shot schedule" true
    (Tool_result.is_success updated);
  let stored = match Schedule_store.get_schedule config ~schedule_id with
    | Some request -> request
    | None -> fail "one-shot schedule missing" in
  check string "omission retains one-shot" "one_shot"
    (Schedule_domain.recurrence_kind_to_string stored.recurrence)
;;

let test_update_requires_id_and_active_row () =
  with_config
  @@ fun config ->
  let missing_id =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (create_args ())
  in
  check bool "id is required" false (Tool_result.is_success missing_id);
  check string "id rejection" "schedule_id is required"
    (Tool_result.message missing_id);
  let schedule_id = "sched-finished-modify" in
  ignore
    (dispatch_exn config Tool_schemas_schedule.Create_request
       (create_args ~schedule_id ()));
  ignore
    (dispatch_exn config Tool_schemas_schedule.Cancel_request
       (`Assoc
         [ "schedule_id", `String schedule_id
         ; "reason", `String "done"
         ]));
  let refused =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (create_args ~schedule_id ~recurrence_kind:"one_shot"
         ~message:"too late" ())
  in
  check_refusal "terminal row is immutable"
    Schedule_contract_values.Refusal_transition_refused refused;
  let open Yojson.Safe.Util in
  check string "refusal names the status the row is in" "cancelled"
    (Tool_result.data refused |> member "current_status" |> to_string);
  check string "refusal names the attempted transition" "modify"
    (Tool_result.data refused |> member "attempted" |> to_string)
;;

let test_content_edit_preserves_due_and_recurrence () =
  List.iter
    (fun (schedule_id, due_at, recurrence) ->
       with_config @@ fun config ->
       let original = create_service_exn config ~schedule_id ~due_at
           ~payload:(keeper_wake_payload "before") ~recurrence () in
       let args extra = `Assoc
           ([ "schedule_id", `String schedule_id
            ; "keeper_name", `String "schedule-keeper"
            ; "message", `String "after" ] @ extra) in
       let updated = dispatch_exn config Tool_schemas_schedule.Update_request (args []) in
       check bool "content-only update succeeds" true (Tool_result.is_success updated);
       let stored = match Schedule_store.get_schedule config ~schedule_id with
         | Some request -> request | None -> fail "content edit lost schedule" in
       check (float 0.) "exact due time preserved" original.due_at stored.due_at;
       check bool "recurrence preserved" true (original.recurrence = stored.recurrence);
       check bool "new definition has its own instance" false
         (String.equal original.schedule_instance_id stored.schedule_instance_id);
       check string "content changed" "after"
         Yojson.Safe.Util.(Schedule_domain.payload_to_yojson stored.payload
           |> member "body" |> member "message" |> to_string);
       let malformed = dispatch_exn config Tool_schemas_schedule.Update_request
           (args ["due_at_unix", `String "later"]) in
       check bool "malformed due is not treated as omitted" false
         (Tool_result.is_success malformed);
       check_refusal "explicit one-shot change still requires a due time"
         Schedule_contract_values.Refusal_due_input_missing
         (dispatch_exn config Tool_schemas_schedule.Update_request
            (args ["recurrence_kind", `String "one_shot"])))
    [ "content-future", future_due_at, Schedule_domain.One_shot
    ; "content-overdue", 200., Schedule_domain.One_shot
    ; "content-daily", future_due_at,
        Schedule_domain.Daily {hour=9; minute=0; second=0; timezone="UTC"} ]
;;

(* The expiry is part of the timing a content edit keeps. A content edit that
   dropped it would turn an expiring schedule into one that never reaches
   [Expired]. An expiry sent on the call wins, and an update that also sends a
   due input replaces expiry, so omitting the expiry there still clears
   it, as the tool description says. *)
let test_content_edit_keeps_expiry () =
  with_config @@ fun config ->
  let schedule_id = "content-edit-expiring" in
  let expires_at = future_due_at +. 3600. in
  let stored_expiry () =
    match Schedule_store.get_schedule config ~schedule_id with
    | Some request -> request.expires_at
    | None -> fail "expiring schedule missing"
  in
  let update extra =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (`Assoc
        ([ "schedule_id", `String schedule_id
         ; "keeper_name", `String "schedule-keeper"
         ; "message", `String "after" ] @ extra))
  in
  ignore
    (create_service_exn config ~schedule_id ~due_at:future_due_at ~expires_at
       ~payload:(keeper_wake_payload "before") ());
  check bool "content-only update succeeds" true
    (Tool_result.is_success (update []));
  check (option (float 0.)) "content edit keeps the stored expiry"
    (Some expires_at) (stored_expiry ());
  let later_expiry = expires_at +. 60. in
  check bool "content edit with an expiry succeeds" true
    (Tool_result.is_success
       (update [ "expires_at_unix", `Float later_expiry ]));
  check (option (float 0.)) "an expiry on the call replaces the stored one"
    (Some later_expiry) (stored_expiry ());
  check bool "retiming update succeeds" true
    (Tool_result.is_success
       (update [ "due_at_unix", `Float (future_due_at +. 7200.) ]));
  check (option (float 0.)) "a full replacement without an expiry clears it"
    None (stored_expiry ())
;;

let test_content_edit_preserves_concurrently_changed_due () =
  with_config @@ fun config ->
  let schedule_id = "content-edit-retimed" in
  let original = create_service_exn config ~schedule_id ~due_at:future_due_at
      ~payload:(keeper_wake_payload "before") () in
  let latest_due = future_due_at +. 600. in
  let latest_recurrence = Schedule_domain.Daily
      {hour=10; minute=0; second=0; timezone="UTC"} in
  let context = { (schedule_ctx config) with
    admit_keeper_wake_creation = (fun _config ~keeper_name:_ write ->
      match Schedule_service.update config ~authority:Schedule_store.Operator_authority ~now:100. ~runner_tick_sec ~schedule_id
          ~requested_by:original.requested_by ~scheduled_by:original.scheduled_by
          ~due_at:latest_due ~payload:(Schedule_domain.payload_to_yojson original.payload)
          ~source:original.source ~recurrence:latest_recurrence () with
      | Error error -> Error error
      | Ok _ -> write ()) } in
  let result = match Tool_schedule.dispatch context
      ~name:(schedule_tool_name Tool_schemas_schedule.Update_request)
      ~args:(`Assoc ["schedule_id",`String schedule_id;
        "keeper_name",`String "schedule-keeper"; "message",`String "after"]) with
    | Some result -> result | None -> fail "update tool missing" in
  check bool "content update succeeds after retiming" true (Tool_result.is_success result);
  let stored = match Schedule_store.get_schedule config ~schedule_id with
    | Some request -> request | None -> fail "concurrent edit lost schedule" in
  check (float 0.) "latest committed due wins over observed snapshot" latest_due stored.due_at;
  check bool "latest committed recurrence survives content edit" true
    (latest_recurrence = stored.recurrence);
  check string "new content is committed" "after"
    Yojson.Safe.Util.(Schedule_domain.payload_to_yojson stored.payload
      |> member "body" |> member "message" |> to_string)
;;

(* Both edits use the public tool. U1 has already observed the old recurrence
   when its intake callback completes U2's explicit cadence change. U1 must
   replace the due time it actually supplied, not restore the old cadence.
   Explicit due inputs resolve independently of recurrence/calendar timezone. *)
let check_due_edit_keeps_concurrent_recurrence
    ~schedule_id ~initial_fields ~latest_fields ~latest_recurrence
    ~due_input ~expected_due_at =
  with_config @@ fun config ->
  let created = dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc ([ "schedule_id", `String schedule_id
               ; "keeper_name", `String "schedule-keeper"
               ; "message", `String "original cadence"
               ; "due_at_unix", `Float future_due_at
               ; "expires_at_unix", `Float (future_due_at +. 3600.) ] @ initial_fields)) in
  check bool "original cadence created" true (Tool_result.is_success created);
  let concurrent_instance = ref None in
  let context = { (schedule_ctx config) with
    admit_keeper_wake_creation = (fun _config ~keeper_name:_ write ->
      let changed = dispatch_exn config Tool_schemas_schedule.Update_request
          (`Assoc ([ "schedule_id", `String schedule_id
                   ; "keeper_name", `String "schedule-keeper"
                   ; "message", `String "concurrent cadence change"
                   ; "due_at_unix", `Float (future_due_at +. 600.)
                   ; "expires_at_unix", `Float (future_due_at +. 7200.) ] @ latest_fields)) in
      check bool "explicit concurrent recurrence update commits" true
        (Tool_result.is_success changed);
      let committed = match Schedule_store.get_schedule config ~schedule_id with
        | Some row -> row | None -> fail "concurrent update lost schedule" in
      check bool "latest recurrence established before U1 resumes" true
        (committed.recurrence = latest_recurrence);
      concurrent_instance := Some committed.schedule_instance_id;
      write ()) } in
  let updated = match Tool_schedule.dispatch context
      ~name:(schedule_tool_name Tool_schemas_schedule.Update_request)
      ~args:(`Assoc [ "schedule_id", `String schedule_id
                   ; "keeper_name", `String "schedule-keeper"
                   ; "message", `String "due-only replacement"
                   ; due_input ]) with
    | Some result -> result | None -> fail "update tool missing" in
  check bool "due-only replacement succeeds" true (Tool_result.is_success updated);
  let stored = match Schedule_store.get_schedule config ~schedule_id with
    | Some row -> row | None -> fail "due-only replacement lost schedule" in
  check (float 0.) "caller's explicit due time wins" expected_due_at stored.due_at;
  check bool "latest recurrence survives omitted kind" true
    (stored.recurrence = latest_recurrence);
  check (option (float 0.)) "due-only omission still removes expiry" None stored.expires_at;
  check string "caller's replacement content is saved" "due-only replacement"
    Yojson.Safe.Util.(Schedule_domain.payload_to_yojson stored.payload
      |> member "body" |> member "message" |> to_string);
  (match !concurrent_instance with
   | Some instance -> check bool "replacement receives its own instance" false
       (String.equal instance stored.schedule_instance_id)
   | None -> fail "concurrent update was never applied")
;;

let test_due_edit_keeps_concurrent_daily_to_interval () =
  check_due_edit_keeps_concurrent_recurrence
    ~schedule_id:"due-edit-daily-to-interval"
    ~initial_fields:[ "recurrence_kind", `String "daily"
                    ; "recurrence_hour", `Int 9
                    ; "recurrence_minute", `Int 0
                    ; "recurrence_timezone", `String "Asia/Seoul" ]
    ~latest_fields:[ "recurrence_kind", `String "interval"; "recurrence_interval_sec", `Int 60 ]
    ~latest_recurrence:(Schedule_domain.Interval { interval_sec = 60 })
    ~due_input:("due_at_iso", `String "2100-01-01T09:20:00+09:00")
    ~expected_due_at:(future_due_at +. 1200.)
;;

let test_due_edit_keeps_concurrent_interval_to_one_shot () =
  check_due_edit_keeps_concurrent_recurrence
    ~schedule_id:"due-edit-interval-to-one-shot"
    ~initial_fields:[ "recurrence_kind", `String "interval"; "recurrence_interval_sec", `Int 60 ]
    ~latest_fields:[ "recurrence_kind", `String "one_shot" ]
    ~latest_recurrence:Schedule_domain.One_shot
    ~due_input:("due_at_unix", `Float (future_due_at +. 1200.))
    ~expected_due_at:(future_due_at +. 1200.)
;;

(* The checkpoint encoder rejects an object that binds the same key twice,
   and it runs after the tool has already succeeded: a duplicate key in a
   schedule result failed the whole turn at
   [Checkpoint v11 message[_].content[_].json], which is how one keeper
   lost 12 consecutive turns on 2026-08-29 ("recurrence" was emitted by
   [schedule_request_to_yojson] and appended a second time by
   [schedule_request_json]). This asserts the same rule the encoder applies,
   on every schedule result shape, so the next appended field that shadows a
   base one fails here instead of on a live keeper. *)
let check_no_duplicate_keys label json =
  match Agent_core.Execution_json.validate ~context:label json with
  | Ok () -> ()
  | Error error ->
    fail (Agent_core.Execution_json.validation_error_to_string error)
;;

let test_results_survive_the_checkpoint_encoder () =
  with_config
  @@ fun config ->
  let create =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (create_args ~schedule_id:"sched-canonical" ())
  in
  check_no_duplicate_keys "create result" (Tool_result.data create);
  let update =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (create_args ~schedule_id:"sched-canonical" ~recurrence_kind:"one_shot"
         ~message:"updated" ())
  in
  check_no_duplicate_keys "update result" (Tool_result.data update);
  let list_result =
    dispatch_exn config Tool_schemas_schedule.List_requests
      (`Assoc [ "owner", `String "all"; "limit", `Int 10 ])
  in
  check_no_duplicate_keys "list result" (Tool_result.data list_result);
  let get_result =
    dispatch_exn config Tool_schemas_schedule.Get_request
      (`Assoc [ "schedule_id", `String "sched-canonical" ])
  in
  check_no_duplicate_keys "get result" (Tool_result.data get_result);
  let cancel_result =
    dispatch_exn config Tool_schemas_schedule.Cancel_request
      (`Assoc
        [ "schedule_id", `String "sched-canonical"
        ; "reason", `String "superseded"
        ])
  in
  check_no_duplicate_keys "cancel result" (Tool_result.data cancel_result)
;;

let test_creation_boundary_owns_result_delivery_destination () =
  with_config
  @@ fun config ->
  let channel =
    match Keeper_continuation_channel.dashboard ~thread_id:"dashboard-thread-42" with
    | Ok channel -> channel
    | Error detail -> fail detail
  in
  (* A caller used to be able to send a result_delivery of its own inside the
     payload envelope, and the boundary overwrote it. The envelope is gone, so
     there is no argument that names a destination -- the route below comes
     from the creating turn's continuation and nowhere else. *)
  let result =
    dispatch_exn
      ~continuation_channel:channel
      config
      Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-owned-result-destination"
        ; "due_at_unix", `Float future_due_at
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "return the result to the invoking thread"
        ])
  in
  check bool "routed schedule creation succeeds" true
    (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  let stored_delivery =
    Tool_result.data result
    |> member "payload"
    |> member "body"
    |> member "result_delivery"
  in
  check string "creation boundary selects reply-to-origin" "reply_to_origin"
    (stored_delivery |> member "policy" |> to_string);
  check bool "exact invoking route is persisted" true
    (Yojson.Safe.equal
       (stored_delivery |> member "channel")
       (Keeper_continuation_channel.to_yojson channel));
  let stored_body_fields =
    Tool_result.data result
    |> member "payload"
    |> member "body"
    |> to_assoc
  in
  check int "forged duplicate delivery fields are replaced once" 1
    (List.fold_left
       (fun count (name, _) ->
          if String.equal name "result_delivery" then count + 1 else count)
       0
       stored_body_fields);
  let request =
    match
      Schedule_store.get_schedule
        config
        ~schedule_id:"sched-owned-result-destination"
    with
    | Some request -> request
    | None -> fail "routed schedule was not persisted"
  in
  (match Schedule_payload_projection.result_delivery request with
   | Ok (Some persisted) ->
     check bool "typed projection preserves exact route" true
       (Keeper_continuation_channel.same_route channel persisted)
   | Ok None -> fail "routed schedule lost its result destination"
   | Error detail -> fail detail)
;;

(* An edit from a surface with no conversation (the TUI and dashboard routes
   stamp no channel) used to replace the creator's route with [none], so the
   wake's result stopped reaching the thread that asked for it. *)
let test_update_keeps_the_creators_result_delivery () =
  with_config
  @@ fun config ->
  let channel =
    match Keeper_continuation_channel.dashboard ~thread_id:"dashboard-thread-77" with
    | Ok channel -> channel
    | Error detail -> fail detail
  in
  let schedule_id = "sched-update-keeps-result-destination" in
  let created =
    dispatch_exn
      ~continuation_channel:channel
      config
      Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String schedule_id
        ; "due_at_unix", `Float future_due_at
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "before"
        ])
  in
  check bool "routed schedule creation succeeds" true (Tool_result.is_success created);
  let updated =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (`Assoc
        [ "schedule_id", `String schedule_id
        ; "due_at_unix", `Float (future_due_at +. 300.0)
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "after"
        ; "recurrence_kind", `String "one_shot"
        ])
  in
  check bool "update without a channel succeeds" true (Tool_result.is_success updated);
  let request =
    match Schedule_store.get_schedule config ~schedule_id with
    | Some request -> request
    | None -> fail "updated schedule was not persisted"
  in
  match Schedule_payload_projection.result_delivery request with
  | Ok (Some persisted) ->
    check bool "the creator's route survives the edit" true
      (Keeper_continuation_channel.same_route channel persisted)
  | Ok None -> fail "the edit dropped the creator's result destination"
  | Error detail -> fail detail
;;

let test_get_recurring_schedule_after_accept_advance () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-recurring-get-after-accept" in
  let request : Schedule_domain.schedule_request =
    create_service_exn
      config
      ~schedule_id
      ~due_at:200.0
      ~payload:(keeper_wake_payload "run every minute")
      ~recurrence:(Schedule_domain.Interval { interval_sec = 60 })
      ()
  in
  (match Schedule_store.refresh_due config ~now:200.0
    ~retention_days:Schedule_store.terminal_schedule_retention_days with
   | Ok _ -> ()
   | Error err -> fail (Schedule_store.store_error_to_string err));
  let started =
    match Schedule_store.start_due_candidate config ~now:201.0 ~candidate:request with
    | Ok started -> started
    | Error err -> fail (Schedule_store.store_error_to_string err)
  in
  let advanced : Schedule_domain.schedule_request =
    match Schedule_store.accept_running config ~now:202.0 ~attempt:started.attempt () with
    | Ok stored -> stored
    | Error err -> fail (Schedule_store.store_error_to_string err)
  in
  check bool "recurring request advanced past the fired occurrence" true
    (advanced.due_at > request.due_at);
  let get_result =
    dispatch_exn config Tool_schemas_schedule.Get_request
      (`Assoc [ "schedule_id", `String schedule_id ])
  in
  check bool "advanced recurring request remains readable" true
    (Tool_result.is_success get_result);
  let open Yojson.Safe.Util in
  check (float 0.001) "get returns the current next occurrence" advanced.due_at
    (Tool_result.data get_result |> member "due_at" |> to_float)
;;

let test_create_accepts_explicit_iso8601_offset () =
  with_config
  @@ fun config ->
  let create ~schedule_id ~due_at_iso =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String schedule_id
        ; "due_at_iso", `String due_at_iso
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "run at nine in Korea"
        ])
  in
  let result =
    create
      ~schedule_id:"sched-kst-offset"
      ~due_at_iso:"2099-08-02T09:00:00+09:00"
  in
  check bool "explicit ISO-8601 offset accepted" true (Tool_result.is_success result);
  let open Yojson.Safe.Util in
  check string "offset normalized to UTC" "2099-08-02T00:00:00Z"
    (Tool_result.data result |> member "due_at_iso" |> to_string);
  let west =
    create
      ~schedule_id:"sched-west-offset"
      ~due_at_iso:"2099-01-02T00:30:00-03:30"
  in
  check bool "negative ISO-8601 offset accepted" true (Tool_result.is_success west);
  check string "negative offset normalized to UTC" "2099-01-02T04:00:00Z"
    (Tool_result.data west |> member "due_at_iso" |> to_string);
  let fractional =
    create
      ~schedule_id:"sched-fractional-offset"
      ~due_at_iso:"2099-01-02T09:00:00.123456789+09:00"
  in
  check bool "fractional RFC 3339 accepted" true (Tool_result.is_success fractional);
  check string "fraction normalized to whole-second UTC" "2099-01-02T00:00:00Z"
    (Tool_result.data fractional |> member "due_at_iso" |> to_string);
  let near_boundary =
    create
      ~schedule_id:"sched-fraction-boundary"
      ~due_at_iso:"2099-01-02T09:00:00.999999999999+09:00"
  in
  check bool "near-boundary fraction accepted" true
    (Tool_result.is_success near_boundary);
  check string "fraction truncates before float conversion" "2099-01-02T00:00:00Z"
    (Tool_result.data near_boundary |> member "due_at_iso" |> to_string);
  let non_rfc3339 =
    create
      ~schedule_id:"sched-non-rfc3339-offset"
      ~due_at_iso:"2099-01-02T09:00:00+0900"
  in
  check bool "offset without colon rejected" false (Tool_result.is_success non_rfc3339);
  let invalid =
    create
      ~schedule_id:"sched-invalid-date"
      ~due_at_iso:"2099-02-29T09:00:00+09:00"
  in
  check bool "invalid civil date rejected" false (Tool_result.is_success invalid);
  check bool "invalid date error is explicit" true
    (String_util.contains_substring
       (Tool_result.message invalid)
       "due_at_iso must be")
;;

let test_removed_convenience_input_does_not_synthesize_payload () =
  with_config
  @@ fun config ->
  let result =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-removed-convenience"
        ; "due_at_unix", `Float future_due_at
        ; "board_content", `String "must not become a scheduled product effect"
        ])
  in
  check bool "removed convenience input rejected" false (Tool_result.is_success result);
  check bool "neutral payload contract names the missing field" true
    (String_util.contains_substring
       (Tool_result.message result)
       "keeper_name and message");
  check int "removed convenience input is not persisted" 0
    (List.length (Schedule_store.read_state config).schedules)
;;

let test_unregistered_wake_target_rejected () =
  with_config
  @@ fun config ->
  let ghost_args allow =
    `Assoc
      ([ "schedule_id", `String "sched-ghost-target"
       ; "due_at_unix", `Float future_due_at
       ; "keeper_name", `String "ghost-keeper"
       ; "message", `String "wake for a keeper that does not exist"
       ]
       @ if allow then [ "allow_unregistered_keeper", `Bool true ] else [])
  in
  let rejected = dispatch_exn config Tool_schemas_schedule.Create_request (ghost_args false) in
  check bool "unregistered wake target rejected" false (Tool_result.is_success rejected);
  check bool "rejection names the missing keeper metadata" true
    (String_util.contains_substring
       (Tool_result.message rejected)
       "has no durable metadata");
  check int "rejected schedule is not persisted" 0
    (List.length (Schedule_store.read_state config).schedules);
  let allowed = dispatch_exn config Tool_schemas_schedule.Create_request (ghost_args true) in
  check bool "explicit opt-in schedules the unregistered target" true
    (Tool_result.is_success allowed);
  check int "opted-in schedule persisted" 1
    (List.length (Schedule_store.read_state config).schedules)
;;

(* The creation tool no longer takes a kind -- the runtime stamps the one that
   exists -- so an unsupported kind cannot arrive through it. The validator
   still takes raw JSON and is still what a second producer would go through,
   so its rejection is checked where it lives rather than through a caller
   that can no longer express the input. *)
let test_unknown_payload_kind_is_rejected_by_the_validator () =
  let rejection =
    Schedule_payload_projection.validate_request_payload_for_creation_detailed
      ~payload:
        (`Assoc [ "kind", `String "unknown.payload"; "body", `Assoc [] ])
  in
  match rejection with
  | Ok () -> fail "unsupported kind was accepted"
  | Error rejection ->
    check bool "typed error names unsupported kind" true
      (String_util.contains_substring
         (Schedule_payload_projection.creation_rejection_message rejection)
         "unsupported schedule payload kind: unknown.payload")
;;

(* The body used to take anything: an unknown key was persisted at creation
   and then dropped by the consumer, which is how a live schedule ended up
   carrying a channel_id no dispatch ever saw (#25689). The body is now built
   by the runtime from declared arguments, so the same key arrives as an
   undeclared argument and the tool's own [additional_properties = false] is
   what refuses it.

   Checked through [Tool_input_validation] rather than [Tool_schedule.dispatch]
   because that is where the refusal happens on every path a caller can reach:
   the MCP server runs it as a pre-hook, and the Keeper descriptor and plan
   paths call it directly. [Tool_schedule.dispatch] is below that line -- the
   test helper calls it with no validation in front, which no caller does. *)
let test_unknown_field_is_rejected_before_persistence () =
  let create_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Create_request).schema
  in
  let validated =
    Tool_input_validation.validate_args
      ~schema:create_schema.input_schema
      ~name:"masc_schedule_create"
      ~args:
        (`Assoc
          [ "schedule_id", `String "sched-unknown-body-field"
          ; "due_at_unix", `Float future_due_at
          ; "keeper_name", `String "alpha"
          ; "message", `String "wake up"
          ; "channel_id", `String "C123"
          ])
      ()
  in
  match validated with
  | Ok _ -> fail "an undeclared field was accepted"
  | Error rejection ->
    check bool "the error names the field" true
      (String_util.contains_substring (Tool_result.message rejection) "channel_id")
;;

(* An empty call was schema-valid while the runtime refused it, and callers
   sent one: 17 of the recorded masc_schedule_create calls carried no
   arguments at all. Now the same boundary that runs before dispatch says
   which two are missing. *)
let test_empty_call_is_rejected_by_name () =
  let create_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Create_request).schema
  in
  match
    Tool_input_validation.validate_args
      ~schema:create_schema.input_schema
      ~name:"masc_schedule_create"
      ~args:(`Assoc [])
      ()
  with
  | Ok _ -> fail "an empty call was accepted"
  | Error rejection ->
    let message = Tool_result.message rejection in
    check bool "the error names keeper_name" true
      (String_util.contains_substring message "keeper_name");
    check bool "the error names message" true
      (String_util.contains_substring message "message")
;;

let test_known_fields_still_create () =
  with_config
  @@ fun config ->
  let result =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-known-body-fields"
        ; "due_at_unix", `Float future_due_at
        ; "keeper_name", `String "alpha"
        ; "message", `String "wake up"
        ; "title", `String "a title"
        ; "urgency", `String "normal"
        ; "allow_unregistered_keeper", `Bool true
        ])
  in
  check bool "every declared field is accepted" true
    (Tool_result.is_success result)
;;

let test_payload_contracts_are_schema_only () =
  let contracts =
    Schedule_payload_projection.supported_contracts_to_yojson ()
    |> Yojson.Safe.Util.to_list
  in
  check (list string) "a contract per supported kind"
    [ Schedule_supported_kinds.keeper_wake; Schedule_supported_kinds.lane_act ]
    (List.map (fun contract -> Yojson.Safe.Util.(contract |> member "kind" |> to_string)) contracts);
  List.iter
    (fun contract ->
       let open Yojson.Safe.Util in
       (* kind, creation_contract, dispatch_contract. [dispatch_tool] was the
          fourth until #31712 removed it as a key nothing read. *)
       check int "contract field count" 3
         (contract |> to_assoc |> List.length);
       check string "creation contract" "per_kind_validator_required"
         (contract |> member "creation_contract" |> to_string);
       check string "dispatch contract" "consumer_supported"
         (contract |> member "dispatch_contract" |> to_string))
    contracts
;;

let test_keeper_wake_schema_validation () =
  with_config
  @@ fun config ->
  let valid =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-wake"
        ; "due_at_unix", `Float future_due_at
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "run maintenance"
        ; "urgency", `String "normal"
        ])
  in
  check bool "valid wake accepted" true (Tool_result.is_success valid);
  let invalid =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-wake-invalid"
        ; "due_at_unix", `Float future_due_at
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "run maintenance"
        ; "urgency", `String "urgent-ish"
        ])
  in
  check bool "invalid urgency rejected" false (Tool_result.is_success invalid);
  check bool "invalid urgency visible" true
    (String_util.contains_substring
       (Tool_result.message invalid)
       "unknown urgency: urgent-ish")
;;

(* A Lane action names its installation and action instead of a Keeper and a
   message (RFC operator-quiz §4.7). The fields name the kind; fields of both
   kinds, or of neither, are refused rather than guessed. *)
let test_lane_act_schedule_is_created_from_its_own_fields () =
  with_config
  @@ fun config ->
  let create schedule_id fields =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc ([ "schedule_id", `String schedule_id; "due_at_unix", `Float future_due_at ] @ fields))
  in
  let compose = `Assoc [ "kind", `String "compose" ] in
  let created =
    create "sched-lane" [ "installation_id", `String "operator-quiz"; "action", compose ]
  in
  check bool "a Lane action is created" true (Tool_result.is_success created);
  (match
     List.find_opt
       (fun (request : Schedule_domain.schedule_request) ->
          String.equal request.schedule_id "sched-lane")
       (Schedule_store.read_state config).schedules
   with
   | Some request ->
     check bool "its payload is masc.lane_act with exactly its fields" true
       (Yojson.Safe.equal
          (Schedule_domain.payload_to_yojson request.payload)
          (`Assoc
             [ "kind", `String Schedule_supported_kinds.lane_act
             ; "body", `Assoc [ "installation_id", `String "operator-quiz"; "action", compose ] ]))
   | None -> fail "the Lane action schedule was not stored");
  let refused label fields =
    check bool label false (Tool_result.is_success (create ("sched-" ^ label) fields))
  in
  refused "both-kinds"
    [ "installation_id", `String "operator-quiz"; "action", compose
    ; "keeper_name", `String "schedule-keeper"; "message", `String "run" ];
  refused "neither-kind" [];
  refused "action-not-an-object"
    [ "installation_id", `String "operator-quiz"; "action", `String "compose" ];
  refused "blank-installation" [ "installation_id", `String " "; "action", compose ];
  (* The boundary every MCP and Keeper call crosses first reads the same
     shapes from the schema. *)
  let create_schema : Masc_domain.tool_schema =
    (schedule_definition Tool_schemas_schedule.Create_request).schema
  in
  let admitted fields =
    Result.is_ok
      (Tool_input_validation.validate_args ~schema:create_schema.input_schema
         ~name:"masc_schedule_create"
         ~args:(`Assoc ([ "due_at_unix", `Float future_due_at ] @ fields)) ())
  in
  check bool "the schema admits a Lane action" true
    (admitted [ "installation_id", `String "operator-quiz"; "action", compose ]);
  check bool "the schema refuses fields of both kinds" false
    (admitted
       [ "installation_id", `String "operator-quiz"; "action", compose
       ; "keeper_name", `String "schedule-keeper"; "message", `String "run" ]);
  check bool "the schema refuses a Lane action with a wake title" false
    (admitted
       [ "installation_id", `String "operator-quiz"; "action", compose; "title", `String "t" ])
;;

let test_due_signal_and_dashboard_projection () =
  with_config
  @@ fun config ->
  let request =
    create_service_exn config ~schedule_id:"sched-signal" ~due_at:200.0
      ~payload:(keeper_wake_payload "signal me") ()
  in
  let tick =
    match Schedule_runner.tick ~pending_settlements:[] config ~now:201.0
      ~retention_days:Schedule_store.terminal_schedule_retention_days with
    | Ok result -> result
    | Error err -> fail (Schedule_runner.tick_failure_to_string err)
  in
  check int "one signal" 1 (List.length tick.emitted);
  let signal = List.hd tick.emitted in
  check string "signal kind" "schedule.due_candidate"
    (Schedule_runner.signal_kind_to_string signal.kind);
  check string "signal request" request.schedule_id signal.schedule_id;
  check string "signal schedule instance" request.schedule_instance_id
    signal.schedule_instance_id;
  let signal_json =
    match
      Dated_jsonl.read_recent
        (Schedule_runner.signal_store config)
        1
    with
    | [ row ] -> row
    | rows -> failf "expected one persisted wake signal, got %d" (List.length rows)
  in
  check int "signal field count" 8
    (Yojson.Safe.Util.to_assoc signal_json |> List.length);
  (match Schedule_runner.wake_signal_of_yojson signal_json with
   | Ok persisted ->
     check string "persisted signal request" signal.schedule_id persisted.schedule_id
   | Error detail -> failf "persisted wake signal did not decode: %s" detail);
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  check string "dashboard status" "ok" (dashboard |> member "status" |> to_string);
  check string "dashboard fsm" "due"
    (dashboard |> member "fsm" |> member "state" |> to_string);
  let row =
    match dashboard |> member "requests" |> to_list with
    | [ row ] -> row
    | rows -> failf "expected one dashboard row, got %d" (List.length rows)
  in
  check string "stored status is the dashboard SSOT" "due"
    (row |> member "status" |> to_string);
  check string "payload support" "supported"
    (row |> member "payload_support" |> to_string);
  check string "display target keeps its keeper: prefix" "keeper:schedule-keeper"
    (row |> member "payload_target" |> to_string);
  check string "bare keeper name rides its own field" "schedule-keeper"
    (row |> member "payload_keeper_name" |> to_string);
  check string "exact editable message is not truncated" "signal me"
    (row |> member "payload" |> member "body" |> member "message" |> to_string)
;;

let test_schedule_store_error_is_explicit () =
  with_config
  @@ fun config ->
  Workspace_core.write_text
    config
    (Filename.concat (Workspace_utils.masc_dir config) "schedules.json")
    "{not-json";
  let result =
    dispatch_exn config Tool_schemas_schedule.List_requests
      (`Assoc [ "owner", `String "all" ])
  in
  check bool "list fails" false (Tool_result.is_success result);
  check bool "store failure visible" true
    (String_util.contains_substring
       (Tool_result.message result)
       "schedule store read failed")
;;

let test_keeper_wake_target_validation_is_inside_creation_fence () =
  with_config
  @@ fun config ->
  let fence_active = ref false in
  let validation_saw_fence = ref false in
  let registered_target_check =
    Atomic.get Workspace_hooks.schedule_wake_target_registered_fn
  in
  Atomic.set Workspace_hooks.schedule_wake_target_registered_fn
    (fun config keeper_name ->
       if !fence_active then validation_saw_fence := true;
       registered_target_check config keeper_name);
  let admit_keeper_wake_creation config ~keeper_name create =
    Keeper_schedule_creation_admission.run config ~keeper_name (fun () ->
      fence_active := true;
      Fun.protect ~finally:(fun () -> fence_active := false) create)
  in
  let ctx : Tool_schedule.context =
    { config
    ; caller = Tool_schedule.Named_caller "scheduler-agent"
    ; stamp_keeper_wake_result_delivery =
        (fun ~payload ->
           Schedule_payload_projection.set_keeper_wake_result_delivery
             ~payload
             ~channel:None)
    ; admit_keeper_wake_creation
    ; withdraw_queued_keeper_wakes = Keeper_schedule_cancel_withdrawal.run
    }
  in
  Fun.protect
    ~finally:(fun () ->
      Atomic.set Workspace_hooks.schedule_wake_target_registered_fn
        registered_target_check)
    (fun () ->
       let result =
         match
           Tool_schedule.dispatch
             ctx
             ~name:(schedule_tool_name Tool_schemas_schedule.Create_request)
             ~args:(create_args ~schedule_id:"sched-fenced-validation" ())
         with
         | Some result -> result
         | None -> fail "schedule dispatch returned None"
       in
       check bool "fenced schedule creation succeeds" true
         (Tool_result.is_success result);
       check bool "target validation ran inside creation fence" true
         !validation_saw_fence)
;;

let test_keeper_wake_creation_respects_shutdown_fence () =
  with_config
  @@ fun config ->
  let keeper_name = "schedule-keeper" in
  let base_path = config.Workspace.base_path in
  let operation_id = Keeper_shutdown_types.Operation_id.generate () in
  (match
     Keeper_shutdown_intake_fence.begin_shutdown
       ~base_path
       ~keeper_name
       ~operation_id
   with
   | Keeper_shutdown_intake_fence.Reserved _ -> ()
   | Keeper_shutdown_intake_fence.Already_reserved _ ->
     fail "fresh shutdown fence was already reserved");
  Fun.protect
    ~finally:(fun () ->
      ignore
        (Keeper_shutdown_intake_fence.rollback_shutdown
           ~base_path
           ~keeper_name
           ~operation_id
         : Keeper_shutdown_intake_fence.rollback_result))
    (fun () ->
       let result =
         dispatch_exn config Tool_schemas_schedule.Create_request
           (create_args
              ~schedule_id:"sched-shutdown-fenced"
              ~allow_unregistered_keeper:true
              ())
       in
       check bool "shutdown-fenced schedule creation fails" false
         (Tool_result.is_success result);
       check string "shutdown fence failure is explicit"
         (Printf.sprintf
            "schedule creation rejected by Keeper shutdown fence keeper=%s operation=%s"
            keeper_name
            (Keeper_shutdown_types.Operation_id.to_string operation_id))
         (Tool_result.message result);
       check int "shutdown-fenced schedule is not persisted" 0
         (List.length (Schedule_store.read_state config).schedules))
;;

(* A schedule-ledger read failure must reach the operator as "we could not
   read it", never as zero schedules. The projection reports it as a typed
   fact: status unknown, every count null, and the reason carried alongside. *)
let test_projection_reports_read_failure_as_unknown () =
  with_config
  @@ fun config ->
  Workspace_core.write_text
    config
    (Filename.concat (Workspace_utils.masc_dir config) "schedules.json")
    "{not-json";
  let dashboard =
    Server_dashboard_schedule_projection.scheduled_automation_dashboard_json config
  in
  let open Yojson.Safe.Util in
  check string "status is unknown" "unknown"
    (dashboard |> member "status" |> to_string);
  check bool "store is not claimed as known" false
    (dashboard |> member "schedule_store_known" |> to_bool);
  check bool "read error is reported" true
    (String_util.contains_substring
       (dashboard |> member "schedule_store_read_error" |> to_string)
       "schedule store read failed");
  check bool "counts stay null rather than zero" true
    (dashboard |> member "counts" = `Null);
  check bool "request_count stays null rather than zero" true
    (dashboard |> member "request_count" = `Null);
  check bool "fsm active_count stays null rather than zero" true
    (dashboard |> member "fsm" |> member "active_count" = `Null)
;;

(* The projection used to ride along inside the tool inventory, so any surface
   that needed schedule state pulled the whole tool registry. It now has its
   own route and must not reappear as a nested field. *)
let test_tools_response_no_longer_carries_the_projection () =
  with_config
  @@ fun config ->
  let tools = Server_dashboard_http_runtime_info.dashboard_tools_http_json config in
  let fields =
    match tools with
    | `Assoc fields -> List.map fst fields
    | _ -> failf "tools projection is not an object"
  in
  check bool "scheduled_automation is not nested in tools" false
    (List.mem "scheduled_automation" fields)
;;

let test_tool_response_carries_structured_recurrence () =
  with_config
  @@ fun config ->
  (* The dashboard projection and the tool response describe the same
     `schedule_request`. Sending only `recurrence_kind` here made the client
     rebuild the structure from flattened strings, with an unknown-shape
     fallback at the end of that chain. The full request is
     masc_schedule_get's; a listing row carries the summary sentence. *)
  let recurrence = Schedule_domain.Interval { interval_sec = 60 } in
  let _request =
    create_service_exn
      config
      ~schedule_id:"sched-structured-recurrence"
      ~due_at:200.0
      ~payload:(keeper_wake_payload "every minute")
      ~recurrence
      ()
  in
  let got =
    dispatch_exn config Tool_schemas_schedule.Get_request
      (`Assoc [ "schedule_id", `String "sched-structured-recurrence" ])
  in
  let open Yojson.Safe.Util in
  let entry = Tool_result.data got in
  check bool "recurrence is present" true (entry |> member "recurrence" <> `Null);
  check string "recurrence matches the domain serialiser"
    (Yojson.Safe.to_string (Schedule_domain.recurrence_to_yojson recurrence))
    (Yojson.Safe.to_string (entry |> member "recurrence"));
  let listed =
    dispatch_exn config Tool_schemas_schedule.List_requests
      (`Assoc [ "owner", `String "all" ])
  in
  let row =
    match Tool_result.data listed |> member "schedules" |> to_list with
    | [ row ] -> row
    | rows -> failf "expected one listed row, got %d" (List.length rows)
  in
  check string "listing row carries the recurrence summary"
    (Schedule_domain.recurrence_summary recurrence)
    (row |> member "recurrence_summary" |> to_string)
;;

(* Jazz-developer created a wake at 03:37:42Z due at 03:36:00Z. It was stored
   as scheduled, the next refresh marked it due, and it fired at 03:37:54Z --
   a delay measurement that measured nothing, and nothing said so. *)
let test_create_refuses_a_due_time_behind_the_clock () =
  with_config
  @@ fun config ->
  let refused =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (`Assoc
        [ "schedule_id", `String "sched-already-past"
        ; "due_at_iso", `String "2026-09-15T03:36:00Z"
        ; "keeper_name", `String "schedule-keeper"
        ; "message", `String "measure the wake delay"
        ])
  in
  check_refusal "a past due time"
    Schedule_contract_values.Refusal_due_already_past refused;
  let open Yojson.Safe.Util in
  check string "the refusal echoes the due time it read" "2026-09-15T03:36:00Z"
    (Tool_result.data refused |> member "due_at_iso" |> to_string);
  check bool "the refusal says what now was" true
    (Tool_result.data refused |> member "now_iso" <> `Null);
  check int "nothing is stored" 0
    (List.length (Schedule_store.read_state config).schedules)
;;

(* The comparison is with the current whole second, because an RFC 3339 due
   time arrives cut to whole seconds: "now" written as an ISO time is the
   current second, and it must not be refused for the fraction it lost. *)
let test_the_current_second_is_not_past () =
  with_config
  @@ fun config ->
  let create ~schedule_id ~due_at =
    Schedule_service.create config ~runner_tick_sec ~now:1_000.9 ~schedule_id
      ~requested_by:(human "operator")
      ~scheduled_by:(automated "scheduler-agent")
      ~due_at ~payload:(keeper_wake_payload "now") ~source:Schedule_domain.Operator_request ()
  in
  (match create ~schedule_id:"sched-this-second" ~due_at:1_000.0 with
   | Ok request ->
     check string "the current second is accepted" "scheduled"
       (Schedule_domain.schedule_status_to_string request.Schedule_domain.status)
   | Error err -> fail (Schedule_service.service_error_to_string err));
  match create ~schedule_id:"sched-last-second" ~due_at:999.0 with
  | Ok _ -> fail "the previous second was accepted"
  | Error (Schedule_service.Due_already_past { due_at; now }) ->
    check (float 0.0) "the refused due time" 999.0 due_at;
    check (float 0.0) "now is the whole second compared" 1_000.0 now
  | Error err -> fail (Schedule_service.service_error_to_string err)
;;

(* The analyst's cancel of a wake that had already fired said only "only
   scheduled or due requests can be cancelled", which left the question it
   was asked -- what state is it in -- unanswered. *)
let test_cancel_refusal_says_the_state_and_the_last_wake () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-already-fired" in
  let request =
    create_service_exn config ~schedule_id ~due_at:200.0
      ~payload:(keeper_wake_payload "fire once") ()
  in
  let store_ok label = function
    | Ok value -> value
    | Error err -> fail (label ^ ": " ^ Schedule_store.store_error_to_string err)
  in
  ignore (store_ok "refresh" (Schedule_store.refresh_due config ~now:200.0
    ~retention_days:Schedule_store.terminal_schedule_retention_days));
  let started = store_ok "start"
      (Schedule_store.start_due_candidate config ~now:201.0 ~candidate:request) in
  ignore (store_ok "accept"
    (Schedule_store.accept_running config ~now:202.0 ~attempt:started.attempt ()));
  let refused =
    dispatch_exn config Tool_schemas_schedule.Cancel_request
      (`Assoc
        [ "schedule_id", `String schedule_id
        ; "reason", `String "no longer needed"
        ])
  in
  check_refusal "a fired schedule is not cancelled"
    Schedule_contract_values.Refusal_transition_refused refused;
  let open Yojson.Safe.Util in
  let data = Tool_result.data refused in
  check string "current status" "succeeded" (data |> member "current_status" |> to_string);
  check string "attempted transition" "cancel" (data |> member "attempted" |> to_string);
  check string "last wake result" "succeeded"
    (data |> member "last_wake" |> member "status" |> to_string);
  check bool "the sentence names the status too" true
    (String_util.contains_substring (Tool_result.message refused) "is succeeded")
;;

let keeper_wake_payload_for keeper_name message =
  `Assoc
    [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; ( "body"
      , `Assoc [ "keeper_name", `String keeper_name; "message", `String message ] )
    ]
;;

let listed_ids result =
  let open Yojson.Safe.Util in
  Tool_result.data result
  |> member "schedules"
  |> to_list
  |> List.map (fun row -> row |> member "schedule_id" |> to_string)
;;

(* Three schedules, one per relation to the caller ([schedule_ctx] calls as
   scheduler-agent): one it created, one that wakes it, one that is neither.
   A caller that could not tell its own rows from 1,232 others read a 144 KB
   listing and still did not find them. *)
let test_list_reads_the_owner_it_is_asked_for () =
  with_config
  @@ fun config ->
  let create schedule_id ~scheduled_by ~wakes =
    match
      Schedule_service.create config ~runner_tick_sec ~now:100.0 ~schedule_id
        ~requested_by:(human "operator")
        ~scheduled_by:(automated scheduled_by)
        ~due_at:200.0
        ~payload:(keeper_wake_payload_for wakes ("wake " ^ schedule_id))
        ~source:Schedule_domain.Operator_request ()
    with
    | Ok _ -> ()
    | Error err -> fail (Schedule_service.service_error_to_string err)
  in
  create "sched-a" ~scheduled_by:"scheduler-agent" ~wakes:"schedule-keeper";
  create "sched-b" ~scheduled_by:"other-actor" ~wakes:"scheduler-agent";
  create "sched-c" ~scheduled_by:"other-actor" ~wakes:"schedule-keeper";
  let list_with args =
    dispatch_exn config Tool_schemas_schedule.List_requests (`Assoc args)
  in
  check (list string) "self is either side of the caller" [ "sched-a"; "sched-b" ]
    (listed_ids (list_with [ "owner", `String "self" ]));
  check (list string) "wake_target reads the woken keeper" [ "sched-a"; "sched-c" ]
    (listed_ids
       (list_with
          [ "owner", `String "wake_target"; "owner_name", `String "schedule-keeper" ]));
  check (list string) "scheduled_by reads the creator" [ "sched-b"; "sched-c" ]
    (listed_ids
       (list_with
          [ "owner", `String "scheduled_by"; "owner_name", `String "other-actor" ]));
  check (list string) "all is every row" [ "sched-a"; "sched-b"; "sched-c" ]
    (listed_ids (list_with [ "owner", `String "all" ]));
  let open Yojson.Safe.Util in
  check string "self echoes whom it resolved to" "scheduler-agent"
    (Tool_result.data (list_with [ "owner", `String "self" ])
     |> member "owner_name"
     |> to_string);
  List.iter
    (fun (label, args, fragment) ->
       let refused = list_with args in
       check bool label false (Tool_result.is_success refused);
       check bool (label ^ " says why") true
         (String_util.contains_substring (Tool_result.message refused) fragment))
    [ "owner is required", [], "owner is required"
    ; ( "a name next to self is refused"
      , [ "owner", `String "self"; "owner_name", `String "someone" ]
      , "owner_name is not accepted with owner=self" )
    ; ( "wake_target needs a name"
      , [ "owner", `String "wake_target" ]
      , "owner_name is required with owner=wake_target" )
    ; "an unknown owner is refused", [ "owner", `String "mine" ], "unknown owner: mine"
    ];
  let row =
    match
      Tool_result.data (list_with [ "owner", `String "all"; "limit", `Int 1 ])
      |> member "schedules"
      |> to_list
    with
    | [ row ] -> row
    | rows -> failf "expected one row, got %d" (List.length rows)
  in
  check (list string) "a row is a summary"
    [ "schedule_id"
    ; "status"
    ; "due_at_iso"
    ; "recurrence_summary"
    ; "wake_target"
    ; "scheduled_by"
    ; "summary"
    ; "last_wake_status"
    ]
    (row |> to_assoc |> List.map fst);
  check string "wake target is the bare keeper name" "schedule-keeper"
    (row |> member "wake_target" |> to_string)
;;

(* Pages follow schedule_id: the next page is every matching row after the
   last id a page showed. The last page has no cursor. *)
let test_list_pages_by_schedule_id () =
  with_config
  @@ fun config ->
  List.iter
    (fun schedule_id ->
       ignore
         (create_service_exn config ~schedule_id ~due_at:200.0
            ~payload:(keeper_wake_payload schedule_id) ()
          : Schedule_domain.schedule_request))
    [ "sched-3"; "sched-1"; "sched-2" ];
  let list_with args =
    dispatch_exn config Tool_schemas_schedule.List_requests (`Assoc args)
  in
  let open Yojson.Safe.Util in
  let first = list_with [ "owner", `String "all"; "limit", `Int 2 ] in
  check (list string) "first page in id order" [ "sched-1"; "sched-2" ] (listed_ids first);
  let cursor = Tool_result.data first |> member "next_cursor" |> to_string in
  let second =
    list_with [ "owner", `String "all"; "limit", `Int 2; "cursor", `String cursor ]
  in
  check (list string) "second page continues after it" [ "sched-3" ] (listed_ids second);
  check bool "the last page has no cursor" true
    (Tool_result.data second |> member "next_cursor" = `Null)
;;

let wake_args ?(extra = []) () =
  `Assoc
    ([ "keeper_name", `String "schedule-keeper"; "message", `String "wake" ] @ extra)
;;

(* An MCP caller that gave no name has only a name the endpoint minted for
   its session, which nobody owns across sessions. Where the tool would stand
   on the caller's name -- owner=self, the scheduler, the canceller, a note's
   author -- such a caller is refused, and naming the actor in the arguments
   does not help. *)
let test_an_unnamed_caller_names_the_actor_itself () =
  with_config
  @@ fun config ->
  let caller = Tool_schedule.Unnamed_caller in
  check_refusal "owner=self"
    Schedule_contract_values.Refusal_caller_unidentified
    (dispatch_exn ~caller config Tool_schemas_schedule.List_requests
       (`Assoc [ "owner", `String "self" ]));
  check bool "a named owner still lists" true
    (Tool_result.is_success
       (dispatch_exn ~caller config Tool_schemas_schedule.List_requests
          (`Assoc
            [ "owner", `String "scheduled_by"; "owner_name", `String "scheduler-agent" ])));
  check_refusal "create"
    Schedule_contract_values.Refusal_caller_unidentified
    (dispatch_exn ~caller config Tool_schemas_schedule.Create_request
       (wake_args ~extra:[ "due_in_sec", `Int 60 ] ()));
  check_refusal "create naming a scheduler in the arguments"
    Schedule_contract_values.Refusal_caller_unidentified
    (dispatch_exn ~caller config Tool_schemas_schedule.Create_request
       (wake_args
          ~extra:[ "due_in_sec", `Int 60; "scheduled_by_id", `String "named-scheduler" ]
          ()));
  check int "nothing stored for the unnamed create" 0
    (List.length (Schedule_store.read_state config).schedules);
  let schedule_id = "sched-unnamed-target" in
  ignore
    (create_service_exn config ~schedule_id ~due_at:future_due_at
       ~payload:(keeper_wake_payload "wake") ()
     : Schedule_domain.schedule_request);
  check_refusal "cancel"
    Schedule_contract_values.Refusal_caller_unidentified
    (dispatch_exn ~caller config Tool_schemas_schedule.Cancel_request
       (`Assoc [ "schedule_id", `String schedule_id; "reason", `String "why" ]));
  check_refusal "note without author_id"
    Schedule_contract_values.Refusal_caller_unidentified
    (dispatch_exn ~caller config Tool_schemas_schedule.Add_note
       (`Assoc [ "schedule_id", `String schedule_id; "body", `String "why" ]))
;;

let stored_schedule config schedule_id =
  match
    List.find_opt
      (fun (request : Schedule_domain.schedule_request) ->
         String.equal request.schedule_id schedule_id)
      (Schedule_store.read_state config).schedules
  with
  | Some request -> request
  | None -> failf "schedule %s is not stored" schedule_id
;;

(* A Keeper is recorded as itself, kind included. An argument naming the
   operator kind is refused: a Keeper that could write human_operator into
   requested_by_kind or cancelled_by_kind could pass itself off as the
   operator. *)
let test_the_recorded_actor_is_the_caller_not_an_argument () =
  with_config
  @@ fun config ->
  let caller = Tool_schedule.Named_caller "keeper-a" in
  let schedule_id = "sched-caller-actor" in
  let create extra =
    dispatch_exn ~caller config Tool_schemas_schedule.Create_request
      (wake_args
         ~extra:([ "due_in_sec", `Int 60; "schedule_id", `String schedule_id ] @ extra)
         ())
  in
  check_refusal "a keeper claiming the operator kind"
    Schedule_contract_values.Refusal_actor_mismatch
    (create [ "requested_by_kind", `String "human_operator" ]);
  check bool "create succeeds" true (Tool_result.is_success (create []));
  let stored = stored_schedule config schedule_id in
  check string "scheduler is the caller" "keeper-a"
    stored.Schedule_domain.scheduled_by.Schedule_domain.id;
  check string "requester is the caller" "keeper-a"
    stored.Schedule_domain.requested_by.Schedule_domain.id;
  check bool "requester is not recorded as the operator" true
    (stored.Schedule_domain.requested_by.Schedule_domain.kind
     = Schedule_domain.Automated_actor);
  let cancel extra =
    dispatch_exn ~caller config Tool_schemas_schedule.Cancel_request
      (`Assoc
        ([ "schedule_id", `String schedule_id; "reason", `String "superseded" ]
         @ extra))
  in
  check_refusal "a keeper cancelling as the operator"
    Schedule_contract_values.Refusal_actor_mismatch
    (cancel [ "cancelled_by_kind", `String "human_operator" ]);
  let cancelled = cancel [] in
  check bool "the caller cancels its own schedule" true
    (Tool_result.is_success cancelled);
  let open Yojson.Safe.Util in
  let canceller = Tool_result.data cancelled |> member "cancelled_by" in
  check string "canceller is the caller" "keeper-a"
    (canceller |> member "id" |> to_string);
  check string "canceller kind is automated" "automated_actor"
    (canceller |> member "kind" |> to_string)
;;

(* A Keeper changes the schedules it made and the ones that wake it -- the
   rows owner=self lists for it -- and no others. *)
let test_a_keeper_cannot_cancel_another_keepers_schedule () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-owned-by-a" in
  let created =
    dispatch_exn ~caller:(Tool_schedule.Named_caller "keeper-a") config
      Tool_schemas_schedule.Create_request
      (wake_args
         ~extra:[ "due_in_sec", `Int 60; "schedule_id", `String schedule_id ]
         ())
  in
  check bool "keeper-a creates" true (Tool_result.is_success created);
  let other = Tool_schedule.Named_caller "keeper-b" in
  check_refusal "keeper-b cancels keeper-a's schedule"
    Schedule_contract_values.Refusal_not_schedule_owner
    (dispatch_exn ~caller:other config Tool_schemas_schedule.Cancel_request
       (`Assoc
         [ "schedule_id", `String schedule_id
         ; "reason", `String "mine now"
         ]));
  check_refusal "keeper-b updates keeper-a's schedule"
    Schedule_contract_values.Refusal_not_schedule_owner
    (dispatch_exn ~caller:other config Tool_schemas_schedule.Update_request
       (wake_args
          ~extra:[ "due_in_sec", `Int 120
                 ; "schedule_id", `String schedule_id
                 ; "recurrence_kind", `String "one_shot" ]
          ()));
  let stored = stored_schedule config schedule_id in
  check bool "the schedule is still scheduled" true
    (stored.Schedule_domain.status = Schedule_domain.Scheduled);
  check string "the scheduler is unchanged" "keeper-a" stored.Schedule_domain.scheduled_by.Schedule_domain.id;
  (* The wake target is the other side owner=self reads. *)
  check bool "the woken keeper may cancel" true
    (Tool_result.is_success
       (dispatch_exn ~caller:(Tool_schedule.Named_caller "schedule-keeper") config
          Tool_schemas_schedule.Cancel_request
          (`Assoc [ "schedule_id", `String schedule_id; "reason", `String "not needed" ])))
;;

(* An update replaces the whole definition, whom it wakes included. The Keeper
   a row wakes may update it, but not point it at another Keeper, and an
   update does not make the updater the row's requester or scheduler. *)
let test_an_update_keeps_the_rows_actors_and_its_target_rule () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-operator-row" in
  ignore
    (create_service_exn config ~schedule_id ~due_at:future_due_at
       ~payload:(keeper_wake_payload "wake") ()
     : Schedule_domain.schedule_request);
  let woken = Tool_schedule.Named_caller "schedule-keeper" in
  let update_args keeper_name =
    `Assoc
      [ "schedule_id", `String schedule_id
      ; "keeper_name", `String keeper_name
      ; "message", `String "moved"
      ; "recurrence_kind", `String "one_shot"
      ; "due_in_sec", `Int 120
      ; "allow_unregistered_keeper", `Bool true
      ]
  in
  check_refusal "the woken keeper retargets the row"
    Schedule_contract_values.Refusal_not_schedule_owner
    (dispatch_exn ~caller:woken config Tool_schemas_schedule.Update_request
       (update_args "other-keeper"));
  check bool "the woken keeper updates the row it keeps" true
    (Tool_result.is_success
       (dispatch_exn ~caller:woken config Tool_schemas_schedule.Update_request
          (update_args "schedule-keeper")));
  let stored = stored_schedule config schedule_id in
  check string "the requester is kept" "operator"
    stored.Schedule_domain.requested_by.Schedule_domain.id;
  check bool "the requester kind is kept" true
    (stored.Schedule_domain.requested_by.Schedule_domain.kind
     = Schedule_domain.Human_operator);
  check string "the scheduler is kept" "scheduler-agent"
    stored.Schedule_domain.scheduled_by.Schedule_domain.id
;;

(* The actor a schedule records is the caller the boundary resolved. A
   client-supplied id that names someone else is refused rather than silently
   ignored: the HTTP boundary already replaced it (#37149), and the MCP path
   does not stamp, so the tool itself must refuse -- otherwise an MCP caller
   names any actor it likes on create, cancel and note_add. *)
(* The real update path reads its authorization snapshot before entering
   Keeper intake. Interleave another public update at that boundary: the old
   recipient must not edit the definition after it stops waking that caller. *)
let test_recipient_edit_rechecks_the_current_target () =
  with_config @@ fun config ->
  let schedule_id = "recipient-edit-retargeted" in
  let creator = Tool_schedule.Named_caller "scheduler-agent" in
  register_wake_target config "replacement-keeper";
  let created = dispatch_exn ~caller:creator config Tool_schemas_schedule.Create_request
      (create_args ~schedule_id ()) in
  check bool "creator schedules A" true (Tool_result.is_success created);
  let committed = ref None in
  let ctx = { (schedule_ctx ~caller:(Tool_schedule.Named_caller "schedule-keeper") config) with
    admit_keeper_wake_creation = (fun _config ~keeper_name:_ write ->
      let retarget = dispatch_exn ~caller:creator config Tool_schemas_schedule.Update_request
          (`Assoc [ "schedule_id", `String schedule_id
                  ; "keeper_name", `String "replacement-keeper"
                  ; "message", `String "creator's replacement" ]) in
      check bool "creator retargets B before recipient commits" true
        (Tool_result.is_success retarget);
      committed := Some (Schedule_store.read_state config);
      write ()) } in
  let result = match Tool_schedule.dispatch ctx
      ~name:(schedule_tool_name Tool_schemas_schedule.Update_request)
      ~args:(`Assoc [ "schedule_id", `String schedule_id
                   ; "keeper_name", `String "schedule-keeper"
                   ; "message", `String "stale recipient edit" ]) with
    | Some result -> result
    | None -> fail "update tool missing" in
  check_refusal "former recipient cannot overwrite B"
    Schedule_contract_values.Refusal_not_schedule_owner result;
  let open Yojson.Safe.Util in
  let facts = Tool_result.data result in
  check string "refusal identifies current target" "replacement-keeper"
    (facts |> member "wake_target" |> to_string);
  check string "refusal identifies caller" "schedule-keeper"
    (facts |> member "caller" |> to_string);
  check string "refusal identifies scheduler" "scheduler-agent"
    (facts |> member "scheduled_by_id" |> to_string);
  let before = match !committed with
    | Some state -> state | None -> fail "retarget did not commit" in
  check int "refused edit leaves the ledger version unchanged" before.version
    (Schedule_store.read_state config).version;
  let stored = stored_schedule config schedule_id in
  check string "creator's content survives" "creator's replacement"
    (Schedule_domain.payload_to_yojson stored.payload |> member "body" |> member "message" |> to_string);
  check bool "creator can still edit the retargeted row" true
    (Tool_result.is_success
       (dispatch_exn ~caller:creator config Tool_schemas_schedule.Update_request
          (`Assoc [ "schedule_id", `String schedule_id
                  ; "keeper_name", `String "schedule-keeper"
                  ; "message", `String "creator's next edit" ])))
;;

let test_locked_cancel_refuses_a_former_recipient_before_withdrawal () =
  with_config @@ fun config ->
  let schedule_id = "cancel-retargeted-owner" in
  let creator = Tool_schedule.Named_caller "scheduler-agent" in
  register_wake_target config "replacement-keeper";
  ignore (dispatch_exn ~caller:creator config Tool_schemas_schedule.Create_request
    (create_args ~schedule_id ()) : Tool_result.result);
  let observed = stored_schedule config schedule_id in
  check (option string) "original recipient" (Some "schedule-keeper")
    (Schedule_payload_projection.wake_keeper_name observed);
  let changed = dispatch_exn ~caller:creator config Tool_schemas_schedule.Update_request
      (`Assoc [ "schedule_id", `String schedule_id
              ; "keeper_name", `String "replacement-keeper"
              ; "message", `String "retargeted" ]) in
  check bool "retarget commits" true (Tool_result.is_success changed);
  let before = Schedule_store.read_state config in
  let withdrawals = ref 0 in
  let withdraw request _cancellation =
    incr withdrawals;
    check (option string) "withdrawal sees the current target" (Some "replacement-keeper")
      (Schedule_payload_projection.wake_keeper_name request);
    Ok () in
  let cancel name = Schedule_service.cancel config
      ~authority:(Schedule_store.Named_authority
        { name; wake_keeper_name = Schedule_payload_projection.wake_keeper_name })
      ~schedule_id ~cancelled_by:(automated name) ~reason:"no longer needed"
      ~withdraw_queued_wakes:withdraw in
  (match cancel "schedule-keeper" with
   | Error (Schedule_service.Store_error (Schedule_store.Not_schedule_owner
       { caller; scheduled_by_id; wake_target; schedule_id = refused_id })) ->
     check string "refused schedule" schedule_id refused_id;
     check string "former recipient" "schedule-keeper" caller;
     check string "current scheduler" "scheduler-agent" scheduled_by_id;
     check (option string) "current target" (Some "replacement-keeper") wake_target
   | Error err -> fail (Schedule_service.service_error_to_string err)
   | Ok _ -> fail "former recipient cancelled the retargeted row");
  check int "unauthorized cancel never calls withdrawal" 0 !withdrawals;
  check int "unauthorized cancel never writes the ledger" before.version
    (Schedule_store.read_state config).version;
  (match cancel "scheduler-agent" with
   | Ok request -> check bool "creator cancels" true (request.status = Schedule_domain.Cancelled)
   | Error err -> fail (Schedule_service.service_error_to_string err));
  check int "authorized creator withdraws once" 1 !withdrawals
;;

let test_locked_replacement_uses_the_current_scheduler () =
  with_config @@ fun config ->
  let schedule_id = "replacement-owner-current-row" in
  let original = create_service_exn config ~schedule_id ~due_at:future_due_at
      ~payload:(keeper_wake_payload "original") () in
  let before = Schedule_store.read_state config in
  let payload = `Assoc [ "kind", `String Schedule_supported_kinds.keeper_wake
    ; "body", `Assoc [ "keeper_name", `String "other-keeper"; "message", `String "moved" ] ] in
  let result = Schedule_service.update config
      ~authority:(Schedule_store.Named_authority
        { name = "schedule-keeper"; wake_keeper_name = Schedule_payload_projection.wake_keeper_name })
      ~now:100. ~runner_tick_sec ~schedule_id
      ~requested_by:(automated "schedule-keeper") ~scheduled_by:(automated "schedule-keeper")
      ~due_at:original.due_at ~payload ~source:original.source () in
  (match result with
   | Error (Schedule_service.Store_error (Schedule_store.Not_schedule_owner
       { scheduled_by_id; wake_target; schedule_id = _; caller = _ })) ->
     check string "current scheduler decides replacement ownership" "scheduler-agent" scheduled_by_id;
     check (option string) "replacement target is refused" (Some "other-keeper") wake_target
   | Error err -> fail (Schedule_service.service_error_to_string err)
   | Ok _ -> fail "replacement supplied its own scheduling authority");
  check int "invalid replacement leaves the ledger unchanged" before.version
    (Schedule_store.read_state config).version
;;

let test_a_named_caller_is_the_actor_not_the_argument () =
  with_config
  @@ fun config ->
  let caller = Tool_schedule.Named_caller "real-caller" in
  let create extra =
    dispatch_exn ~caller config Tool_schemas_schedule.Create_request
      (`Assoc
        ([ "schedule_id", `String "sched-actor-binding"
         ; "due_at_unix", `Float future_due_at
         ; "keeper_name", `String "schedule-keeper"
         ; "message", `String "actor binding"
         ]
         @ extra))
  in
  check_refusal "requested_by_id naming another actor"
    Schedule_contract_values.Refusal_actor_mismatch
    (create [ "requested_by_id", `String "spoofed-requester" ]);
  check_refusal "scheduled_by_id naming another actor"
    Schedule_contract_values.Refusal_actor_mismatch
    (create [ "scheduled_by_id", `String "spoofed-scheduler" ]);
  let created = create [ "requested_by_id", `String "real-caller" ] in
  check bool "an id that names the caller is accepted" true
    (Tool_result.is_success created);
  let open Yojson.Safe.Util in
  check string "requested_by is the caller" "real-caller"
    (Tool_result.data created |> member "requested_by" |> member "id" |> to_string);
  check string "scheduled_by is the caller" "real-caller"
    (Tool_result.data created |> member "scheduled_by" |> member "id" |> to_string);
  check_refusal "cancelled_by_id naming another actor"
    Schedule_contract_values.Refusal_actor_mismatch
    (dispatch_exn ~caller config Tool_schemas_schedule.Cancel_request
       (`Assoc
         [ "schedule_id", `String "sched-actor-binding"
         ; "cancelled_by_id", `String "spoofed-canceller"
         ; "reason", `String "spoofed"
         ]));
  check_refusal "author_id naming another actor"
    Schedule_contract_values.Refusal_actor_mismatch
    (dispatch_exn ~caller config Tool_schemas_schedule.Add_note
       (`Assoc
         [ "schedule_id", `String "sched-actor-binding"
         ; "body", `String "spoofed author"
         ; "author_id", `String "spoofed-author"
         ]));
  let cancelled =
    dispatch_exn ~caller config Tool_schemas_schedule.Cancel_request
      (`Assoc
        [ "schedule_id", `String "sched-actor-binding"
        ; "reason", `String "done"
        ])
  in
  check bool "cancel without an id succeeds" true (Tool_result.is_success cancelled);
  check string "cancelled_by is the caller" "real-caller"
    (Tool_result.data cancelled |> member "cancelled_by" |> member "id" |> to_string)
;;

(* A call gives one due input, or none when a calendar recurrence derives
   it. Two inputs are refused with the names the call gave, and an input of
   the wrong JSON type is refused rather than read as absent. *)
let test_a_call_gives_exactly_one_due_input () =
  with_config
  @@ fun config ->
  let create extra =
    dispatch_exn config Tool_schemas_schedule.Create_request (wake_args ~extra ())
  in
  let conflict =
    create [ "due_at_unix", `Float future_due_at; "due_at_iso", `String "2100-01-01T00:00:00Z" ]
  in
  check_refusal "unix and iso together"
    Schedule_contract_values.Refusal_due_inputs_conflict conflict;
  let open Yojson.Safe.Util in
  check (list string) "the refusal names what the call gave"
    [ "due_at_unix"; "due_at_iso" ]
    (Tool_result.data conflict |> member "given" |> to_list |> List.map to_string);
  check_refusal "a delay with an absolute time"
    Schedule_contract_values.Refusal_due_inputs_conflict
    (create [ "due_in_sec", `Int 60; "due_at_unix", `Float future_due_at ]);
  check_refusal "no due input on a one-shot"
    Schedule_contract_values.Refusal_due_input_missing
    (create []);
  check_refusal "a zero delay"
    Schedule_contract_values.Refusal_argument_out_of_range
    (create [ "due_in_sec", `Int 0 ]);
  let wrong_type = create [ "due_in_sec", `String "60"; "due_at_unix", `Float future_due_at ] in
  check bool "a mistyped delay is refused, not skipped" false
    (Tool_result.is_success wrong_type);
  check bool "the refusal names the type" true
    (String_util.contains_substring (Tool_result.message wrong_type) "due_in_sec must be an integer");
  check int "no refused call is stored" 0
    (List.length (Schedule_store.read_state config).schedules)
;;

(* The schedule runner looks once per tick, so an interval shorter than the
   tick would fire once per tick and the stored interval would misstate it
   (#38176). The tool refuses it as a typed out-of-range argument that says
   the smallest interval it takes, the tick, and what the call gave; an
   interval equal to the tick is created. The tick is the one the production
   runner sleeps on, read from the same value the tool reads. *)
let test_create_refuses_an_interval_below_the_runner_tick () =
  with_config
  @@ fun config ->
  let runner_tick_sec = Env_config_runtime_services.ScheduleRunner.interval_sec in
  let minimum = int_of_float (Float.ceil runner_tick_sec) in
  let create interval_sec =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (wake_args
         ~extra:
           [ "due_at_unix", `Float future_due_at
           ; "recurrence_kind", `String "interval"
           ; "recurrence_interval_sec", `Int interval_sec
           ]
         ())
  in
  let below = minimum - 1 in
  let refused = create below in
  check_refusal "interval below the tick"
    Schedule_contract_values.Refusal_argument_out_of_range refused;
  let open Yojson.Safe.Util in
  let data = Tool_result.data refused in
  check string "names the field" "recurrence_interval_sec"
    (data |> member "field" |> to_string);
  check int "says the smallest interval taken" minimum (data |> member "minimum" |> to_int);
  check (float 0.0) "says the runner tick" runner_tick_sec
    (data |> member "runner_tick_sec" |> to_number);
  check int "says what the call gave" below (data |> member "given" |> to_int);
  check int "the refused call is not stored" 0
    (List.length (Schedule_store.read_state config).schedules);
  let created = create minimum in
  check bool "an interval equal to the tick is created" true
    (Tool_result.is_success created);
  check int "the created schedule is stored" 1
    (List.length (Schedule_store.read_state config).schedules)
;;

(* A Keeper has the current time on its turn's first request only. A delay
   counts from the server's dispatch clock, so it needs none. *)
let test_due_in_sec_counts_from_the_dispatch_clock () =
  with_config
  @@ fun config ->
  let delay = 90 in
  let before = Unix.gettimeofday () in
  let created =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (wake_args ~extra:[ "due_in_sec", `Int delay ] ())
  in
  let after = Unix.gettimeofday () in
  check bool "a delay creates" true (Tool_result.is_success created);
  let open Yojson.Safe.Util in
  let due_at = Tool_result.data created |> member "due_at" |> to_number in
  let clock_resolution = 1.0 in
  check bool "due is the delay after the dispatch clock" true
    (due_at >= before +. Float.of_int delay -. clock_resolution
     && due_at <= after +. Float.of_int delay +. clock_resolution)
;;

(* requested_at_unix is a replay field a caller may set, so no due time
   counts from it: a daily schedule with no due time takes its first due
   after the dispatch clock whatever requested_at_unix says. *)
let test_a_calendar_first_due_counts_from_dispatch_not_requested_at () =
  with_config
  @@ fun config ->
  let before = Unix.gettimeofday () in
  let created =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (wake_args
         ~extra:
           [ "requested_at_unix", `Float 100.0
           ; "recurrence_kind", `String "daily"
           ; "recurrence_hour", `Int 9
           ; "recurrence_minute", `Int 0
           ; "recurrence_timezone", `String "UTC"
           ]
         ())
  in
  check bool "a daily schedule with an old requested_at creates" true
    (Tool_result.is_success created);
  let open Yojson.Safe.Util in
  check bool "its first due is after the dispatch clock" true
    (Tool_result.data created |> member "due_at" |> to_number >= before);
  check (float 0.0) "requested_at is recorded as given" 100.0
    (Tool_result.data created |> member "requested_at" |> to_number)
;;

(* The TUI edit form sends a due row's due time back as it read it. That is
   not a new due time; moving it behind the clock is, and it would fire at
   once. *)
let test_update_refuses_a_due_time_moved_behind_the_clock () =
  with_config
  @@ fun config ->
  let schedule_id = "sched-edit-past-due" in
  ignore
    (create_service_exn config ~schedule_id ~due_at:200.0
       ~payload:(keeper_wake_payload "fire once") ()
     : Schedule_domain.schedule_request);
  let update extra =
    dispatch_exn config Tool_schemas_schedule.Update_request
      (wake_args
         ~extra:([ "schedule_id", `String schedule_id
                 ; "recurrence_kind", `String "one_shot" ] @ extra)
         ())
  in
  check bool "the stored due time sent back unchanged is accepted" true
    (Tool_result.is_success (update [ "due_at_iso", `String "1970-01-01T00:03:20Z" ]));
  let moved = update [ "due_at_unix", `Float 150.0 ] in
  check_refusal "a due time moved into the past"
    Schedule_contract_values.Refusal_due_already_past moved;
  let open Yojson.Safe.Util in
  check string "the refusal names the stored due time" "1970-01-01T00:03:20Z"
    (Tool_result.data moved |> member "stored_due_at_iso" |> to_string);
  check bool "a delay is always later and is accepted" true
    (Tool_result.is_success (update [ "due_in_sec", `Int 60 ]))
;;

(* A limit outside 1..200 is refused with the range, so the page a caller
   gets is always the size it asked for. *)
let test_a_limit_outside_its_range_is_refused () =
  with_config
  @@ fun config ->
  let list_with limit =
    dispatch_exn config Tool_schemas_schedule.List_requests
      (`Assoc [ "owner", `String "all"; "limit", limit ])
  in
  let zero = list_with (`Int 0) in
  check_refusal "limit 0" Schedule_contract_values.Refusal_argument_out_of_range zero;
  let open Yojson.Safe.Util in
  check int "the refusal names the maximum" Tool_schedule.max_list_limit
    (Tool_result.data zero |> member "maximum" |> to_int);
  check_refusal "limit above the maximum"
    Schedule_contract_values.Refusal_argument_out_of_range
    (list_with (`Int (Tool_schedule.max_list_limit + 1)));
  check bool "the maximum itself is accepted" true
    (Tool_result.is_success (list_with (`Int Tool_schedule.max_list_limit)));
  check_refusal "notes limit 0"
    Schedule_contract_values.Refusal_argument_out_of_range
    (dispatch_exn config Tool_schemas_schedule.List_notes
       (`Assoc [ "schedule_id", `String "sched-any"; "limit", `Int 0 ]))
;;

(* A cursor carries the filters of the listing that issued it. Under other
   filters it would skip rows those filters never compared against its id, so
   it is refused, as are an empty cursor and one no listing issued. *)
let test_a_cursor_belongs_to_the_filters_that_issued_it () =
  with_config
  @@ fun config ->
  List.iter
    (fun schedule_id ->
       ignore
         (create_service_exn config ~schedule_id ~due_at:200.0
            ~payload:(keeper_wake_payload schedule_id) ()
          : Schedule_domain.schedule_request))
    [ "sched-1"; "sched-2"; "sched-3" ];
  let list_with args =
    dispatch_exn config Tool_schemas_schedule.List_requests (`Assoc args)
  in
  let open Yojson.Safe.Util in
  let first = list_with [ "owner", `String "all"; "limit", `Int 1 ] in
  let cursor = Tool_result.data first |> member "next_cursor" |> to_string in
  let mismatch =
    list_with
      [ "owner", `String "all"
      ; "status", `String "scheduled"
      ; "limit", `Int 1
      ; "cursor", `String cursor
      ]
  in
  check_refusal "the cursor under another status"
    Schedule_contract_values.Refusal_cursor_mismatch mismatch;
  check string "the refusal names the cursor's owner" "all"
    (Tool_result.data mismatch |> member "cursor_owner" |> to_string);
  check_refusal "the cursor under another owner"
    Schedule_contract_values.Refusal_cursor_mismatch
    (list_with
       [ "owner", `String "scheduled_by"
       ; "owner_name", `String "scheduler-agent"
       ; "cursor", `String cursor
       ]);
  List.iter
    (fun (label, raw, fragment) ->
       let refused = list_with [ "owner", `String "all"; "cursor", `String raw ] in
       check bool label false (Tool_result.is_success refused);
       check bool (label ^ " says why") true
         (String_util.contains_substring (Tool_result.message refused) fragment))
    [ "an empty cursor", "", "cursor is empty"
    ; "a cursor no listing issued", "not-a-cursor", "cursor is not one a listing issued"
    ; "a bare schedule id", "sched-1", "cursor is not one a listing issued"
    ];
  check (list string) "the same filters continue" [ "sched-2" ]
    (listed_ids
       (list_with
          [ "owner", `String "all"; "limit", `Int 1; "cursor", `String cursor ]))
;;

(* status=active reads a Keeper's live schedules in one call. Which statuses
   it covers is the domain's [is_terminal], not a list the caller keeps. *)
let test_status_active_lists_every_status_that_is_not_terminal () =
  with_config
  @@ fun config ->
  let create schedule_id ~due_at =
    ignore
      (create_service_exn config ~schedule_id ~due_at
         ~payload:(keeper_wake_payload schedule_id) ()
       : Schedule_domain.schedule_request)
  in
  create "sched-live" ~due_at:future_due_at;
  create "sched-due" ~due_at:200.0;
  create "sched-gone" ~due_at:future_due_at;
  (match Schedule_store.refresh_due config ~now:201.0
    ~retention_days:Schedule_store.terminal_schedule_retention_days with
   | Ok _ -> ()
   | Error err -> fail (Schedule_store.store_error_to_string err));
  (match
     Schedule_service.cancel
       config
       ~authority:Schedule_store.Operator_authority
       ~schedule_id:"sched-gone"
       ~cancelled_by:(human "operator")
       ~reason:"list fixture"
       ~withdraw_queued_wakes:(Keeper_schedule_cancel_withdrawal.run config)
   with
   | Ok _ -> ()
   | Error err -> fail (Schedule_service.service_error_to_string err));
  let list_with args =
    dispatch_exn config Tool_schemas_schedule.List_requests (`Assoc args)
  in
  check (list string) "active is every status that is not terminal"
    [ "sched-due"; "sched-live" ]
    (listed_ids (list_with [ "owner", `String "all"; "status", `String "active" ]));
  check (list string) "one status still selects that status" [ "sched-gone" ]
    (listed_ids (list_with [ "owner", `String "all"; "status", `String "cancelled" ]));
  let open Yojson.Safe.Util in
  let cursor =
    Tool_result.data
      (list_with [ "owner", `String "all"; "status", `String "active"; "limit", `Int 1 ])
    |> member "next_cursor"
    |> to_string
  in
  check_refusal "an active cursor under one status"
    Schedule_contract_values.Refusal_cursor_mismatch
    (list_with
       [ "owner", `String "all"; "status", `String "due"; "cursor", `String cursor ]);
  check (list string) "the active cursor continues under active" [ "sched-live" ]
    (listed_ids
       (list_with
          [ "owner", `String "all"
          ; "status", `String "active"
          ; "cursor", `String cursor
          ]))
;;

(* The arguments that decide which rows a call makes or reads are refused
   when they arrive as another JSON type. Read as absent, a string expiry
   would store a row that never expires and a numeric status would list
   every status. *)
let test_a_mistyped_deciding_argument_is_refused () =
  with_config
  @@ fun config ->
  let expiry =
    dispatch_exn config Tool_schemas_schedule.Create_request
      (wake_args
         ~extra:[ "due_in_sec", `Int 60; "expires_at_unix", `String "tomorrow" ]
         ())
  in
  check bool "a string expiry is refused" false (Tool_result.is_success expiry);
  check bool "the refusal names the expiry type" true
    (String_util.contains_substring
       (Tool_result.message expiry)
       "expires_at_unix must be a number");
  check int "nothing is stored" 0
    (List.length (Schedule_store.read_state config).schedules);
  let status =
    dispatch_exn config Tool_schemas_schedule.List_requests
      (`Assoc [ "owner", `String "all"; "status", `Int 1 ])
  in
  check bool "a numeric status is refused" false (Tool_result.is_success status);
  check bool "the refusal names the status type" true
    (String_util.contains_substring (Tool_result.message status) "status must be a string")
;;

(* The schema advertises the same bounds the handler enforces. The TOML
   cannot read an OCaml constant, so the two are compared here. *)
let test_declared_bounds_match_the_handler () =
  let property action name =
    let schema : Masc_domain.tool_schema = (schedule_definition action).schema in
    let open Yojson.Safe.Util in
    schema.input_schema |> member "properties" |> member name
  in
  let bound json key =
    let open Yojson.Safe.Util in
    json |> member key |> to_int_option
  in
  List.iter
    (fun action ->
       let limit = property action "limit" in
       check (option int) "limit minimum" (Some Tool_schedule.min_list_limit)
         (bound limit "minimum");
       check (option int) "limit maximum" (Some Tool_schedule.max_list_limit)
         (bound limit "maximum"))
    [ Tool_schemas_schedule.List_requests; Tool_schemas_schedule.List_notes ];
  List.iter
    (fun action ->
       check (option int) "due_in_sec minimum" (Some Tool_schedule.min_due_in_sec)
         (bound (property action "due_in_sec") "minimum"))
    [ Tool_schemas_schedule.Create_request; Tool_schemas_schedule.Update_request ]
;;


let test_note_pages_keep_older_history_when_new_notes_arrive () =
  with_config @@ fun config ->
  let schedule_id = "note-pages" in
  let other_schedule = "other-note-pages" in
  List.iter
    (fun id ->
       ignore (create_service_exn config ~schedule_id:id ~due_at:future_due_at
                 ~payload:(keeper_wake_payload "wake") ()))
    [ schedule_id; other_schedule ];
  let append id body now =
    match Schedule_store.append_note config ~schedule_id:id ~author_id:"operator"
            ~author_kind:Schedule_domain.Human_operator ~body ~now with
    | Ok (note, _) -> note.Schedule_domain.note_id
    | Error err -> fail (Schedule_store.store_error_to_string err)
  in
  let first_id = append schedule_id "one" 101.0 in
  let second_id = append schedule_id "two" 102.0 in
  ignore (append schedule_id "three" 103.0);
  let fourth_id = append schedule_id "four" 104.0 in
  ignore (append schedule_id "five" 105.0);
  let foreign_id = append other_schedule "other" 106.0 in
  let list_notes id extra =
    dispatch_exn config Tool_schemas_schedule.List_notes
      (`Assoc ([ "schedule_id", `String id; "limit", `Int 2 ] @ extra))
  in
  let open Yojson.Safe.Util in
  let bodies result =
    Tool_result.data result |> member "notes" |> to_list
    |> List.map (fun note -> note |> member "body" |> to_string)
  in
  let newest = list_notes schedule_id [] in
  check bool "newest page succeeds" true (Tool_result.is_success newest);
  check (list string) "newest window is oldest first" [ "four"; "five" ] (bodies newest);
  check int "count includes all notes for this schedule" 5
    (Tool_result.data newest |> member "total_count" |> to_int);
  check bool "older notes are reported" true
    (Tool_result.data newest |> member "has_more_older" |> to_bool);
  check string "cursor is the oldest returned note" fourth_id
    (Tool_result.data newest |> member "next_before_note_id" |> to_string);
  ignore (append schedule_id "six" 107.0);
  let middle = list_notes schedule_id [ "before_note_id", `String fourth_id ] in
  check (list string) "a later append does not shift the preceding page"
    [ "two"; "three" ] (bodies middle);
  check int "each response counts the state it read" 6
    (Tool_result.data middle |> member "total_count" |> to_int);
  check string "the next anchor advances toward older notes" second_id
    (Tool_result.data middle |> member "next_before_note_id" |> to_string);
  let oldest = list_notes schedule_id [ "before_note_id", `String second_id ] in
  check (list string) "oldest page is reachable" [ "one" ] (bodies oldest);
  check bool "oldest page reports completion" false
    (Tool_result.data oldest |> member "has_more_older" |> to_bool);
  check bool "complete history has no next anchor" true
    (Tool_result.data oldest |> member "next_before_note_id" = `Null);
  check (list string) "refresh reads the new note" [ "five"; "six" ]
    (bodies (list_notes schedule_id []));
  check (list string) "a cursor at the first note yields an empty page" []
    (bodies (list_notes schedule_id [ "before_note_id", `String first_id ]));
  ignore (append schedule_id "backdated" 100.5);
  let refreshed = list_notes schedule_id [] in
  check (list string) "an earlier timestamp can leave the newest window unchanged"
    [ "five"; "six" ] (bodies refreshed);
  check int "the changed count signals that the history must be rescanned" 7
    (Tool_result.data refreshed |> member "total_count" |> to_int);
  let rec scan before accumulated =
    let extra = match before with None -> [] | Some id -> [ "before_note_id", `String id ] in
    let page = list_notes schedule_id extra in
    let accumulated = bodies page @ accumulated in
    match Tool_result.data page |> member "next_before_note_id" with
    | `Null -> accumulated
    | `String id -> scan (Some id) accumulated
    | _ -> fail "the next note anchor must be a string or null"
  in
  check (list string) "a fresh scan includes a later backdated append"
    [ "backdated"; "one"; "two"; "three"; "four"; "five"; "six" ]
    (scan None []);
  List.iter
    (fun (label, cursor) ->
       check bool label false
         (Tool_result.is_success (list_notes schedule_id [ "before_note_id", cursor ])))
    [ "foreign note id is refused", `String foreign_id
    ; "unknown note id is refused", `String "unknown"
    ; "blank note id is refused", `String ""
    ; "non-string note id is refused", `Int 1
    ]
;;

let test_note_tool_distinguishes_missing_schedule_from_unreadable_ledger () =
  with_config @@ fun config ->
  let schedule_id = "note-tool-corruption" in
  ignore (create_service_exn config ~schedule_id ~due_at:future_due_at
            ~payload:(keeper_wake_payload "wake") ());
  let primary = Filename.concat (Workspace_utils.masc_dir config) "schedules.json" in
  let mirror = primary ^ ".last-good" in
  let note schedule_id =
    dispatch_exn config Tool_schemas_schedule.Add_note
      (`Assoc [ "schedule_id", `String schedule_id; "body", `String "reviewed" ])
  in
  let primary_before = Workspace_core.read_text config primary in
  let mirror_before = Workspace_core.read_text config mirror in
  (match Tool_result.failure_class (note "missing-schedule") with
   | Some Tool_result.Workflow_rejection -> ()
   | Some _ | None -> fail "a readable missing schedule must be a workflow refusal");
  check string "absence does not change primary" primary_before (Workspace_core.read_text config primary);
  check string "absence does not change mirror" mirror_before (Workspace_core.read_text config mirror);
  Workspace_core.write_text config primary "{not json";
  Workspace_core.write_text config mirror "}also not json";
  let corrupt_primary = Workspace_core.read_text config primary in
  let corrupt_mirror = Workspace_core.read_text config mirror in
  (match Tool_result.failure_class (note schedule_id) with
   | Some Tool_result.Runtime_failure -> ()
   | Some _ | None -> fail "an unreadable note ledger must be a runtime failure");
  check string "corrupt primary is preserved" corrupt_primary (Workspace_core.read_text config primary);
  check string "corrupt mirror is preserved" corrupt_mirror (Workspace_core.read_text config mirror)
;;

let test_note_tool_reports_actual_primary_write_failure () =
  with_config @@ fun config ->
  let schedule_id = "note-tool-write-failure" in
  ignore (create_service_exn config ~schedule_id ~due_at:future_due_at
            ~payload:(keeper_wake_payload "wake") ());
  let primary = Filename.concat (Workspace_utils.masc_dir config) "schedules.json" in
  let mirror = primary ^ ".last-good" in
  let primary_before = Workspace_core.read_text config primary in
  let mirror_before = Workspace_core.read_text config mirror in
  (* Backend.FileSystem.set opens this sibling for output after the valid
     ledger read. A directory there refuses that write even as root. *)
  let staging = primary ^ ".tmp-atomic" in
  Unix.mkdir staging 0o755;
  Fun.protect ~finally:(fun () -> Unix.rmdir staging) @@ fun () ->
  let result =
    dispatch_exn config Tool_schemas_schedule.Add_note
      (`Assoc [ "schedule_id", `String schedule_id; "body", `String "reviewed" ])
  in
  (match Tool_result.failure_class result with
   | Some Tool_result.Runtime_failure -> ()
   | Some _ | None -> fail "note persistence failure must be a runtime failure");
  check string "failed primary write preserves primary" primary_before (Workspace_core.read_text config primary);
  check string "failed primary write preserves mirror" mirror_before (Workspace_core.read_text config mirror)
;;

(* Compose the public schedule tools with real durable queue transitions.
   Queue seeds represent accepted occurrences, not model/runtime execution. *)
let f1_ok label = function
  | Ok value -> value
  | Error detail -> failf "%s: %s" label detail
;;

let f1_state config keeper_name =
  Keeper_event_queue_persistence.load_state_result
    ~base_path:config.Workspace.base_path ~keeper_name |> f1_ok "read queue"
;;

let f1_seed config keeper_name schedule_id occurrence =
  let source : Keeper_event_queue.stimulus =
    { post_id = "f1-" ^ occurrence; urgency = Keeper_event_queue.Normal
    ; arrived_at = 1.0
    ; payload = Schedule_due
        { schedule_id; schedule_instance_id = "instance-" ^ occurrence
        ; occurrence_id = occurrence; due_at = 1.0; payload_digest = "f1-digest"
        ; title = None; message = "old occurrence"; result_delivery = None }
    }
  in
  Keeper_event_queue_persistence.update_result
    ~base_path:config.Workspace.base_path ~keeper_name
    (fun pending -> Keeper_event_queue.enqueue pending source)
  |> f1_ok "seed accepted occurrence";
  source
;;

let f1_create config schedule_id =
  check bool "public create succeeds" true
    (Tool_result.is_success
       (dispatch_exn config Tool_schemas_schedule.Create_request
          (create_args ~schedule_id ())));
  stored_schedule config schedule_id
;;

let f1_cancel config schedule_id =
  dispatch_exn config Tool_schemas_schedule.Cancel_request
    (`Assoc [ "schedule_id", `String schedule_id; "reason", `String "withdraw old work" ])
;;

let f1_empty config keeper_name =
  check int (keeper_name ^ " has no pending work") 0
    (f1_state config keeper_name |> Keeper_event_queue_state.pending |> Keeper_event_queue.length)
;;

let f1_transfer_commit config ~from_keeper ~to_keeper source operation_id =
  let selection =
    f1_state config from_keeper |> Keeper_event_queue_state.pending_selections
    |> List.find (fun (selection : Keeper_event_queue_state.pending_selection) ->
         Keeper_event_queue.stimulus_identity_equal source selection.source)
  in
  let meta = match Keeper_meta_store.read_meta config to_keeper with
    | Ok (Some meta) -> meta
    | Ok None -> fail "missing transfer target metadata"
    | Error detail -> fail detail
  in
  let transfer : Keeper_event_queue_persistence.accepted_transfer =
    { source; source_incarnation = selection.admitted_revision
    ; operator_operation_id = operation_id; from_keeper; to_keeper
    ; target_trace_id = meta.runtime.trace_id }
  in
  Keeper_event_queue_persistence.transfer_pending_accepted_result
    ~base_path:config.Workspace.base_path ~keeper_name:from_keeper
    ~applied_at:2.0 ~transfer () |> f1_ok "commit transfer outbox" |> ignore;
  transfer
;;

let f1_recover config keeper_name =
  match Keeper_event_queue_recovery.project_owner_result
          ~base_path:config.Workspace.base_path ~keeper_name with
  | Ok Keeper_event_queue_recovery.Transition_converged -> ()
  | Ok _ -> fail "expected transfer recovery convergence"
  | Error error -> fail (Keeper_event_queue_recovery.projection_error_to_string error)
;;

let test_cancel_finds_old_target_and_all_instances () =
  with_config @@ fun config ->
  let schedule_id = "f1-old-target" in
  ignore (f1_create config schedule_id : Schedule_domain.schedule_request);
  let meta = match Keeper_meta_store.read_meta config "schedule-keeper" with
    | Ok (Some meta) -> meta | _ -> fail "missing old owner metadata" in
  Keeper_meta_store.replace_snapshot config { meta with paused = true }
  |> f1_ok "pause old owner";
  (* More accepted instances than the retained terminal-wake history bound.
     None is found through ledger wake history or live registry registration. *)
  for n = 0 to Schedule_store.terminal_wakes_retained_per_schedule do
    ignore (f1_seed config "schedule-keeper" schedule_id (string_of_int n)
            : Keeper_event_queue.stimulus)
  done;
  let unrelated = f1_seed config "schedule-keeper" "another-public-id" "unrelated" in
  register_wake_target config "replacement-keeper";
  check bool "public retarget succeeds" true
    (Tool_result.is_success (dispatch_exn config Tool_schemas_schedule.Update_request
       (`Assoc [ "schedule_id", `String schedule_id
               ; "keeper_name", `String "replacement-keeper"; "message", `String "new target" ])));
  check bool "old owner is absent from live registry" true
    (Option.is_none (Keeper_registry.get ~base_path:config.Workspace.base_path "schedule-keeper"));
  check bool "public cancellation succeeds" true (Tool_result.is_success (f1_cancel config schedule_id));
  check bool "only the unrelated public schedule survives" true
    (f1_state config "schedule-keeper" |> Keeper_event_queue_state.pending
     |> Keeper_event_queue.to_list = [unrelated]);
  f1_empty config "replacement-keeper";
  check bool "cancelled ledger follows withdrawal" true
    ((stored_schedule config schedule_id).status = Schedule_domain.Cancelled)
;;

let test_cancel_keeper_to_lane_still_withdraws () =
  with_config @@ fun config ->
  let schedule_id = "f1-keeper-to-lane" in
  ignore (f1_create config schedule_id : Schedule_domain.schedule_request);
  ignore (f1_seed config "schedule-keeper" schedule_id "before-lane" : Keeper_event_queue.stimulus);
  check bool "public Keeper-to-Lane update succeeds" true
    (Tool_result.is_success (dispatch_exn config Tool_schemas_schedule.Update_request
       (`Assoc [ "schedule_id", `String schedule_id; "installation_id", `String "operator-quiz"
               ; "action", `Assoc [ "kind", `String "compose" ] ])));
  check bool "Lane definition cancels" true (Tool_result.is_success (f1_cancel config schedule_id));
  f1_empty config "schedule-keeper"
;;

let test_cancel_refuses_outbox_then_recovers_multihop () =
  with_config ~strict_executor:true @@ fun config ->
  let schedule_id = "f1-multi-hop" in
  ignore (f1_create config schedule_id : Schedule_domain.schedule_request);
  register_wake_target config "transfer-middle";
  register_wake_target config "transfer-final";
  let source = f1_seed config "schedule-keeper" schedule_id "transferred" in
  ignore (f1_transfer_commit config ~from_keeper:"schedule-keeper"
      ~to_keeper:"transfer-middle" source "first-hop"
      : Keeper_event_queue_persistence.accepted_transfer);
  check bool "unfinished transfer refuses public cancel" false
    (Tool_result.is_success (f1_cancel config schedule_id));
  check bool "refused cancellation preserves active definition" true
    ((stored_schedule config schedule_id).status = Schedule_domain.Scheduled);
  f1_recover config "schedule-keeper";
  ignore (f1_transfer_commit config ~from_keeper:"transfer-middle"
      ~to_keeper:"transfer-final" source "second-hop"
      : Keeper_event_queue_persistence.accepted_transfer);
  check bool "second unfinished transfer also refuses cancel" false
    (Tool_result.is_success (f1_cancel config schedule_id));
  f1_recover config "transfer-middle";
  check bool "cancel after both recoveries succeeds" true
    (Tool_result.is_success (f1_cancel config schedule_id));
  List.iter (f1_empty config) [ "schedule-keeper"; "transfer-middle"; "transfer-final" ]
;;

let f1_snapshot config keeper_name =
  Filename.concat
    (Filename.concat (Common.keepers_runtime_dir_of_base ~base_path:config.Workspace.base_path) keeper_name)
    Keeper_event_queue_persistence.snapshot_filename
;;

let test_cancel_strict_read_error_preserves_pending () =
  with_config @@ fun config ->
  let schedule_id = "f1-corrupt-owner" in
  ignore (f1_create config schedule_id : Schedule_domain.schedule_request);
  ignore (f1_seed config "schedule-keeper" schedule_id "valid" : Keeper_event_queue.stimulus);
  ignore (f1_seed config "z-corrupt-owner" "unrelated" "corrupt" : Keeper_event_queue.stimulus);
  let snapshot = f1_snapshot config "z-corrupt-owner" in
  Out_channel.with_open_bin snapshot (fun channel -> output_string channel "invalid queue");
  check bool "corrupt current state refuses cancel" false
    (Tool_result.is_success (f1_cancel config schedule_id));
  check int "preflight failure preserves pending work" 1
    (f1_state config "schedule-keeper" |> Keeper_event_queue_state.pending |> Keeper_event_queue.length);
  check bool "ledger remains active" true
    ((stored_schedule config schedule_id).status = Schedule_domain.Scheduled)
;;

let test_cancel_discovery_error_is_not_empty_success () =
  with_config @@ fun config ->
  let schedule_id = "f1-discovery" in
  ignore (f1_create config schedule_id : Schedule_domain.schedule_request);
  let root = Common.keepers_runtime_dir_of_base ~base_path:config.Workspace.base_path in
  rm_rf root;
  Out_channel.with_open_bin root (fun channel -> output_string channel "not a directory");
  check bool "invalid discovery root refuses cancel" false
    (Tool_result.is_success (f1_cancel config schedule_id));
  check bool "discovery refusal preserves definition" true
    ((stored_schedule config schedule_id).status = Schedule_domain.Scheduled)
;;

let test_cancel_partial_withdrawal_does_not_claim_rollback () =
  with_config @@ fun config ->
  let schedule_id = "f1-partial" in
  ignore (f1_create config schedule_id : Schedule_domain.schedule_request);
  ignore (f1_seed config "a-first-owner" schedule_id "first" : Keeper_event_queue.stimulus);
  ignore (f1_seed config "z-last-owner" schedule_id "last" : Keeper_event_queue.stimulus);
  let injected = ref false in
  Keeper_event_queue_persistence.install_state_change_observer (fun () ->
    if not !injected then (
      injected := true;
      Out_channel.with_open_bin (f1_snapshot config "z-last-owner")
        (fun channel -> output_string channel "injected read failure after first withdrawal")));
  Fun.protect
    ~finally:(fun () -> Keeper_event_queue_persistence.install_state_change_observer ignore)
    (fun () ->
       check bool "partial withdrawal returns failure" false
         (Tool_result.is_success (f1_cancel config schedule_id)));
  check bool "fault was injected after the first durable change" true !injected;
  f1_empty config "a-first-owner";
  check bool "schedule ledger remains active after partial failure" true
    ((stored_schedule config schedule_id).status = Schedule_domain.Scheduled);
  check bool "first withdrawal retains a canonical disposition" true
    (Option.is_some (f1_state config "a-first-owner" |> Keeper_event_queue_state.last_transition))
;;

let test_cancel_ledger_write_failure_retains_withdrawal () =
  with_config @@ fun config ->
  let schedule_id = "f1-ledger-write-failure" in
  ignore (f1_create config schedule_id : Schedule_domain.schedule_request);
  ignore (f1_seed config "schedule-keeper" schedule_id "before-write" : Keeper_event_queue.stimulus);
  let primary = Filename.concat (Workspace_utils.masc_dir config) "schedules.json" in
  let before = Workspace_core.read_text config primary in
  let staging = primary ^ ".tmp-atomic" in
  Unix.mkdir staging 0o755;
  Fun.protect ~finally:(fun () -> Unix.rmdir staging) (fun () ->
    check bool "ledger publication failure returns failure" false
      (Tool_result.is_success (f1_cancel config schedule_id)));
  f1_empty config "schedule-keeper";
  check string "failed publication preserves the active ledger" before
    (Workspace_core.read_text config primary);
  check bool "retry converges without restoring old work" true
    (Tool_result.is_success (f1_cancel config schedule_id))
;;

let () =
  run "Schedule_tool_wiring"
    [ ( "wiring"
      , [ test_case "cancel ledger write failure retains withdrawal" `Quick test_cancel_ledger_write_failure_retains_withdrawal
        ; test_case "cancel finds old target and all instances" `Quick test_cancel_finds_old_target_and_all_instances
        ; test_case "Keeper-to-Lane cancellation withdraws old wakes" `Quick test_cancel_keeper_to_lane_still_withdraws
        ; test_case "unfinished transfer refuses cancel then recovers multi-hop" `Quick test_cancel_refuses_outbox_then_recovers_multihop
        ; test_case "cancel refuses corrupt durable owner" `Quick test_cancel_strict_read_error_preserves_pending
        ; test_case "cancel refuses discovery failure" `Quick test_cancel_discovery_error_is_not_empty_success
        ; test_case "partial cancel preserves durable effects and reports failure" `Quick test_cancel_partial_withdrawal_does_not_claim_rollback
        ; test_case "note pages retain older history across appends" `Quick
            test_note_pages_keep_older_history_when_new_notes_arrive
        ; test_case "note distinguishes absent schedule from unreadable ledger" `Quick
            test_note_tool_distinguishes_missing_schedule_from_unreadable_ledger
        ; test_case "note reports actual primary write failure" `Quick
            test_note_tool_reports_actual_primary_write_failure
        ; test_case "flat tool surface" `Quick test_flat_tool_surface
        ; test_case "create list get cancel" `Quick test_create_list_get_cancel
        ; test_case "update keeps public id and replaces instance" `Quick
            test_update_keeps_public_id_and_replaces_instance
        ; test_case "update omitted kind keeps daily" `Quick
            test_update_omitted_kind_preserves_daily
        ; test_case "update omitted kind keeps one-shot" `Quick
            test_update_omitted_kind_preserves_one_shot
        ; test_case "update requires id and active row" `Quick
            test_update_requires_id_and_active_row
        ; test_case "content edit preserves time and recurrence" `Quick
            test_content_edit_preserves_due_and_recurrence
        ; test_case "content edit keeps the stored expiry" `Quick
            test_content_edit_keeps_expiry
        ; test_case "content edit keeps a concurrent retime" `Quick
            test_content_edit_preserves_concurrently_changed_due
        ; test_case "due edit keeps a concurrent daily-to-interval change" `Quick
            test_due_edit_keeps_concurrent_daily_to_interval
        ; test_case "due edit keeps a concurrent interval-to-one-shot change" `Quick
            test_due_edit_keeps_concurrent_interval_to_one_shot
        ; test_case "results survive the checkpoint encoder" `Quick
            test_results_survive_the_checkpoint_encoder
        ; test_case "creation boundary owns result delivery destination" `Quick
            test_creation_boundary_owns_result_delivery_destination
        ; test_case "update keeps the creator's result delivery" `Quick
            test_update_keeps_the_creators_result_delivery
        ; test_case "get recurring schedule after accept advance" `Quick
            test_get_recurring_schedule_after_accept_advance
        ; test_case "create accepts explicit ISO-8601 offset" `Quick
            test_create_accepts_explicit_iso8601_offset
        ; test_case "removed convenience input does not synthesize payload" `Quick
            test_removed_convenience_input_does_not_synthesize_payload
        ; test_case "unregistered wake target rejected" `Quick
            test_unregistered_wake_target_rejected
        ; test_case "unknown payload kind rejected by the validator" `Quick
            test_unknown_payload_kind_is_rejected_by_the_validator
        ; test_case "unknown field rejected before persistence" `Quick
            test_unknown_field_is_rejected_before_persistence
        ; test_case "empty call rejected by name" `Quick
            test_empty_call_is_rejected_by_name
        ; test_case "every declared field still creates" `Quick
            test_known_fields_still_create
        ; test_case "payload contracts are schema only" `Quick
            test_payload_contracts_are_schema_only
        ; test_case "keeper wake schema validation" `Quick
            test_keeper_wake_schema_validation
        ; test_case "lane act schedule is created from its own fields" `Quick
            test_lane_act_schedule_is_created_from_its_own_fields
        ; test_case "due signal and dashboard projection" `Quick
            test_due_signal_and_dashboard_projection
        ; test_case "schedule store error is explicit" `Quick
            test_schedule_store_error_is_explicit
        ; test_case "projection reports read failure as unknown" `Quick
            test_projection_reports_read_failure_as_unknown
        ; test_case "tools response no longer carries the projection" `Quick
            test_tools_response_no_longer_carries_the_projection
        ; test_case "Keeper wake target validation is fenced" `Quick
            test_keeper_wake_target_validation_is_inside_creation_fence
        ; test_case "Keeper wake creation respects shutdown fence" `Quick
            test_keeper_wake_creation_respects_shutdown_fence
        ; test_case "tool response carries structured recurrence" `Quick
            test_tool_response_carries_structured_recurrence
        ; test_case "create refuses a due time behind the clock" `Quick
            test_create_refuses_a_due_time_behind_the_clock
        ; test_case "the current second is not past" `Quick
            test_the_current_second_is_not_past
        ; test_case "cancel refusal says the state and the last wake" `Quick
            test_cancel_refusal_says_the_state_and_the_last_wake
        ; test_case "list reads the owner it is asked for" `Quick
            test_list_reads_the_owner_it_is_asked_for
        ; test_case "list pages by schedule_id" `Quick
            test_list_pages_by_schedule_id
        ; test_case "an unnamed caller names the actor itself" `Quick
            test_an_unnamed_caller_names_the_actor_itself
        ; test_case "the recorded actor is the caller, not an argument" `Quick
            test_the_recorded_actor_is_the_caller_not_an_argument
        ; test_case "a keeper cannot cancel another keeper's schedule" `Quick
            test_a_keeper_cannot_cancel_another_keepers_schedule
        ; test_case "an update keeps the row's actors and its target rule" `Quick
            test_an_update_keeps_the_rows_actors_and_its_target_rule
        ; test_case "recipient edit rechecks the current target" `Quick
            test_recipient_edit_rechecks_the_current_target
        ; test_case "locked cancel refuses a former recipient before withdrawal" `Quick
            test_locked_cancel_refuses_a_former_recipient_before_withdrawal
        ; test_case "locked replacement uses the current scheduler" `Quick
            test_locked_replacement_uses_the_current_scheduler
        ; test_case "a named caller is the actor, not the argument" `Quick
            test_a_named_caller_is_the_actor_not_the_argument
        ; test_case "a call gives exactly one due input" `Quick
            test_a_call_gives_exactly_one_due_input
        ; test_case "create refuses an interval below the runner tick" `Quick
            test_create_refuses_an_interval_below_the_runner_tick
        ; test_case "due_in_sec counts from the dispatch clock" `Quick
            test_due_in_sec_counts_from_the_dispatch_clock
        ; test_case "a calendar first due counts from dispatch, not requested_at" `Quick
            test_a_calendar_first_due_counts_from_dispatch_not_requested_at
        ; test_case "update refuses a due time moved behind the clock" `Quick
            test_update_refuses_a_due_time_moved_behind_the_clock
        ; test_case "a limit outside its range is refused" `Quick
            test_a_limit_outside_its_range_is_refused
        ; test_case "a cursor belongs to the filters that issued it" `Quick
            test_a_cursor_belongs_to_the_filters_that_issued_it
        ; test_case "status active lists every status that is not terminal" `Quick
            test_status_active_lists_every_status_that_is_not_terminal
        ; test_case "a mistyped deciding argument is refused" `Quick
            test_a_mistyped_deciding_argument_is_refused
        ; test_case "declared bounds match the handler" `Quick
            test_declared_bounds_match_the_handler
        ] )
    ]
;;
