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

let string_assoc_json fields =
  `Assoc (List.map (fun (key, value) -> (key, `String value)) fields)

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
    ~channel_workspace_id ~metadata ~content =
  let safe_channel = normalized_or_unknown channel in
  let safe_user_id = normalized_or_unknown channel_user_id in
  let safe_user_name = normalized_or_unknown channel_user_name in
  let safe_workspace_id = normalized_or_unknown channel_workspace_id in
  let safe_content = String.trim content in
  let metadata_lines =
    metadata
    |> List.filter_map (fun (key, value) ->
           let key = normalized_context_value key in
           let value = normalized_context_value value in
           if key = "" || value = "" then None
           else Some (key ^ ": " ^ value))
  in
  let context_lines =
    [
      "[External channel context]";
      "channel: " ^ safe_channel;
      "workspace_id: " ^ safe_workspace_id;
      "user_id: " ^ safe_user_id;
      "user_name: " ^ safe_user_name;
    ]
  in
  let metadata_block =
    match metadata_lines with
    | [] -> []
    | lines -> "" :: "[External channel metadata]" :: lines
  in
  String.concat "\n"
    (context_lines
     @ metadata_block
     @ [ ""; "[User message]"; safe_content ])

let metadata_value key metadata =
  match List.assoc_opt key metadata with
  | Some value ->
      let value = String.trim value in
      if value = "" then None else Some value
  | None -> None

let persist_connector_assistant_reply ~base_dir ~keeper_name ~source
    ?conversation_id ?turn_ref ~reply () =
  let content = String.trim reply in
  if content <> "" then begin
    (* RFC-0232 P5: the gate recorder knows the connector label only;
       coordinates ride [conversation_id] as before. *)
    let surface = Surface_ref.Gate { label = source; address = [] } in
    (* RFC-0233 §7: [turn_ref] is the join key the keeper minted into the
       reply payload, carried onto this connector turn's assistant row. *)
    Keeper_chat_store.append_assistant_message ~base_dir ~keeper_name
      ~content ~surface ?conversation_id ?turn_ref ();
    Keeper_chat_broadcast.chat_appended ~keeper_name ~source ~content ()
  end

(* The trailing [()] makes the leading optional [?on_text_snapshot] erasable
   (warning 16 [unerasable-optional-argument]). Without it the unerased
   optional leaks into the inferred type of callers that omit it (e.g.
   [dispatch]), so that inferred type no longer matches the .mli that
   declares [dispatch] without [?on_text_snapshot]. *)
let dispatch_core ?on_text_snapshot ~sw ~clock ~proc_mgr ~net ~config
    ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
    ~keeper_name ~metadata ~content () =
  let keeper_name = String.trim keeper_name in
  let redaction =
    Keeper_secret_redaction.snapshot
      ~base_path:config.Workspace.base_path
      ~keeper_name
  in
  let redact_text = Keeper_secret_redaction.redact_text redaction in
  let redact_json = Keeper_secret_redaction.redact_json redaction in
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
     failed or silent turn cannot drop the inbound message. The final
     connector reply is appended below after [dispatch_stream] returns
     the keeper's direct reply. The user line carries the raw [content];
     the contextualized wrapper below is turn input, not conversation
     history. *)
  let lane = String.trim channel in
  let opt value = match String.trim value with "" -> None | v -> Some v in
  let conversation_id = metadata_value "conversation_id" metadata in
  let external_message_id = metadata_value "external_message_id" metadata in
  (* RFC-0232 §3.3: the connector decoded a structured mention of this
     channel's bound keeper (e.g. Discord <@snowflake>, invisible to
     the content token parser), so the recorder persists it as an
     explicit mention of the lane owner. *)
  let extra_mentions =
    match metadata_value "mentions_bound_keeper" metadata with
    | Some "true" ->
        Option.to_list (Keeper_identity.Keeper_id.of_string keeper_name)
    | Some _ | None -> []
  in
  Keeper_chat_store.append_user_message
    ~base_dir:config.Workspace.base_path
    ~keeper_name
    ~content:(String.trim content)
    ~surface:(Surface_ref.Gate { label = lane; address = [] })
    ?conversation_id
    ?external_message_id
    ~speaker:
      { Keeper_chat_store.speaker_id = opt channel_user_id
      ; speaker_name = opt channel_user_name
      ; speaker_authority = Keeper_chat_store.External
      }
    ~extra_mentions
    ();
  Keeper_chat_broadcast.chat_appended
    ~keeper_name ~source:lane ();
  let args =
    `Assoc [
      ("name", `String keeper_name);
      ( "message",
        `String
          (contextualize_message ~channel ~channel_user_id ~channel_user_name
             ~channel_workspace_id ~metadata ~content) );
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
      ("channel_metadata", string_assoc_json metadata);
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
  let on_text_delta =
    match on_text_snapshot with
    | None -> (fun _ -> ())
    | Some publish_snapshot ->
        let streamed_text = Buffer.create 1024 in
        fun delta ->
          Buffer.add_string streamed_text delta;
          let snapshot = redact_text (Buffer.contents streamed_text) in
          (try publish_snapshot snapshot with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | exn ->
               Log.Server.warn
                 "channel gate text snapshot callback failed (keeper=%s): %s"
                 keeper_name (Printexc.to_string exn))
  in
  (* Channel gate needs the final keeper reply, not the async request ACK that
     plain [Keeper_tool_surface.dispatch] returns for masc_keeper_msg. *)
  match
    Keeper_tool_surface.dispatch_stream ~on_text_delta keeper_ctx
      ~name:"masc_keeper_msg" ~args
  with
  | Some result when Tool_result.is_success result ->
      let body = Tool_result.message result in
      let duration_ms =
        int_of_float ((Unix.gettimeofday () -. start_time) *. 1000.0)
      in
      let reply = extract_reply_text body |> redact_text in
      let structured = Option.map redact_json (extract_structured body) in
      let stats = match extract_turn_stats body with
        | Some s -> Some { s with duration_ms }
        | None -> Some { Gate_protocol.model_used = "runtime"; duration_ms; tokens_used = 0 }
      in
      (* RFC-0233 §7: pull the turn's join key out of the same reply payload
         (parse, don't repair) so the connector assistant row joins to its
         Turn_record. *)
      let turn_ref =
        Keeper_turn_outcome.turn_ref_of_reply_payload
          (try Some (Yojson.Safe.from_string body)
           with Yojson.Json_error _ -> None)
      in
      persist_connector_assistant_reply
        ~base_dir:config.Workspace.base_path ~keeper_name ~source:lane
        ?conversation_id ?turn_ref ~reply ();
      Gate_protocol.Reply { content = reply; structured; stats }
  | Some result ->
      Gate_protocol.Keeper_error_result (redact_text (Tool_result.message result))
  | None ->
      Gate_protocol.Unavailable_result

let dispatch ~sw ~clock ~proc_mgr ~net ~config ~channel ~channel_user_id
    ~channel_user_name ~channel_workspace_id ~keeper_name ~metadata ~content =
  dispatch_core ~sw ~clock ~proc_mgr ~net ~config ~channel ~channel_user_id
    ~channel_user_name ~channel_workspace_id ~keeper_name ~metadata ~content ()

let dispatch_with_text_snapshot ~on_text_snapshot ~sw ~clock ~proc_mgr ~net
    ~config ~channel ~channel_user_id ~channel_user_name ~channel_workspace_id
    ~keeper_name ~metadata ~content =
  dispatch_core ~on_text_snapshot ~sw ~clock ~proc_mgr ~net ~config ~channel
    ~channel_user_id ~channel_user_name ~channel_workspace_id ~keeper_name
    ~metadata ~content ()
