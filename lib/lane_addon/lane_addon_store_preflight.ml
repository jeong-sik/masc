open Result.Syntax

module Store = struct
  type t =
    | Bindings
    | Native_claims
    | Actions
    | Exact_requests
    | Tool_request_owners
  [@@deriving enumerate]
end

type decoder =
  | Json
  | Retained_binding
  | Inventory_record
  | Native_lease
  | Cleanup_descriptor
  | Action_receipt
  | Exact_record
  | Exact_proof_link
  | Exact_slot_observation
  | Exact_directory_entry
  | Tool_request_inventory
  | Tool_request_owner
  | Tool_request_payload
  | Tool_request_exact_reads

let decoder_name = function
  | Json -> "Yojson.Safe.from_string"
  | Retained_binding -> "Lane_addon_runtime.check_retained_binding"
  | Inventory_record -> "Lane_addon_runtime.check_inventory_record"
  | Native_lease -> "Native_addon_lease.inspect"
  | Cleanup_descriptor -> "Browser_addon_socket.check_retained"
  | Action_receipt -> "Lane_addon_action.of_json"
  | Exact_record -> "Lane_addon_exact.check_retained_record"
  | Exact_proof_link -> "Lane_addon_exact.Retained_key.proof_path"
  | Exact_slot_observation -> "Lane_addon_exact_observation.request_id"
  | Exact_directory_entry -> "Lane_addon_store.exact_directory_entry"
  | Tool_request_inventory -> "Lane_addon_store.tool_request_owner_entry"
  | Tool_request_owner -> "Lane_addon_tool_request_owner.Published_reader.read"
  | Tool_request_payload -> "consumer original request payload"
  | Tool_request_exact_reads -> "consumer Exact reads of the original"

type tool_request_reader = scope:string -> request_id:string ->
  (Lane_addon_tool_request_owner.retained option, string) result
type request_body_reader = scope:string -> request_digest:string -> (Yojson.Safe.t, string) result
type tool_request_scope_reader = scope:string ->
  (Lane_addon_tool_request_owner.retained list, string) result
type tool_request_records_reader = scope:string ->
  (Lane_addon_tool_request_owner.Record.t list, string) result
type tool_request_archive_reader = scope:string -> date:string -> request_id:string ->
  (Lane_addon_tool_request_owner.Record.t option, string) result
type deleted_record = Deleted_open | Deleted_terminal of Lane_addon_exact.final | Deleted_unknown
type exact_proof = No_proof | Proof of Yojson.Safe.t | Unreadable_proof of string
type exact_files =
  { record : Yojson.Safe.t option
  ; deleted : deleted_record option
  ; proof : exact_proof
  ; store : Lane_addon_store.t
  }
type exact_reader = declaration_id:string -> Lane_addon_exact.identity -> (exact_files, string) result
type payload_verdict =
  | Payload_valid
  | Body_unreadable of string
  | Payload_invalid of string
  | Consumer_stops_on_exact of { detail : string; scopes : string list; paths : string list }
  | Exact_root_differs of string
type original = {
  record : Lane_addon_tool_request_owner.Record.t;
  restore : unit -> (Lane_addon_tool_request_owner.retained, string) result;
}

type payload_validator = read:tool_request_reader -> read_scope:tool_request_scope_reader ->
  read_records:tool_request_records_reader -> read_body:request_body_reader ->
  read_archive:tool_request_archive_reader ->
  read_exact:exact_reader -> original -> payload_verdict

type refusal =
  { path : string
  ; decoder : decoder
  ; detail : string
  ; delete : string list
  }

type report =
  { rows : int
  ; refusals : refusal list
  }

let name = function
  | Store.Bindings -> "lane-addon bindings"
  | Native_claims -> "lane-addon native claims"
  | Actions -> "lane-addon action receipts"
  | Exact_requests -> "lane-addon exact requests"
  | Tool_request_owners -> "lane-addon tool request owners"

let on_refusal = function
  | Store.Bindings ->
    "the Lane Add-on inventory lists the record as an issue, a declaration the \
     record names (every declaration, when its owner cannot be read) fails to \
     apply while the record is there, and every read of that instance fails; a \
     detached record that names its declaration is not refused here, because \
     declaration application passes it and keeps its fields as evidence"
  | Native_claims ->
    "the host cannot confirm the cleanup of the instance the slot holds, so that \
     installation stays failed and refuses every new start (#45106)"
  | Actions -> "reading that action receipt fails"
  | Exact_requests ->
    "the next run of that request fails before anything is sent, so the worker's \
     request is never answered; a proof link no record names fails the next run \
     of a request with its ID and digest the same way; the startup sweep stops at \
     a slot observation it cannot read, or at an entry of an Exact directory that \
     is not a regular <name>.json file, and removes nothing"
  | Tool_request_owners ->
    "discovering the original requests of that scope fails as a whole, and so \
     does reading that request; an original refused on its consumer's Exact \
     reads stops that consumer at every pass, or keeps an admission part waiting \
     for size evidence and every later candidate behind it"

let fresh_state_step refusal =
  Printf.sprintf "stop the server, delete %s, start the new build"
    (String.concat " and " refusal.delete)

(* A missing directory is an empty store. Once it exists, a listing failure
   means the preflight has not read records the server uses. *)
let entries dir =
  match Unix.lstat dir with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok []
  | exception Unix.Unix_error (code, call, _) ->
    Error (dir ^ ": " ^ call ^ ": " ^ Unix.error_message code)
  | stat when stat.Unix.st_kind <> Unix.S_DIR -> Error (dir ^ ": not a directory")
  | _ ->
    (match Sys.readdir dir with
     | exception Sys_error detail -> Error (dir ^ ": " ^ detail)
     | names -> Ok (Array.to_list names |> List.sort String.compare))

let is_directory path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> false
  | stat -> stat.Unix.st_kind = Unix.S_DIR

let exists path =
  match Unix.lstat path with
  | exception Unix.Unix_error _ -> false
  | _ -> true

let empty = { rows = 0; refusals = [] }

let counted report = { report with rows = report.rows + 1 }

let refused report refusal =
  { rows = report.rows + 1; refusals = refusal :: report.refusals }

(* The Exact scan refuses files in three directories, so the report sorts
   them; the other scans already meet them in path order. *)
let finish report =
  { report with
    refusals =
      List.stable_sort (fun (left : refusal) right -> String.compare left.path right.path)
        (List.rev report.refusals)
  }

let removed path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> true
  | exception Unix.Unix_error _ -> false
  | _ -> false

type 'a read =
  | Gone
  | Unreadable of refusal
  | Read of 'a

(* One store file: read and parse it as the store's readers do, then hand it
   to [decode]. A file removed between the listing and the read is gone, and
   so is one removed while it was checked: a running server settles an
   original by moving its record and then the body the check reads next. *)
let read_file ~after_read ~delete ~path decode =
  match Fs_compat.load_file_opt path with
  | exception Sys_error detail -> Unreadable { path; decoder = Json; detail; delete = delete path }
  | None -> Gone
  | Some bytes ->
    after_read path;
    (match Yojson.Safe.from_string bytes with
     | exception Yojson.Json_error detail ->
       Unreadable { path; decoder = Json; detail; delete = delete path }
     | json ->
       (match decode json with
        | Ok value -> Read value
        | Error (decoder, detail) ->
          if removed path then Gone else Unreadable { path; decoder; detail; delete = delete path }))

let read_record ~after_read ~delete report ~path decode =
  match read_file ~after_read ~delete ~path decode with
  | Gone -> report
  | Unreadable refusal -> refused report refusal
  | Read () -> counted report

let decoded decoder result = Result.map_error (fun detail -> decoder, detail) result

(* What the store's reader does with one name in a record directory. *)
type entry =
  | Record
  | Skipped
  | Refused of decoder * string

(* Bindings and action receipts: only [.json] names are records, and their
   readers read nothing else in the directory. *)
let json_entry name = if Filename.check_suffix name ".json" then Record else Skipped

(* Discovery reads a whole scope and fails it on an entry it does not know. *)
let tool_request_owner_entry name =
  match Lane_addon_store.tool_request_owner_entry name with
  | Lane_addon_store.Record_entry -> Record
  | Staged_entry -> Skipped
  | Unknown_entry -> Refused (Tool_request_inventory, "unknown entry in original request namespace")

(* What fresh state deletes for a refused record when nothing else reads it
   with that record. *)
let record_alone path = [ path ]

let fold_entries ~delete report ~dir ~entry ~record names =
  List.fold_left
    (fun state name ->
       let* report = state in
       let path = Filename.concat dir name in
       match entry name with
       | Skipped -> Ok report
       | Refused (decoder, detail) -> Ok (refused report { path; decoder; detail; delete = delete path })
       | Record -> record report ~name ~path)
    (Ok report)
    names

let read_entries ~after_read ~delete report ~dir ~entry decode names =
  fold_entries ~delete report ~dir ~entry names ~record:(fun report ~name ~path ->
    Ok (read_record ~after_read ~delete report ~path (decode ~name ~path)))

let scan_bindings ~after_read root =
  let dir = Filename.concat root Lane_addon_store.bindings_directory in
  let* names = entries dir in
  read_entries ~after_read ~delete:record_alone empty ~dir ~entry:json_entry
    (fun ~name:_ ~path json ->
       let* () = decoded Retained_binding (Lane_addon_runtime.check_retained_binding json) in
       decoded Inventory_record (Lane_addon_runtime.check_inventory_record ~path json))
    names

(* Records grouped one directory deep: [<store>/<digest>/<digest>.json]. *)
let scan_groups root directory scan_group =
  let dir = Filename.concat root directory in
  let* groups = entries dir in
  List.fold_left
    (fun result group ->
       let* report = result in
       let group_dir = Filename.concat dir group in
       if is_directory group_dir then scan_group report ~group ~group_dir else Ok report)
    (Ok empty)
    groups

let scan_grouped ~after_read ~delete root directory ~entry decode =
  scan_groups root directory (fun report ~group ~group_dir ->
    let* names = entries group_dir in
    read_entries ~after_read ~delete:(delete ~group ~group_dir) report ~dir:group_dir ~entry
      (decode ~group) names)

(* The runtime loads a receipt by its key and refuses one that names another
   request. *)
let check_action ~group ~name json =
  let* receipt = Lane_addon_action.of_json json in
  let key =
    Lane_addon_store.action_path
      ~instance_id:receipt.Lane_addon_action.instance_id
      ~request_id:receipt.request_id
  in
  if String.equal key (Filename.concat Lane_addon_store.actions_directory (Filename.concat group name))
  then Ok ()
  else Error "retained receipt belongs to a different request"

(* The binding and observations of the instance a native claim holds are
   deleted with the slot: a binding left behind keeps retrying the cleanup of a
   slot that is gone. *)
let instance_records root instance =
  [ Lane_addon_store.binding_path instance; Lane_addon_store.observation_dir instance ]
  |> List.map (Filename.concat root)
  |> List.filter exists

(* The host reads an installation slot and, through the cleanup descriptor of
   the instance it holds, that instance's Chrome and live BiDi child slots. A
   child slot of an earlier instance is never read again, so it is not read
   here either: refusing it would stop every later deploy over a file nothing
   uses. *)
let scan_native_claims root =
  let dir = Filename.concat root Lane_addon_runtime.native_claims_directory in
  let* names = entries dir in
  Ok
    (List.fold_left
       (fun report name ->
          let slot_dir = Filename.concat dir name in
          let delete instance =
            slot_dir :: Option.fold ~none:[] ~some:(instance_records root) instance
          in
          match Lane_addon_runtime.is_installation_slot name with
          | false -> report
          | true ->
            (match Native_addon_lease.inspect ~directory:slot_dir with
             | Error (lease : Native_addon_lease.inspection_error) ->
               refused
                 report
                 { path = slot_dir
                 ; decoder = Native_lease
                 ; detail = lease.refusal
                 ; delete = delete lease.refused_instance
                 }
             | Ok None -> counted report
             | Ok (Some recorded) ->
               (match
                  Browser_addon_socket.check_retained
                    ~instance_id:recorded.Native_addon_lease.instance
                    ~slot:slot_dir
                    recorded.context
                with
                | Ok () -> counted report
                | Error detail ->
                  refused
                    report
                    { path = Filename.concat slot_dir recorded.history
                    ; decoder = Cleanup_descriptor
                    ; detail
                    ; delete = delete (Some recorded.instance)
                    })))
       empty
       names)

module Exact = Lane_addon_exact
module Exact_observation = Lane_addon_exact_observation

(* A proof link and a slot observation name the store root they were written
   under. A file that names another root than this scan's comes from another
   store, or this scan's root is wrong; the check cannot tell which, so it
   deletes nothing and stops (RFC exact-request-skips-a-slot-that-refused-its-input
   3.3). *)
let same_store store ~path roots =
  let own = Lane_addon_store.root store in
  match List.find_opt (fun found -> not (String.equal found own)) roots with
  | None -> Ok ()
  | Some found ->
    Error (Printf.sprintf "%s names the store root %s, and this check reads %s" path found own)

let lstat_failed path code = Error (path ^ ": lstat: " ^ Unix.error_message code)

let entry_refusal = function
  | Lane_addon_store.Not_a_json_name ->
    "the startup sweep stops at an entry that is not a <name>.json file"
  | Not_a_regular_file -> "the startup sweep stops at a <name>.json entry that is not a regular file"

(* What one Exact directory holds as the startup sweep lists it
   ([Lane_addon_store.exact_directory] and [exact_directory_entry]): the
   names of its regular <name>.json files, and a refusal for each entry the
   sweep stops at, which fresh state deletes alone. A path that is not a
   directory is such an entry. *)
let exact_listing ~dir =
  let refusal path detail = { path; decoder = Exact_directory_entry; detail; delete = [ path ] } in
  match Lane_addon_store.exact_directory dir with
  | Error code -> lstat_failed dir code
  | Ok Lane_addon_store.Exact_directory_absent -> Ok ([], [])
  | Ok Exact_directory_refused ->
    Ok ([], [ refusal dir "the startup sweep stops at an Exact directory that is not a directory" ])
  | Ok Exact_directory_present ->
    let* names = entries dir in
    let+ files, refusals =
      List.fold_left
        (fun state name ->
           let* files, refusals = state in
           let path = Filename.concat dir name in
           match Lane_addon_store.exact_directory_entry ~directory:dir name with
           | Ok (Lane_addon_store.Exact_file _) -> Ok (name :: files, refusals)
           | Ok (Exact_staged | Exact_gone) -> Ok (files, refusals)
           | Ok (Exact_refused reason) -> Ok (files, refusal path (entry_refusal reason) :: refusals)
           | Error code -> lstat_failed path code)
        (Ok ([], []))
        names
    in
    List.rev files, List.rev refusals

(* What fresh state leaves at a path an Exact file is read by. [run] opens
   that path and follows a symbolic link, but the listing refuses an entry
   the startup sweep stops at and fresh state deletes it, so the check does
   not open it either. *)
type left_at_path =
  | File_left
  | Nothing_left
  | Entry_refused of string

let left_at path =
  match
    Lane_addon_store.exact_directory_entry ~directory:(Filename.dirname path) (Filename.basename path)
  with
  | Ok (Lane_addon_store.Exact_file _) -> Ok File_left
  | Ok (Exact_staged | Exact_gone) -> Ok Nothing_left
  | Ok (Exact_refused reason) -> Ok (Entry_refused (entry_refusal reason))
  | Error code -> lstat_failed path code

type keyed_record =
  { record_path : string
  ; first : Yojson.Safe.t
  ; key : Exact.Retained_key.t
  }

(* The first read of an Exact record. [run] reads the record of a request at
   the path its declaration and request ID name, and compares the ids the
   record holds. A record whose ids name another path is refused alone: the
   proof link and observations its ids name belong to the record at that
   path. *)
let read_first ~after_read ~group ~name path =
  read_file ~after_read ~delete:record_alone ~path (fun first ->
    let* ({ Exact.Retained_key.declaration_id; request_id; _ } as key) =
      decoded Exact_record (Exact.Retained_key.of_record first)
    in
    let stored =
      Filename.concat Lane_addon_store.exact_requests_directory (Filename.concat group name)
    in
    if String.equal stored (Lane_addon_store.exact_request_path ~declaration_id ~request_id)
    then Ok { record_path = path; first; key }
    else Error (Exact_record, "retained Exact record is stored under another request's key"))

(* The slot observations of one declaration, read once with the startup
   sweep's read: the request each file belongs to. The sweep stops at a file
   it cannot read, so the check refuses that file. *)
let read_slot_observations ~after_read store ~root report ~declaration_id =
  let dir = Filename.concat root (Exact_observation.directory ~declaration_id) in
  let* names, stray = exact_listing ~dir in
  let report = List.fold_left refused report stray in
  let* owned, report =
    List.fold_left
      (fun state name ->
         let* owned, report = state in
         let path = Filename.concat dir name in
         match read_file ~after_read ~delete:record_alone ~path Result.ok with
         | Gone -> Ok (owned, report)
         | Unreadable refusal -> Ok (owned, refused report refusal)
         | Read json ->
           let* () = same_store store ~path (Option.to_list (Exact_observation.store_root json)) in
           (match Exact_observation.request_id ~store ~declaration_id ~file_name:name json with
            | Ok request_id -> Ok ((request_id, path) :: owned, counted report)
            | Error _ when removed path -> Ok (owned, report)
            | Error detail ->
              Ok
                ( owned
                , refused
                    report
                    { path; decoder = Exact_slot_observation; detail; delete = record_alone path } )))
      (Ok ([], report))
      names
  in
  Ok (List.rev owned, report)

(* What the Exact scan does with one record stored under its own key. *)
type record_judgment =
  | Record_gone
  | Record_kept of Yojson.Safe.t
  | Record_deleted of refusal

(* One record with its proof link: the record, the link, then the record
   again. Fresh state deletes a refused record with its link and the slot
   observations of its request: [run] reads that link with the record, and the
   observations are read with that link. A link the startup sweep stops at is
   judged before it is opened, and fresh state deletes it; like a link [run]
   cannot read, it takes the record with it. *)
let judge_record ~after_read store ~root ~observations { record_path; first; key } =
  let link = Filename.concat root (Exact.Retained_key.proof_path key) in
  let { Exact.Retained_key.request_id; _ } = key in
  let delete _ =
    let observed =
      List.filter_map
        (fun (owner, file) -> if String.equal owner request_id then Some file else None)
        observations
    in
    record_path :: List.filter exists (link :: observed)
  in
  let read_second proof =
    match
      read_file ~after_read ~delete ~path:record_path (fun second ->
        let+ () = decoded Exact_record (Exact.check_retained_record ~store ~first ~proof ~second) in
        second)
    with
    | Gone -> Ok Record_gone
    | Unreadable refusal -> Ok (Record_deleted refusal)
    | Read second -> Ok (Record_kept second)
  in
  let* left = left_at link in
  match left with
  | Nothing_left -> read_second None
  | Entry_refused detail ->
    Ok (Record_deleted { path = link; decoder = Exact_directory_entry; detail; delete = delete link })
  | File_left ->
    (match read_file ~after_read ~delete ~path:link Result.ok with
     | Gone -> read_second None
     | Unreadable refusal -> Ok (Record_deleted refusal)
     | Read proof ->
       let* () = same_store store ~path:link (Exact.proof_store_roots proof) in
       read_second (Some proof))

let check_record ~after_read store ~root ~observations report record =
  let+ judgment = judge_record ~after_read store ~root ~observations record in
  match judgment with
  | Record_gone -> report
  | Record_kept _ -> counted report
  | Record_deleted refusal -> refused report refusal

(* What the record the Exact scan deletes at an original's path shows of that
   original: a record of another request, or one whose shape cannot be read,
   shows nothing. *)
let deleted_state ~key ~found first =
  if not (Exact.Retained_key.equal key found) then Deleted_unknown
  else
    match Exact.retained_final first with
    | Ok None -> Deleted_open
    | Ok (Some final) -> Deleted_terminal final
    | Error _ -> Deleted_unknown

(* The Exact files of one original as the Exact scan leaves them (RFC
   exact-request-skips-a-slot-that-refused-its-input 3.3, item 5). The record
   at the original's path is judged as the Exact scan judges it, so a record
   it deletes is absent here and so is the proof link deleted with it. A
   record the startup sweep stops at is deleted unread, so it shows nothing of
   the original; such a link is unreadable. The
   proof link the original's request names is read otherwise, even when no
   kept record names it: whether the Exact scan finds such a link depends on
   the other records of the declaration. A link that names another store root
   stops the check. *)
let read_exact ~after_read store ~root ~declaration_id identity =
  let key = Exact.Retained_key.of_identity ~declaration_id identity in
  let stored = Lane_addon_store.exact_request_path ~declaration_id ~request_id:key.Exact.Retained_key.request_id in
  let group = Filename.basename (Filename.dirname stored) and name = Filename.basename stored in
  let record_path = Filename.concat root stored in
  let* left = left_at record_path in
  let* record, deleted, gone =
    match left with
    | Nothing_left -> Ok (None, None, [])
    | Entry_refused _ -> Ok (None, Some Deleted_unknown, [ record_path ])
    | File_left ->
      (match read_first ~after_read ~group ~name record_path with
       | Gone -> Ok (None, None, [])
       | Unreadable refusal -> Ok (None, Some Deleted_unknown, refusal.delete)
       | Read ({ key = found; first; _ } as keyed) ->
         let+ judgment = judge_record ~after_read store ~root ~observations:[] keyed in
         (match judgment with
          | Record_gone -> None, None, []
          | Record_kept second -> Some second, None, []
          | Record_deleted refusal -> None, Some (deleted_state ~key ~found first), refusal.delete))
  in
  let path = Filename.concat root (Exact.Retained_key.proof_path key) in
  let+ proof =
    if List.mem path gone
    then Ok No_proof
    else
      let* left = left_at path in
      match left with
      | Nothing_left -> Ok No_proof
      | Entry_refused detail -> Ok (Unreadable_proof detail)
      | File_left ->
        (match read_file ~after_read ~delete:record_alone ~path Result.ok with
         | Gone -> Ok No_proof
         | Unreadable { detail; _ } -> Ok (Unreadable_proof detail)
         | Read json ->
           let+ () = same_store store ~path (Exact.proof_store_roots json) in
           Proof json)
  in
  { record; deleted; proof; store }

let link_name key = Filename.basename (Exact.Retained_key.proof_path key)

(* The proof links of one declaration that no record names. The server writes
   a record before its link, so the records are listed and read again after
   the links: a record written in between names its link too. A record read
   before is read again, since the startup sweep may have removed it and the
   same request id may have been written there since, with another digest and
   so another link. A record a fresh-state line deletes is not read again: the
   file at its path goes, so it keeps no link, and the line already names the
   link the check read with it. A link removed before it is refused is not
   refused. *)
let unnamed_proof_links ~after_read ~root report ~group ~group_dir ~declaration_id ~named_links =
  let dir = Filename.concat root (Exact.proof_directory ~declaration_id) in
  let* links, stray = exact_listing ~dir in
  let* again, stray_again = exact_listing ~dir:group_dir in
  let deleted = List.concat_map (fun { delete; _ } -> delete) report.refusals in
  let later =
    List.filter_map
      (fun name ->
         let path = Filename.concat group_dir name in
         if List.mem path deleted
         then None
         else
           match read_first ~after_read ~group ~name path with
           | Read { key; _ } -> Some (link_name key)
           | Gone | Unreadable _ -> None)
      again
  in
  let named = named_links @ later in
  (* An entry a line already deletes is not refused again: a link the sweep
     stops at goes with its record's line, and the records listed again hold
     the entries their first listing refused. *)
  let report =
    List.fold_left refused report
      (List.filter (fun (refusal : refusal) -> not (List.mem refusal.path deleted))
         (stray @ stray_again))
  in
  Ok
    (List.fold_left
       (fun report link ->
          let path = Filename.concat dir link in
          if List.mem link named || not (exists path)
          then report
          else
            refused
              report
              { path
              ; decoder = Exact_proof_link
              ; detail = "no retained record names this original execution link"
              ; delete = [ path ]
              })
       report
       links)

(* What the check keeps of one declaration between its records: the slot
   observations, read once the first record names the declaration, and the
   proof links the records read name. *)
type declaration_read =
  { declaration_id : string
  ; observations : (string * string) list
  ; named_links : string list
  }

(* Exact requests (RFC exact-request-skips-a-slot-that-refused-its-input 3.3).
   Per declaration the check reads a record, its proof link and the record
   again before it reads the next record, then the proof links no record
   names. The declaration comes from a record whose ids name its own path; the
   links of a declaration none of whose records can be read are not found. *)
let scan_exact_declaration ~after_read store ~root report ~group ~group_dir =
  let* listed, stray = exact_listing ~dir:group_dir in
  let report = List.fold_left refused report stray in
  let* report, declaration =
    List.fold_left
      (fun state name ->
         let* report, declaration = state in
         match read_first ~after_read ~group ~name (Filename.concat group_dir name) with
         | Gone -> Ok (report, declaration)
         | Unreadable refusal -> Ok (refused report refusal, declaration)
         | Read record ->
           let* report, ({ observations; named_links; _ } as declaration) =
             match declaration with
             | Some declaration -> Ok (report, declaration)
             | None ->
               let { Exact.Retained_key.declaration_id; _ } = record.key in
               let* observations, report =
                 read_slot_observations ~after_read store ~root report ~declaration_id
               in
               Ok (report, { declaration_id; observations; named_links = [] })
           in
           let* report = check_record ~after_read store ~root ~observations report record in
           Ok (report, Some { declaration with named_links = link_name record.key :: named_links }))
      (Ok (report, None))
      listed
  in
  match declaration with
  | None -> Ok report
  | Some { declaration_id; named_links; _ } ->
    unnamed_proof_links ~after_read ~root report ~group ~group_dir ~declaration_id ~named_links

(* Every entry below the Exact request store is a declaration's directory.
   The startup sweep stops at one that is not a directory, so
   [scan_exact_declaration] refuses it with its listing. *)
let scan_exact_requests ~after_read root =
  let store = Lane_addon_store.create ~root in
  let dir = Filename.concat root Lane_addon_store.exact_requests_directory in
  let* groups = entries dir in
  List.fold_left
    (fun result group ->
       let* report = result in
       scan_exact_declaration ~after_read store ~root report ~group ~group_dir:(Filename.concat dir group))
    (Ok empty)
    groups

(* The namespaces of one tool request scope, each under the scope's digest:
   owner records and request bodies. *)
let scope_namespaces =
  [ Lane_addon_store.tool_request_owners_directory
  ; Lane_addon_store.tool_request_bodies_directory
  ]

let scope_group_directories ~root ~group namespaces =
  List.map (fun namespace -> Filename.concat root (Filename.concat namespace group)) namespaces

(* The directories of one tool request scope below the store root, its
   settled originals included. *)
let scope_store_directories ~root scope =
  scope_group_directories ~root ~group:(Lane_addon_store.digest scope)
    (scope_namespaces @ [ Lane_addon_store.tool_request_archive_directory ])

let scan_with ?(validate_tool_request=(fun () ~read:_ ~read_scope:_ ~read_records:_ ~read_body:_ ~read_archive:_
    ~read_exact:_ original ->
      match original.restore () with Ok _ -> Payload_valid | Error detail -> Body_unreadable detail))
    ~after_read store ~base_path =
  let root = Lane_addon_store.directory ~masc_dir:(Common.masc_dir_from_base_path ~base_path) in
  let report =
    match store with
    | Store.Bindings -> scan_bindings ~after_read root
    | Native_claims -> scan_native_claims root
    | Actions ->
      scan_grouped ~after_read ~delete:(fun ~group:_ ~group_dir:_ -> record_alone) root
        Lane_addon_store.actions_directory ~entry:json_entry
        (fun ~group ~name ~path:_ json -> check_action ~group ~name json |> decoded Action_receipt)
    | Exact_requests ->
      scan_exact_requests ~after_read root
    | Tool_request_owners ->
      (* One validator serves the whole scan, so it can keep what it already
         proved about an owner whose records it meets again. *)
      let validate_tool_request = validate_tool_request () in
      let archive_store=Lane_addon_store.create ~root in
      let read_archive ~scope ~date ~request_id =
        Lane_addon_tool_request_owner.load_settled ~store:archive_store ~scope ~date ~request_id
        |> Result.map_error Lane_addon_tool_request_owner.error_to_string in
      (* A record is checked with the body it names: present, named by its
         digest, canonical JSON. Like records, the body is read by path; the
         owner, mode and link checks stay with the runtime reader. *)
      let read_text path =
        try Ok (Fs_compat.load_file_opt path) with
        | Sys_error detail -> Error (path ^ ": " ^ detail)
        | Unix.Unix_error (error, operation, _) ->
          Error (path ^ ": " ^ operation ^ ": " ^ Unix.error_message error) in
      let read_body_bytes ~scope ~request_digest =
        read_text (Filename.concat root (Lane_addon_store.tool_request_body_path ~scope ~request_digest)) in
      let read_exact=read_exact ~after_read archive_store ~root in
      (* Discovery reads a scope as a whole and fails it on one record it
         cannot read, so fresh state deletes the scope: its owner records and
         its request bodies. *)
      let scope_directories ~group ~group_dir:_ _ =
        List.filter exists (scope_group_directories ~root ~group scope_namespaces) in
      scan_groups root Lane_addon_store.tool_request_owners_directory
        (fun report ~group ~group_dir ->
          let* names = entries group_dir in
          let delete = scope_directories ~group ~group_dir in
          (* Share verified body decoding while checking this physical scope.
             Every parent/body/scope read still observes the current bytes.
             Discard these retained bytes and JSON before the next group. *)
          let module Reader=Lane_addon_tool_request_owner.Published_reader in
          let reader=Reader.create ~read_body:read_body_bytes in
          let read_body ~scope ~request_digest =
            Reader.request reader ~scope ~request_digest
            |> Result.map_error (fun detail ->
              Filename.concat root (Lane_addon_store.tool_request_body_path ~scope ~request_digest) ^ ": " ^ detail) in
          (* A record read again from the bytes it was decoded from is the
             record decoded then, while its body also reads the bytes it was
             verified from. A check can then tell a parent that reads the same
             by identity, and does not decode it again for each record that
             names it. Both files are still read each time. *)
          let read_before=Hashtbl.create 16 in
          let read_name ~scope ~name =
            let group=Lane_addon_store.digest scope in
            let path=Filename.concat root (Filename.concat Lane_addon_store.tool_request_owners_directory
              (Filename.concat group name)) in
            let* bytes=read_text path in
            match bytes with
            | None -> Hashtbl.remove read_before path; Ok None
            | Some bytes ->
              let same_body (record:Lane_addon_tool_request_owner.retained) =
                match Reader.request reader ~scope:record.scope ~request_digest:record.request_digest with
                | Ok request -> request == record.request
                | Error _ -> false in
              let result =
                let* record=match Hashtbl.find_opt read_before path with
                  | Some (seen,record) when String.equal seen bytes && same_body record -> Ok record
                  | Some _ | None ->
                    Hashtbl.remove read_before path;
                    let* json=try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error detail in
                    let+ record=Reader.read reader ~directory_name:group ~file_name:name json in
                    Hashtbl.replace read_before path (bytes,record);
                    record in
                if record.scope=scope then Ok (Some record)
                else Error "original parent belongs to another scope" in
              Result.map_error (fun detail -> path ^ ": " ^ detail) result
          in
          let read ~scope ~request_id =
            let* record=read_name ~scope ~name:(Lane_addon_store.digest request_id ^ ".json") in
            match record with
            | Some record when record.request_id<>request_id -> Error "original parent belongs to another request"
            | None | Some _ -> Ok record in
          let read_scope ~scope =
            let directory=Filename.concat root (Filename.concat Lane_addon_store.tool_request_owners_directory
              (Lane_addon_store.digest scope)) in
            let* names=entries directory in
            List.fold_right (fun name rest ->
              let* rest=rest in
              match tool_request_owner_entry name with
              | Skipped -> Ok rest
              | Refused (_,detail) -> Error (Filename.concat directory name ^ ": " ^ detail)
              | Record -> let* record=read_name ~scope ~name in
                Ok (Option.fold ~none:rest ~some:(fun record -> record::rest) record)) names (Ok []) in
          let read_records ~scope =
            let group=Lane_addon_store.digest scope in
            let directory=Filename.concat root (Filename.concat Lane_addon_store.tool_request_owners_directory group) in
            let* names=entries directory in
            List.fold_right (fun name rest ->
              let* rest=rest in
              let path=Filename.concat directory name in
              match tool_request_owner_entry name with
              | Skipped -> Ok rest
              | Refused (_,detail) -> Error (path ^ ": " ^ detail)
              | Record ->
                let* bytes=read_text path in
                match bytes with
                | None -> Ok rest
                | Some bytes ->
                  let* json=try Ok (Yojson.Safe.from_string bytes) with Yojson.Json_error detail -> Error (path ^ ": " ^ detail) in
                  let* record=Lane_addon_tool_request_owner.decode_published ~directory_name:group ~file_name:name json
                    |> Result.map_error (fun detail -> path ^ ": " ^ detail) in
                  if Lane_addon_tool_request_owner.Record.scope record=scope then Ok (record::rest)
                  else Error (path ^ ": original metadata belongs to another scope")) names (Ok []) in
          fold_entries ~delete report ~dir:group_dir ~entry:tool_request_owner_entry names
            ~record:(fun report ~name ~path ->
              match
                read_file ~after_read ~delete ~path (fun json ->
                  let+ record=Lane_addon_tool_request_owner.decode_published ~directory_name:group ~file_name:name json
                    |> decoded Tool_request_owner in
                  {record;restore=(fun () -> Reader.read reader ~directory_name:group ~file_name:name json)})
              with
              | Gone -> Ok report
              | Unreadable refusal -> Ok (refused report refusal)
              | Read original ->
                let record=original.record in
                let module Record=Lane_addon_tool_request_owner.Record in
                (* A record settled while its consumer check read it is gone,
                   as [read_file] finds a record removed while it was decoded. *)
                let refuse decoder detail delete =
                  if removed path then report
                  else
                    refused report
                      { path; decoder; delete
                      ; detail = Printf.sprintf "scope=%S request_id=%S request_digest=%s: %s"
                          (Record.scope record) (Record.request_id record) (Record.request_digest record) detail } in
                (match
                   validate_tool_request ~read ~read_scope ~read_records ~read_body ~read_archive
                     ~read_exact original
                 with
                 | Payload_valid -> Ok (counted report)
                 | Body_unreadable detail -> Ok (refuse Tool_request_owner detail (delete path))
                 | Payload_invalid detail -> Ok (refuse Tool_request_payload detail (delete path))
                 | Consumer_stops_on_exact { detail; scopes; paths } ->
                   Ok (refuse Tool_request_exact_reads detail
                         (List.filter exists
                            (List.concat_map (scope_store_directories ~root) scopes
                             @ List.map (Filename.concat root) paths)))
                 | Exact_root_differs detail -> Error detail)))
  in
  Result.map finish report

let scan = scan_with ~after_read:(fun _ -> ())

module For_testing = struct
  let scan = scan_with
end
