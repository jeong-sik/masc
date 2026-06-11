(** Gate_keeper_backend -- adapter between the Channel Gate and the keeper subsystem.
    See [gate_keeper_backend.mli] for the full contract. *)

(* ── Keeper response parsing ─────────────────────────────────── *)

let extract_turn_stats (body : string) : Gate_protocol.turn_stats option =
  Safe_ops.protect ~default:None (fun () ->
    let json = Yojson.Safe.from_string body in
    let dur = Json_util.get_int json "duration_ms"
              |> Option.value ~default:0 in
    let tok = Json_util.get_int json "total_tokens"
              |> Option.value ~default:0 in
    if dur = 0 && tok = 0 then None
    else
      Some
        { Gate_protocol.model_used = "runtime"; duration_ms = dur; tokens_used = tok })

let extract_reply_text (body : string) : string =
  Safe_ops.protect ~default:body (fun () ->
    let json = Yojson.Safe.from_string body in
    match Json_util.get_string json "reply" with
    | Some r -> r
    | None -> body)

let extract_structured (body : string) : Yojson.Safe.t option =
  Safe_ops.protect ~default:None (fun () ->
    let json = Yojson.Safe.from_string body in
    match Json_util.assoc_member_opt "structured" json with
    | None | Some `Null -> None
    | Some v -> Some v)

(* ── Dispatch ────────────────────────────────────────────────── *)

let normalized_context_value value =
  value
  |> String.to_seq
  |> Seq.map (function
       | '\n' | '\r' | '\t' -> ' '
       | ch -> ch)
  |> String.of_seq
  |> String.trim

let normalized_or_unknown value =
  match normalized_context_value value with
  | "" -> "unknown"
  | trimmed -> trimmed

(** Sanitize a value for use as a filesystem path component.
    Replaces everything outside [A-Za-z0-9_-] with '_' so that the resulting
    string cannot escape its intended parent directory via '/', '\\', or '..'
    sequences. Empty or fully-stripped values collapse to "unknown". *)
let filesystem_safe_or_unknown value =
  let normalized = normalized_context_value value in
  if normalized = "" then "unknown"
  else
    let buf = Buffer.create (String.length normalized) in
    String.iter
      (fun ch ->
        match ch with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' ->
          Buffer.add_char buf ch
        | _ -> Buffer.add_char buf '_')
      normalized;
    let s = Buffer.contents buf in
    if s = "" || String.for_all (fun c -> c = '_') s then "unknown" else s

let agent_name_for_channel_actor ~channel ~channel_workspace_id ~channel_user_id =
  Printf.sprintf "gate:%s:%s:%s"
    (filesystem_safe_or_unknown channel)
    (filesystem_safe_or_unknown channel_workspace_id)
    (filesystem_safe_or_unknown channel_user_id)

let contextualize_message ~channel ~channel_user_id ~channel_user_name
    ~channel_workspace_id ~content =
  let safe_channel = normalized_or_unknown channel in
  let safe_user_id = normalized_or_unknown channel_user_id in
  let safe_user_name = normalized_or_unknown channel_user_name in
  let safe_workspace_id = normalized_or_unknown channel_workspace_id in
  let safe_content = String.trim content in
  String.concat "\n"
    [
      "[External channel context]";
      "channel: " ^ safe_channel;
      "workspace_id: " ^ safe_workspace_id;
      "user_id: " ^ safe_user_id;
      "user_name: " ^ safe_user_name;
      "";
      "[User message]";
      safe_content;
    ]

let dispatch ~sw ~clock ~proc_mgr ~net ~config
    ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
    ~keeper_name ~content =
  let agent_name =
    agent_name_for_channel_actor ~channel ~channel_workspace_id ~channel_user_id
  in
  (* Use filesystem-safe sanitizer: this key is later used as a directory
     component in session_dir. An unsanitized channel_workspace_id with '..' or '/'
     would escape the intended traces/channels/ subtree. Discord passes
     numeric IDs so this is defensive for future integrations (webhooks,
     custom channels) that could pass attacker-controlled values. *)
  let channel_session_key =
    Printf.sprintf "%s_%s"
      (filesystem_safe_or_unknown channel)
      (filesystem_safe_or_unknown channel_workspace_id)
  in
  (* RFC-0226: the gate inbound boundary is the sole recorder of
     connector user lines. Recording happens here — post
     validation/dedup ([Channel_gate.handle_inbound]), pre turn — so a
     failed or silent turn cannot drop the inbound message. The reply
     path ([Keeper_tool_surface_ops.append_direct_chat_pair_if_reply])
     appends the assistant line only for connector traffic. The line
     carries the raw [content]; the contextualized wrapper below is
     turn input, not conversation history. *)
  let lane = String.trim channel in
  let opt value = match String.trim value with "" -> None | v -> Some v in
  Keeper_chat_store.append_user_message
    ~base_dir:config.Workspace.base_path
    ~keeper_name:(String.trim keeper_name)
    ~content:(String.trim content)
    ~source:lane
    ~speaker:
      { Keeper_chat_store.speaker_id = opt channel_user_id
      ; speaker_name = opt channel_user_name
      ; speaker_authority = Keeper_chat_store.External
      }
    ();
  Keeper_chat_broadcast.chat_appended
    ~keeper_name:(String.trim keeper_name) ~source:lane;
  let args =
    `Assoc [
      ("name", `String (String.trim keeper_name));
      ( "message",
        `String
          (contextualize_message ~channel ~channel_user_id ~channel_user_name
             ~channel_workspace_id ~content) );
      ("direct_reply", `Bool true);
      ("channel_session_key", `String channel_session_key);
      (* RFC-0223 P1: raw connector identity, consumed by
         [Keeper_tool_surface_ops.append_direct_chat_pair_if_reply] so the
         persisted chat line carries the lane label and speaker instead
         of the generic "agent" source. Internal-only args, same class
         as [direct_reply] / [channel_session_key]. *)
      ("channel", `String channel);
      ("channel_user_id", `String channel_user_id);
      ("channel_user_name", `String channel_user_name);
    ]
  in
  let keeper_ctx : _ Keeper_tool_surface.context = {
    config;
    agent_name;
    sw;
    clock;
    proc_mgr;
    net;
  } in
  let start_time = Unix.gettimeofday () in
  (* Channel gate needs the final keeper reply, not the async request ACK that
     plain [Keeper_tool_surface.dispatch] returns for masc_keeper_msg. *)
  match
    Keeper_tool_surface.dispatch_stream ~on_text_delta:(fun _ -> ()) keeper_ctx
      ~name:"masc_keeper_msg" ~args
  with
  | Some result when Tool_result.is_success result ->
      let body = Tool_result.message result in
      let duration_ms =
        int_of_float ((Unix.gettimeofday () -. start_time) *. 1000.0)
      in
      let reply = extract_reply_text body in
      let structured = extract_structured body in
      let stats = match extract_turn_stats body with
        | Some s -> Some { s with duration_ms }
        | None -> Some { Gate_protocol.model_used = "runtime"; duration_ms; tokens_used = 0 }
      in
      Gate_protocol.Reply { content = reply; structured; stats }
  | Some result ->
      Gate_protocol.Keeper_error_result (Tool_result.message result)
  | None ->
      Gate_protocol.Unavailable_result
