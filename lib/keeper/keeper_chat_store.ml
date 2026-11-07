(** Keeper_chat_store — JSONL-based persistence for keeper direct messages.

    Each keeper gets a file: [<base_dir>/.masc/keeper_chat/<name>.jsonl]
    Lines are append-only with timestamps.

    Line format:
    {v {"id":"msg-...","role":"user","content":"hello","ts":1774000000.0} v}

    Tool-call lines (persisted between the user and assistant lines of a
    turn) carry the executed tool name and accumulated arguments:
    {v {"id":"msg-...","role":"tool","content":"{\"path\":\"x\"}","ts":...,
        "tool_call_id":"toolu_1","tool_call_name":"Read",
        "surface":{"kind":"dashboard"}} v}

    Connector rows may additionally carry opaque route coordinates:
    [conversation_id] for channel/thread grouping and [external_message_id]
    for the inbound platform message. The store does not interpret these
    values.

    @since 2.145.0 *)

open Keeper_approval_lifecycle

include Keeper_chat_types

open Keeper_chat_projection
include Keeper_chat_store_paths
include Keeper_chat_store_redaction
include Keeper_chat_store_row_codec
include Keeper_chat_store_delivery_rules
include Keeper_chat_store_provenance_index
include Keeper_chat_store_append_primitives
include Keeper_chat_store_turn_append
include Keeper_chat_store_append_once
include Keeper_chat_store_message_append
include Keeper_chat_store_line_decode
include Keeper_chat_store_history_window
include Keeper_chat_store_transcript_rows
include Keeper_chat_store_transcript_load
include Keeper_chat_store_approval_lifecycle

(* RFC-0235 P3: the history endpoint can tell the dashboard that a clip
   has been reaped by checking the same audio directory the synthesis side
   writes to. This keeps the TTL reaper simple while avoiding a broken
   native player on reload. *)
let audio_clip_exists ~base_dir token =
  (* Which container the clip is in is the endpoint's, not this reader's, so
     the token is resolved against every format rather than against MP3 --
     a say clip is WAVE, and looking only for MP3 reports every one of them
     as reaped. *)
  Voice_bridge_core.find_clip
    ~dir:
      (Filename.concat (Common.masc_dir_from_base_path ~base_path:base_dir) "audio")
    ~token
  |> Option.is_some

(* How a file the synthesis side just wrote is announced on a chat line.

   Both halves come out of the one path: the token builds the URL the
   dashboard fetches, and the extension says what the bytes are. They used to
   be taken separately -- the token chopped off by hand, the type the literal
   "audio/mpeg" -- so every [say] reply, which is WAVE and is what a fresh mac
   has, was announced as MP3. The dashboard reads the container off the clip
   response rather than off this field, which is why nothing looked broken;
   the field is still what is persisted here and emitted on SSE, so a reader
   that has only the payload had only the wrong answer.

   It lives here, next to {!audio_clip_exists}, because this is the module
   that owns the clip record: a caller that builds one field at a time is
   where the two halves came apart. *)
let audio_clip_of_synthesized_file ~audio_file ~message_text ~device_id =
  match Voice_bridge_core.clip_of_path audio_file with
  | None ->
    (* A file under a name masc does not serve would be announced at a URL the
       clip route answers 404 for: it resolves a token by trying each known
       extension. The line is still recorded, without audio. *)
    Voice_bridge_core.log_error
      (Printf.sprintf
         "voice: synthesized %s is not a clip masc can serve; the reply is \
          recorded without audio"
         (Filename.basename audio_file));
    None
  | Some (token, format) ->
    Some
      { token
      ; audio_url = Some (Masc_network_defaults.voice_audio_path token)
      ; mime = Voice_bridge_core.clip_content_type format
      ; duration_sec = Voice_bridge_core.audio_duration_seconds ~audio_file
      ; message_text
      ; device_id
      ; expired = false
      }

let valid_audio_token token =
  Re.execp (Re.compile (Re.Pcre.re "^[A-Za-z0-9_-]+$")) token

let resolve_audio_expiry ~base_dir audio =
  match audio with
  | None -> None
  | Some a ->
      let expired =
        if not (valid_audio_token a.token) then true
        else
          match base_dir with
          | None -> a.expired
          | Some base_dir ->
              a.expired
              || not (audio_clip_exists ~base_dir a.token)
      in
      Some { a with expired }

let trace_block_for_turn ~trace_block_by_turn_ref (m : chat_message) =
  match m.turn_ref, trace_block_by_turn_ref with
  | Some turn_ref, Some trace_block_by_turn_ref -> trace_block_by_turn_ref turn_ref
  | None, _ | Some _, None -> None

let to_json_array ?base_dir ?trace_block_by_turn_ref
    ?(omit_stream_contract = false)
    (messages : chat_message list) : Yojson.Safe.t =
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
