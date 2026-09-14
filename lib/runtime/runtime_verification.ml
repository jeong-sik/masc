type unavailable =
  | Missing_credential of string
  | Invalid_credential of string
  | Unsupported_runtime
  | Tools_not_declared
  | Invalid_configuration of string
  | Client_not_authenticated of string
  | Client_not_started of string

type failure =
  | Unavailable of unavailable
  | Provider_rejected of string
  | Timed_out
  | Tool_not_called
  | Tool_result_not_consumed
  | Empty_response
  | Model_unreported

type observation =
  { model : string
  ; text : string
  }

type result =
  { runtime_id : string
  ; selected_model : string
  ; observed_model : string option
  ; response : bool
  ; tool_called : bool
  ; tool_roundtrip : bool
  ; failure : failure option
  }

let failure_code = function
  | Unavailable (Missing_credential _) -> "missing_credential"
  | Unavailable (Invalid_credential _) -> "invalid_credential"
  | Unavailable Unsupported_runtime -> "unsupported_runtime"
  | Unavailable Tools_not_declared -> "tools_not_declared"
  | Unavailable (Invalid_configuration _) -> "invalid_configuration"
  | Unavailable (Client_not_authenticated _) -> "client_not_authenticated"
  | Unavailable (Client_not_started _) -> "client_not_started"
  | Provider_rejected _ -> "provider_rejected"
  | Timed_out -> "timed_out"
  | Tool_not_called -> "tool_not_called"
  | Tool_result_not_consumed -> "tool_result_not_consumed"
  | Empty_response -> "empty_response"
  | Model_unreported -> "model_unreported"
;;

let failure_message = function
  | Unavailable (Missing_credential _) ->
    "The selected runtime's configured credential is unavailable."
  | Unavailable (Invalid_credential _) ->
    "The selected runtime's declared credential could not be used."
  | Unavailable Unsupported_runtime ->
    "This transport has no readiness tool roundtrip yet."
  | Unavailable Tools_not_declared -> "This model binding does not declare tool calling."
  | Unavailable (Invalid_configuration _) ->
    "The selected runtime configuration is invalid."
  | Unavailable (Client_not_authenticated _) ->
    "The configured client reports no sign-in. Sign in with the client itself, or \
     export its credential variables."
  | Unavailable (Client_not_started _) -> "The configured client could not be started."
  | Provider_rejected _ ->
    "The selected model request failed; check model access, endpoint and authentication."
  | Timed_out -> "The selected runtime did not finish verification before its deadline."
  | Tool_not_called -> "The model answered without calling the readiness tool."
  | Tool_result_not_consumed ->
    "The model did not return the challenge from the actual tool result."
  | Empty_response -> "The selected model returned no assistant response."
  | Model_unreported -> "The runtime returned no observed model identity."
;;

(* The client already wrote an account of what it looked for and did not find;
   without this it is discarded and every unavailable client reads the same. *)
let failure_detail = function
  | Unavailable (Missing_credential detail)
  | Unavailable (Invalid_credential detail)
  | Unavailable (Invalid_configuration detail)
  | Unavailable (Client_not_authenticated detail)
  | Unavailable (Client_not_started detail)
  | Provider_rejected detail -> Some detail
  | Unavailable (Unsupported_runtime | Tools_not_declared)
  | Timed_out
  | Tool_not_called
  | Tool_result_not_consumed
  | Empty_response
  | Model_unreported -> None
;;

(* Why the run stopped short of completing. A verification run declares one
   tool and asks one question, so every yield here is a refusal to answer it,
   and the operator needs to know which. *)
let unfinished_run_reason (stop_reason : Runtime_agent.stop_reason) =
  match stop_reason with
  | Runtime_agent.Completed -> "the run completed"
  | Runtime_agent.Yielded_to_operation_queued { turns_used } ->
    Printf.sprintf "the run yielded to a queued operation after %d turns" turns_used
  | Runtime_agent.Yielded_to_durable_stimulus { turns_used } ->
    Printf.sprintf "the run yielded to a durable stimulus after %d turns" turns_used
  | Runtime_agent.Yielded_after_repeated_tool_call
      { turns_used; tool_name; repeated_count } ->
    Printf.sprintf
      "the run yielded after calling %s %d times in %d turns"
      tool_name
      repeated_count
      turns_used
  | Runtime_agent.Yielded_after_repeated_assistant_text { turns_used; repeated_count } ->
    Printf.sprintf
      "the run yielded after repeating the same reply %d times in %d turns"
      repeated_count
      turns_used
  | Runtime_agent.InputRequired { turns_used; request } ->
    Printf.sprintf
      "the run asked for operator input after %d turns: %s"
      turns_used
      request.Agent_core.Error.question
;;

let schema = "masc.runtime_verification.v1"
let unavailable_status = "unavailable"

let status_of_failure = function
  | None -> "verified"
  | Some (Unavailable _) -> unavailable_status
  | Some
      ( Provider_rejected _ | Timed_out | Tool_not_called | Tool_result_not_consumed
      | Empty_response | Model_unreported ) -> "failed"
;;

let to_json result =
  `Assoc
    [ "schema", `String schema
    ; "runtime_id", `String result.runtime_id
    ; "model", `String result.selected_model
    ; ( "observed_model"
      , match result.observed_model with
        | None -> `Null
        | Some model -> `String model )
    ; "status", `String (status_of_failure result.failure)
    ; ( "checks"
      , `Assoc
          [ "response", `Bool result.response
          ; "tool_called", `Bool result.tool_called
          ; "tool_roundtrip", `Bool result.tool_roundtrip
          ] )
    ; ( "failure"
      , match result.failure with
        | None -> `Null
        | Some failure ->
          `Assoc
            [ "code", `String (failure_code failure)
            ; "message", `String (failure_message failure)
            ; ( "detail"
              , match failure_detail failure with
                | None -> `Null
                | Some detail -> `String detail )
            ] )
    ]
;;

let unavailable_to_json ?detail ~runtime_id ~code ~message () =
  `Assoc
    [ "schema", `String schema
    ; "runtime_id", `String runtime_id
    ; "model", `Null
    ; "observed_model", `Null
    ; "status", `String unavailable_status
    ; ( "checks"
      , `Assoc
          [ "response", `Bool false
          ; "tool_called", `Bool false
          ; "tool_roundtrip", `Bool false
          ] )
    ; ( "failure"
      , `Assoc
          [ "code", `String code
          ; "message", `String message
          ; ( "detail"
            , match detail with
              | None -> `Null
              | Some d -> `String d )
          ] )
    ]
;;

let exit_code result =
  match result.failure with
  | None -> 0
  | Some (Unavailable _) -> 2
  | Some _ -> 1
;;

type unmeasured =
  { runtime_id : string
  ; code : string
  ; message : string
  ; detail : string option
  }

type report =
  | Measured of result
  | Unmeasured of unmeasured

(* The inverse of [failure_code] and [failure_detail]: a code that carries an
   account must arrive with one, and a code that carries none must arrive
   without, so a document cannot claim a detail the producer never wrote. *)
let failure_of_code ~code ~detail =
  match code, detail with
  | "missing_credential", Some detail -> Ok (Unavailable (Missing_credential detail))
  | "invalid_credential", Some detail -> Ok (Unavailable (Invalid_credential detail))
  | "unsupported_runtime", None -> Ok (Unavailable Unsupported_runtime)
  | "tools_not_declared", None -> Ok (Unavailable Tools_not_declared)
  | "invalid_configuration", Some detail -> Ok (Unavailable (Invalid_configuration detail))
  | "client_not_authenticated", Some detail ->
    Ok (Unavailable (Client_not_authenticated detail))
  | "client_not_started", Some detail -> Ok (Unavailable (Client_not_started detail))
  | "provider_rejected", Some detail -> Ok (Provider_rejected detail)
  | "timed_out", None -> Ok Timed_out
  | "tool_not_called", None -> Ok Tool_not_called
  | "tool_result_not_consumed", None -> Ok Tool_result_not_consumed
  | "empty_response", None -> Ok Empty_response
  | "model_unreported", None -> Ok Model_unreported
  | ( ( "missing_credential" | "invalid_credential" | "invalid_configuration"
      | "client_not_authenticated" | "client_not_started" | "provider_rejected" )
    , None ) -> Error (Printf.sprintf "failure code %S arrived without its detail" code)
  | ( ( "unsupported_runtime" | "tools_not_declared" | "timed_out" | "tool_not_called"
      | "tool_result_not_consumed" | "empty_response" | "model_unreported" )
    , Some _ ) -> Error (Printf.sprintf "failure code %S carries no detail" code)
  | code, (None | Some _) -> Error (Printf.sprintf "unknown failure code %S" code)
;;

let ( let* ) = Result.bind

let of_json json =
  let object_fields ~name = function
    | `Assoc fields ->
      let rec unique = function
        | [] -> true
        | (key, _) :: rest -> (not (List.mem_assoc key rest)) && unique rest
      in
      if unique fields then Ok fields else Error (name ^ " repeats a key")
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Tuple _
    | `Variant _ -> Error (name ^ " is not an object")
  in
  let exact_keys ~name expected fields =
    let actual = List.sort String.compare (List.map fst fields) in
    if actual = List.sort String.compare expected
    then Ok ()
    else
      Error
        (Printf.sprintf
           "%s has keys %s, expected %s"
           name
           (String.concat "," actual)
           (String.concat "," expected))
  in
  let string ~name = function
    | `String value -> Ok value
    | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Tuple _ | `Variant _
    | `Assoc _ -> Error (name ^ " is not a string")
  in
  let string_or_null ~name = function
    | `Null -> Ok None
    | `String value -> Ok (Some value)
    | `Bool _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Tuple _ | `Variant _ | `Assoc _ ->
      Error (name ^ " is neither a string nor null")
  in
  let bool ~name = function
    | `Bool value -> Ok value
    | `Null | `String _ | `Int _ | `Intlit _ | `Float _ | `List _ | `Tuple _ | `Variant _
    | `Assoc _ -> Error (name ^ " is not a boolean")
  in
  let* fields = object_fields ~name:"report" json in
  let* () =
    exact_keys
      ~name:"report"
      [ "schema"; "runtime_id"; "model"; "observed_model"; "status"; "checks"; "failure" ]
      fields
  in
  let field key = List.assoc key fields in
  let* found_schema = string ~name:"schema" (field "schema") in
  let* () =
    if String.equal found_schema schema
    then Ok ()
    else Error (Printf.sprintf "schema %S is not %S" found_schema schema)
  in
  let* runtime_id = string ~name:"runtime_id" (field "runtime_id") in
  let* selected_model = string_or_null ~name:"model" (field "model") in
  let* observed_model = string_or_null ~name:"observed_model" (field "observed_model") in
  let* status = string ~name:"status" (field "status") in
  let* checks = object_fields ~name:"checks" (field "checks") in
  let* () = exact_keys ~name:"checks" [ "response"; "tool_called"; "tool_roundtrip" ] checks in
  let* response = bool ~name:"checks.response" (List.assoc "response" checks) in
  let* tool_called = bool ~name:"checks.tool_called" (List.assoc "tool_called" checks) in
  let* tool_roundtrip =
    bool ~name:"checks.tool_roundtrip" (List.assoc "tool_roundtrip" checks)
  in
  let* failure =
    match field "failure" with
    | `Null -> Ok None
    | ( `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ | `Tuple _
      | `Variant _ | `Assoc _ ) as other ->
      let* failure = object_fields ~name:"failure" other in
      let* () = exact_keys ~name:"failure" [ "code"; "message"; "detail" ] failure in
      let* code = string ~name:"failure.code" (List.assoc "code" failure) in
      let* message = string ~name:"failure.message" (List.assoc "message" failure) in
      let* detail = string_or_null ~name:"failure.detail" (List.assoc "detail" failure) in
      Ok (Some (code, message, detail))
  in
  match selected_model, failure with
  | Some selected_model, (None | Some _) ->
    let* failure =
      match failure with
      | None -> Ok None
      | Some (code, _, detail) ->
        let* failure = failure_of_code ~code ~detail in
        Ok (Some failure)
    in
    let derived = status_of_failure failure in
    let* () =
      if String.equal status derived
      then Ok ()
      else Error (Printf.sprintf "status %S disagrees with the failure (%s)" status derived)
    in
    let* () =
      if tool_roundtrip = (failure = None)
      then Ok ()
      else Error "checks.tool_roundtrip disagrees with the failure"
    in
    Ok
      (Measured
         { runtime_id
         ; selected_model
         ; observed_model
         ; response
         ; tool_called
         ; tool_roundtrip
         ; failure
         })
  | None, None -> Error "a report without a model must carry a failure"
  | None, Some (code, message, detail) ->
    let* () =
      if String.equal status unavailable_status
      then Ok ()
      else Error (Printf.sprintf "status %S on a report without a model" status)
    in
    let* () =
      match observed_model, response, tool_called, tool_roundtrip with
      | None, false, false, false -> Ok ()
      | (None | Some _), (true | false), (true | false), (true | false) ->
        Error "a report without a model claims an observation or a check"
    in
    Ok (Unmeasured { runtime_id; code; message; detail })
;;

let input_schema =
  `Assoc
    [ "type", `String "object"
    ; "properties", `Assoc []
    ; "required", `List []
    ; "additionalProperties", `Bool false
    ]
;;

let prompt =
  "Verify this exact model connection. Call runtime_readiness_challenge with no \
   arguments. Read its result, then reply with only the JSON object {\"challenge\":\"the \
   exact challenge returned by the tool\"}. Do not invent a challenge or use other \
   tools."
;;

let measure ~runtime_id ~selected_model ~challenge ~run =
  let called = ref false in
  let tool : Runtime_official_client_tool.dynamic_tool =
    { name = "runtime_readiness_challenge"
    ; description =
        "Return a fresh readiness challenge. This tool has no external effects."
    ; input_schema
    ; call =
        (fun ~call_id:_ input ->
          match input with
          | `Assoc [] ->
            called := true;
            { success = true
            ; content = Yojson.Safe.to_string (`Assoc [ "challenge", `String challenge ])
            ; content_blocks = None; abort_turn = None
            }
          | _ ->
            { success = false
            ; content = "This tool accepts an empty object only."
            ; content_blocks = None; abort_turn = None
            })
    }
  in
  let observed, response, failure =
    match run tool ~prompt with
    | Error failure -> None, false, Some failure
    | Ok observation ->
      let response = String.trim observation.text <> "" in
      let consumed =
        try
          match Yojson.Safe.from_string observation.text with
          | `Assoc [ ("challenge", `String value) ] -> String.equal value challenge
          | _ -> false
        with
        | Yojson.Json_error _ -> false
      in
      let failure =
        if not response
        then Some Empty_response
        else if String.trim observation.model = ""
        then Some Model_unreported
        else if not !called
        then Some Tool_not_called
        else if not consumed
        then Some Tool_result_not_consumed
        else None
      in
      ( (if String.trim observation.model = "" then None else Some observation.model)
      , response
      , failure )
  in
  { runtime_id
  ; selected_model
  ; observed_model = observed
  ; response
  ; tool_called = !called
  ; tool_roundtrip = failure = None
  ; failure
  }
;;

let initial_runtime_id ~default_runtime_id ~assignments ~lanes ~keeper_name =
  let assigned_id =
    (* DET-OK: absence of an explicit Keeper assignment inherits the already
       validated workspace default by routing contract; no parse error is hidden. *)
    match List.assoc_opt keeper_name assignments with
    | Some id -> id
    | None -> default_runtime_id
  in
  match List.find_opt (fun (lane : Runtime_lane.t) -> lane.id = assigned_id) lanes with
  | None -> Some assigned_id
  | Some lane ->
    (match Runtime_lane.ordered_candidates lane with
     | [] -> None
     | candidate :: _ -> Some candidate)
;;

let verify ~secure_random ~sw ~net ~mgr ~clock ~cwd ~cwd_path ~timeout_s (runtime : Runtime.t) =
  let run (tool : Runtime_official_client_tool.dynamic_tool) ~prompt =
    if not runtime.model.tools_support
    then Error (Unavailable Tools_not_declared)
    else (
      match runtime.execution with
      | Runtime_execution.Antigravity_cli execution ->
        let config = { (Runtime_antigravity.default_config ~cwd:cwd_path ~model:execution.model) with
          cli_path = execution.cli_path;
          effort = execution.effort;
          admission_timeout_s = Float.min timeout_s execution.timeout_s;
          timeout_s = Some timeout_s; wall_clock_ceiling_s = Some timeout_s } in
        (match Runtime_verification_antigravity.run ~secure_random ~net ~mgr ~clock ~cwd
           ~directory:cwd_path ~oauth_source:execution.oauth_source ~config ~tool ~prompt with
         | Ok result -> Ok {model=result.model; text=result.text}
         | Error Runtime_verification_antigravity.Private_home_unavailable ->
           Error (Unavailable (Client_not_authenticated "Antigravity private authentication could not be prepared"))
         | Error (Client_error (Runtime_antigravity.Spawn_failed _)) ->
           Error (Unavailable (Client_not_started "The Antigravity executable could not be started"))
         | Error (Client_error (Runtime_antigravity.Invalid_config _)) ->
           Error (Unavailable (Invalid_configuration "Antigravity readiness configuration is invalid"))
         | Error (Client_error (Runtime_antigravity.Timeout _)) -> Error Timed_out
         | Error (Client_error err) ->
           Error (Provider_rejected (Runtime_antigravity.error_to_string err)))
      | Runtime_execution.Agent_core provider_cfg ->
        (match
           Runtime.validate_dispatch_credential ~provider_config:provider_cfg runtime
         with
         | Error (Runtime.Required_env_credential_missing _ as error) ->
           Error
             (Unavailable
                (Missing_credential (Runtime.dispatch_credential_error_to_string error)))
         | Error (Runtime.Declared_credential_unavailable _ as error) ->
           Error
             (Unavailable
                (Invalid_credential (Runtime.dispatch_credential_error_to_string error)))
         | Ok () ->
           let seed =
             Runtime_inference.seed_of_thinking_support
               ~preserve_thinking:runtime.model.preserve_thinking
               runtime.model.thinking_support
           in
           let provider_cfg =
             Runtime_agent_core_runner.apply_inference_seed ~seed provider_cfg
           in
           (match
              Agent_core.Types.tool_schema_of_input_schema
                ~name:tool.name
                ~description:tool.description
                ~input_schema:tool.input_schema
                ()
            with
            | Error _ ->
              Error
                (Unavailable
                   (Invalid_configuration
                      "the readiness tool schema could not be built from this model \
                       binding"))
            | Ok schema ->
              let handler input =
                let result = tool.call ~call_id:"readiness" input in
                if result.success
                then Ok { Agent_core.Types.content = result.content; content_blocks = result.content_blocks; _meta = None }
                else
                  Error
                    { Agent_core.Types.message = result.content
                    ; recoverable = false
                    ; error_class = Some Agent_core.Types.Deterministic
                    }
              in
              let tools =
                [ Agent_core.Tool.of_schema
                    schema
                    (Agent_core.Tool.ignoring_execution_env handler)
                ]
              in
              (* The same [timeout_s] the CLI arms above install, as the
                 bound on the whole call: the wait for the binding's admission
                 permit and the round trip after it, connection and response
                 headers included (Http_client's sync path arms the body
                 deadline in front of the headers when no connect budget is
                 declared). Without it this arm had no bound at all: a binding
                 whose endpoint accepted the request and never answered, or
                 whose permits a keeper's streams were holding, held
                 `masc runtime verify` and the imp start-up check for as long
                 as that lasted, while the same command ended an official
                 client at [timeout_s]. *)
              let config =
                { (Runtime_agent.default_config
                     ~name:"runtime-verification"
                     ~provider_cfg
                     ~system_prompt:prompt
                     ~tools)
                  with
                  body_timeout_s = Some timeout_s
                ; call_timeout_s = Some timeout_s
                }
              in
              (match Runtime_agent.run ~sw ~net ~config prompt with
               | Error
                   ( Agent_core.Error.Provider (Llm_provider.Error.Timeout _)
                   | Agent_core.Error.Api (Agent_core.Retry.Timeout _) ) ->
                 (* The deadline above, or the transport's own: the same
                    verdict the CLI arms give their client's timeout. *)
                 Error Timed_out
               | Error error ->
                 Error (Provider_rejected (Agent_core.Error.to_string error))
               | Ok result ->
                 (match result.stop_reason with
                  | Runtime_agent.Completed ->
                    Ok
                      { model = result.response.model
                      ; text = Agent_core.Types.text_of_response result.response
                      }
                  | stop_reason ->
                    Error (Provider_rejected (unfinished_run_reason stop_reason))))))
      | Runtime_execution.Claude_code execution ->
        let config =
          { (Runtime_claude_code.default_config ~cwd:cwd_path) with
            cli_path = execution.cli_path
          ; model = execution.model
          ; admission_timeout_s = Float.min timeout_s execution.timeout_s
          ; timeout_s = Some timeout_s
          ; wall_clock_ceiling_s = Some timeout_s
          }
        in
        (match
           Runtime_claude_code.run_turn
             ~dynamic_tools:[ tool ]
             ~mgr
             ~clock
             ~cwd
             config
             ~prompt
             ~images:[]
         with
         | Ok result -> Ok { model = result.model; text = result.text }
         | Error (Runtime_claude_code.Subscription_required _ as error) ->
           Error
             (Unavailable
                (Client_not_authenticated (Runtime_claude_code.error_to_string error)))
         | Error (Runtime_claude_code.Spawn_failed _ as error) ->
           Error
             (Unavailable (Client_not_started (Runtime_claude_code.error_to_string error)))
         | Error (Runtime_claude_code.Invalid_config _ as error) ->
           Error
             (Unavailable
                (Invalid_configuration (Runtime_claude_code.error_to_string error)))
         | Error (Runtime_claude_code.Timeout _) -> Error Timed_out
         | Error error ->
           Error (Provider_rejected (Runtime_claude_code.error_to_string error)))
      | Runtime_execution.Codex_app_server execution ->
        (match Runtime_verification_codex_home.prepare ~directory:cwd_path with
        | Error detail -> Error (Unavailable (Invalid_configuration detail))
        | Ok isolated_home ->
        (* Codex rejects Native_none. Native_read is its least supported
           posture and disables shell/unified_exec in the existing adapter;
           the only host-declared tool is the private challenge above. *)
        let config =
          { (Runtime_codex_app_server.default_config ()) with
            cli_path = execution.cli_path
          ; isolated_home = Some isolated_home
          ; model = execution.model
          ; admission_timeout_s = Float.min timeout_s execution.timeout_s
          ; timeout_s = Some timeout_s
          ; wall_clock_ceiling_s = Some timeout_s
          }
        in
        (match
           Runtime_codex_app_server.run_turn
             ~dynamic_tools:[ tool ]
             ~mgr
             ~clock
             ~cwd
             config
             ~prompt
             ~images:[]
         with
         | Ok result -> Ok { model = result.model; text = result.text }
         | Error (Runtime_codex_app_server.Subscription_required _ as error) ->
           Error
             (Unavailable
                (Client_not_authenticated
                   (Runtime_codex_app_server.error_to_string error)))
         | Error (Runtime_codex_app_server.Spawn_failed _ as error) ->
           Error
             (Unavailable
                (Client_not_started (Runtime_codex_app_server.error_to_string error)))
         | Error (Runtime_codex_app_server.Invalid_config _ as error) ->
           Error
             (Unavailable
                (Invalid_configuration
                   (Runtime_codex_app_server.error_to_string error)))
         | Error (Runtime_codex_app_server.Timeout _) -> Error Timed_out
         | Error error ->
           Error
             (Provider_rejected (Runtime_codex_app_server.error_to_string error)))))
  in
  measure
    ~runtime_id:runtime.id
    ~selected_model:runtime.model.api_name
    ~challenge:(Random_id.hex ~bytes:16)
    ~run:(fun tool ~prompt ->
      try Eio.Time.with_timeout_exn clock timeout_s (fun () -> run tool ~prompt) with
      | Eio.Time.Timeout -> Error Timed_out
      | (Eio.Io _ | Unix.Unix_error _ | Sys_error _) as exn ->
        Error (Provider_rejected (Printexc.to_string exn)))
;;

module For_testing = struct
  let measure = measure
end
