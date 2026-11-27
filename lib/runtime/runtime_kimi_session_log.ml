(* See the .mli. *)

open Result.Syntax

type root = string

type error =
  | Home_unavailable
  | Session_id_invalid of string
  | Session_record_not_found of
      { searched : string
      ; session_id : string
      }
  | Session_record_ambiguous of
      { session_id : string
      ; paths : string list
      }
  | Read_failed of
      { path : string
      ; detail : string
      }
  | Record_shrank of
      { path : string
      ; marked_at : int
      ; size : int
      }
  | Slice_too_large of { bytes : int }
  | Unsupported_protocol of
      { path : string
      ; found : string option
      ; supported : string
      }
  | Malformed_record of
      { byte_offset : int
      ; detail : string
      }

(* Checked against Kimi Code 2.7.3 on 2026-11-27: every record file of the
   102 sessions written in the two days before opened with this version. *)
let supported_protocol_version = "1.5"
let max_slice_bytes = 256 * 1024 * 1024
let record_path_under_session = [ "agents"; "main"; "wire.jsonl" ]

let error_to_string = function
  | Home_unavailable ->
    "KIMI_CODE_HOME is a relative path, or it is unset and HOME is not an absolute \
     directory, so the host's home is unknown"
  | Session_id_invalid id -> Printf.sprintf "session id %S cannot name a session directory" id
  | Session_record_not_found { searched; session_id } ->
    Printf.sprintf "no record of session %s under %s" session_id searched
  | Session_record_ambiguous { session_id; paths } ->
    Printf.sprintf
      "session %s has a record in more than one workspace directory: %s"
      session_id
      (String.concat ", " paths)
  | Read_failed { path; detail } -> Printf.sprintf "cannot read %s: %s" path detail
  | Record_shrank { path; marked_at; size } ->
    Printf.sprintf
      "%s is %d bytes, shorter than the %d bytes it had when the prompt was sent"
      path
      size
      marked_at
  | Slice_too_large { bytes } ->
    Printf.sprintf "the prompt added %d bytes to the record, more than %d" bytes max_slice_bytes
  | Unsupported_protocol { path; found; supported } ->
    Printf.sprintf
      "%s opens with protocol_version %s; this reader was checked against %s"
      path
      (Option.value found ~default:"(none)")
      supported
  | Malformed_record { byte_offset; detail } ->
    Printf.sprintf "the record at byte %d is not readable: %s" byte_offset detail
;;

(* ── Where the record is ─────────────────────────────────────────────────── *)

let env_value env key =
  let prefix = key ^ "=" in
  let prefix_length = String.length prefix in
  Array.find_map
    (fun entry ->
       if String.starts_with ~prefix entry
       then Some (String.sub entry prefix_length (String.length entry - prefix_length))
       else None)
    env
;;

let root_of_environment env =
  let sessions_under home = Filename.concat home "sessions" in
  match env_value env "KIMI_CODE_HOME" with
  | Some home when home <> "" ->
    if Filename.is_relative home then Error Home_unavailable else Ok (sessions_under home)
  | Some _ | None ->
    (match env_value env "HOME" with
     | Some home when home <> "" && not (Filename.is_relative home) ->
       Ok (sessions_under (Filename.concat home ".kimi-code"))
     | Some _ | None -> Error Home_unavailable)
;;

let root_directory root = root

let valid_session_id id =
  id <> ""
  && id <> "."
  && id <> ".."
  && String.for_all (fun c -> c <> '/' && c <> '\\' && c <> '\000') id
;;

(* The host names each workspace directory after the workspace and a hash of
   its path, so the session is found by its id under every one of them. *)
let locate root ~session_id =
  if not (valid_session_id session_id)
  then Error (Session_id_invalid session_id)
  else (
    let record_in workspace =
      let path =
        List.fold_left
          Filename.concat
          (Filename.concat (Filename.concat root workspace) session_id)
          record_path_under_session
      in
      if Sys.file_exists path then Some path else None
    in
    let workspaces =
      match Sys.readdir root with
      | names -> Array.to_list names
      | exception Sys_error _ -> []
    in
    match List.filter_map record_in workspaces with
    | [ path ] -> Ok path
    | [] -> Error (Session_record_not_found { searched = root; session_id })
    | paths -> Error (Session_record_ambiguous { session_id; paths }))
;;

let string_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`String s) -> Some s
     | Some _ | None -> None)
  | _ -> None
;;

let int_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Int n) -> Some n
     | Some _ | None -> None)
  | _ -> None
;;

let object_field key = function
  | `Assoc fields ->
    (match List.assoc_opt key fields with
     | Some (`Assoc _ as value) -> Some value
     | Some _ | None -> None)
  | _ -> None
;;

let check_protocol path =
  let unsupported found =
    Error (Unsupported_protocol { path; found; supported = supported_protocol_version })
  in
  match In_channel.with_open_bin path In_channel.input_line with
  | exception Sys_error detail -> Error (Read_failed { path; detail })
  | None -> unsupported None
  | Some first ->
    (match Yojson.Safe.from_string first with
     | exception Yojson.Json_error _ -> unsupported None
     | json ->
       (match string_field "type" json, string_field "protocol_version" json with
        | Some "metadata", Some version when String.equal version supported_protocol_version ->
          Ok ()
        | Some "metadata", found -> unsupported found
        | (Some _ | None), _ -> unsupported None))
;;

type mark =
  { path : string
  ; offset : int
  }

let mark root ~session_id =
  let* path = locate root ~session_id in
  let* () = check_protocol path in
  match Unix.stat path with
  | stats -> Ok { path; offset = stats.Unix.st_size }
  | exception Unix.Unix_error (err, _, _) ->
    Error (Read_failed { path; detail = Unix.error_message err })
;;

(* ── What the prompt added ────────────────────────────────────────────────── *)

(* Returns the file offset of the first byte read and the bytes up to the end
   of the file as it is now. One byte before the mark is read as well: it
   tells whether the mark fell between two records. *)
let read_slice { path; offset } =
  let read ic =
    let size = Int64.to_int (In_channel.length ic) in
    if size < offset
    then Error (Record_shrank { path; marked_at = offset; size })
    else if size - offset > max_slice_bytes
    then Error (Slice_too_large { bytes = size - offset })
    else (
      let start = max 0 (offset - 1) in
      In_channel.seek ic (Int64.of_int start);
      match In_channel.really_input_string ic (size - start) with
      | Some slice -> Ok (start, slice)
      | None ->
        Error
          (Read_failed { path; detail = "the file ended before the length it had when read" }))
  in
  match In_channel.with_open_bin path read with
  | result -> result
  | exception Sys_error detail -> Error (Read_failed { path; detail })
;;

(* The newline-terminated lines of [slice] that begin at or after [offset],
   each with the file offset it begins at. [start] is the file offset of
   [slice.[0]]. A line the host was still writing has no newline yet and is
   left out. When [offset > 0], [slice.[0]] is the byte before the mark: a
   newline there means the mark fell between two records; anything else means
   it fell inside one, which belongs to earlier activity, so that record's
   remaining bytes are skipped. *)
let complete_lines ~start ~offset slice =
  let first_line =
    if offset = 0
    then Some 0
    else if String.length slice = 0
    then None
    else if slice.[0] = '\n'
    then Some 1
    else Option.map (fun newline -> newline + 1) (String.index_from_opt slice 1 '\n')
  in
  let rec from position found =
    match String.index_from_opt slice position '\n' with
    | Some newline ->
      from
        (newline + 1)
        ((start + position, String.sub slice position (newline - position)) :: found)
    | None -> List.rev found
  in
  match first_line with
  | Some position when position <= String.length slice -> from position []
  | Some _ | None -> []
;;

type turn_end =
  | Turn_completed
  | Turn_cancelled
  | Turn_failed of
      { code : string
      ; message : string
      ; status : int option
      }

type record =
  | Prompt_started
  | Context_compacted
  | Turn_ended of turn_end
  | Other_event

(* [turn.ended] reasons seen in 290 records of 144 sessions written in the
   three days to 2026-11-27: [completed] 269, [cancelled] 9, [failed] 12. Every
   [failed] record carried [error.code] and [error.message]; a provider refusal
   also carries [error.details.statusCode] (429 for the weekly usage limit). *)
let decode_turn_end ~byte_offset json =
  let malformed detail = Error (Malformed_record { byte_offset; detail }) in
  match string_field "reason" json with
  | Some "completed" -> Ok Turn_completed
  | Some "cancelled" -> Ok Turn_cancelled
  | Some "failed" ->
    let error = object_field "error" json in
    (match
       Option.bind error (string_field "code"), Option.bind error (string_field "message")
     with
     | Some code, Some message ->
       let status =
         Option.bind (Option.bind error (object_field "details")) (int_field "statusCode")
       in
       Ok (Turn_failed { code; message; status })
     | (Some _ | None), _ ->
       malformed "turn.ended failed without string error.code and error.message")
  | Some reason -> malformed (Printf.sprintf "turn.ended has unknown reason %S" reason)
  | None -> malformed "turn.ended has no string \"reason\" field"
;;

let decode_record ~byte_offset line =
  match Yojson.Safe.from_string line with
  | exception Yojson.Json_error detail -> Error (Malformed_record { byte_offset; detail })
  | json ->
    (match string_field "type" json with
     | Some "turn.prompt" -> Ok Prompt_started
     | Some "context.apply_compaction" -> Ok Context_compacted
     | Some "turn.ended" ->
       let* turn_end = decode_turn_end ~byte_offset json in
       Ok (Turn_ended turn_end)
     | Some _ -> Ok Other_event
     | None -> Error (Malformed_record { byte_offset; detail = "no string \"type\" field" }))
;;

(* The next count starts after the last newline read, so a record the host
   was still writing is read once it ends. *)
let next_mark m ~start slice =
  match String.rindex_opt slice '\n' with
  | Some newline -> { m with offset = max m.offset (start + newline + 1) }
  | None -> m
;;

type prompt_record =
  { compactions : int
  ; turn_end : turn_end option
  }

let read_prompt m =
  let* start, slice = read_slice m in
  let* record =
    List.fold_left
      (fun acc (byte_offset, line) ->
         let* acc = acc in
         if line = ""
         then Ok acc
         else (
           let* record = decode_record ~byte_offset line in
           match record with
           (* A prompt may end without a record: 30 of 320 did in the three
              days to 2026-11-27, 11 of them before the next prompt. Each
              prompt starts with no ending, so an earlier prompt's ending is
              never read as this one's. *)
           | Prompt_started -> Ok { acc with turn_end = None }
           | Context_compacted -> Ok { acc with compactions = acc.compactions + 1 }
           | Turn_ended turn_end -> Ok { acc with turn_end = Some turn_end }
           | Other_event -> Ok acc))
      (Ok { compactions = 0; turn_end = None })
      (complete_lines ~start ~offset:m.offset slice)
  in
  Ok (record, next_mark m ~start slice)
;;
