(* RFC-0203 Phase 3 — pure helpers for discord_send_message.
   See discord_tool_helpers.mli for the rationale of this split. *)

type input =
  { channel_id : string
  ; content : string
  }

let required_string_field obj field =
  match List.assoc_opt field obj with
  | None -> Error (Printf.sprintf "missing required field %S" field)
  | Some (`String s) when String.trim s <> "" -> Ok s
  | Some (`String _) ->
    Error (Printf.sprintf "field %S must be a non-empty string" field)
  | Some _ ->
    Error (Printf.sprintf "field %S must be a string" field)

let parse_input (json : Yojson.Safe.t) : (input, string) result =
  match json with
  | `Assoc obj ->
    (match required_string_field obj "channel_id" with
     | Error _ as e -> e
     | Ok channel_id ->
       (match required_string_field obj "content" with
        | Error _ as e -> e
        | Ok content -> Ok { channel_id; content }))
  | _ -> Error "expected JSON object with fields {channel_id, content}"

let builtin_enabled () =
  Env_config_core.get_bool ~default:false "MASC_DISCORD_BUILTIN"

let failure_class_of_send_error
  : Channel_gate_discord_state.send_error -> Tool_result.tool_failure_class
  = function
  | Missing_token ->
    (* Operator forgot to set DISCORD_BOT_TOKEN — caller cannot retry
       blindly; the env must be fixed. *)
    Tool_result.Policy_rejection
  | Rest_error (Network _) ->
    (* Transport-level: DNS/TLS/timeout — retryable. *)
    Tool_result.Transient_error
  | Rest_error (Http_status { code; _ }) when code >= 500 ->
    Tool_result.Transient_error
  | Rest_error (Http_status _) ->
    (* 4xx without a Discord envelope — caller input or permission. *)
    Tool_result.Workflow_rejection
  | Rest_error (Discord_api { code; _ }) when code = 429 ->
    (* Rate limit. *)
    Tool_result.Transient_error
  | Rest_error (Discord_api _) ->
    (* Permission / missing access / invalid form body / etc. *)
    Tool_result.Workflow_rejection
  | Rest_error (Other _) ->
    (* 2xx without [id] or other unexpected shape — unclassified. *)
    Tool_result.Runtime_failure

let dispatch ~send ~tool_name ~name ~args =
  if not (String.equal name tool_name) then None
  else
    let start_time = Time_compat.now () in
    let mk_err class_ msg =
      Tool_result.make_err
        ~tool_name:name
        ~class_
        ~start_time
        msg
    in
    let mk_ok id =
      Tool_result.make_ok
        ~tool_name:name
        ~start_time
        ~data:(`Assoc [ "message_id", `String id ])
        ()
    in
    Some
      (match parse_input args with
       | Error msg -> mk_err Tool_result.Workflow_rejection msg
       | Ok _ when not (builtin_enabled ()) ->
         (* RFC-0203 §Phases bullet 1: ships off behind
            MASC_DISCORD_BUILTIN=false. Fail-closed; the operator
            must opt in explicitly. *)
         mk_err Tool_result.Policy_rejection
           "discord_send_message is disabled (MASC_DISCORD_BUILTIN is not enabled)"
       | Ok { channel_id; content } ->
         (match send ~channel_id ~content with
          | Ok id -> mk_ok id
          | Error e ->
            let msg =
              Format.asprintf "%a"
                Channel_gate_discord_state.pp_send_error e
            in
            mk_err (failure_class_of_send_error e) msg))

let input_schema : Yojson.Safe.t =
  `Assoc
    [ "type", `String "object"
    ; "properties",
      `Assoc
        [ "channel_id",
          `Assoc
            [ "type", `String "string"
            ; "description",
              `String
                "Discord snowflake — guild text channel, DM, or thread id."
            ]
        ; "content",
          `Assoc
            [ "type", `String "string"
            ; "description", `String "Message content (plain text or markdown)."
            ]
        ]
    ; "required", `List [ `String "channel_id"; `String "content" ]
    ; "additionalProperties", `Bool false
    ]
