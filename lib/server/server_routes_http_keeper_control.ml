open Server_auth

module Http = Http_server_eio
module Stream = Server_routes_http_keeper_stream

(* Answer a held tool call.

   The reply says whether a wait was actually released. A late answer -- one
   whose call already timed out, or was never held -- reports [settled: false]
   rather than reading as success, so an operator is not told a call was
   approved when nothing was listening for it.

   A late answer is not discarded, though: when the wait it names timed out
   here, the decision is remembered in {!Keeper_late_approval} and the reply
   says [remembered: true]. The operator's decision is about the call, and
   the retried call -- same tool, same arguments, new call id -- is then
   settled by it once instead of asking the same question again. An answer
   that names no wait this process ever held matches nothing and is dropped,
   as before. *)
let handle_keeper_tool_approval ~actor state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let config = Mcp_server.workspace_config state in
    let base_path = config.base_path in
    let parsed =
      Result.bind (Server_json_object_body.fields body_str) (fun fields ->
          let json = `Assoc fields in
          let open Result.Syntax in
          let* stripped_json =
            match Workspace.validate_expected_workspace ~config json with
            | Ok payload -> Ok payload
            | Error error -> Error (Workspace.expected_workspace_error_message error)
          in
          let fields =
            match stripped_json with
            | `Assoc f -> f
            | _ -> fields
          in
          let field name =
            match List.assoc_opt name fields with
            | Some (`String value) -> Ok (String.trim value)
            | Some _ | None ->
              Error (Printf.sprintf "%s (string) is required" name)
          in
          let* keeper_name = field "name" in
          let* tool_call_id = field "tool_call_id" in
          let* approval_id =
            match List.filter (fun (key, _) -> String.equal key "approval_id") fields with
            | [ (_, `String value) ] when String.trim value <> "" -> Ok value
            | _ -> Error "approval_id (nonempty string) is required exactly once"
          in
          let* decision_raw = field "decision" in
          (match Keeper_tool_approval_registry.decision_of_string decision_raw with
           | Some decision -> Ok (keeper_name, tool_call_id, approval_id, decision)
           | None ->
             Error
               (Printf.sprintf "decision must be approve or deny, got %S"
                  decision_raw)))
    in
    match parsed with
    | Error msg ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (Stream.keeper_chat_stream_error_json msg)
    | Ok (keeper_name, tool_call_id, approval_id, decision) ->
      if not (Keeper_registry.is_registered ~base_path keeper_name)
      then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (Stream.keeper_chat_stream_error_json "keeper not registered")
      else (
        let settled =
          Keeper_tool_approval_registry.settle
            (Keeper_tool_approval_registry.shared ())
            ~keeper_name ~tool_call_id ~approval_id decision
        in
        let remembered =
          if settled then false
          else
            (* The wait is gone, but if it timed out here the answer still
               descends from a question this operator was really shown, so it
               stands for the identical retried call. *)
            match
              Keeper_late_approval.remember_late
                (Keeper_late_approval.shared ())
                ~base_path ~keeper_name ~tool_call_id ~approval_id ~actor decision ()
            with
            | Keeper_late_approval.Remembered _ -> true
            | Keeper_late_approval.No_matching_ask -> false
        in
        Log.Keeper.info
          "keeper_tool_approval: keeper=%s tool_call_id=%s approval_id=%s decision=%s actor=%s settled=%b remembered=%b"
          keeper_name tool_call_id approval_id
          (Keeper_tool_approval_registry.decision_to_string decision)
          actor settled remembered;
        respond_json_value_with_cors ~status:`OK request reqd
          (`Assoc
             [ ("settled", `Bool settled)
             ; ("remembered", `Bool remembered)
             ; ( "decision"
               , `String (Keeper_tool_approval_registry.decision_to_string decision) )
             ; ("actor", `String actor)
             ])))
;;

(* The waits live only in the registry while their turns are parked, so this
   is a projection of live state, not a store read. Listing them is what lets
   an operator answer a turn whose owning stream watcher is gone — without
   this, such a call could only time out (masc#30034). [asked_at] is the
   registry clock's epoch reading; the consumer derives display age against
   its own clock rather than trusting one computed here. *)
let handle_keeper_tool_approvals_list _state request reqd =
  let held =
    Keeper_tool_approval_registry.pending
      (Keeper_tool_approval_registry.shared ())
  in
  respond_json_value_with_cors ~status:`OK request reqd
    (`Assoc
       [ ( "pending"
         , `List
             (List.map
                (fun (p : Keeper_tool_approval_registry.pending) ->
                  `Assoc
                    [ ("keeper", `String p.keeper_name)
                    ; ("tool_call_id", `String p.tool_call_id)
                    ; ("approval_id", `String p.approval_id)
                    ; ("tool", `String p.tool_name)
                    ; ("args", `String p.args)
                    ; ("question", `String p.question)
                    ; ("because", `String p.because)
                    ; ("asked_at", `Float p.asked_at)
                    ; ("timeout_sec", `Float p.timeout_sec)
                    ])
                held) )
       ])
;;

(* Which keepers are mid-turn right now, one row per registered keeper. The
   running-turn slot lives in the Keeper Owner (process memory), not in the
   durable meta a keeper list is read from, so surfaces that want an
   "answering now" badge poll this projection instead of growing the meta
   contract. [started_at_unix] is the owner clock's epoch reading; the
   consumer derives display age against its own clock (same policy as
   [asked_at] above). An unreadable name census is an error response, not an
   empty fleet: reading unreadable as "nobody is running" would hide every
   badge exactly when the store is broken. *)
let handle_keeper_turns_list state request reqd =
  let preparation_details_for = Server_utils.query_param request "preparation_details_for" in
  let config = Mcp_server.workspace_config state in
  match Keeper_meta_store.keeper_names_result config with
  | exception (Eio.Cancel.Cancelled _ as exn) -> raise exn
  | exception exn ->
    respond_json_value_with_cors ~status:`Internal_server_error request reqd
      (`Assoc
         [ ( "error"
           , `String
               (Printf.sprintf "keeper name census failed: %s"
                  (Printexc.to_string exn)) )
         ])
  | Error detail ->
    respond_json_value_with_cors ~status:`Internal_server_error request reqd
      (`Assoc
         [ ( "error"
           , `String (Printf.sprintf "keeper name census failed: %s" detail) )
         ])
  | Ok keeper_names ->
    let waiting_snapshot =
      Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
        Server_keeper_waiting_inventory.keeper_json_by_name config)
    in
    let waiting_by_name, waiting_errors =
      match waiting_snapshot with
      | Error errors -> [], errors
      | Ok rows -> rows, []
    in
    let waiting_json keeper_name =
      Option.value ~default:`Null (List.assoc_opt keeper_name waiting_by_name)
    in
    let row keeper_name =
      match
        Keeper_owner_registry.get ~base_path:config.base_path ~keeper_name
      with
      | Error error ->
        `Assoc
          [ ("keeper_name", `String keeper_name)
          ; ("status", `String "unavailable")
          ; ( "detail"
            , `String (Keeper_owner_registry.lookup_error_to_string error) )
          ; ("turn", `Null)
          ; ("waiting", waiting_json keeper_name)
          ]
      | Ok owner ->
        let turn_json =
          match Keeper_owner.turn_in_flight owner with
          | None -> `Null
          | Some (turn : Keeper_owner.turn_in_flight) ->
            (* The live glance rides only a running turn: the preview plane
               is process memory that outlives turn end unread, and gating
               it here is what keeps a stale tail unreachable. *)
            let preview_json =
              match Keeper_turn_preview.current_for_turn ~keeper_name ~interrupt_token:turn.interrupt_token with
              | None -> `Null
              | Some (preview : Keeper_turn_preview.t) ->
                (* The name selects detail volume only. The actual Owner token
                   above remains the identity authority for the preview. *)
                Keeper_turn_preview.to_json
                  ~include_preparation_timeline:(Option.exists (String.equal keeper_name) preparation_details_for)
                  preview
            in
            `Assoc
              [ ("lane", `String (Keeper_owner.turn_lane_to_string turn.lane))
              ; ("turn_ref", match Keeper_autonomous_stream.current ~base_path:config.base_path ~keeper_name with
                   | None -> `Null | Some turn_ref -> Ids.Turn_ref.to_yojson turn_ref)
              ; ("started_at_unix", `Float turn.started_at)
              ; ("interrupt_token", `String (Keeper_interrupt_token.to_string turn.interrupt_token))
              ; ("preview", preview_json)
              ]
        in
        Tool_args.ok_assoc
          [ ("keeper_name", `String keeper_name)
          ; ("chat_control_token", `String (Keeper_owner.chat_control_token owner))
          ; ("turn", turn_json)
          ; ("waiting", waiting_json keeper_name)
          ]
    in
    respond_json_value_with_cors ~status:`OK request reqd
      (`Assoc
         [ ("schema", `String "masc.keeper_turns.v1")
         ; ("keepers", `List (List.map row (List.sort String.compare keeper_names)))
         ; ("waiting_errors", `List waiting_errors)
         ])
;;

(* The per-keeper approval stance. GET lists the overrides — a keeper absent
   from the list is [auto] — and POST sets one. Setting is logged at the
   server, not only echoed to the caller: [yolo] means every tool call runs
   unasked, and the operator who set it is not always the operator reading
   the logs later. *)
let handle_keeper_tool_approval_mode_get _state request reqd =
  let store = Keeper_tool_approval_mode.shared () in
  let overrides = Keeper_tool_approval_mode.overrides store in
  let restore_error = Keeper_tool_approval_mode.last_restore_error store in
  respond_json_value_with_cors ~status:`OK request reqd
    (`Assoc
       [ ( "overrides"
         , `List
             (List.map
                (fun (keeper_name, mode) ->
                  `Assoc
                    [ ("keeper", `String keeper_name)
                    ; ( "mode"
                      , `String (Keeper_tool_approval_mode.mode_to_string mode)
                      )
                    ])
                overrides) )
       ; ("default", `String "auto")
       ; ( "restore_error"
         , match restore_error with
           | Some detail -> `String detail
           | None -> `Null )
       ])
;;

let handle_keeper_tool_approval_mode_set ~actor state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let parsed =
      Result.bind (Server_json_object_body.fields body_str) (fun fields ->
          let field name =
            match List.assoc_opt name fields with
            | Some (`String value) -> Ok (String.trim value)
            | Some _ | None ->
              Error (Printf.sprintf "%s (string) is required" name)
          in
          let open Result.Syntax in
          let* keeper_name = field "name" in
          let* mode_raw = field "mode" in
          (match Keeper_tool_approval_mode.mode_of_string mode_raw with
           | Some mode -> Ok (keeper_name, mode)
           | None ->
             Error
               (Printf.sprintf "mode must be auto or yolo, got %S" mode_raw)))
    in
    match parsed with
    | Error msg ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (Stream.keeper_chat_stream_error_json msg)
    | Ok (keeper_name, mode) ->
      if not (Keeper_registry.is_registered ~base_path keeper_name)
      then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (Stream.keeper_chat_stream_error_json "keeper not registered")
      else (
        match
          Keeper_tool_approval_mode.set
            (Keeper_tool_approval_mode.shared ())
            ~base_path ~actor ~keeper_name mode
        with
        | Error detail ->
          respond_json_value_with_cors ~status:`Internal_server_error request
            reqd
            (Stream.keeper_chat_stream_error_json detail)
        | Ok outcome ->
          let audit_error =
            match outcome with
            | Keeper_tool_approval_mode.Applied -> None
            | Keeper_tool_approval_mode.Applied_audit_failed detail ->
              Log.Keeper.warn
                "keeper_tool_approval_mode: audit failed keeper=%s mode=%s actor=%s: %s"
                keeper_name
                (Keeper_tool_approval_mode.mode_to_string mode)
                actor
                detail;
              Some detail
          in
          Log.Keeper.info
            "keeper_tool_approval_mode: keeper=%s mode=%s actor=%s"
            keeper_name
            (Keeper_tool_approval_mode.mode_to_string mode)
            actor;
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc
               ([ ("keeper", `String keeper_name)
                ; ( "mode"
                  , `String (Keeper_tool_approval_mode.mode_to_string mode) )
                ]
                @
                match audit_error with
                | None -> []
                | Some detail -> [ ("audit_error", `String detail) ]))))
;;

let control_public_error kind detail =
  let error = Server_keeper_chat_public_error.make
      ~incident_id:(Random_id.uuid_v7 ()) kind in
  Log.Keeper.warn "keeper_chat_control incident_id=%s code=%s detail=%s"
    error.incident_id error.code detail;
  error
;;

let control_failure_fields kind detail =
  control_public_error kind detail |> Server_keeper_chat_public_error.failure_fields
;;

let control_error_json kind detail =
  control_public_error kind detail |> Server_keeper_chat_public_error.to_json
;;

let handle_keeper_run_next state ~actor request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let parse_predecessors = function
      | None -> Ok None
      | Some (`List ids) ->
        let rec parse reversed = function
          | [] -> Ok (Some (List.rev reversed))
          | `String id :: rest ->
            (match Keeper_chat_operation.Operation_id.of_string id with
             | Ok operation_id -> parse (operation_id :: reversed) rest
             | Error error -> Error error)
          | _ -> Error "priority_predecessors must contain request IDs" in
        parse [] ids
      | Some _ -> Error "priority_predecessors must be a list of request IDs" in
    let parsed =
      try match Yojson.Safe.from_string body with
      | `Assoc fields ->
        (match List.assoc_opt "name" fields, List.assoc_opt "request_id" fields,
          List.assoc_opt "interrupt_token" fields,
          List.assoc_opt "priority_predecessors" fields with
          | Some (`String name), Some (`String id), token, predecessors
            when String.trim name <> "" ->
            let token = match token with
              | None | Some `Null -> Ok None
              | Some (`String token) -> Result.map Option.some (Keeper_interrupt_token.of_string token)
              | Some _ -> Error "interrupt_token must be a UUID or null" in
            (match Keeper_chat_operation.Operation_id.of_string id, token,
              parse_predecessors predecessors with
             | Ok operation_id, Ok token, Ok predecessors ->
               Ok (name, id, operation_id, token, predecessors)
             | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error)
         | _ -> Error "name and request_id are required")
      | _ -> Error "JSON object required"
      with Yojson.Json_error error -> Error error
    in
    let respond_error status kind detail = respond_json_value_with_cors ~status request reqd
      (control_error_json kind detail) in
    match parsed with
    | Error error -> respond_error `Bad_request Invalid_input error
    | Ok (name, request_id, operation_id, token, priority_predecessors) ->
      match Keeper_owner_registry.exact_operation ~base_path ~keeper_name:name operation_id with
      | Error error -> respond_error `Service_unavailable (Keeper_chat_public_error.of_command_error error)
          (Keeper_owner_registry.command_error_to_string error)
      | Ok None -> respond_error `Not_found Unknown_operation "operation not found"
      | Ok (Some operation) ->
        match Keeper_chat_operation_payload.source_of_json operation.source with
        | Error error -> respond_error `Service_unavailable Store_unavailable error
        | Ok source when not (String.equal actor source.submitted_by) ->
          respond_error `Forbidden Operation_forbidden "only your own queued message can be prioritized"
        | Ok _ ->
          match Keeper_owner_registry.run_next_operation ?priority_predecessors
            ~base_path ~keeper_name:name ~operation_id ~interrupt_token:token () with
          | Error error -> respond_error `Conflict (Keeper_chat_public_error.of_command_error error)
              (Keeper_owner_registry.command_error_to_string error)
          | Ok Keeper_owner.Run_next_paused -> respond_error `Conflict Keeper_paused "Keeper is explicitly paused; resume it before run-next"
          | Ok (Keeper_owner.Run_next_applied result) ->
            let interrupt_error = Option.map
                (control_public_error Server_keeper_chat_public_error.Interrupt_failed)
                result.interrupt_error in
            respond_json_value_with_cors ~status:`OK request reqd
              (Server_keeper_chat_public_error.prioritized_operation_json
                 ~request_id ~signalled:result.signalled ~interrupt_error))
;;

let handle_keeper_memory_catch_up ~actor state request reqd =
  Http.Request.read_body_async reqd (fun body ->
    let config = Mcp_server.workspace_config state in
    let parsed =
      let open Result.Syntax in
      let* fields = Server_json_object_body.fields body in
      let* () = if List.mem_assoc "expected_workspace" fields then Ok ()
        else Error "expected_workspace is required" in
      let* json = Workspace.validate_expected_workspace ~config (`Assoc fields)
        |> Result.map_error Workspace.expected_workspace_error_message in
      let context = "memory catch-up request" in
      let* fields = Candle_json.object_fields ~context json in
      let* name, fields = Candle_json.field ~context "name" Candle_json.as_non_blank fields in
      let* () = Candle_json.finish ~context fields in
      match Keeper_identity.Keeper_id.of_string name with
      | Some keeper -> Ok (Keeper_identity.Keeper_id.to_string keeper)
      | None -> Error "invalid Keeper name" in
    let fail status message = respond_json_value_with_cors ~status request reqd
      (Stream.keeper_chat_stream_error_json message) in
    match parsed with
    | Error message -> fail `Bad_request message
    | Ok keeper_name ->
      let presence = Pool_work.submit (Pool_work.io ~name:__FUNCTION__ (fun () ->
        Keeper_meta_store.read_meta_presence config keeper_name)) in
      match presence with
      | Error detail | Ok (Keeper_meta_store.Meta_not_current detail) ->
        respond_json_value_with_cors ~status:`Service_unavailable request reqd
          (control_error_json Store_unavailable detail)
      | Ok Meta_absent -> fail `Not_found "Keeper metadata is absent"
      | Ok (Meta_present _) ->
        match Env_config.KeeperMemoryOs.librarian_config_state () with
        | Disabled | Invalid -> fail `Conflict "Librarian is disabled or its setting is invalid"
        | Enabled ->
          let outcome = Eio_context.run_on_owner_domain (fun () ->
            if Keeper_memory_lane.initialized () then
              Some (Keeper_librarian_queue_refresh.submit_durable
                ~base_path:config.Workspace.base_path ~keeper_name)
            else None) in
          match outcome with
          | None | Some Keeper_memory_lane.Dropped ->
            fail `Service_unavailable "Librarian executor could not accept this wake"
          | Some Ran_inline ->
            fail `Service_unavailable "Librarian ran without its detached executor; completion is unconfirmed"
          | Some (Submitted | Coalesced as outcome) ->
            let submission = match outcome with
              | Keeper_memory_lane.Submitted -> "submitted"
              | Coalesced -> "coalesced"
              | Ran_inline | Dropped -> "unconfirmed" in
            Log.Keeper.info ~keeper_name "Operator Librarian catch-up %s actor=%s" submission actor;
            respond_json_value_with_cors ~status:`Accepted request reqd
              (`Assoc ["schema", `String "keeper.memory.catch_up.v1";
                "keeper", `String keeper_name; "submission", `String submission;
                "completion", `String "unobserved"]))

let handle_keeper_turn_interrupt ~actor state request reqd =
  Http.Request.read_body_async reqd (fun body_str ->
    let base_path = (Mcp_server.workspace_config state).base_path in
    let target_result =
      Result.bind (Server_json_object_body.fields body_str) (fun fields ->
          (match List.assoc_opt "name" fields with
           | Some (`String s) when String.trim s <> "" ->
             let request_id_result =
               match List.assoc_opt "request_id" fields with
               | None -> Ok None
               | Some (`String value) when String.trim value <> "" ->
                 Ok (Some (String.trim value))
               | Some (`String _) -> Error "request_id must be non-blank"
               | Some _ -> Error "request_id must be a string when present"
             in
             let interrupt_token_result =
               match List.assoc_opt "interrupt_token" fields with
               | None -> Ok None
               | Some (`String token) -> Result.map Option.some (Keeper_interrupt_token.of_string token)
               | Some _ -> Error "interrupt_token must be a UUID"
             in
             let control_result = match List.assoc_opt "expected_control_token" fields with
               | None -> Ok None
               | Some (`String token) when String.trim token <> "" -> Ok (Some token)
               | Some _ -> Error "expected_control_token must be a nonempty string" in
             (match request_id_result, interrupt_token_result, control_result with
              | Ok (Some _), Ok (Some _), _ -> Error "choose request_id or interrupt_token, not both"
              | Ok None, Ok _, Ok (Some _) -> Error "expected_control_token requires an exact request_id"
              | Ok request_id, Ok interrupt_token, Ok control_token -> Ok (String.trim s, request_id, interrupt_token, control_token)
              | Error error, _, _ | _, Error error, _ | _, _, Error error -> Error error)
           (* A blank name trims to "" and then reads as an unregistered
              keeper, so the caller saw 404 for what is a bad request. The
              request_id check below already worked this way. *)
           | Some (`String _) -> Error "name must be non-blank"
           | _ -> Error "name (string) is required"))
    in
    match target_result with
    | Error msg ->
      respond_json_value_with_cors ~status:`Bad_request request reqd
        (control_error_json Invalid_input msg)
    | Ok (keeper_name, request_id, interrupt_token, expected_control_token) ->
      if not (Keeper_registry.is_registered ~base_path keeper_name)
      then
        respond_json_value_with_cors ~status:`Not_found request reqd
          (control_error_json Unknown_keeper "keeper not registered")
      else match interrupt_token with
      | Some token ->
        let fields = match Keeper_owner_registry.pause_observed_turn ~base_path ~keeper_name ~interrupt_token:token with
          | Ok (result, control_token) ->
            ("chat_control_token", `String control_token) ::
            (match result with
             | Keeper_owner.Pending_admission_paused -> ["signalled", `Bool false; "paused", `Bool true; "reason", `String "paused_pending_admission"]
             | Keeper_owner.Interrupt_result Operation_interrupt_signalled -> ["signalled", `Bool true]
             | Interrupt_result (Operation_not_current _) -> ["signalled", `Bool false; "reason", `String "observed_turn_changed"]
             | Interrupt_result Operation_settling -> ["signalled", `Bool false; "reason", `String "settling"]
             | Interrupt_result Operation_maintenance_running ->
               ["signalled", `Bool false; "reason", `String "maintenance_running"]
             | Interrupt_result Operation_slot_held_by_autonomous_turn ->
               ["signalled", `Bool false; "reason", `String "slot_held_by_autonomous_turn"]
             | Interrupt_result (Operation_interrupt_failed detail) ->
               ["signalled", `Bool false; "reason", `String "cancel_failed"]
               @ control_failure_fields Interrupt_failed detail)
          | Error error -> ["signalled", `Bool false; "reason", `String "interrupt_failed"]
              @ control_failure_fields (Keeper_chat_public_error.of_command_error error)
                (Keeper_owner_registry.command_error_to_string error) in
        respond_json_value_with_cors ~status:`OK request reqd (`Assoc (("interrupt_token", `String (Keeper_interrupt_token.to_string token)) :: fields))
      | None ->
        match request_id with
        | Some request_id ->
          (match Keeper_chat_operation.Operation_id.of_string request_id with
           | Error detail -> respond_json_value_with_cors ~status:`Bad_request request reqd
               (control_error_json Invalid_input detail)
           | Ok operation_id ->
             let fields = match Keeper_owner_registry.pause_running_operation ?expected_control_token ~base_path ~keeper_name operation_id with
               | Ok (result, control_token) ->
                 ("chat_control_token", `String control_token) ::
                 (match result with
                  | Keeper_owner.Pending_admission_paused -> ["signalled", `Bool false; "paused", `Bool true; "reason", `String "paused_pending_admission"]
                  | Keeper_owner.Interrupt_result Operation_interrupt_signalled -> ["signalled", `Bool true]
                  | Interrupt_result (Operation_not_current {running_operation_id}) ->
                    ["signalled", `Bool false; "reason", `String "operation_not_current"] @
                    Option.fold ~none:[] ~some:(fun id -> ["current_request_id", `String (Keeper_chat_operation.Operation_id.to_string id)]) running_operation_id
                  | Interrupt_result Operation_settling -> ["signalled", `Bool false; "reason", `String "settling"]
                  | Interrupt_result Operation_maintenance_running ->
                    ["signalled", `Bool false; "reason", `String "maintenance_running"]
                  | Interrupt_result Operation_slot_held_by_autonomous_turn ->
                    ["signalled", `Bool false; "reason", `String "slot_held_by_autonomous_turn"]
                  | Interrupt_result (Operation_interrupt_failed detail) ->
                    ["signalled", `Bool false; "reason", `String "cancel_failed"]
                    @ control_failure_fields Interrupt_failed detail)
               | Error error -> ["signalled", `Bool false; "reason", `String "owner_unavailable"]
                   @ control_failure_fields (Keeper_chat_public_error.of_command_error error)
                     (Keeper_owner_registry.command_error_to_string error) in
             respond_json_value_with_cors ~status:`OK request reqd (`Assoc (("request_id", `String request_id) :: fields)))
        | None ->
        (* The server fails the turn switch and learns nothing more within this
           request: whether the signal reaches the running fiber, and whether
           that fiber then terminates, are later events. [signalled] reports
           what happened here. A turn parked in an uncancellable section keeps
           running after a [signalled: true] response, so an operator has to
           read the turn state to know the outcome. The former [cancelled:
           true] read as that outcome and hid a 63-minute hang (#29229). *)
        (match Keeper_registry.interrupt_current_turn ~base_path keeper_name with
        | Keeper_registry.Exact_turn_cancelled turn_id ->
          Log.Keeper.info ~keeper_name ~turn_id
            "keeper_turn_interrupt: exact turn cancelled actor=%s" actor;
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc
               [ ("signalled", `Bool true)
               ; ("turn_id", `Int turn_id)
               ; ("actor", `String actor)
               ])
        | Keeper_registry.Exact_no_turn_in_flight ->
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc
               [ ("signalled", `Bool false)
               ; ("reason", `String "no_in_flight_turn")
               ; ("actor", `String actor)
               ])
        | Keeper_registry.Exact_turn_cancel_failed { turn_id; detail } ->
          respond_json_value_with_cors ~status:`OK request reqd
            (`Assoc
               ([ ("signalled", `Bool false)
                ; ("reason", `String "cancel_failed")
                ; ("actor", `String actor)
                ]
                @ control_failure_fields Interrupt_failed detail
                @ (match turn_id with
                   | Some turn_id -> [ ("turn_id", `Int turn_id) ]
                   | None -> [])))))
;;

module For_testing = struct
  let control_public_error = control_public_error
end
