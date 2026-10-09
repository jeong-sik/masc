let ( let* ) = Result.bind

type leader = Started_at of string | Start_unreadable

type entry = { group : int; leader : leader; profile : string; port : int; started_at : float }

let record_name = "keeper-firefox.json"
let file_permissions = 0o600

(* The version of this layout. A reader built for another one says so
   instead of guessing at fields it does not know. *)
let schema = 1

let directory base_path =
  List.fold_left Filename.concat base_path [ Common.masc_dirname; Common.browser_lane_dirname ]

let record_path ~base_path = Filename.concat (directory base_path) record_name

(* Written to the nearest millisecond, as the host's record writes its times
   (Browser_bidi_host_record). *)
let half_millisecond = 0.0005
let time at = `String (Time_codec.rfc3339_of_unix_ms (at +. half_millisecond))

let leader_to_json = function
  | Started_at started -> `Assoc [ "kind", `String "started_at"; "started", `String started ]
  | Start_unreadable -> `Assoc [ "kind", `String "start_unreadable" ]

let entry_to_json entry =
  `Assoc
    [ "schema", `Int schema
    ; "group", `Int entry.group
    ; "leader", leader_to_json entry.leader
    ; "profile", `String entry.profile
    ; "port", `Int entry.port
    ; "started_at", time entry.started_at
    ]

(* Exactly these fields, so a record from another writer is not half read. *)
let fields_of ~names = function
  | `Assoc fields ->
    let known = List.sort String.compare names in
    let found = List.sort String.compare (List.map fst fields) in
    if List.equal String.equal known found then Ok fields
    else Error ("expected exactly the fields " ^ String.concat ", " names)
  | _ -> Error "expected a JSON object"

let field fields name =
  Option.to_result ~none:("missing " ^ name) (List.assoc_opt name fields)

let positive name = function
  | `Int value when value > 0 -> Ok value
  | _ -> Error (name ^ " is not a positive integer")

let text name = function
  | `String value when not (String.equal value "") -> Ok value
  | _ -> Error (name ^ " is not a non-empty string")

let leader_of_json = function
  | `Assoc fields as json ->
    let* kind = Result.bind (field fields "kind") (text "leader kind") in
    (match kind with
     | "started_at" ->
       let* fields = fields_of ~names:[ "kind"; "started" ] json in
       let* started = Result.bind (field fields "started") (text "leader started") in
       Ok (Started_at started)
     | "start_unreadable" ->
       let* _ = fields_of ~names:[ "kind" ] json in
       Ok Start_unreadable
     | other -> Error (Printf.sprintf "leader kind %S is not one this reader knows" other))
  | _ -> Error "leader is not a JSON object"

let entry_of_json json =
  let* fields =
    fields_of ~names:[ "schema"; "group"; "leader"; "profile"; "port"; "started_at" ] json
  in
  let* () =
    match List.assoc_opt "schema" fields with
    | Some (`Int version) when version = schema -> Ok ()
    | Some (`Int version) ->
      Error (Printf.sprintf "written as layout %d; this reader knows %d" version schema)
    | Some _ | None -> Error "schema is not an integer"
  in
  let* group = Result.bind (field fields "group") (positive "group") in
  let* leader = Result.bind (field fields "leader") leader_of_json in
  let* profile = Result.bind (field fields "profile") (text "profile") in
  let* port = Result.bind (field fields "port") (positive "port") in
  let* started_at =
    match field fields "started_at" with
    | Ok (`String raw) ->
      Result.map_error (fun Time_codec.Invalid_rfc3339 -> "started_at is not a time")
        (Time_codec.parse_rfc3339 raw)
    | Ok _ -> Error "started_at is not a time"
    | Error detail -> Error detail
  in
  Ok { group; leader; profile; port; started_at }

type read = Absent | Recorded of entry | Unreadable of string

let read ~base_path =
  match Fs_compat.load_file_opt (record_path ~base_path) with
  | exception Sys_error detail -> Unreadable detail
  | None -> Absent
  | Some contents ->
    (match Yojson.Safe.from_string contents with
     | exception Yojson.Json_error _ -> Unreadable (record_name ^ " is not JSON")
     | json ->
       (match entry_of_json json with
        | Ok entry -> Recorded entry
        | Error detail -> Unreadable (record_name ^ ": " ^ detail)))

type write_failure = Not_written of string | Not_synced of string

let write_failure_message = function
  | Not_written detail -> "not written: " ^ detail
  | Not_synced detail -> "written, and its directory entry was not flushed: " ^ detail

let write ~base_path entry =
  match Fs_compat.mkdir_p (directory base_path) with
  | exception Sys_error detail -> Error (Not_written detail)
  | exception Unix.Unix_error (error, call, _) ->
    Error (Not_written (Printf.sprintf "%s: %s" call (Unix.error_message error)))
  | () ->
    let text = Yojson.Safe.pretty_to_string (entry_to_json entry) in
    (match
       Fs_compat.write_file_atomic_strict_staged (record_path ~base_path) ~write:(fun channel ->
         Unix.fchmod (Unix.descr_of_out_channel channel) file_permissions;
         output_string channel text;
         output_char channel '\n')
     with
     | Ok () -> Ok ()
     | Error ({ stage = Fs_compat.Before_rename; _ } as failure) ->
       Error (Not_written (Fs_compat.atomic_replace_failure_to_string failure))
     | Error ({ stage = Fs_compat.After_rename; _ } as failure) ->
       Error (Not_synced (Fs_compat.atomic_replace_failure_to_string failure)))

let remove ~base_path =
  match Unix.unlink (record_path ~base_path) with
  | () -> Ok ()
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok ()
  | exception Unix.Unix_error (error, _, _) ->
    Error (Printf.sprintf "%s: %s" record_name (Unix.error_message error))
