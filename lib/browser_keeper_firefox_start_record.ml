module Starter = Browser_keeper_firefox_starter

let ( let* ) = Result.bind

type outcome = Attached of Starter.started | Not_attached of Starter.not_attached

type entry = { at : float; outcome : outcome }

let record_name = "keeper-firefox-start.json"
let file_permissions = 0o600

(* The version of this layout. A reader built for another one says so
   instead of guessing at fields it does not know. *)
let schema = 1

let message_limit_bytes = 1024

let directory base_path =
  List.fold_left Filename.concat base_path [ Common.masc_dirname; Common.browser_lane_dirname ]

let record_path ~base_path = Filename.concat (directory base_path) record_name

(* Written to the nearest millisecond, as the other lane records write
   their times (Browser_bidi_host_record). *)
let half_millisecond = 0.0005
let time at = `String (Time_codec.rfc3339_of_unix_ms (at +. half_millisecond))

let started_to_wire = function
  | Starter.Firefox_and_host -> "firefox_and_host"
  | Starter.Host_only -> "host_only"
  | Starter.Nothing -> "nothing"

let started_of_wire = function
  | "firefox_and_host" -> Some Starter.Firefox_and_host
  | "host_only" -> Some Starter.Host_only
  | "nothing" -> Some Starter.Nothing
  | _ -> None

let outcome_to_json = function
  | Attached started -> `Assoc [ "kind", `String "attached"; "started", `String (started_to_wire started) ]
  | Not_attached not_attached ->
    let kind, message =
      match not_attached with
      | Starter.Operator_needed message -> "operator_needed", message
      | Starter.Start_failed message -> "start_failed", message
      | Starter.Not_listed_in_time message -> "not_listed_in_time", message
    in
    `Assoc [ "kind", `String kind; "message", `String message ]

let entry_to_json { at; outcome } =
  `Assoc [ "schema", `Int schema; "at", time at; "outcome", outcome_to_json outcome ]

(* Exactly these fields, once each. *)
let fields_of ~names = function
  | `Assoc fields ->
    if List.equal String.equal (List.sort String.compare names) (List.sort String.compare (List.map fst fields))
    then Ok fields
    else Error ("expected exactly the fields " ^ String.concat ", " names)
  | _ -> Error "expected a JSON object"

let field fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing " ^ name)

let string_of name = function
  | `String value -> Ok value
  | _ -> Error (name ^ " is not a string")

let message_of json =
  let* raw = string_of "outcome.message" json in
  if Printable_line.written ~limit:message_limit_bytes raw then Ok raw
  else Error "outcome.message is not what a server writes"

let outcome_of_json json =
  let* kind =
    match json with
    | `Assoc fields -> Result.bind (field fields "kind") (string_of "outcome.kind")
    | _ -> Error "outcome is not a JSON object"
  in
  let not_attached make =
    let* fields = fields_of ~names:[ "kind"; "message" ] json in
    let* message = Result.bind (field fields "message") message_of in
    Ok (Not_attached (make message))
  in
  match kind with
  | "attached" ->
    let* fields = fields_of ~names:[ "kind"; "started" ] json in
    let* wire = Result.bind (field fields "started") (string_of "outcome.started") in
    Option.to_result ~none:"outcome.started is not one this reader knows"
      (Option.map (fun started -> Attached started) (started_of_wire wire))
  | "operator_needed" -> not_attached (fun message -> Starter.Operator_needed message)
  | "start_failed" -> not_attached (fun message -> Starter.Start_failed message)
  | "not_listed_in_time" -> not_attached (fun message -> Starter.Not_listed_in_time message)
  | _ -> Error "outcome.kind is not one this reader knows"

let entry_of_json json =
  let* fields = fields_of ~names:[ "schema"; "at"; "outcome" ] json in
  let* () =
    match List.assoc_opt "schema" fields with
    | Some (`Int version) when version = schema -> Ok ()
    | Some (`Int version) -> Error (Printf.sprintf "written as layout %d; this reader knows %d" version schema)
    | Some _ | None -> Error "schema is not an integer"
  in
  let* at =
    match field fields "at" with
    | Ok (`String raw) ->
      Result.map_error (fun Time_codec.Invalid_rfc3339 -> "at is not a time") (Time_codec.parse_rfc3339 raw)
    | Ok _ -> Error "at is not a time"
    | Error detail -> Error detail
  in
  let* outcome = Result.bind (field fields "outcome") outcome_of_json in
  Ok { at; outcome }

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

let printable_outcome = function
  | Attached started -> Attached started
  | Not_attached not_attached ->
    let line = Printable_line.write ~limit:message_limit_bytes in
    Not_attached
      (match not_attached with
       | Starter.Operator_needed message -> Starter.Operator_needed (line message)
       | Starter.Start_failed message -> Starter.Start_failed (line message)
       | Starter.Not_listed_in_time message -> Starter.Not_listed_in_time (line message))

let write ~base_path { at; outcome } =
  match Fs_compat.mkdir_p (directory base_path) with
  | exception Sys_error detail -> Error detail
  | exception Unix.Unix_error (error, call, _) -> Error (Printf.sprintf "%s: %s" call (Unix.error_message error))
  | () ->
    let text = Yojson.Safe.pretty_to_string (entry_to_json { at; outcome = printable_outcome outcome }) in
    (match
       Fs_compat.write_file_atomic_strict_staged (record_path ~base_path) ~write:(fun channel ->
         Unix.fchmod (Unix.descr_of_out_channel channel) file_permissions;
         output_string channel text;
         output_char channel '\n')
     with
     | Ok () -> Ok ()
     | Error ({ stage = Fs_compat.Before_rename; _ } as failure) ->
       Error ("not written: " ^ Fs_compat.atomic_replace_failure_to_string failure)
     | Error ({ stage = Fs_compat.After_rename; _ } as failure) ->
       Error ("written, and its directory entry was not flushed: " ^ Fs_compat.atomic_replace_failure_to_string failure))
