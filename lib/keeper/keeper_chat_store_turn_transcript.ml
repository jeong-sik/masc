open Keeper_chat_types
open Keeper_chat_store_paths
open Keeper_chat_store_redaction
open Keeper_chat_store_line_decode
open Keeper_chat_store_transcript_rows
open Keeper_chat_store_transcript_load
open Keeper_chat_store_audio_clip

let trace_block_for_turn ~trace_block_by_turn_ref (m : chat_message) =
  match m.turn_ref, trace_block_by_turn_ref with
  | Some turn_ref, Some trace_block_by_turn_ref -> trace_block_by_turn_ref turn_ref
  | None, _ | Some _, None -> None

let to_json_array ?base_dir ?trace_block_by_turn_ref
    ?(omit_stream_contract = false)
    (messages : chat_message list) : Yojson.Safe.t =
  let messages = List.filter (fun (message : chat_message) ->
    not (Option.exists (fun provenance ->
      Keeper_chat_delivery_identity.transcript_slot_is_internal
        provenance.Keeper_chat_delivery_identity.transcript_slot)
      message.delivery_provenance)) messages in
  `List
    (List.map
       (fun (m : chat_message) ->
          let trace_block = trace_block_for_turn ~trace_block_by_turn_ref m in
          let audio = resolve_audio_expiry ~base_dir m.audio in
          Keeper_chat_projection.message_to_json ~omit_stream_contract
            ~trace_lookup_available:(Option.is_some trace_block_by_turn_ref)
            ~trace_block { m with audio })
       messages)

type turn_transcript = Keeper_chat_projection.turn_transcript = {
  user : chat_message list;
  assistant : chat_message list;
}

let transcript_of_messages = Keeper_chat_projection.transcript_of_messages
let turn_transcript_to_json = Keeper_chat_projection.turn_transcript_to_json

let exact_transcript_row_identity line =
  let open Result.Syntax in
  match Yojson.Safe.from_string line with
  | `Assoc fields ->
      let keys = List.map fst fields in
      let* () =
        if List.length keys = List.length (List.sort_uniq String.compare keys)
        then Ok () else Error "duplicate transcript row fields" in
      let* () = match List.assoc_opt "id" fields with
        | Some (`String id) when String.trim id <> "" -> Ok ()
        | _ -> Error "transcript row has no non-blank identity" in
      let* () = match List.assoc_opt "content" fields with
        | Some (`String _) -> Ok () | _ -> Error "transcript content is not text" in
      let* () = match List.assoc_opt "ts" fields with
        | Some (`Float ts) when Float.is_finite ts -> Ok ()
        | Some (`Int _) -> Ok () | _ -> Error "transcript timestamp is not finite" in
      let* () = match List.assoc_opt "turn_ref" fields with
        | None -> Ok ()
        | Some json -> Result.map (fun _ -> ()) (Ids.Turn_ref.of_yojson json) in
      Result.map (fun _ -> ())
        (Keeper_chat_delivery_identity.delivery_provenance_of_fields fields)
  | _ -> Error "transcript row is not an object"
  | exception Yojson.Json_error detail -> Error detail

let load_turn_transcript_result ~base_dir ~keeper_name ~turn_ref =
  let open Result.Syntax in
  let path = chat_path ~base_dir ~keeper_name in
  let redaction = redaction_for ~base_dir ~keeper_name in
  let read_page ?cursor () =
    Eio_guard.fair_yield ();
    let* page = Keeper_chat_history_page.read ~path ~owner:keeper_name ?cursor
        ~max_rows:max_int () in
    let* messages_rev = List.fold_left
        (fun state (row : Keeper_chat_history_page.row) ->
          let* messages = state in
          let* () = exact_transcript_row_identity row.line
            |> Result.map_error (fun detail ->
                 Keeper_chat_history_page.Invalid_row { offset = row.offset; detail }) in
          match parse_transcript_row_strict ~path ~redaction ~position:(Byte_offset row.offset) row.line with
          | `Blank -> Ok messages
          | `Message message -> Ok (message :: messages)
          | `Unreadable err ->
              Error (Keeper_chat_history_page.Invalid_row { offset = row.offset; detail = strict_decode_error_to_string err }))
        (Ok []) page.rows in
    Ok { history_messages = List.rev messages_rev; next_cursor = page.next_cursor }
  in
  let* first = read_page () in
  (* Reuse the same first page and its cursor for both passes: a later append
     cannot widen the second pass to a different newest boundary. *)
  let scan select =
    let rec loop page newer =
      let selected = List.filter select page.history_messages in
      let newer = selected @ newer in
      match page.next_cursor with
      | None -> Ok newer
      | Some cursor ->
          let* older = read_page ~cursor () in
          loop older newer
    in
    loop first []
  in
  let* target = scan (fun (message : chat_message) ->
      Option.exists (Ids.Turn_ref.equal turn_ref) message.turn_ref) in
  let assistant = (transcript_of_messages target ~turn_ref).assistant in
  let* user = scan (Keeper_chat_projection.user_matches_turn ~messages:target ~turn_ref) in
  Ok { user; assistant }
