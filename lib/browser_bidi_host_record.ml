let ( let* ) = Result.bind

type session = No_session_left | Session_left | Session_unknown | Session_refused

type ending = { at : float; reason : string; session : session }

type outcome = Succeeded | Not_started | Unknown

type cause = Refused | Not_sent | Unconfirmed

type unacknowledged =
  { request_id : Uuidm.t option
  ; verb : Browser_bidi_peer.verb option
  ; outcome : outcome
  ; cause : cause
  ; at : float
  }

(* Exactly the text the server issues: [Uuidm.of_string] alone would also
   take a UUID with more text behind it. *)
let request_id_of_wire wire =
  match Uuidm.of_string wire with
  | Some id when String.equal (Uuidm.to_string id) wire -> Some id
  | Some _ | None -> None

let request_id_to_wire id = Uuidm.to_string id

type entry =
  { pid : int
  ; started_at : float
  ; bidi_url : string
  ; client_id : Browser_lane.client_id
  ; attached_at : float option
  ; unacknowledged : unacknowledged list
  ; ended : ending option
  }

type state =
  | Never_started
  | Running of entry
  | Ended of entry * ending
  | Died of entry
  | Unreadable of { detail : string; held : bool option }

let record_name = "bidi-host.json"
let lock_name = "bidi-host.lock"
let file_permissions = 0o600

(* The version of this layout. A reader built for another one says so
   instead of guessing at fields it does not know. *)
let schema = 1

let directory base_path =
  Browser_chromium_process.lane_dir ~masc_root:(Filename.concat base_path Common.masc_dirname)

let path base_path name = Filename.concat (directory base_path) name
let record_path ~base_path = path base_path record_name
let unacknowledged_archive_path ~base_path = path base_path "bidi-host-unacknowledged.jsonl"

(* The codec cuts a time to the millisecond below it, and a time read back
   from its text sits a hair under that millisecond as often as not. Half a
   millisecond is added first, so a time is written to the nearest one and a
   time that was read is written back as the text it was read from. *)
let half_millisecond = 0.0005
let time at = `String (Time_codec.rfc3339_of_unix_ms (at +. half_millisecond))

let time_of name = function
  | `String raw ->
    (match Time_codec.parse_rfc3339 raw with
     | Ok at -> Ok at
     | Error Time_codec.Invalid_rfc3339 -> Error (name ^ " is not a time"))
  | _ -> Error (name ^ " is not a time")

let session_to_wire = function
  | No_session_left -> "none"
  | Session_left -> "left"
  | Session_unknown -> "unknown"
  | Session_refused -> "refused"

let session_of_wire = function
  | "none" -> Some No_session_left
  | "left" -> Some Session_left
  | "unknown" -> Some Session_unknown
  | "refused" -> Some Session_refused
  | _ -> None

let outcome_to_wire = function
  | Succeeded -> "succeeded"
  | Not_started -> "not_started"
  | Unknown -> "unknown"

let outcome_of_wire = function
  | "succeeded" -> Some Succeeded
  | "not_started" -> Some Not_started
  | "unknown" -> Some Unknown
  | _ -> None

let cause_to_wire = function
  | Refused -> "refused"
  | Not_sent -> "not_sent"
  | Unconfirmed -> "unconfirmed"

let cause_of_wire = function
  | "refused" -> Some Refused
  | "not_sent" -> Some Not_sent
  | "unconfirmed" -> Some Unconfirmed
  | _ -> None

(* The address as a reader may be shown it. [Browser_bidi_downloads.endpoint]
   has refused userinfo and a fragment; the query goes here. *)
let recorded_address bidi_url =
  let* uri, (_ : string * int * string) = Browser_bidi_downloads.endpoint_uri bidi_url in
  Ok (Uri.to_string (Uri.with_query uri []))

let ending_to_json { at; reason; session } =
  `Assoc
    [ "at", time at; "reason", `String reason; "session_in_firefox", `String (session_to_wire session) ]

let optional to_json = function
  | Some value -> to_json value
  | None -> `Null

let unacknowledged_to_json { request_id; verb; outcome; cause; at } =
  `Assoc
    [ "request_id", optional (fun id -> `String (request_id_to_wire id)) request_id
    ; "verb", optional (fun verb -> `String (Browser_bidi_peer.verb_to_wire verb)) verb
    ; "outcome", `String (outcome_to_wire outcome)
    ; "cause", `String (cause_to_wire cause)
    ; "at", time at
    ]

let entry_to_json entry =
  `Assoc
    [ "schema", `Int schema
    ; "pid", `Int entry.pid
    ; "started_at", time entry.started_at
    ; "bidi_url", `String entry.bidi_url
    ; "client_id", `String (Browser_lane.client_id_to_string entry.client_id)
    ; "attached_at", optional time entry.attached_at
    ; "unacknowledged", `List (List.map unacknowledged_to_json entry.unacknowledged)
    ; "ended", optional ending_to_json entry.ended
    ]

(* Exactly these fields, once each. A field this reader does not know could
   change what the others mean. *)
let fields_of ~names = function
  | `Assoc fields ->
    let known = List.sort String.compare names in
    let found = List.sort String.compare (List.map fst fields) in
    if List.equal String.equal known found then Ok fields
    else Error ("expected exactly the fields " ^ String.concat ", " names)
  | _ -> Error "expected a JSON object"

let field fields name =
  match List.assoc_opt name fields with
  | Some value -> Ok value
  | None -> Error ("missing " ^ name)

let string_of name = function
  | `String value -> Ok value
  | _ -> Error (name ^ " is not a string")

(* A value written from a closed set of names. *)
let named name of_wire json =
  let* wire = string_of name json in
  Option.to_result ~none:(name ^ " is not one this reader knows") (of_wire wire)

let nullable read = function
  | `Null -> Ok None
  | json -> Result.map Option.some (read json)

(* How much of a reason the record keeps. The longest the host writes itself
   is under 200 bytes; the rest of the room is for a peer's own words. *)
let reason_limit_bytes = 512
let cut_mark = "..."
let printable_byte byte = byte >= ' ' && byte <= '~'

(* A reason in the bytes and at the length the writer leaves one: printable
   ASCII, within the limit, or cut there and marked. The reader takes no
   other, so that what it passes on to a screen is one bounded line. *)
let written_reason raw =
  let length = String.length raw in
  let cut = length <= reason_limit_bytes + String.length cut_mark && String.ends_with ~suffix:cut_mark raw in
  if (length <= reason_limit_bytes || cut) && String.for_all printable_byte raw
  then Ok raw
  else Error "ended.reason is not what a host writes"

let ending_of_json json =
  let* fields = fields_of ~names:[ "at"; "reason"; "session_in_firefox" ] json in
  let* at = Result.bind (field fields "at") (time_of "ended.at") in
  let* reason =
    let* raw = Result.bind (field fields "reason") (string_of "ended.reason") in
    written_reason raw
  in
  let* session =
    Result.bind (field fields "session_in_firefox") (named "ended.session_in_firefox" session_of_wire)
  in
  Ok { at; reason; session }

let unacknowledged_of_json json =
  let* fields = fields_of ~names:[ "request_id"; "verb"; "outcome"; "cause"; "at" ] json in
  let* request_id =
    Result.bind (field fields "request_id") (nullable (named "request_id" request_id_of_wire))
  in
  let* verb =
    let* json = field fields "verb" in
    match json with
    | `Null -> Ok None
    (* Verbs are added without the layout changing. One this reader was built
       before is one it cannot name, as a host's unknown one is. *)
    | `String name -> Ok (Browser_bidi_peer.verb_of_wire name)
    | _ -> Error "verb is not a string"
  in
  let* outcome = Result.bind (field fields "outcome") (named "outcome" outcome_of_wire) in
  let* cause = Result.bind (field fields "cause") (named "cause" cause_of_wire) in
  let* at = Result.bind (field fields "at") (time_of "at") in
  Ok { request_id; verb; outcome; cause; at }

let entry_of_json json =
  (* The layout is asked first: another one may have other fields, and what
     the reader is told is which layout it met. *)
  let* () =
    match json with
    | `Assoc fields ->
      (match List.assoc_opt "schema" fields with
       | Some (`Int version) when version = schema -> Ok ()
       | Some (`Int version) ->
         Error (Printf.sprintf "written as layout %d; this reader knows %d" version schema)
       | Some _ | None -> Error "schema is not an integer")
    | _ -> Error "expected a JSON object"
  in
  let* fields =
    fields_of
      ~names:
        [ "schema"; "pid"; "started_at"; "bidi_url"; "client_id"; "attached_at"; "unacknowledged"
        ; "ended" ]
      json
  in
  let* pid =
    match List.assoc_opt "pid" fields with
    | Some (`Int pid) when pid > 0 -> Ok pid
    | Some _ | None -> Error "pid is not a process ID"
  in
  let* started_at = Result.bind (field fields "started_at") (time_of "started_at") in
  let* bidi_url =
    let* raw = Result.bind (field fields "bidi_url") (string_of "bidi_url") in
    match recorded_address raw with
    | Ok written when String.equal written raw -> Ok raw
    | Ok _ | Error _ -> Error "bidi_url is not what a host writes"
  in
  let* client_id =
    let* raw = Result.bind (field fields "client_id") (string_of "client_id") in
    Result.map_error (fun _ -> "client_id is not a lane client ID") (Browser_lane.client_id_of_string raw)
  in
  let* attached_at = Result.bind (field fields "attached_at") (nullable (time_of "attached_at")) in
  let* unacknowledged =
    match List.assoc_opt "unacknowledged" fields with
    | Some (`List listed) ->
      List.fold_right
        (fun json rest ->
          let* rest = rest in
          let* read = unacknowledged_of_json json in
          Ok (read :: rest))
        listed (Ok [])
    | Some _ | None -> Error "unacknowledged is not a list"
  in
  let* ended = Result.bind (field fields "ended") (nullable ending_of_json) in
  Ok { pid; started_at; bidi_url; client_id; attached_at; unacknowledged; ended }

let state_of ~lock_held = function
  | Error detail -> Unreadable { detail; held = Some lock_held }
  | Ok None -> Never_started
  | Ok (Some ({ ended = Some ending; _ } as entry)) -> Ended (entry, ending)
  | Ok (Some ({ ended = None; _ } as entry)) -> if lock_held then Running entry else Died entry

let read_entry base_path =
  match Fs_compat.load_file_opt (path base_path record_name) with
  | exception Sys_error detail -> Error detail
  | None -> Ok None
  | Some contents ->
    (match Yojson.Safe.from_string contents with
     | exception Yojson.Json_error _ -> Error (record_name ^ " is not JSON")
     | json -> Result.map Option.some (entry_of_json json))

(* [lockf] locks belong to the process, not to the descriptor. This process's
   own test of a lock it holds says "free", a second [take] here would be
   granted, and closing any descriptor of the file drops the lock. So the
   locks this process holds are listed here and it opens no lock file that is
   on the list. A lock is on a file, whatever path reached it, so the list is
   kept by the file's device and inode, which a path is asked for without
   opening anything. The mutex covers a look at the list together with the
   open, test and close that depend on it. *)
(* Device and inode. *)
type lock_identity = int * int

let held_here : (lock_identity, unit) Hashtbl.t = Hashtbl.create 1
let held_here_mu = Mutex.create ()

let unix_failure error call = Printf.sprintf "%s %s: %s" lock_name call (Unix.error_message error)
let identity_of (stats : Unix.stats) : lock_identity = stats.st_dev, stats.st_ino

(* The lock file's identity, or [None] before any host made it. *)
let lock_identity base_path =
  match Unix.stat (path base_path lock_name) with
  | stats -> Ok (Some (identity_of stats))
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
  | exception Unix.Unix_error (error, call, _) -> Error (unix_failure error call)

(* Closes a descriptor of a lock file this process holds no lock on. *)
let closed descriptor =
  match Unix.close descriptor with
  | () -> Ok ()
  | exception Unix.Unix_error (error, call, _) -> Error (unix_failure error call)

let lock_held base_path =
  Mutex.protect held_here_mu (fun () ->
    let* identity = lock_identity base_path in
    match identity with
    | None -> Ok false
    | Some identity when Hashtbl.mem held_here identity -> Ok true
    | Some _ ->
      (* Reading is enough to ask: a reader that may not write the lock file
         still learns whether a host holds it. *)
      (match Unix.openfile (path base_path lock_name) [ Unix.O_RDONLY; Unix.O_CLOEXEC ] 0 with
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
       | exception Unix.Unix_error (error, call, _) -> Error (unix_failure error call)
       | descriptor ->
         let held =
           match Unix.lockf descriptor Unix.F_TEST 0 with
           | () -> Ok false
           | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> Ok true
           | exception Unix.Unix_error (error, call, _) -> Error (unix_failure error call)
         in
         let* () = closed descriptor in
         held))

let observe ~base_path =
  match read_entry base_path with
  (* No record, and a record with its ending, say the same whatever the lock
     says, so a lock that cannot be asked takes nothing from them. *)
  | (Ok None | Ok (Some { ended = Some _; _ })) as entry -> state_of ~lock_held:false entry
  | (Ok (Some { ended = None; _ }) | Error _) as entry ->
    (match lock_held base_path with
     | Ok lock_held -> state_of ~lock_held entry
     | Error detail -> Unreadable { detail; held = None })

type held =
  { base_path : string
  ; identity : lock_identity
  ; lock : Unix.file_descr
  ; mutation : Cross_context_mutex.t
  ; mutable entry : entry
  ; mutable released : bool
  }

type refusal = Another_host of int option | Bad_address of string | Unavailable of string

let refusal_message = function
  | Another_host (Some pid) ->
    Printf.sprintf "another BiDi host (pid %d) is running for this workspace; stop it first" pid
  | Another_host None -> "another BiDi host is running for this workspace; stop it first"
  | Bad_address detail -> detail
  | Unavailable detail -> "the BiDi host record cannot be kept: " ^ detail

type write_failure = Not_written of string | Not_synced of string

let write_failure_message = function
  | Not_written detail -> "not written: " ^ detail
  | Not_synced detail -> "written, and its directory entry was not flushed: " ^ detail

type taken = { held : held; not_synced : string option }

let write held =
  if held.released then Error (Not_written "this host gave the workspace up")
  else (
    (* Rendered here: the replacement runs as a blocking job, and it writes
       the record as it was when this was called. *)
    let text = Yojson.Safe.pretty_to_string (entry_to_json held.entry) in
    match
      Fs_compat.write_file_atomic_strict_staged (path held.base_path record_name) ~write:(fun channel ->
        Unix.fchmod (Unix.descr_of_out_channel channel) file_permissions;
        output_string channel text;
        output_char channel '\n')
    with
    | Ok () -> Ok ()
    | Error ({ stage = Fs_compat.Before_rename; _ } as failure) ->
      Error (Not_written (Fs_compat.atomic_replace_failure_to_string failure))
    | Error ({ stage = Fs_compat.After_rename; _ } as failure) ->
      Error (Not_synced (Fs_compat.atomic_replace_failure_to_string failure)))

(* The record in memory moves first, so a write that failed is carried by the
   next one that succeeds. *)
let replace held entry =
  held.entry <- entry;
  write held

let release held =
  Cross_context_mutex.with_durable_lock held.mutation (fun () ->
  Mutex.protect held_here_mu (fun () ->
    if held.released then Ok ()
    else (
      held.released <- true;
      Hashtbl.remove held_here held.identity;
      match Unix.close held.lock with
      | () -> Ok ()
      | exception Unix.Unix_error (error, call, _) -> Error (unix_failure error call))))

type lock_attempt =
  | Locked of lock_identity * Unix.file_descr
  | Held_by_another
  | Lock_failed of string

let lock base_path =
  match Fs_compat.mkdir_p (directory base_path) with
  | exception Sys_error detail -> Lock_failed detail
  | exception Unix.Unix_error (error, call, _) -> Lock_failed (unix_failure error call)
  | () ->
    Mutex.protect held_here_mu (fun () ->
      match lock_identity base_path with
      | Error detail -> Lock_failed detail
      | Ok (Some identity) when Hashtbl.mem held_here identity -> Held_by_another
      | Ok (Some _ | None) ->
        (match
           Unix.openfile (path base_path lock_name)
             [ Unix.O_RDWR; Unix.O_CREAT; Unix.O_CLOEXEC ]
             file_permissions
         with
         | exception Unix.Unix_error (error, call, _) -> Lock_failed (unix_failure error call)
         | descriptor ->
           (* Closing here drops nothing this process holds: the file was not
              on the list, and a lock just taken is given up with it. *)
           let without_it outcome =
             match closed descriptor with
             | Ok () -> outcome
             | Error detail -> Lock_failed detail
           in
           (match Unix.lockf descriptor Unix.F_TLOCK 0 with
            | exception Unix.Unix_error ((Unix.EACCES | Unix.EAGAIN), _, _) -> without_it Held_by_another
            | exception Unix.Unix_error (error, call, _) -> without_it (Lock_failed (unix_failure error call))
            | () ->
              (match Unix.fstat descriptor with
               | exception Unix.Unix_error (error, call, _) ->
                 without_it (Lock_failed (unix_failure error call))
               | stats ->
                 let identity = identity_of stats in
                 Hashtbl.replace held_here identity ();
                 Locked (identity, descriptor)))))

let take ~base_path ~pid ~bidi_url ~client_id ~now =
  match recorded_address bidi_url with
  | Error detail -> Error (Bad_address detail)
  | Ok bidi_url ->
    (match lock base_path with
     | Lock_failed detail -> Error (Unavailable detail)
     | Held_by_another ->
       Error
         (Another_host
            (match read_entry base_path with
             | Ok (Some entry) -> Some entry.pid
             | Ok None | Error _ -> None))
     | Locked (identity, lock) ->
       let held =
         { base_path
         ; identity
         ; lock
         ; mutation = Cross_context_mutex.create ()
         ; released = false
         ; entry =
             { pid; started_at = now; bidi_url; client_id; attached_at = None; unacknowledged = []
             ; ended = None }
         }
       in
       (match write held with
        | Ok () -> Ok { held; not_synced = None }
        | Error (Not_synced detail) -> Ok { held; not_synced = Some detail }
        | Error (Not_written detail) ->
          (match release held with
           | Ok () -> Error (Unavailable detail)
           | Error unreleased -> Error (Unavailable (detail ^ "; " ^ unreleased)))
        | exception exn ->
          (* A cancelled write leaves through here. The workspace goes back
             before it does; what the close said is not what is raised. *)
          let backtrace = Printexc.get_raw_backtrace () in
          ignore (release held : (unit, string) result);
          Printexc.raise_with_backtrace exn backtrace))

let attached held ~now =
  Cross_context_mutex.with_durable_lock held.mutation (fun () ->
    replace held { held.entry with attached_at = Some now })
let client_changed held ~client_id =
  Cross_context_mutex.with_durable_lock held.mutation (fun () ->
    replace held { held.entry with client_id })

(* Bound snapshot rewrites without discarding unacknowledged evidence. *)
let unacknowledged_limit = 64

let note_unacknowledged held noted =
  Cross_context_mutex.with_durable_lock held.mutation (fun () ->
  if held.released then Error (Not_written "this host gave the workspace up")
  else
  let kept = held.entry.unacknowledged @ [ noted ] in
  let excess = List.length kept - unacknowledged_limit in
  if excess <= 0 then replace held { held.entry with unacknowledged = kept }
  else
  let archive_row result =
    `Assoc [ "schema", `Int 1; "pid", `Int held.entry.pid
           ; "started_at", time held.entry.started_at
           ; "client_id", `String (Browser_lane.client_id_to_string held.entry.client_id)
           ; "result", unacknowledged_to_json result ]
  in
  let suffix = List.take excess kept
    |> List.map (fun result -> Yojson.Safe.to_string (archive_row result) ^ "\n")
    |> String.concat "" in
  match Fs_compat.append_private_jsonl_durable_stable_result
      (unacknowledged_archive_path ~base_path:held.base_path) suffix with
  | Ok _ ->
      replace held { held.entry with unacknowledged = List.drop excess kept }
  | Error error ->
      let detail = "unacknowledged archive: "
        ^ Fs_compat.private_jsonl_transaction_error_to_string error in
      (* Preserve the new result as well as every unarchived predecessor.
         A later note retries archival; failure never authorizes eviction. *)
      (match replace held { held.entry with unacknowledged = kept } with
       | Ok () -> Error (Not_written detail)
       | Error failure -> Error (Not_written (detail ^ "; snapshot "
                                              ^ write_failure_message failure))))

(* A reason can quote bytes a peer sent. The record stays ASCII that a reader
   in any language loads: a byte outside printable ASCII, and the backslash
   that marks one, is written as [\xNN]. What would pass the limit is left
   out, whole bytes at a time, and marked. *)
let printable reason =
  let written = Buffer.create (String.length reason) in
  let rec add index =
    if index = String.length reason then Buffer.contents written
    else (
      let byte = reason.[index] in
      let piece =
        if printable_byte byte && byte <> '\\' then String.make 1 byte
        else Printf.sprintf "\\x%02X" (Char.code byte)
      in
      if Buffer.length written + String.length piece > reason_limit_bytes
      then Buffer.contents written ^ cut_mark
      else (
        Buffer.add_string written piece;
        add (index + 1)))
  in
  add 0

let ended held ~reason ~session ~now =
  Cross_context_mutex.with_durable_lock held.mutation (fun () ->
    replace held { held.entry with ended = Some { at = now; reason = printable reason; session } })
