open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_redaction
open Keeper_chat_store_row_codec
open Keeper_chat_store_append_primitives

(* RFC-0232 §3.3: the append IS the parse boundary.  Mentions are
   derived from the content that is actually persisted (post-redaction),
   so an offline re-parse of the stored line reproduces the field;
   connectors with structured mention data add [extra_mentions]. *)
let user_line_mentions ~extra_mentions content =
  Keeper_lane_mentions.mention_ids_of_content content @ extra_mentions
  |> List.sort_uniq Keeper_identity.Keeper_id.compare

let append_turn_result ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ?(tool_calls = []) ?surface
    ?conversation_id ?external_message_id ?speaker ?(extra_mentions = [])
    ?blocks
    ?turn_ref
    ?stream_lifecycle
    ~(assistant_content : string)
    () =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let user_content =
      Keeper_secret_redaction.redact_text redaction user_content
    in
    let user_attachments =
      List.map (redact_attachment redaction) user_attachments
    in
    let persisted_user_attachments =
      List.map (persisted_attachment ~base_dir) user_attachments
    in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let assistant_content =
      Keeper_secret_redaction.redact_text redaction assistant_content
    in
    let blocks = redact_blocks redaction blocks in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    (* Speaker identity belongs to the user line only: tool and
       assistant lines are the keeper's own output. *)
    let user_line =
      encode_line ~role:Role.User ~content:user_content ~ts
        ~attachments:persisted_user_attachments ?surface ?conversation_id
        ?external_message_id ?speaker ?turn_ref
        ~mentions:(user_line_mentions ~extra_mentions user_content) ()
    in
    let tool_lines =
      List.mapi
        (fun position tc ->
          encode_line ~role:Role.Tool
            ~content:(normalize_tool_args tc.args)
            ~ts
            ?tool_call_id:(provider_tool_call_id tc.call_id)
            ?execution_id:tc.execution_id
            ~tool_call_name:tc.call_name
            ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    let asst_line =
      encode_line ~role:Role.Assistant ~content:assistant_content ~ts ?surface
        ?conversation_id ?blocks ?turn_ref
        ?stream_lifecycle ()
    in
    let payload =
      String.concat "\n" ((user_line :: tool_lines) @ [ asst_line ]) ^ "\n"
    in
    append_chat_payload_durable path payload;
    announce_appended ~keeper_name ?surface ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    let message = Printexc.to_string exn in
    Log.Keeper.warn "keeper_chat_store: append failed for %s: %s"
      (sanitize_name keeper_name) message;
    Error message

let append_turn ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ?(tool_calls = []) ?surface
    ?conversation_id ?external_message_id ?speaker ?(extra_mentions = [])
    ?blocks ?turn_ref ?stream_lifecycle
    ~(assistant_content : string) () =
  ignore
    (append_turn_result ~base_dir ~keeper_name ~user_content ~user_attachments
       ~tool_calls ?surface ?conversation_id ?external_message_id ?speaker
       ~extra_mentions ?blocks ?turn_ref ?stream_lifecycle
       ~assistant_content ()
      : (unit, string) result)

(* A turn that executed tools but reached no assistant terminal still has a
   durable user/tool timeline.  Do not fabricate an assistant utterance (or a
   transport failure) merely to reuse [append_turn_result]. *)
let append_user_and_tool_calls_result ~base_dir ~keeper_name ~(user_content : string)
    ~(user_attachments : attachment list) ~(tool_calls : tool_call list) ?surface
    ?conversation_id ?external_message_id ?speaker ?(extra_mentions = [])
    ?turn_ref () : (unit, string) result =
  if tool_calls = [] then Error "tool-only continuation requires at least one tool call"
  else try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let user_content = Keeper_secret_redaction.redact_text redaction user_content in
    let user_attachments = List.map (redact_attachment redaction) user_attachments in
    let persisted_user_attachments = List.map (persisted_attachment ~base_dir) user_attachments in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let user_line =
      encode_line ~role:Role.User ~content:user_content ~ts
        ~attachments:persisted_user_attachments ?surface ?conversation_id
        ?external_message_id ?speaker ?turn_ref
        ~mentions:(user_line_mentions ~extra_mentions user_content) ()
    in
    let tool_lines =
      List.mapi
        (fun position tc ->
           encode_line ~role:Role.Tool
             ~content:(normalize_tool_args tc.args)
             ~ts
             ?tool_call_id:(provider_tool_call_id tc.call_id)
             ?execution_id:tc.execution_id
             ~tool_call_name:tc.call_name
             ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    append_chat_payload_durable path (String.concat "\n" (user_line :: tool_lines) ^ "\n");
    announce_appended ~keeper_name ?surface ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    let message = Printexc.to_string exn in
    Log.Keeper.warn "keeper_chat_store: user/tool append failed for %s: %s"
      (sanitize_name keeper_name) message;
    Error message

let append_tool_calls_result ~base_dir ~keeper_name ~(tool_calls : tool_call list)
    ?surface ?conversation_id ?turn_ref () : (unit, string) result =
  if tool_calls = [] then Error "tool-only continuation requires at least one tool call"
  else try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let tool_lines =
      List.mapi
        (fun position tc ->
           encode_line ~role:Role.Tool
             ~content:(normalize_tool_args tc.args)
             ~ts
             ?tool_call_id:(provider_tool_call_id tc.call_id)
             ?execution_id:tc.execution_id
             ~tool_call_name:tc.call_name
             ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    append_chat_payload_durable path (String.concat "\n" tool_lines ^ "\n");
    announce_appended ~keeper_name ?surface ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    let message = Printexc.to_string exn in
    Log.Keeper.warn "keeper_chat_store: tool-only append failed for %s: %s"
      (sanitize_name keeper_name) message;
    Error message

(* RFC-0223 P4: keeper-initiated message on one lane. A single
   assistant line — there is no user turn to pair it with.

   [append_assistant_message_result] surfaces a write failure as [Error msg] so
   a caller bound by a no-silent-loss contract (e.g. {!Fusion_sink.emit}) can
   propagate it. The failure is still counted + warn-logged here so callers that
   use the unit wrapper below keep the existing swallow-and-count telemetry. *)
let append_assistant_message_result ~base_dir ~keeper_name ~(content : string)
    ?(tool_calls = []) ?surface ?conversation_id ?audio
    ?blocks ?turn_ref ?stream_lifecycle
    () : (unit, string) result =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let blocks = redact_blocks redaction blocks in
    let audio = Option.map (redact_audio redaction) audio in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let tool_lines =
      List.mapi
        (fun position tc ->
          encode_line ~role:Role.Tool
            ~content:(normalize_tool_args tc.args)
            ~ts
            ?tool_call_id:(provider_tool_call_id tc.call_id)
            ?execution_id:tc.execution_id
            ~tool_call_name:tc.call_name
            ?surface ?conversation_id ?turn_ref ())
        tool_calls
    in
    let line =
      encode_line ~role:Role.Assistant ~content ~ts ?surface ?conversation_id
        ?audio ?blocks ?turn_ref ?stream_lifecycle ()
    in
    let payload =
      String.concat "\n" (tool_lines @ [ line ]) ^ "\n"
    in
    append_chat_payload_durable path payload;
    announce_appended ~keeper_name ?surface ?audio ();
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    Otel_metric_store.inc_counter
      Keeper_metrics.(to_string ChatStoreFailures)
      ~labels:[("operation", Keeper_chat_store_operation.(to_label Append))]
      ();
    Log.Keeper.warn "keeper_chat_store: assistant append failed for %s: %s"
      (sanitize_name keeper_name) (Printexc.to_string exn);
    Error (Printexc.to_string exn)
