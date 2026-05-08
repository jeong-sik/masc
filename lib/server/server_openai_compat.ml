(** Server_openai_compat -- Optional OpenAI-compatible /v1/chat/completions endpoint.

    Opt-in via MASC_OPENAI_COMPAT=1 environment variable.

    Routes:
    - model:"keeper:<name>" -> dispatches to Keeper_turn.handle_keeper_msg
    - model:"default" or other -> direct MASC named-cascade execution via [Oas_worker.run_named]

    Request/response format follows the OpenAI Chat Completions API spec. *)

(** Whether the OpenAI-compatible endpoint is enabled (default: false). *)
let is_enabled () = Env_config.Transport.openai_compat_enabled

(** Generate a random chat completion ID. *)
let generate_completion_id () =
  Printf.sprintf "chatcmpl-%08x%08x"
    (Random.bits () land 0x7FFFFFFF)
    (Random.bits () land 0x7FFFFFFF)

(** Build an OpenAI-format error response JSON string. *)
let error_response ~(status : string) ~(message : string) : string =
  Yojson.Safe.to_string
    (`Assoc [
      ("error", `Assoc [
        ("message", `String message);
        ("type", `String status);
        ("param", `Null);
        ("code", `Null);
      ]);
    ])

(** Build an OpenAI-format chat completion response JSON string. *)
let completion_response ~model ~content : string =
  let id = generate_completion_id () in
  let created = int_of_float (Time_compat.now ()) in
  Yojson.Safe.to_string
    (`Assoc [
      ("id", `String id);
      ("object", `String "chat.completion");
      ("created", `Int created);
      ("model", `String model);
      ("choices", `List [
        `Assoc [
          ("index", `Int 0);
          ("message", `Assoc [
            ("role", `String "assistant");
            ("content", `String content);
          ]);
          ("finish_reason", `String "stop");
        ];
      ]);
      ("usage", `Assoc [
        ("prompt_tokens", `Int 0);
        ("completion_tokens", `Int 0);
        ("total_tokens", `Int 0);
      ]);
    ])

(** Extract the last user message content from the messages array.
    Returns the concatenation of all user messages if multiple exist,
    or the last user message content. *)
let extract_user_message (messages : Yojson.Safe.t) : string option =
  let msgs = match messages with `List items -> items | _ -> [] in
  let user_msgs = List.filter (fun m ->
    String.equal (Safe_ops.json_string ~default:"" "role" m) "user"
  ) msgs in
  match List.rev user_msgs with
  | last :: _ ->
    Safe_ops.json_string_opt "content" last
  | [] -> None

(** Route to a keeper via Keeper_turn.handle_keeper_msg.
    Constructs the args JSON and context, then extracts the reply. *)
let route_keeper ~config ~sw ~clock ~keeper_name ~message : (string, string) result =
  let ctx : _ Keeper_types.context = {
    config;
    agent_name = "openai-compat";
    sw;
    clock;
    proc_mgr = None;
    net = None;
  } in
  let args = `Assoc [
    ("name", `String keeper_name);
    ("message", `String message);
  ] in
  let (ok, body) = Keeper_turn.handle_keeper_msg ctx args in
  if ok then
    (* body is JSON with "reply" field *)
    (try
      let json = Yojson.Safe.from_string body in
      match Safe_ops.json_string_opt "reply" json with
      | Some reply -> Ok reply
      | None -> Ok body
    with Yojson.Json_error _ ->
      (* If not JSON, use the body as-is *)
      Ok body)
  else
    Error body

(** Route to direct MASC named-cascade execution via [Oas_worker.run_named]. *)
let route_cascade ~message ~system_prompt ~max_tokens ~temperature
  : (string, string) result =
  let cascade_name =
    Keeper_cascade_profile.cascade_name_for_use
      Keeper_cascade_profile.Openai_compat
  in
  match
    Masc_oas_bridge.run_with_caller
      ~caller:Env_config_oas_bridge.Server_openai_compat (fun () ->
      Oas_worker.run_named
        ~cascade_name
        ~goal:message
        ~system_prompt
        ~max_turns:1
        ~temperature
        ~max_tokens
        ~approval:Approval_callbacks.auto_approve
        ()
    )
  with
  | Ok result ->
    Ok (Agent_sdk_response.text_of_response result.response)
  | Error err ->
    Error (Agent_sdk.Error.to_string err)

(** Handle a POST /v1/chat/completions request.
    Parses the OpenAI-format request body, routes to keeper or cascade,
    and returns an OpenAI-format response. *)
let handle_chat_completions ~config ~sw ~clock (body : string)
  : Httpun.Status.t * string =
  try
    let json = Yojson.Safe.from_string body in
    let model = Safe_ops.json_string ~default:"" "model" json in
    let messages =
      match Safe_ops.json_member_opt "messages" json with
      | Some v -> v
      | None -> `List []
    in
    let max_tokens = Safe_ops.json_int
      ~default:Oas_worker_cascade.default_max_tokens "max_tokens" json in
    let temperature = Safe_ops.json_float
      ~default:Oas_worker_cascade.default_temperature "temperature" json in
    if model = "" then
      (`Bad_request,
       error_response ~status:"invalid_request_error"
         ~message:"Missing or invalid 'model' field")
    else
    match extract_user_message messages with
    | None ->
      (`Bad_request,
       error_response ~status:"invalid_request_error"
         ~message:"No user message found in messages array")
    | Some user_message ->
      (* Check if this is a keeper route *)
      let is_keeper_prefix =
        String.length model > 7
        && String.starts_with ~prefix:"keeper:" model
      in
      if is_keeper_prefix then begin
        let keeper_name = String.sub model 7 (String.length model - 7) in
        match route_keeper ~config ~sw ~clock ~keeper_name ~message:user_message with
        | Ok reply ->
          (`OK, completion_response ~model ~content:reply)
        | Error e ->
          (`Internal_server_error,
           error_response ~status:"server_error"
             ~message:(Printf.sprintf "Keeper error: %s" e))
      end
      else begin
        (* Build system prompt from system messages *)
        let system_prompt =
          try
            let msgs = match messages with `List items -> items | _ -> [] in
            let sys_msgs = List.filter_map (fun m ->
              if String.equal (Safe_ops.json_string ~default:"" "role" m) "system" then
                Safe_ops.json_string_opt "content" m
              else None
            ) msgs in
            String.concat "\n" sys_msgs
          with Failure _ -> ""
        in
        match route_cascade ~message:user_message ~system_prompt
                ~max_tokens ~temperature with
        | Ok reply ->
          (`OK, completion_response ~model ~content:reply)
        | Error e ->
          (`Internal_server_error,
           error_response ~status:"server_error"
             ~message:(Printf.sprintf "Cascade error: %s" e))
      end
  with
  | Yojson.Json_error e ->
    (`Bad_request,
     error_response ~status:"invalid_request_error"
       ~message:(Printf.sprintf "Invalid JSON: %s" e))
