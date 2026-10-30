type cursor =
  { owner : string
  ; device : int
  ; inode : int
  ; offset : int
  ; anchor_id : string
  }

type error =
  | Invalid_cursor of string
  | Stale_cursor
  | Invalid_row of { offset : int; detail : string }
  | Row_exceeds_window
  | Io_error of string

let error_to_string = function
  | Invalid_cursor detail -> "Invalid conversation cursor: " ^ detail
  | Stale_cursor -> "Conversation history changed; reload it before reading earlier pages."
  | Invalid_row { offset; detail } ->
    Printf.sprintf "Unreadable conversation row at byte %d: %s" offset detail
  | Row_exceeds_window -> "A conversation row exceeds the history page byte window."
  | Io_error detail -> "Conversation history could not be read: " ^ detail

let cursor_to_string cursor =
  `Assoc
    [ "schema", `String "masc.keeper_chat_history.cursor.v1"
    ; "owner", `String cursor.owner
    ; "device", `Int cursor.device
    ; "inode", `Int cursor.inode
    ; "offset", `Int cursor.offset
    ; "anchor_id", `String cursor.anchor_id
    ]
  |> Yojson.Safe.to_string
  |> Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet

let cursor_of_string encoded =
  let invalid detail = Error (Invalid_cursor detail) in
  match Base64.decode ~pad:false ~alphabet:Base64.uri_safe_alphabet encoded with
  | Error (`Msg detail) -> invalid detail
  | Ok bytes ->
    (match Yojson.Safe.from_string bytes with
     | `Assoc fields ->
       let string key =
         match List.assoc_opt key fields with
         | Some (`String value) when String.trim value <> "" -> Some value
         | Some _ | None -> None
       in
       let integer key =
         match List.assoc_opt key fields with
         | Some (`Int value) when value >= 0 -> Some value
         | Some _ | None -> None
       in
       (match string "schema", string "owner", integer "device", integer "inode",
              integer "offset", string "anchor_id" with
        | Some "masc.keeper_chat_history.cursor.v1", Some owner, Some device,
          Some inode, Some offset, Some anchor_id
          when List.length fields = 6 ->
          let cursor = { owner; device; inode; offset; anchor_id } in
          if String.equal encoded (cursor_to_string cursor)
          then Ok cursor
          else invalid "noncanonical cursor"
        | _ -> invalid "unknown or incomplete cursor")
     | _ -> invalid "cursor is not an object"
     | exception Yojson.Json_error detail -> invalid detail)

type row = { offset : int; line : string }
type page = { rows : row list; next_cursor : cursor option }

let byte_window = 4 * 1024 * 1024

let read_bytes channel ~from ~length =
  seek_in channel from;
  really_input_string channel length

let row_id ({ offset; line } : row) =
  match Yojson.Safe.from_string line with
  | `Assoc fields ->
    (match List.assoc_opt "id" fields with
     | Some (`String id) when String.trim id <> "" -> Ok id
     | Some _ | None -> Error (Invalid_row { offset; detail = "missing stable row id" }))
  | _ -> Error (Invalid_row { offset; detail = "row is not an object" })
  | exception Yojson.Json_error detail -> Error (Invalid_row { offset; detail })

let rows_in_slice ~from bytes =
  let length = String.length bytes in
  let start =
    if from = 0 then Some 0
    else Option.map (( + ) 1) (String.index_opt bytes '\n')
  in
  match start with
  | None -> Error Row_exceeds_window
  | Some start ->
    let rec walk position rows =
      if position = length then Ok (List.rev rows)
      else
        match String.index_from_opt bytes position '\n' with
        | None -> Error (Invalid_row { offset = from + position; detail = "incomplete final row" })
        | Some finish ->
          let line = String.sub bytes position (finish - position) in
          let rows =
            if String.trim line = "" then rows
            else { offset = from + position; line } :: rows
          in
          walk (finish + 1) rows
    in
    walk start []

let same_file (left : Unix.stats) (right : Unix.stats) =
  left.st_dev = right.st_dev && left.st_ino = right.st_ino

type source = Absent | Present of string

let source_is_present = function Absent -> false | Present _ -> true

let source_fingerprint = function Absent -> "absent" | Present stamp -> stamp

let stat_fingerprint (stat : Unix.stats) =
  Printf.sprintf "%d:%d:%d:%h:%h"
    stat.st_dev stat.st_ino stat.st_size stat.st_mtime stat.st_ctime

let inspect_source ~path =
  try
    let opened =
      match Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 with
      | fd -> Some fd
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
    in
    match opened with
    | None -> Ok Absent
    | Some fd ->
      Fun.protect ~finally:(fun () -> Unix.close fd) (fun () ->
        let opened = Unix.fstat fd in
        if opened.Unix.st_kind <> Unix.S_REG
        then Error (Io_error ("history source is not a regular file: " ^ path))
        else
          let named = Unix.stat path in
          if not (String.equal (stat_fingerprint opened) (stat_fingerprint named))
          then Error Stale_cursor
          else Ok (Present (stat_fingerprint opened)))
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Error Stale_cursor
  | Unix.Unix_error (error, operation, argument) ->
    Error (Io_error (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error)))

let read ~path ~owner ?cursor ~max_rows () =
  let open Result.Syntax in
  try
    let fd = Unix.openfile path [Unix.O_RDONLY; Unix.O_NONBLOCK; Unix.O_CLOEXEC] 0 in
    let channel = Unix.in_channel_of_descr fd in
    Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
      let opened = Unix.fstat fd in
      if opened.Unix.st_kind <> Unix.S_REG
      then Error (Io_error "conversation path is not a regular file")
      else
        let* upto =
          match cursor with
          | None -> Ok opened.st_size
          | Some cursor ->
            if not (String.equal cursor.owner owner)
               || cursor.device <> opened.st_dev || cursor.inode <> opened.st_ino
               || cursor.offset < 0 || cursor.offset >= opened.st_size
            then Error Stale_cursor
            else
              let boundary = cursor.offset = 0
                || String.equal (read_bytes channel ~from:(cursor.offset - 1) ~length:1) "\n" in
              if not boundary then Error Stale_cursor
              else
                let bytes = read_bytes channel ~from:cursor.offset
                  ~length:(min byte_window (opened.st_size - cursor.offset)) in
                (match String.index_opt bytes '\n' with
                 | None -> Error Stale_cursor
                 | Some finish ->
                   let anchor = { offset = cursor.offset; line = String.sub bytes 0 finish } in
                   (match row_id anchor with
                    | Ok id when String.equal id cursor.anchor_id -> Ok cursor.offset
                    | Ok _ | Error _ -> Error Stale_cursor))
        in
        let from = max 0 (upto - byte_window) in
        let* available = rows_in_slice ~from (read_bytes channel ~from ~length:(upto - from)) in
        let rows = List.rev available |> List.take (max 1 max_rows) |> List.rev in
        let* next_cursor =
          match rows with
          | [] when from > 0 -> Error Row_exceeds_window
          | [] | { offset = 0; _ } :: _ -> Ok None
          | ({ offset; _ } as first) :: _ ->
            let* anchor_id = row_id first in
            Ok (Some { owner; device = opened.st_dev; inode = opened.st_ino; offset; anchor_id })
        in
        let current = Unix.fstat fd in
        let named =
          match Unix.stat path with
          | named -> Some named
          | exception Unix.Unix_error (Unix.ENOENT, _, _) -> None
        in
        if not (same_file opened current
                && Option.exists (same_file opened) named)
           || current.st_size < opened.st_size
        then Error Stale_cursor
        else Ok { rows; next_cursor })
  with
  | Unix.Unix_error (Unix.ENOENT, _, _) ->
    (match cursor with None -> Ok { rows = []; next_cursor = None } | Some _ -> Error Stale_cursor)
  | Unix.Unix_error (error, operation, argument) ->
    Error (Io_error (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error)))
  | Sys_error detail -> Error (Io_error detail)
  | End_of_file -> Error Stale_cursor
