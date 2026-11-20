module Unit = Librarian_unit
module Read_unit = Librarian_read_unit
module Scan = Private_jsonl_scan
module Objects = Agent_core.Checkpoint_objects

type stores =
  { session_dir : session:string -> string
  ; base_path : string
  ; keeper_name : string
  }

type read_error =
  | Fault of Unit.input_fault
  | Unread of { detail : string }

let ( let* ) = Result.bind

(* What one store gave for a segment: its items in order and what it does
   not hold. *)
type part =
  { bodies : Read_unit.body list
  ; missing : Unit.missing_part list
  }

let nothing = { bodies = []; missing = [] }
let is_empty ({ from; until } : Unit.range) = until <= from

(* A store is read as many rows per locked read as the turn log is. *)
let rows_per_read = Keeper_turn_log_store.scan_window_rows

let unread error = Error (Unread { detail = Scan.error_to_string error })

(* The rows of [path] that start inside [range], with the byte offset each
   starts at, and the part of the range the file does not hold. A range
   that does not start a row of the file is not held at all. *)
let rows_between path (range : Unit.range) =
  let past (at, row) = at + String.length row + 1 in
  let held rows =
    let reached =
      match rows with
      | [] -> range.from
      | last :: (_ : (int * string) list) -> past last
    in
    Ok (List.rev rows, if reached < range.until then Some { range with from = reached } else None)
  in
  match
    Scan.fold_from path ~from:range.from ~rows_per_read ~init:[] ~f:(fun rows ~at row ->
      if at >= range.until then Scan.Stop rows else Scan.Continue ((at, row) :: rows))
  with
  | Ok (Stopped rows | Reached_end rows) -> held rows
  | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) -> Ok ([], Some range)
  | Error (Scan_failed error) -> unread error
;;

let official_rows path file (range : Unit.range) =
  if is_empty range
  then Ok nothing
  else (
    let* rows, lacking = rows_between path range in
    let undecodable offset : Unit.missing_part =
      match (file : Keeper_turn_fragments.file) with
      | Main -> Undecodable_history_line { offset }
      | Internal -> Undecodable_internal_line { offset }
    in
    let lacking_bytes range : Unit.missing_part =
      match file with
      | Main -> History_bytes range
      | Internal -> Internal_bytes range
    in
    let bodies, missing =
      List.fold_right
        (fun (at, row) (bodies, missing) ->
           match Keeper_turn_fragments.decode_line row with
           | Ok line -> Read_unit.Fragment { file; line } :: bodies, missing
           | Error (_ : Keeper_turn_fragments.read_error) -> bodies, undecodable at :: missing)
        rows ([], [])
    in
    Ok { bodies; missing = missing @ Option.to_list (Option.map lacking_bytes lacking) })
;;

let chat_rows path (range : Unit.range) =
  if is_empty range
  then Ok nothing
  else (
    let* rows, lacking = rows_between path range in
    Ok
      { bodies =
          List.map
            (fun ((_ : int), row) ->
               Read_unit.Chat_row (Keeper_chat_store_line_decode.parse_line_decoded ~file_path:path row))
            rows
      ; missing = Option.to_list (Option.map (fun range -> Unit.Chat_bytes range) lacking)
      })
;;

(* The external store is counted in rows from its first, so its rows are
   found by counting from there. *)
let external_rows path (range : Unit.range) =
  if is_empty range
  then Ok nothing
  else (
    match
      Scan.fold_from path ~from:0 ~rows_per_read ~init:(0, []) ~f:(fun (count, rows) ~at:(_ : int) row ->
        if count >= range.until
        then Scan.Stop (count, rows)
        else Scan.Continue (count + 1, if count >= range.from then (count, row) :: rows else rows))
    with
    | Error (Not_a_row_start { from = (_ : int); length = (_ : int) }) ->
      Ok { nothing with missing = [ External_rows range ] }
    | Error (Scan_failed error) -> unread error
    | Ok (Stopped (count, rows) | Reached_end (count, rows)) ->
      let decoded row =
        match Yojson.Safe.from_string row with
        | exception Yojson.Json_error (_ : string) -> None
        | json ->
          (match Keeper_external_attention.event_of_json json with
           | Ok (Recorded item) -> Some item
           | Error (_ : string) -> None)
      in
      let bodies, missing =
        List.fold_left
          (fun (bodies, missing) (row_number, row) ->
             match decoded row with
             | Some item -> Read_unit.External_row item :: bodies, missing
             | None -> bodies, Unit.Undecodable_external_row { row = row_number } :: missing)
          ([], []) rows
      in
      let lacking =
        if count < range.until then [ Unit.External_rows { from = Int.max range.from count; until = range.until } ] else []
      in
      Ok { bodies; missing = missing @ lacking })
;;

let messages ~line ~session_dir (slices : Keeper_turn_log.slice list) =
  let read_object = Keeper_checkpoint_object_store.read ~session_dir in
  let unreadable = Error (Fault (Content_unreadable { line })) in
  let slice_part ({ bundle; skip; take } as slice : Keeper_turn_log.slice) =
    if take <= 0
    then Ok nothing
    else (
      match Objects.load_bundle ~read_object bundle with
      | Error (Object_missing (_ : Objects.digest)) -> Ok { nothing with missing = [ Bundle slice ] }
      | Error
          ( Head_invalid _ | Checkpoint_invalid _ | Object_unreadable _ | Object_digest_mismatch _
          | Bundle_invalid _ | Turn_mismatch _ | Message_invalid _ | Segment_invalid _
          | Header_object_invalid _ ) -> unreadable
      | Ok held ->
        if List.length held < skip + take
        then unreadable
        else
          Ok
            { nothing with
              bodies =
                List.filteri (fun index (_ : Agent_core.Types.message) -> index >= skip && index < skip + take) held
                |> List.map (fun message -> Read_unit.Message message)
            })
  in
  List.fold_left
    (fun parts slice ->
       let* parts = parts in
       let* part = slice_part slice in
       Ok (part :: parts))
    (Ok []) slices
  |> Result.map List.rev
;;

(* The segment's conversation from the one record that holds it (§5.1):
   the checkpoint's messages, or the official-client files' rows. *)
let conversation stores ~line ~(through : Keeper_turn_log.mark) : Librarian_unread.record -> _ = function
  | Checkpoint slices -> messages ~line ~session_dir:(stores.session_dir ~session:through.trace) slices
  | Official_files { history; internal } ->
    let official = stores.session_dir ~session:through.session in
    let* history = official_rows (Keeper_turn_fragments.path ~session_dir:official Main) Main history in
    let* internal = official_rows (Keeper_turn_fragments.path ~session_dir:official Internal) Internal internal in
    Ok [ history; internal ]
;;

(* One segment's items in the order {!Librarian_unit} gives: chat rows,
   external rows, then the conversation. *)
let segment stores ~line ~through (segment : Librarian_unread.segment) =
  let* chat =
    chat_rows (Keeper_chat_store.chat_path ~base_dir:stores.base_path ~keeper_name:stores.keeper_name)
      segment.chat
  in
  let* external_ =
    external_rows
      (Keeper_external_attention.attention_path ~base_path:stores.base_path ~keeper_name:stores.keeper_name)
      segment.external_rows
  in
  let* conversation = conversation stores ~line ~through segment.record in
  let parts = chat :: external_ :: conversation in
  Ok
    ( List.concat_map (fun part -> part.bodies) parts
    , List.concat_map (fun (part : part) -> part.missing) parts )
;;

let numbered ~first bodies = List.mapi (fun at body : Read_unit.item -> { index = first + at; body }) bodies

let read stores (span : Librarian_unread.span) =
  let segment = segment stores ~line:span.line ~through:span.through in
  match span.source with
  | Turn { turn; outcome; opened; unattributed; own } ->
    let* before, before_missing = segment unattributed in
    let* after, after_missing = segment own in
    Ok
      ({ line = span.line
       ; at = span.at
       ; kind =
           Turn
             { turn
             ; outcome
             ; opened
             ; unattributed = numbered ~first:0 before
             ; own = numbered ~first:(List.length before) after
             }
       ; missing = before_missing @ after_missing
       }
       : Read_unit.t)
  | Announced_reset { cause; segment = held } ->
    let* bodies, missing = segment held in
    Ok
      ({ line = span.line; at = span.at; kind = Reset { cause; items = numbered ~first:0 bodies }; missing }
       : Read_unit.t)
;;
