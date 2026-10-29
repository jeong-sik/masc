(* HIGH-RISK-UNREVIEWED: this module sets up an installation. It writes the
   record that says where the external store is, creates the store, and appends
   the first record of the authorization log. A bootstrap that runs on an
   installation that was already set up replaces its history. *)

(* See authz_bootstrap.mli. *)

module Log = Authz_log
module Store = Authz_external_store
module Mark = Authz_high_water
module Install_record = Authz_install_record
module Record = Authz_record

let ( let* ) = Result.bind

type request =
  { base_path : string
  ; config_dir : string option
  ; external_store : string
  ; workspace_id : Authz_types.Workspace_id.t
  ; at_ms : int
  }

type completed =
  { record_hash : Record.Hash.t
  ; closed_intent : Store.intent option
  }

type path_problem =
  | Not_absolute
  | Holds_nul
  | Not_normal
  | Inside_base_path
  | Is_install_record

type error =
  | External_store_path_invalid of
      { path : string
      ; problem : path_problem
      }
  | No_config_dir
  | Install_record_not_located of Install_record.locate_error
  | Install_record_unreadable of Install_record.read_error
  | Install_record_changed of
      { expected : string option
      ; found : string option
      }
  | Path_not_inspected of
      { path : string
      ; detail : string
      }
  | External_store_in_the_way of { path : string }
  | Log_not_opened of unit Log.open_error
  | Log_not_empty of { lines : int }
  | External_store_not_opened of
      { path : string
      ; error : unit Store.open_error
      }
  | Not_a_fresh_installation of
      { store : string
      ; value : Mark.t
      }
  | Install_record_not_written of Install_record.write_error
  | External_store_not_created of
      { path : string
      ; detail : string
      }
  | Store_stopped of Store.stop
  | Log_stopped of Log.stop
  | Dead_intent_not_closed of Store.append_error
  | Intent_not_written of Store.append_error
  | Record_not_appended of Log.append_error
  | Answer_not_written of
      { record_hash : Record.Hash.t
      ; error : Store.append_error
      }
  | Mode_event_not_built of Authz_body.error
  | Record_not_built of Record.make_error

let value_to_string = function
  | Mark.Absent -> "absent"
  | Mark.Matches -> "matches"
  | Mark.Mismatch (first, rest) ->
    String.concat "; " (List.map Mark.reason_to_string (first :: rest))
;;

let path_problem_to_string = function
  | Not_absolute -> "it is not absolute"
  | Holds_nul -> "it holds a NUL byte"
  | Not_normal -> "it has an empty, . or .. segment, or ends with a separator"
  | Inside_base_path ->
    "it is inside the base path, which a backup of the base path takes back, or inside the \
     directory of the log, where the log and its lock file are"
  | Is_install_record -> "it is the file of the install record"
;;

let error_to_string = function
  | External_store_path_invalid { path; problem } ->
    Printf.sprintf
      "the path of the external store cannot be used (%s): %S"
      (path_problem_to_string problem)
      path
  | No_config_dir ->
    "no config directory is known (neither XDG_CONFIG_HOME nor HOME), so no install record \
     can be written"
  | Install_record_not_located error -> Install_record.locate_error_to_string error
  | Install_record_unreadable error -> Install_record.read_error_to_string error
  | Install_record_changed { expected; found } ->
    let show = function
      | Some store -> store
      | None -> "no store"
    in
    Printf.sprintf
      "the install record named %s when the checks ran and names %s now"
      (show expected)
      (show found)
  | Path_not_inspected { path; detail } ->
    Printf.sprintf "cannot tell whether %s exists: %s" path detail
  | External_store_in_the_way { path } ->
    Printf.sprintf
      "%s cannot be taken for the external store (it is not a regular file, or the install \
       record does not name it), so it was not opened"
      path
  | Log_not_opened error -> Log.open_error_to_string (fun () -> "") error
  | Log_not_empty { lines } ->
    Printf.sprintf "the authorization log has %d record(s), so this is not a new installation" lines
  | External_store_not_opened { path; error } ->
    Printf.sprintf "the external store %s did not open: %s" path (Store.open_error_to_string (fun () -> "") error)
  | Not_a_fresh_installation { store; value } ->
    Printf.sprintf
      "the external store %s is not that of a new installation: %s"
      store
      (value_to_string value)
  | Install_record_not_written error -> Install_record.write_error_to_string error
  | External_store_not_created { path; detail } ->
    Printf.sprintf "the external store %s was not created: %s" path detail
  | Store_stopped { Store.path; reason } ->
    Printf.sprintf "the external store %s is stopped: %s" path reason
  | Log_stopped { Log.path; reason } ->
    Printf.sprintf "the authorization log %s is stopped: %s" path reason
  | Dead_intent_not_closed error ->
    Printf.sprintf "the intent of an earlier bootstrap was not given up: %s" (Store.append_error_to_string error)
  | Intent_not_written error ->
    Printf.sprintf "the intent of the bootstrap was not written: %s" (Store.append_error_to_string error)
  | Record_not_appended error ->
    Printf.sprintf
      "the record of the bootstrap was not appended: %s"
      (Log.append_error_to_string error)
  | Answer_not_written { record_hash; error } ->
    Printf.sprintf
      "the record %s is in the log and its answer was not written: %s"
      (Record.Hash.to_hex record_hash)
      (Store.append_error_to_string error)
  | Mode_event_not_built error ->
    Printf.sprintf "the body of the mode event was refused: %s" (Authz_body.error_to_string error)
  | Record_not_built (Record.Author_not_admitted { kind; author = _ }) ->
    Printf.sprintf "the local operator may not write a %s record" (Record.Kind.to_string kind)
;;

(* ---- what is already there ---- *)

type presence =
  | Nothing
  | Regular_file
  | Something_else  (** A directory, a link (one that leads nowhere included), or a special file. *)

let inspect path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_REG; _ } -> Ok Regular_file
  | { Unix.st_kind = Unix.S_DIR | Unix.S_CHR | Unix.S_BLK | Unix.S_LNK | Unix.S_FIFO | Unix.S_SOCK; _ }
    -> Ok Something_else
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok Nothing
  | exception Unix.Unix_error (error, _, _) ->
    Error (Path_not_inspected { path; detail = Unix.error_message error })
;;

(* An absolute path without an empty segment, a [.] or a [..], and without a
   separator at the end. The install record keeps the spelling that is given
   and a boot opens the store by it, so the spelling must leave no doubt about
   the file. *)
let normal_form path =
  match String.split_on_char '/' path with
  | "" :: (_ :: _ as segments) ->
    List.for_all
      (fun segment -> (not (String.equal segment "")) && segment <> "." && segment <> "..")
      segments
  | "" :: [] | _ :: _ | [] -> false
;;

let valid_store_path path =
  let invalid problem = Error (External_store_path_invalid { path; problem }) in
  if Filename.is_relative path
  then invalid Not_absolute
  else if String.contains path '\000'
  then invalid Holds_nul
  else if not (normal_form path)
  then invalid Not_normal
  else Ok ()
;;

let locate request =
  match
    Install_record.locate ~config_dir:request.config_dir ~base_path:request.base_path
  with
  | Error error -> Error (Install_record_not_located error)
  | Ok Install_record.No_config_dir -> Error No_config_dir
  | Ok (Install_record.Located record as located) ->
    Ok (located, Install_record.file_path record)
;;

(* Whether [path], or a directory above it, is the directory [dir]. They are
   compared by the files they are, the device and the inode, so that a link, a
   mount that shows one directory twice (a firmlink, a bind mount), or the case
   of a name on a volume that ignores case does not hide it. A name that does
   not exist has no file to compare, and the directories above it are compared
   instead. *)
let reaches_directory ~dir path =
  match Unix.stat dir with
  | exception Unix.Unix_error _ -> false
  | target ->
    let rec up candidate =
      let is_target =
        match Unix.stat candidate with
        | stats -> stats.Unix.st_dev = target.Unix.st_dev && stats.Unix.st_ino = target.Unix.st_ino
        | exception Unix.Unix_error _ -> false
      in
      is_target
      ||
      let parent = Filename.dirname candidate in
      (not (String.equal parent candidate)) && up parent
    in
    up path
;;

(* Whether the two paths are one file that exists. *)
let same_file left right =
  match Unix.stat left, Unix.stat right with
  | left_stats, right_stats ->
    left_stats.Unix.st_dev = right_stats.Unix.st_dev
    && left_stats.Unix.st_ino = right_stats.Unix.st_ino
  | exception Unix.Unix_error _ -> false
;;

(* The store is neither the install record nor anything inside the base path or
   inside the directory of the log (which a link can put outside the base path).
   The log, its lock file, and the rest of what this module writes are there. A
   store inside the base path is in every backup of it, which is what the
   install record and the store are there to survive. The install record may not
   exist yet, and then its path is compared as spelled, after the links in the
   part that exists are resolved: a spelling that differs in the case of a name
   that does not exist yet gets past. *)
let outside_installation request ~record_file =
  let path = request.external_store in
  let invalid problem = Error (External_store_path_invalid { path; problem }) in
  let log_directory = Filename.dirname (Log.path_of_base_path ~base_path:request.base_path) in
  if same_file path record_file
     || String.equal (Fs_compat.realpath_lenient path) (Fs_compat.realpath_lenient record_file)
  then invalid Is_install_record
  else if
    reaches_directory ~dir:request.base_path path
    || reaches_directory ~dir:log_directory path
  then invalid Inside_base_path
  else Ok ()
;;

let read_record located =
  Result.map_error (fun error -> Install_record_unreadable error) (Install_record.read located)
;;

(* Whether the path of the new store holds the store that the install record
   names. It must hold nothing else. *)
let store_present ~recorded path =
  let* presence = inspect path in
  match presence, recorded with
  | Nothing, (Some _ | None) -> Ok false
  | Regular_file, Some recorded when String.equal recorded path -> Ok true
  | (Regular_file | Something_else), (Some _ | None) ->
    Error (External_store_in_the_way { path })
;;

(* The log is opened, which cuts a last line that never ended, and must hold no
   record. *)
let open_empty_log base_path =
  let path = Log.path_of_base_path ~base_path in
  match
    Log.open_at_start ~path ~init:() ~step:(fun () _record -> (Ok () : (unit, unit) result))
  with
  | Error error -> Error (Log_not_opened error)
  | Ok (log, (), recovered) ->
    (match recovered.Log.contents with
     | Log.Missing | Log.Empty -> Ok log
     | Log.Lines lines -> Error (Log_not_empty { lines }))
;;

let open_store path =
  match
    Store.open_at_start ~path ~init:() ~step:(fun () _entry -> (Ok () : (unit, unit) result))
  with
  | Error error -> Error (External_store_not_opened { path; error })
  | Ok (store, (), _recovered) -> Ok store
;;

let state_of store =
  match Store.with_writer store (fun _writer state -> state) with
  | Ok state -> Ok state
  | Error stop -> Error (Store_stopped stop)
;;

(* The store that the install record names, read over the empty log: it must say
   that nothing was answered. *)
let open_absent_store path =
  let* store = open_store path in
  let* state = state_of store in
  match Mark.judge (Mark.Probe.create state) with
  | Mark.Absent -> Ok (store, state)
  | (Mark.Matches | Mark.Mismatch _) as value -> Error (Not_a_fresh_installation { store = path; value })
;;

(* The store that the install record names, when there is something at its
   path. A path that holds nothing is a store that reads as absent. *)
let named_store recorded =
  match recorded with
  | None -> Ok None
  | Some named_path ->
    let* presence = inspect named_path in
    (match presence with
     | Nothing -> Ok None
     | Something_else -> Error (External_store_in_the_way { path = named_path })
     | Regular_file ->
       let* opened = open_absent_store named_path in
       Ok (Some (named_path, opened)))
;;

(* The intent that an earlier bootstrap left pending is given up: the log is
   empty, so that bootstrap never appended its record. *)
let intent_to_give_up ~path state =
  let probe = Mark.Probe.create state in
  match Mark.settle probe with
  | Ok Mark.Nothing_to_settle -> Ok None
  | Ok (Mark.Abort intent) -> Ok (Some intent)
  | Ok (Mark.Promote _) | Error _ ->
    (* [judge] read this state as [Absent], and that excludes both. *)
    Error (Not_a_fresh_installation { store = path; value = Mark.judge probe })
;;

(* ---- what is written ---- *)

(* The record is the one that [prepare] read. Another bootstrap that ran in
   between has written it, and replacing it would point the installation at a
   store that has no answer. *)
let record_unchanged located ~recorded =
  let* found = read_record located in
  if Option.equal String.equal found recorded
  then Ok ()
  else Error (Install_record_changed { expected = recorded; found })
;;

(* The record is written even when it names the path already: a write that
   returned [Replaced_but_not_durable] on an earlier call left a record that is
   not known to survive a crash, and the call after it must write it again. *)
let write_install_record located path =
  Result.map_error
    (fun error -> Install_record_not_written error)
    (Install_record.write located ~external_store:path)
;;

let store_permissions = 0o600

(* The file is created empty, so that the first append finds it. [O_EXCL] makes
   the call fail when the path holds anything, a link included. The call that
   makes the file is not [Fs_compat.create_file_exclusive]: that one keeps a
   registry of publications in the directory of the file, and a process that
   dies while the registry is being made leaves a registry that blocks every
   later creation by the same owner. A process that dies here leaves no file or
   an empty one, and both are met by calling again. *)
let create_store path =
  let not_created detail = External_store_not_created { path; detail } in
  let* () =
    match Fs_compat.mkdir_p (Filename.dirname path) with
    | () -> Ok ()
    | exception Unix.Unix_error (error, _, _) -> Error (not_created (Unix.error_message error))
    | exception Sys_error detail -> Error (not_created detail)
    | exception (Eio.Io _ as exn) -> Error (not_created (Printexc.to_string exn))
  in
  let* () =
    match
      Unix.openfile
        path
        [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL; Unix.O_CLOEXEC ]
        store_permissions
    with
    | exception Unix.Unix_error (error, _, _) -> Error (not_created (Unix.error_message error))
    | descriptor ->
      (match Unix.close descriptor with
       | () -> Ok ()
       | exception Unix.Unix_error (error, _, _) -> Error (not_created (Unix.error_message error)))
  in
  Result.map_error not_created (Fs_compat.sync_file_and_parent_strict path)
;;

(* The zone of the store, and inside it the zone of the log: the intent, the
   record, and the answer, in this order. *)
let write_bootstrap ~store ~log ~closed request =
  (* The intent and the record say the same thing because both come from this
     one value. *)
  let mode_event =
    { Authz_mode_event.event = Authz_mode_event.Fresh_bootstrap
    ; workspace_id = request.workspace_id
    }
  in
  let in_log_zone store_writer log_writer head =
    let* body =
      Result.map_error
        (fun error -> Mode_event_not_built error)
        (Authz_mode_event.to_body mode_event)
    in
    let* record =
      Result.map_error
        (fun error -> Record_not_built error)
        (Record.make
           ~head
           ~at_ms:request.at_ms
           ~author:Authz_records.Author.Local_operator
           ~kind:Record.Kind.Mode_event
           ~body)
    in
    let intent =
      { Store.previous_record_hash = Record.head_hash head
      ; intended_next_record_digest = record.Record.hash
      ; change =
          Store.Change.Mode
            { event = mode_event.Authz_mode_event.event
            ; workspace_id = mode_event.Authz_mode_event.workspace_id
            }
      }
    in
    let* (_ : Store.State.t) =
      Result.map_error
        (fun error -> Intent_not_written error)
        (Store.append store_writer [ Store.Intent_pending intent ])
    in
    let* head_after =
      Result.map_error (fun error -> Record_not_appended error) (Log.append log_writer [ record ])
    in
    (* The answer is made from the head that the append returned, so it cannot
       be written before the record is in the log. *)
    let appended_hash = Record.head_hash head_after in
    let* (_ : Store.State.t) =
      Result.map_error
        (fun error -> Answer_not_written { record_hash = appended_hash; error })
        (Store.append store_writer [ Store.Committed { record_hash = appended_hash } ])
    in
    Ok appended_hash
  in
  let in_store_zone store_writer (_ : Store.State.t) =
    let* () =
      match closed with
      | None -> Ok ()
      | Some intent ->
        let* (_ : Store.State.t) =
          Result.map_error
            (fun error -> Dead_intent_not_closed error)
            (Store.append store_writer [ Store.Aborted_intent intent ])
        in
        Ok ()
    in
    match Log.with_writer log (in_log_zone store_writer) with
    | Ok result -> result
    | Error stop -> Error (Log_stopped stop)
  in
  match Store.with_writer store in_store_zone with
  | Ok result -> result
  | Error stop -> Error (Store_stopped stop)
;;

(* ---- the two steps ---- *)

type prepared =
  { request : request
  ; located : Install_record.located
  ; recorded : string option  (** The store that the install record names. *)
  ; store_present : bool  (** The path of the new store holds the recorded store. *)
  ; log : Log.t
  ; named : (string * (Store.t * Store.State.t)) option
        (** The recorded store, opened, when there is a file at its path. *)
  }

let prepare request =
  let path = request.external_store in
  let* () = valid_store_path path in
  let* located, record_file = locate request in
  let* () = outside_installation request ~record_file in
  let* recorded = read_record located in
  let* store_present = store_present ~recorded path in
  let* log = open_empty_log request.base_path in
  let* named = named_store recorded in
  Ok { request; located; recorded; store_present; log; named }
;;

let write { request; located; recorded; store_present; log; named } =
  let path = request.external_store in
  let* () = record_unchanged located ~recorded in
  let* () = write_install_record located path in
  let* () = if store_present then Ok () else create_store path in
  let* store, state =
    match named with
    | Some (named_path, opened) when String.equal named_path path -> Ok opened
    | Some _ | None ->
      let* store = open_store path in
      let* state = state_of store in
      Ok (store, state)
  in
  let* closed = intent_to_give_up ~path state in
  let* record_hash = write_bootstrap ~store ~log ~closed request in
  Ok { record_hash; closed_intent = closed }
;;

let fresh_bootstrap request =
  let* prepared = prepare request in
  write prepared
;;
