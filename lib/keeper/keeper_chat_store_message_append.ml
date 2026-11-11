open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_redaction
open Keeper_chat_store_row_codec
open Keeper_chat_store_provenance_index
open Keeper_chat_store_transcript_index
open Keeper_chat_store_append_primitives
open Keeper_chat_store_turn_append
open Keeper_chat_store_append_once

type terminal_row = Reply of string | Failed_request of string | Settled_failure of string

let append_terminal_message_once
      ~base_dir
      ~keeper_name
      ~delivery_key
      ~terminal
      ~route
      ?(tool_calls = [])
      ?blocks
      ?turn_ref
      ?stream_lifecycle
      ()
  =
  let role, content = match terminal with
    | Reply content -> Role.Assistant, content
    | Failed_request content | Settled_failure content -> Role.Request_failure, content in
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let tool_calls = List.map (redact_tool_call redaction) tool_calls in
    let blocks = redact_blocks redaction blocks in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let row_id = mint_message_id ~ts in
    let transcript_slot = match terminal with
      | Reply _ | Failed_request _ -> Keeper_chat_delivery_identity.Terminal_result
      | Settled_failure _ -> Keeper_chat_delivery_identity.Settled_failure
    in
    let line =
      lazy
        (let { Row_route.surface; conversation_id } = Lazy.force route in
         encode_line
           ~role
           ~content
           ~ts
           ~message_id:row_id
           ?surface
           ?conversation_id
           ?blocks
           ?turn_ref
           ?stream_lifecycle
           ~provenance:
             { Keeper_chat_delivery_identity.delivery_key; transcript_slot }
           ())
    in
    let tool_lines =
      tool_call_append_lines ~ts ~route ~turn_ref ~delivery_key tool_calls
    in
    let assistant_line = { transcript_slot; row_id; line } in
    append_lines_once
      ~reject_partial_after_result:(tool_lines <> [])
      path
      ~delivery_key
      ~result_slot:transcript_slot
      (tool_lines @ [ assistant_line ])
    |> announce_if_appended ~keeper_name ~route
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (report_store_failure
         ~operation:Keeper_chat_store_operation.Append
         ~keeper_name
         ~what:"terminal append-once"
         exn)
;;

let append_assistant_message_once ~base_dir ~keeper_name ~delivery_key ~content
    ?surface ?conversation_id ?tool_calls ?blocks ?turn_ref ?stream_lifecycle () =
  append_terminal_message_once ~base_dir ~keeper_name ~delivery_key
    ~terminal:(Reply content)
    ~route:(Lazy.from_val { Row_route.surface; conversation_id })
    ?tool_calls ?blocks ?turn_ref ?stream_lifecycle ()
;;

let append_request_failure_once ~base_dir ~keeper_name ~delivery_key ~content
    ?(route = Lazy.from_val Row_route.none) ?tool_calls ?blocks ?turn_ref
    ?stream_lifecycle () =
  append_terminal_message_once ~base_dir ~keeper_name ~delivery_key
    ~terminal:(Failed_request content) ~route ?tool_calls ?blocks ?turn_ref
    ?stream_lifecycle ()
;;

let append_settled_failure_once ~base_dir ~keeper_name ~delivery_key ~content ~route () =
  append_terminal_message_once ~base_dir ~keeper_name ~delivery_key
    ~terminal:(Settled_failure content) ~route ()
;;

module Settled_failure = struct
  type t =
    { delivery_key : Keeper_chat_delivery_identity.delivery_key
    ; content : string
    ; route : Row_route.t Lazy.t
    }
end

(* The transcript is read and indexed once for every failure, under one lock;
   each failure is then checked against that index as
   [append_settled_failure_once] checks it, and the missing rows are appended
   in one durable write. A key this batch has already added answers with that
   row. *)
let append_settled_failures_once ~base_dir ~keeper_name failures =
  match failures with
  | [] -> Ok []
  | _ :: _ ->
    (try
       ensure_dir_once ~base_dir;
       let redaction = redaction_for ~base_dir ~keeper_name in
       let path = chat_path ~base_dir ~keeper_name in
       let transcript_slot = Keeper_chat_delivery_identity.Settled_failure in
       let candidates =
         List.map
           (fun (tag, { Settled_failure.delivery_key; content; route }) ->
              (* Each row takes its own time, as the single append does: the
                 history pages by [ts], so rows sharing one could fall on
                 both sides of a page boundary. *)
              let ts = Time_compat.now () in
              let content = Keeper_secret_redaction.redact_text redaction content in
              let row_id = mint_message_id ~ts in
              let line =
                lazy
                  (let { Row_route.surface; conversation_id } = Lazy.force route in
                   encode_line
                     ~role:Role.Request_failure
                     ~content
                     ~ts
                     ~message_id:row_id
                     ?surface
                     ?conversation_id
                     ~provenance:
                       { Keeper_chat_delivery_identity.delivery_key; transcript_slot }
                     ())
              in
              tag, delivery_key, route, ({ transcript_slot; row_id; line } : append_once_line))
           failures
       in
       let inspect index =
         let rec loop added results additions = function
           | [] -> List.rev results, List.rev additions
           | (tag, delivery_key, route, ({ row_id; _ } as candidate : append_once_line)) :: rest ->
             let earlier (key, _) = Keeper_chat_delivery_identity.delivery_key_equal key delivery_key in
             (match List.find_opt earlier added with
              | Some (_, row_id) ->
                loop added ((tag, Ok (Already_present { row_id })) :: results) additions rest
              | None ->
                (match
                   find_indexed_provenance
                     index
                     ~provenance:{ Keeper_chat_delivery_identity.delivery_key; transcript_slot }
                 with
                 | Error detail -> loop added ((tag, Error detail) :: results) additions rest
                 | Ok (Some row_id) ->
                   loop added ((tag, Ok (Already_present { row_id })) :: results) additions rest
                 | Ok None ->
                   loop
                     ((delivery_key, row_id) :: added)
                     ((tag, Ok (Appended { row_id })) :: results)
                     ((candidate, route) :: additions)
                     rest))
         in
         loop [] [] [] candidates
       in
       let announce_settled = function
         | Error _ as error -> error
         | Ok (results, appended_routes) ->
           List.iter
             (fun (route : Row_route.t Lazy.t) ->
                announce_appended ~keeper_name ?surface:(Lazy.force route).surface ())
             appended_routes;
           Ok results
       in
       match
         update_indexed_transcript path (fun index ->
           match index with
           | Error detail -> None, Error detail
           | Ok index ->
             let results, additions = inspect index in
             let payload =
               additions
               |> List.map (fun ((candidate : append_once_line), _) -> Lazy.force candidate.line ^ "\n")
               |> String.concat ""
             in
             (if additions = [] then None else Some payload),
             Ok (results, List.map snd additions))
       with
       | Private_file_succeeded result -> announce_settled result
       | Private_file_succeeded_with_cleanup_failure { value = result; cleanup_failure } ->
         Log.Keeper.error
           "keeper_chat_store: settled failure batch succeeded with descriptor settlement failure path=%s: %s"
           path
           (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
         announce_settled result
       | Private_file_failed error -> Error (Fs_compat.durable_append_error_to_string error)
       | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
         Error
           (Printf.sprintf
              "%s; descriptor settlement failed: %s"
              (Fs_compat.durable_append_error_to_string error)
              (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
     with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Error
         (report_store_failure
            ~operation:Keeper_chat_store_operation.Append
            ~keeper_name
            ~what:"settled failure batch"
            exn))
;;

(* Unit wrapper: existing callers keep the prior swallow-and-count behavior (the
   failure is already counted + logged inside the [_result] variant). New callers
   that must surface the failure call [append_assistant_message_result] directly. *)
let append_assistant_message ~base_dir ~keeper_name ~(content : string)
    ?tool_calls ?surface ?conversation_id ?audio ?blocks ?turn_ref
    ?stream_lifecycle () =
  ignore
    (append_assistant_message_result ~base_dir ~keeper_name ~content ?tool_calls
       ?surface ?conversation_id ?audio ?blocks ?turn_ref ?stream_lifecycle ()
      : (unit, string) result)

(* RFC-0226: inbound user line recorded at delivery time, before (and
   independent of) any turn. A single user line — the assistant reply,
   if one ever comes, is appended separately by the reply path. *)
let append_user_message ~base_dir ~keeper_name ~(content : string)
    ?(attachments = []) ?surface ?conversation_id ?external_message_id ?speaker
    ?(extra_mentions = []) () =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let attachments = List.map (redact_attachment redaction) attachments in
    let persisted_attachments = List.map (persisted_attachment ~base_dir) attachments in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let line =
      encode_line ~role:Role.User ~content ~ts ?surface ?conversation_id
        ~attachments:persisted_attachments
        ?external_message_id ?speaker
        ~mentions:(user_line_mentions ~extra_mentions content) ()
    in
    append_chat_payload_durable path (line ^ "\n");
    announce_appended ~keeper_name ?surface ()
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | exn ->
    ignore
      (report_store_failure
         ~operation:Keeper_chat_store_operation.Append
         ~keeper_name
         ~what:"user append"
         exn
        : string)

type mention_policy = Parse_mentions | Passive_context

let append_user_message_once
      ~base_dir
      ~keeper_name
      ~delivery_key
      ~(content : string)
      ?(attachments = [])
      ?surface
      ?conversation_id
      ?external_message_id
      ?workspace_id
      ?speaker
      ?(mention_policy = Parse_mentions)
      ?(extra_mentions = [])
      ()
  =
  try
    ensure_dir_once ~base_dir;
    let redaction = redaction_for ~base_dir ~keeper_name in
    let content = Keeper_secret_redaction.redact_text redaction content in
    let attachments = List.map (redact_attachment redaction) attachments in
    let persisted_attachments = List.map (persisted_attachment ~base_dir) attachments in
    let path = chat_path ~base_dir ~keeper_name in
    let ts = Time_compat.now () in
    let row_id = mint_message_id ~ts in
    let provenance =
      { Keeper_chat_delivery_identity.delivery_key
      ; transcript_slot = Keeper_chat_delivery_identity.Accepted_user
      }
    in
    let line =
      encode_line
        ~role:Role.User
        ~content
        ~ts
        ~message_id:row_id
        ~attachments:persisted_attachments
        ?surface
        ?conversation_id
        ?external_message_id
        ?workspace_id
        ?speaker
        ~mentions:(match mention_policy with
          | Parse_mentions -> user_line_mentions ~extra_mentions content
          | Passive_context -> [])
        ~provenance
        ()
    in
    append_line_once path ~provenance ~row_id line
    |> announce_if_appended ~keeper_name ~route:(Lazy.from_val { Row_route.surface; conversation_id })
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (report_store_failure
         ~operation:Keeper_chat_store_operation.Append
         ~keeper_name
         ~what:"user append-once"
         exn)
;;
