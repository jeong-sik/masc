open Keeper_chat_types
open Keeper_chat_store_redaction
open Keeper_chat_store_row_codec
open Keeper_chat_store_line_decode

(* ── Transcript cache (RFC main-domain-scheduler-latency §8.8, P4k) ────
   [load_all] used to read the whole transcript, parse every row and redact
   every message on the calling fiber, on every keeper wake: 1.7-3.5 MB and
   2,000-3,700 rows per keeper on the live root, and the regex passes of the
   redaction alone were 19% of the main domain's busy time (2026-09-05).
   The transcript is append-only — the store's one writer appends under the
   private JSONL lock — so a load parses only the rows past the last parsed
   row boundary and appends them to what was parsed before. The cache is per
   path and holds while the file keeps its identity (device, inode), has not
   shrunk below the parsed boundary, and the redaction snapshot the messages
   were redacted with is the one in force ([redaction_for] hands back the
   same value while the secret sources are unchanged). Anything else, and a
   torn tail, reload the whole transcript through the rows reader. Parsing
   and redaction run on the domain pool when one is installed. *)
type transcript_cache =
  { device : int
  ; inode : int
  ; parsed_end : int  (** Offset just past the last parsed ['\n']-terminated row. *)
  ; messages_rev : chat_message list  (** Newest first. *)
  ; redaction : Keeper_secret_redaction.t
  }

let transcript_caches : (string, transcript_cache) Hashtbl.t = Hashtbl.create 16
let transcript_caches_mu = Stdlib.Mutex.create ()

let remember_transcript path cache =
  Stdlib.Mutex.protect transcript_caches_mu (fun () ->
    Hashtbl.replace transcript_caches path cache)
;;

(* The registration of a load that went on from [from]. It stands only while
   the table still holds that very entry: a purge in between removed it, and a
   load that finished first put its own in. *)
let advance_transcript path ~from cache =
  Stdlib.Mutex.protect transcript_caches_mu (fun () ->
    match Hashtbl.find_opt transcript_caches path with
    | Some held when held == from -> Hashtbl.replace transcript_caches path cache
    | Some _ | None -> ())
;;

let forget_transcript path =
  Stdlib.Mutex.protect transcript_caches_mu (fun () -> Hashtbl.remove transcript_caches path)
;;

let transcript_identity path =
  match Unix.stat path with
  | st -> Some (st.Unix.st_dev, st.Unix.st_ino, st.Unix.st_size)
  | exception Unix.Unix_error _ -> None
;;

let parse_transcript_row_permissive ~path ~redaction line =
  let trimmed = String.trim line in
  if String.equal trimmed ""
  then None
  else (
    let decoded = parse_line_decoded ~file_path:path trimmed in
    Option.map (redact_message redaction) decoded.message)
;;

type transcript_position = Line_number of int | Byte_offset of int

let parse_transcript_row_strict ~path ~redaction ~position line =
  let location = match position with
    | Line_number line -> Printf.sprintf "%s:%d" path line
    | Byte_offset offset -> Printf.sprintf "%s at byte %d" path offset in
  let trimmed = String.trim line in
  if String.equal trimmed ""
  then `Blank
  else
    match parse_line_decoded ~file_path:path trimmed with
        | { strict_decode_error = Some cause; _ } ->
      `Unreadable { location; cause }
    | { message = Some message; strict_decode_error = None } ->
      `Message (redact_message redaction message)
    | { message = None; strict_decode_error = None } ->
      `Unreadable { location; cause = Invalid_row_contract "unreadable chat row" }
;;

let parse_transcript_rows ~path ~redaction rows =
  rows
  |> String.split_on_char '\n'
  |> List.filter_map (parse_transcript_row_permissive ~path ~redaction)
;;

type captured_row = { raw_line : string; projected_line : string; captured_message : chat_message }

let captured_row_message row = row.captured_message
let captured_row_same_source left right = String.equal left.raw_line right.raw_line
let captured_row_to_json row =
  `Assoc ["raw_line", `String row.raw_line; "projected_line", `String row.projected_line]

let redacted_row_fields = ["content"; "attachments"; "blocks"; "audio"; "approval_lifecycle"]

let projected_row_line raw_line (message : chat_message) =
  let encoded = encode_line ~role:message.role ~content:message.content ~ts:message.ts
      ~message_id:message.id ?attachments:message.attachments ?tool_call_id:message.tool_call_id
      ?execution_id:message.execution_id ?tool_call_name:message.tool_call_name
      ?surface:message.surface ?conversation_id:message.conversation_id
      ?external_message_id:message.external_message_id ?workspace_id:message.workspace_id
      ?speaker:message.speaker ?audio:message.audio ?blocks:message.blocks
      ~mentions:message.mentions ?turn_ref:message.turn_ref
      ?stream_lifecycle:message.stream_lifecycle ?approval_lifecycle:message.approval_lifecycle
      ?provenance:message.delivery_provenance () |> Yojson.Safe.from_string in
  match Yojson.Safe.from_string raw_line, encoded with
  | `Assoc raw, `Assoc fields ->
    `Assoc (List.map (fun (key, value) ->
      key, if List.mem key redacted_row_fields then
        (match List.assoc_opt key fields with Some redacted -> redacted | None -> value)
      else value) raw) |> Yojson.Safe.to_string
  | _ -> raw_line
;;

let captured_row_of_json = function
  | `Assoc fields when List.sort String.compare (List.map fst fields) = ["projected_line";"raw_line"] ->
    (match List.assoc "raw_line" fields, List.assoc "projected_line" fields with
     | `String raw_line, `String projected_line ->
       let decode line =
         try
           let value = Yojson.Safe.from_string line in
           match value with
           | `Assoc fields when List.length fields = List.length (List.sort_uniq String.compare (List.map fst fields)) ->
             (match parse_transcript_row_strict ~path:"captured chat row"
                ~redaction:Keeper_secret_redaction.empty ~position:(Line_number 1) line with
              | `Message message when Float.is_finite message.ts -> Ok (fields, message)
              | `Message _ -> Error "captured chat timestamp is not finite"
              | `Blank -> Error "blank captured chat row"
              | `Unreadable error -> Error (strict_decode_error_to_string error))
           | _ -> Error "invalid or duplicate captured chat row fields"
         with Yojson.Json_error detail -> Error detail in
       let open Result.Syntax in
       let* raw_fields, _ = decode raw_line in
       let* projected_fields, captured_message = decode projected_line in
       let immutable fields = List.filter (fun (key, _) -> not (List.mem key redacted_row_fields)) fields in
       if not (Yojson.Safe.equal (`Assoc (immutable raw_fields)) (`Assoc (immutable projected_fields)))
          || List.sort String.compare (List.map fst raw_fields) <> List.sort String.compare (List.map fst projected_fields)
       then Error "captured chat projection changed original identity or field presence"
       else Ok {raw_line; projected_line; captured_message}
     | _ -> Error "captured chat rows must contain original strings")
  | _ -> Error "unexpected captured chat row fields"
;;

let parse_transcript_captures_result ~select ~path ~redaction rows =
  rows
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun state line ->
          let open Result.Syntax in
          let* messages_rev, line_no = state in
          let line_no = line_no + 1 in
          match parse_transcript_row_strict ~path ~redaction ~position:(Line_number line_no) line with
          | `Blank -> Ok (messages_rev, line_no)
          | `Message message when not (Float.is_finite message.ts) ->
            Error {location=Printf.sprintf "%s:%d" path line_no;
              cause=Invalid_row_contract "captured chat timestamp is not finite"}
          | `Message message when not (select message) -> Ok (messages_rev, line_no)
          | `Message message ->
            let projected_line = projected_row_line line message in
            let row = {raw_line=line;projected_line;captured_message=message} in
            (match captured_row_of_json (captured_row_to_json row) with
             | Ok restored when restored.captured_message = message -> Ok (row :: messages_rev, line_no)
             | Ok _ -> Error {location=Printf.sprintf "%s:%d" path line_no;
                 cause=Invalid_row_contract "captured chat projection cannot preserve its complete typed row"}
             | Error detail -> Error {location=Printf.sprintf "%s:%d" path line_no;
                 cause=Invalid_row_contract detail})
          | `Unreadable err -> Error err)
       (Ok ([], 0))
  |> Result.map (fun (messages_rev, _line_no) -> List.rev messages_rev)
;;

let parse_transcript_rows_result ~path ~redaction rows =
  rows |> String.split_on_char '\n'
  |> List.fold_left (fun state line ->
    let open Result.Syntax in
    let* messages_rev, line_no = state in
    let line_no = line_no + 1 in
    match parse_transcript_row_strict ~path ~redaction ~position:(Line_number line_no) line with
    | `Blank -> Ok (messages_rev, line_no)
    | `Message message -> Ok (message :: messages_rev, line_no)
    | `Unreadable error -> Error error) (Ok ([], 0))
  |> Result.map (fun (messages_rev, _) -> List.rev messages_rev)
;;
