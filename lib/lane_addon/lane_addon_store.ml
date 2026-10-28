open Lane_addon_types
open Result.Syntax
type jsonl_snapshot = { entry_count : int; reference : evidence }
type t = { root : string; mutable root_parent_pending : bool; sequence_mutex : Mutex.t;
           sequences : (string, jsonl_snapshot) Hashtbl.t }
let create ~root =
  let root = if Filename.is_relative root then Filename.concat (Sys.getcwd ()) root else root in
  let rec trim_separator root =
    let length = String.length root in
    if length > 1 && root.[length - 1] = Filename.dir_sep.[0] then
      trim_separator (String.sub root 0 (length - 1)) else root in
  { root = trim_separator root; root_parent_pending = true; sequence_mutex = Mutex.create (); sequences = Hashtbl.create 4 }
let root t = t.root
(* Agent_core_sha256 feeds bounded slices, so hashing a large original request
   answers stop-the-world requests between slices (RFC-0474 L2). *)
let digest bytes = Agent_core_sha256.(to_hex (digest_string bytes))
let protect f =
  try f () with
  | Sys_error message -> Error message
  | Unix.Unix_error (error, call, path) ->
      Error (call ^ " " ^ path ^ ": " ^ Unix.error_message error)
  | Yojson.Json_error message -> Error message
(* Also sync existing ancestors: they may have been created by a preceding
   attempt whose parent sync failed. A retry must establish the entire path. *)
let sync_parent_directory parent =
  let fd = Unix.openfile parent [Unix.O_RDONLY; Unix.O_CLOEXEC] 0 in
  Fun.protect ~finally:(fun () -> Unix.close fd) (fun () -> Unix.fsync fd)
let rec sync_existing_parent ~sync_parent directory =
  try sync_parent directory with
  | Unix.Unix_error (Unix.ENOENT, _, _) as exn ->
      let parent = Filename.dirname directory in
      if parent=directory then raise exn else sync_existing_parent ~sync_parent parent
let rec durable_directory t ~sync_parent directory =
  let parent = Filename.dirname directory in
  if directory = t.root then (
    (try Unix.mkdir directory 0o700; t.root_parent_pending <- true with
     | Unix.Unix_error (Unix.EEXIST, _, _) ->
         if (Unix.lstat directory).Unix.st_kind <> Unix.S_DIR then
           raise (Sys_error "retained evidence root is not a directory"));
    (* Flush only the new root entry, never walk preexisting ancestors.
       Keep the obligation on failure so a retry in this store cannot skip it. *)
    if t.root_parent_pending then (sync_parent parent; t.root_parent_pending <- false))
  else if parent <> directory then (
    durable_directory t ~sync_parent parent;
    (try Unix.mkdir directory 0o700 with
     | Unix.Unix_error (Unix.EEXIST, _, _) ->
         if (Unix.lstat directory).Unix.st_kind <> Unix.S_DIR then
           raise (Sys_error "retained evidence parent is not a directory"));
    sync_parent parent)
let write_with ~sync_parent t relative bytes = protect (fun () ->
  let path = Filename.concat t.root relative in
  durable_directory t ~sync_parent (Filename.dirname path);
  Fs_compat.save_file_atomic_strict path bytes)
let write = write_with ~sync_parent:sync_parent_directory
let blob_path hash = Filename.concat "evidence" (hash ^ ".json")
let canonical_blob_kind t hash = protect (fun () ->
  let* _ = Fs_compat.inspect_owned_directory_chain
      ~ownership_root:t.root (Filename.concat t.root "evidence")
    |> Result.map_error Fs_compat.owned_directory_chain_rejection_to_string in
  Ok (Fs_compat.exact_path_kind ~follow:false (Filename.concat t.root (blob_path hash))))
let blob_reference_of_hash hash =
  { uri = "lane-evidence:" ^ hash; sha256 = Some hash }
let blob_reference bytes = blob_reference_of_hash (digest bytes)
let write_blob t bytes =
  let hash = digest bytes in
  let* () = write t (blob_path hash) bytes in
  Ok (blob_reference_of_hash hash)
let recovery_blob_path hash = Filename.concat "sampling-evidence" (hash ^ ".json")
let write_sampling_blob t bytes =
  let hash = digest bytes in
  match write t (blob_path hash) bytes with
  | Ok () -> Ok (blob_reference_of_hash hash)
  | Error detail -> protect (fun () ->
      (* A missing leaf under a symlinked parent is not an owned missing
         canonical blob and cannot authorize fallback publication. *)
      let* kind = canonical_blob_kind t hash
        |> Result.map_error (fun _ -> detail) in
      (* The immutable address is readable from recovery only for these
         canonical states. Do not advertise a blob behind an unreadable parent. *)
      match kind with
      | Fs_compat.Exact_missing | Fs_compat.Exact_kind Unix.S_DIR ->
          let* () = write t (recovery_blob_path hash) bytes in
          Ok (blob_reference_of_hash hash)
      | Fs_compat.Exact_kind (Unix.S_REG) | Fs_compat.Exact_unknown
      | Fs_compat.Exact_kind (Unix.S_CHR) | Fs_compat.Exact_kind (Unix.S_BLK)
      | Fs_compat.Exact_kind (Unix.S_LNK) | Fs_compat.Exact_kind (Unix.S_FIFO)
      | Fs_compat.Exact_kind (Unix.S_SOCK) -> Error detail)
type retained_kind = Blob | Sequence
let retained_address (reference : evidence) =
  match reference.sha256 with
  | Some hash when String.length hash = 64
      && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) hash ->
      if reference.uri = "lane-evidence:" ^ hash then Ok (Blob, hash)
      else if reference.uri = "lane-sequence:" ^ hash then Ok (Sequence, hash)
      else Error "evidence is not retained in this Lane store"
  | _ -> Error "evidence is not retained in this Lane store"
let sequence_path hash = Filename.concat "sequences" (hash ^ ".json")
type read_budget = { mutable remaining : int }
type bounded_read_error = Read_limit_exceeded | Read_failed of string
let read_budget ~max_bytes = { remaining = max 0 max_bytes }
let bounded_protect f =
  match protect (fun () -> Ok (f ())) with
  | Ok result -> result | Error detail -> Error (Read_failed detail)
let read_file_bounded ~budget ~ownership_root path = bounded_protect (fun () ->
  let before = Unix.lstat path in
  let size = before.Unix.st_size in
  if before.Unix.st_kind <> Unix.S_REG || before.Unix.st_nlink <> 1 then
    Error (Read_failed "retained evidence is not a unique regular file")
  else if size > budget.remaining then Error Read_limit_exceeded
  else begin
    budget.remaining <- budget.remaining - size;
    let* contents = Fs_compat.load_owned_regular_file_range
      ~ownership_root ~offset:0 ~max_bytes:size path
      |> Result.map_error (fun error -> Read_failed
        (Fs_compat.owned_regular_file_read_error_to_string error)) in
    match contents with
    | None -> Error (Read_failed "retained file disappeared during read")
    | Some contents ->
        let after = Unix.lstat path in
        let snapshot = contents.snapshot in
        if snapshot.device <> before.st_dev || snapshot.inode <> before.st_ino
          || snapshot.file_size <> size || snapshot.modified_at <> before.st_mtime
          || snapshot.changed_at <> before.st_ctime
          || after.st_kind <> Unix.S_REG || after.st_nlink <> 1
          || after.st_dev <> snapshot.device || after.st_ino <> snapshot.inode
          || after.st_size <> snapshot.file_size || after.st_mtime <> snapshot.modified_at
          || after.st_ctime <> snapshot.changed_at then
          Error (Read_failed "retained file changed during read")
        else Ok contents.content
  end)
let read_blob_bounded ~budget t reference =
  let* kind, hash = retained_address reference |> Result.map_error (fun e -> Read_failed e) in
  let read relative =
    let* bytes = read_file_bounded ~budget ~ownership_root:t.root (Filename.concat t.root relative) in
    if digest bytes = hash then Ok bytes else Error (Read_failed "evidence digest mismatch") in
  match kind with
  | Sequence -> read (sequence_path hash)
  | Blob ->
      let canonical = blob_path hash in
      let* kind = canonical_blob_kind t hash
        |> Result.map_error (fun detail -> Read_failed detail) in
      (match kind with
       | Fs_compat.Exact_kind Unix.S_REG -> read canonical
       | Fs_compat.Exact_missing | Fs_compat.Exact_kind Unix.S_DIR -> read (recovery_blob_path hash)
       | Fs_compat.Exact_unknown | Fs_compat.Exact_kind (Unix.S_CHR)
       | Fs_compat.Exact_kind (Unix.S_BLK) | Fs_compat.Exact_kind (Unix.S_LNK)
       | Fs_compat.Exact_kind (Unix.S_FIFO) | Fs_compat.Exact_kind (Unix.S_SOCK) ->
           Error (Read_failed "retained evidence is not a regular file"))
let read_blob ?(max_bytes=max_int) t reference =
  read_blob_bounded ~budget:(read_budget ~max_bytes) t reference
  |> Result.map_error (function
    | Read_limit_exceeded -> "retained evidence exceeds the source envelope"
    | Read_failed detail -> detail)

type blob_slice = { content : string; snapshot : Fs_compat.owned_regular_file_snapshot }
let read_blob_slice ?snapshot t reference ~offset ~max_bytes = protect (fun () ->
  if offset < 0 || max_bytes < 0 then Error "invalid retained result slice bounds"
  else
    let* kind, hash = retained_address reference in
    let* relative = match kind with
      | Sequence -> Error "a retained host result must be a blob"
      | Blob ->
        let* kind = canonical_blob_kind t hash in
        (match kind with
         | Fs_compat.Exact_kind Unix.S_REG -> Ok (blob_path hash)
         | Fs_compat.Exact_missing | Fs_compat.Exact_kind Unix.S_DIR -> Ok (recovery_blob_path hash)
         | Fs_compat.Exact_unknown | Fs_compat.Exact_kind (Unix.S_CHR | Unix.S_BLK | Unix.S_LNK
             | Unix.S_FIFO | Unix.S_SOCK) -> Error "retained result is not a regular file") in
    let path = Filename.concat t.root relative in
    let checked content (observed : Fs_compat.owned_regular_file_snapshot) =
      if offset > observed.Fs_compat.file_size then Error "offset exceeds the retained result"
      else if String.length content <> min max_bytes (observed.file_size-offset) then
        Error "retained result ended before its recorded size"
      else Ok {content; snapshot=observed} in
    match snapshot with
    | None ->
        let* chunk = Fs_compat.load_owned_regular_file_range_with_sha256
            ~ownership_root:t.root ~offset ~max_bytes path
          |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
        (match chunk with
         | None -> Error "retained result disappeared"
         | Some chunk when chunk.Fs_compat.sha256 <> hash -> Error "retained result digest mismatch"
         | Some chunk -> checked chunk.content chunk.snapshot)
    | Some expected ->
        let* chunk = Fs_compat.load_owned_regular_file_range
            ~ownership_root:t.root ~offset ~max_bytes path
          |> Result.map_error Fs_compat.owned_regular_file_read_error_to_string in
        (match chunk with
         | None -> Error "retained result disappeared"
         | Some chunk when not (Fs_compat.equal_owned_regular_file_snapshot expected chunk.Fs_compat.snapshot) ->
             Error "retained result snapshot changed; request a new source read"
         | Some chunk -> checked chunk.content chunk.snapshot))

type sequence_node = Empty | Record of { count : int; previous : evidence; bytes : string }
let sequence_schema = "masc.lane-jsonl-sequence.v1"
let read_sequence_node t reference =
  let* kind, _ = retained_address reference in
  if kind <> Sequence then Error "sequence requires a host-owned lane-sequence reference"
  else
    let* bytes = read_blob t reference in
    protect (fun () ->
      match Yojson.Safe.from_string bytes with
      | `Assoc fields when List.sort String.compare (List.map fst fields)
          = ["entry_count"; "previous"; "record"; "schema"]
          && List.assoc "schema" fields = `String sequence_schema ->
          (match List.assoc "entry_count" fields, List.assoc "previous" fields,
                 List.assoc "record" fields with
           | `Int 0, `Null, `Null -> Ok Empty
           | `Int count, previous, `String bytes when count > 0 ->
               let* previous = evidence_of_json previous in
               let* kind, _ = retained_address previous in
               if kind <> Sequence then Error "sequence predecessor is not host-owned"
               else Ok (Record { count; previous; bytes })
           | _ -> Error "invalid sequence record")
      | _ -> Error "invalid sequence schema")
let node_count = function Empty -> 0 | Record node -> node.count
let write_sequence_node t node =
  let count, previous, record = match node with
    | Empty -> 0, `Null, `Null
    | Record node -> node.count, evidence_to_json node.previous, `String node.bytes in
  let bytes = Yojson.Safe.to_string (`Assoc ["schema", `String sequence_schema;
    "entry_count", `Int count; "previous", previous; "record", record]) in
  let hash = digest bytes in
  let reference = { uri = "lane-sequence:" ^ hash; sha256 = Some hash } in
  if Sys.file_exists (Filename.concat t.root (sequence_path hash)) then
    let* _ = read_blob t reference in Ok reference
  else let* () = write t (sequence_path hash) bytes in Ok reference
let sequence_prefix t snapshot count =
  let rec walk expected reference =
    let* node = read_sequence_node t reference in
    if node_count node <> expected then Error "sequence predecessor count mismatch"
    else if expected = count then Ok {entry_count = count; reference}
    else match node with
      | Empty -> Error "sequence cursor is outside retained history"
      | Record node -> walk (expected - 1) node.previous in
  walk snapshot.entry_count snapshot.reference
let retain_jsonl t ~history ~entry_count ~newest_first ~encode =
  (* This API is used by offloaded source acquisition, never a running fiber. *)
  Mutex.lock t.sequence_mutex;
  Fun.protect ~finally:(fun () -> Mutex.unlock t.sequence_mutex) (fun () ->
    if entry_count < 0 then Error "negative sequence cursor"
    else
      let* previous = match Hashtbl.find_opt t.sequences history with
        | Some snapshot -> Ok snapshot
        | None -> let* reference = write_sequence_node t Empty in
            let snapshot = {entry_count = 0; reference} in
            Hashtbl.add t.sequences history snapshot;
            Ok snapshot in
      if entry_count <= previous.entry_count then sequence_prefix t previous entry_count
      else
        let rec new_records remaining acc = function
          | _ when remaining = 0 -> Ok acc
          | [] -> Error "input history is shorter than its captured cursor"
          | entry :: rest -> new_records (remaining - 1) (entry :: acc) rest in
        let* entries = new_records (entry_count - previous.entry_count) [] newest_first in
        let rec append snapshot = function
          | [] -> Hashtbl.replace t.sequences history snapshot; Ok snapshot
          | entry :: rest ->
              let count = snapshot.entry_count + 1 in
              let* reference = write_sequence_node t
                (Record {count; previous = snapshot.reference; bytes = encode entry}) in
              append {entry_count = count; reference} rest in
        append previous entries)
let fold_sequence ?seen t reference ~init ~f =
  let rec walk expected acc reference =
    let* kind, _ = retained_address reference in
    if kind <> Sequence then Error "sequence requires a host-owned lane-sequence reference"
    else
    let count_matches count = Option.fold ~none:true ~some:((=) count) expected in
    match Option.bind seen (fun table -> Hashtbl.find_opt table reference.uri) with
    | Some count ->
        if count_matches count then Ok acc else Error "sequence predecessor count mismatch"
    | None ->
        let* node = read_sequence_node t reference in
        let count = node_count node in
        if not (count_matches count) then Error "sequence predecessor count mismatch"
        else
          let* acc = f acc reference node in
          Option.iter (fun table -> Hashtbl.add table reference.uri count) seen;
          match node with Empty -> Ok acc
          | Record node -> walk (Some (node.count - 1)) acc node.previous in
  walk None init reference
let read_jsonl t reference =
  let* records = fold_sequence t reference ~init:[]
    ~f:(fun records _ -> function Empty -> Ok records
      | Record node -> Ok (node.bytes :: records)) in
  Ok (String.concat "" records)
let bindings_directory = "bindings"
let actions_directory = "actions"
let exact_requests_directory = "exact-requests"
let tool_request_owners_directory = "tool-request-owners"
let tool_request_bodies_directory = "tool-request-bodies"
let binding_path instance_id = Filename.concat bindings_directory (digest instance_id ^ ".json")
let save_binding t ~instance_id json = write t (binding_path instance_id) (Yojson.Safe.to_string json)
type binding_write_error =
  | Binding_rejected of string
  | Binding_publication_failed of Fs_compat.atomic_replace_failure
let binding_write_error_to_string = function
  | Binding_rejected detail -> detail
  | Binding_publication_failed failure -> Fs_compat.atomic_replace_failure_to_string failure
let save_binding_staged_with ~replace_file t ~instance_id json =
  let* path = protect (fun () ->
    let path = Filename.concat t.root (binding_path instance_id) in
    durable_directory t ~sync_parent:sync_parent_directory (Filename.dirname path);
    Ok path) |> Result.map_error (fun detail -> Binding_rejected detail) in
  replace_file path (Yojson.Safe.to_string json)
  |> Result.map_error (fun failure -> Binding_publication_failed failure)
let save_binding_staged = save_binding_staged_with ~replace_file:Fs_compat.save_file_atomic_strict_staged
let remove_binding_with ~sync_parent t ~instance_id = protect (fun () ->
  let path = Filename.concat t.root (binding_path instance_id) in
  (try Unix.unlink path
   with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  (* A previous unlink may have succeeded before its directory sync failed.
     Missing ancestor directories are also removals; sync the first surviving
     parent rather than creating directories just to report absence. *)
  sync_existing_parent ~sync_parent (Filename.dirname path);
  Ok ())
let remove_binding = remove_binding_with ~sync_parent:sync_parent_directory
let action_path ~instance_id ~request_id =
  Filename.concat actions_directory (Filename.concat (digest instance_id) (digest request_id ^ ".json"))
(* One keyed JSON record, published with every directory below root synced. *)
let save_record_with ~sync_parent t relative json = protect (fun () ->
  let path = Filename.concat t.root relative in
  durable_directory t ~sync_parent (Filename.dirname path);
  Fs_compat.save_file_atomic_strict path (Yojson.Safe.to_string json))
let save_action_with ~sync_parent t ~instance_id ~request_id json =
  save_record_with ~sync_parent t (action_path ~instance_id ~request_id) json
let save_action = save_action_with ~sync_parent:sync_parent_directory
(* Keyed by the declaration id, not the instance id: an attach mints a new
   instance id, and a restarted worker must find what the host retained. *)
let exact_request_path ~declaration_id ~request_id =
  Filename.concat exact_requests_directory (Filename.concat (digest declaration_id) (digest request_id ^ ".json"))
let save_exact_request t ~declaration_id ~request_id json =
  save_record_with ~sync_parent:sync_parent_directory t (exact_request_path ~declaration_id ~request_id) json
let tool_request_owner_path ~scope ~request_id =
  Filename.concat tool_request_owners_directory (Filename.concat (digest scope) (digest request_id ^ ".json"))
let with_tool_request_owner_directory_serialization t ~directory_name work =
  (* The parent is the existing authority anchor, even before the store/scope
     exists. Resolve its aliases without creating missing authority. Store and
     descriptor checks inside [work] still reject external replacement. *)
  let parent=Unix.realpath (Filename.dirname t.root) in
  let key=Filename.concat parent (Filename.concat (Filename.basename t.root)
    (Filename.concat tool_request_owners_directory directory_name)) in
  File_lock_eio.with_mutex key work
let with_tool_request_owner_serialization t ~scope work =
  with_tool_request_owner_directory_serialization t ~directory_name:(digest scope) work
(* A wake scans all scopes and can re-enter their readers. This separate
   store-wide mutex keeps a settle from moving a listed record until that
   scan has finished without holding any scope mutex across its callbacks.
   Like the scope mutex, it relies on the caller's workspace process lease. *)
let with_tool_request_settlement_barrier t work =
  let key () =
    let parent = Unix.realpath (Filename.dirname t.root) in
    Filename.concat parent
      (Filename.concat (Filename.basename t.root) "tool-request-settlement-barrier") in
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> protect (fun () -> Ok (File_lock_eio.with_mutex (key ()) work))
  | Fs_compat.Eio_fiber ->
    let key = Systhread_host.run ~label:"addon-settlement-barrier-key" (fun () ->
      protect (fun () -> Ok (key ()))) in
    Eio.Fiber.check ();
    let* key = key in
    (* Waiting is cancellable. Once admitted, the system-thread work must
       finish before releasing the mutex, even if its caller is cancelled. *)
    let result = protect (fun () -> Ok (File_lock_eio.with_mutex key (fun () ->
      Eio.Fiber.check ();
      Eio.Cancel.protect (fun () -> Systhread_host.run ~label:"addon-original-wake-sweep" work)))) in
    Eio.Fiber.check (); result
let save_tool_request_owner t ~scope ~request_id json =
  protect (fun () -> with_tool_request_owner_serialization t ~scope (fun () ->
    save_record_with ~sync_parent:sync_parent_directory t (tool_request_owner_path ~scope ~request_id) json))
let broadcast_path ~instance_id ~request_id =
  Filename.concat "broadcasts" (Filename.concat (digest instance_id) (digest request_id ^ ".json"))
let save_broadcast t ~instance_id ~request_id json =
  write t (broadcast_path ~instance_id ~request_id) (Yojson.Safe.to_string json)
let load_broadcast t ~instance_id ~request_id = protect (fun () ->
  let path = Filename.concat t.root (broadcast_path ~instance_id ~request_id) in
  match Fs_compat.exact_path_kind path with
  | Fs_compat.Exact_missing -> Ok None
  | Fs_compat.Exact_unknown | Fs_compat.Exact_kind _ -> let stat = Unix.stat path in
      if stat.Unix.st_kind <> Unix.S_REG then Error "Broadcast evidence record is not a regular file"
      else Ok (Some (Fs_compat.load_file path |> Yojson.Safe.from_string)))
type binding_inventory = {
  records : (string * Yojson.Safe.t) list;
  issues : (string * string) list;
  complete : bool;
}

(* Binding inventory issue details carry a bracketed failure-kind tag so a
   recurring application.kind=unknown signal can be attributed to publication
   contention ([identity-changed], [absent-unconfirmed]) versus real damage
   ([parse], [non-regular …], [unreadable]) without opening the store. Pure
   over the fs_compat failure variants: no paths and no message strings are
   sniffed. *)
let issue_detail (error : Fs_compat.owned_regular_file_read_error) =
  let failure = error.Fs_compat.failure in
  let tag =
    match failure with
    | Fs_compat.Filesystem_identity_changed _ -> "identity-changed"
    | Fs_compat.Path_is_not_regular_file { kind; _ } ->
        if kind = Unix.S_DIR then "non-regular directory"
        else "non-regular " ^ Fs_compat.file_kind_to_string kind
    | Fs_compat.Ownership_boundary_rejected _
    | Fs_compat.Owned_path_owner_mismatch _
    | Fs_compat.Owned_path_writable_by_others _
    | Fs_compat.Owned_file_operation_failed _ -> "unreadable" in
  "[" ^ tag ^ "] " ^ Fs_compat.owned_regular_file_read_error_to_string error

let binding_inventory_with ~sync_parent ~root =
  let directory = Filename.concat root bindings_directory in
  let listed = protect (fun () ->
    match Fs_compat.exact_path_kind directory with
    | Fs_compat.Exact_missing -> Ok []
    | Fs_compat.Exact_unknown | Fs_compat.Exact_kind _ -> Ok (Fs_compat.read_dir directory |> List.sort String.compare)) in
  match listed with
  | Error detail -> { records=[]; issues=[directory,detail]; complete=false }
  | Ok names ->
      (* A binding publication is a temp-file rename and a removal is an
         unlink; both change the identity metadata of the very file an
         inventory read has open (rename-over/unlink bumps its ctime and
         drops its link count, and a path can vanish mid-read). Such a
         concurrent write is the writer succeeding, not a damaged record, so
         one bounded retry takes either the published bytes or a confirmed
         absence; only a failure that repeats without any writer finishing is
         an issue that makes the reading incomplete. *)
      let read_record path =
        let attempt () =
          match Fs_compat.load_owned_regular_file_range
                  ~ownership_root:root ~offset:0 ~max_bytes:max_int path with
          | Error error -> Error (issue_detail error)
          | Ok (Some { Fs_compat.content; _ }) -> Ok (Some content)
          | Ok None -> Ok None in
        let rec retry = function
          | 0 -> attempt ()
          | remaining ->
            (match attempt () with
             | Ok _ as published -> published
             | Error _ when remaining > 0 -> retry (remaining - 1)
             | Error _ as failure -> failure) in
        match retry 1 with
        | Ok (Some contents) ->
            (try Ok (Some (Yojson.Safe.from_string contents))
             with Yojson.Json_error detail ->
               Error ("[parse] " ^ detail))
        | Ok None ->
            (* The listing saw the name and the record is gone: a rename
               source or an unlink. Report absence only when a fresh look
               agrees, so a writer that was mid-flight does not read as
               cleanup. *)
            (match Fs_compat.exact_path_kind path with
             | Fs_compat.Exact_missing -> Ok None
             | Fs_compat.Exact_unknown | Fs_compat.Exact_kind _ ->
               Error "[absent-unconfirmed] binding disappeared during inventory read")
        | Error _ as failure -> failure in
      let records,issues = List.fold_left (fun (records,issues) name ->
        if not (Filename.check_suffix name ".json") then records,issues
        else
          let path = Filename.concat directory name in
          let read = protect (fun () -> read_record path) in
          match read with
          | Ok (Some value) -> (path,value)::records,issues
          | Ok None -> records,issues
          | Error detail -> records,(path,detail)::issues) ([],[]) names in
      (* A prior process may have renamed a terminal binding or unlinked it,
         then failed its parent sync. Reestablish that publication before a
         caller treats Detached or absence as completed cleanup. Binding
         writers sync file contents before rename. No record is rewritten. *)
      let issues = match protect (fun () ->
        sync_existing_parent ~sync_parent directory; Ok ()) with
        | Ok () -> issues
        | Error detail -> (directory,detail)::issues in
      { records=List.rev records; issues=List.rev issues; complete=issues=[] }
let binding_inventory = binding_inventory_with ~sync_parent:sync_parent_directory
let sampling_directory instance_id = Filename.concat "sampling" (digest instance_id)
let save_sampling_request t ~instance_id ~request_id json =
  write t (Filename.concat (sampling_directory instance_id) (digest request_id ^ ".json"))
    (Yojson.Safe.to_string json)
let sampling_outcome_directory instance_id = Filename.concat "sampling-outcomes" (digest instance_id)
let save_sampling_outcome t ~instance_id ~request_id json =
  write t (Filename.concat (sampling_outcome_directory instance_id) (digest request_id ^ ".json"))
    (Yojson.Safe.to_string json)
let observation_dir instance_id = Filename.concat "observations" (digest instance_id)
type record_verification = Visible | Durable
(* [Republished]: the path names another file by the end of the read, so
   the bytes read belong to a file the path no longer names. *)
type confirmed_read = Confirmed of string | Republished
let same_file a b = a.Unix.st_dev=b.Unix.st_dev && a.Unix.st_ino=b.Unix.st_ino
let record_bytes fd size =
  let buffer=Bytes.create size in
  let rec read offset =
    if offset=size then Ok () else
    match Unix.read fd buffer offset (size-offset) with
    | 0 -> Error "retained file shrank during read"
    | count -> read (offset+count)
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> read offset in
  let* ()=read 0 in
  let rec end_of_record () =
    match Unix.read fd (Bytes.create 1) 0 1 with
    | 0 ->
      (* This read owns [buffer]; it has never escaped and no write follows
         EOF. Transfer it to the immutable result without copying the whole
         record. The verification read still owns a distinct buffer. *)
      Ok (Bytes.unsafe_to_string buffer)
    | _ -> Error "retained file grew during read"
    | exception Unix.Unix_error (Unix.EINTR,_,_) -> end_of_record () in
  end_of_record ()
let with_record_fd path fn =
  let fd = Unix.openfile path [Unix.O_RDONLY;Unix.O_NONBLOCK;Unix.O_CLOEXEC] 0 in
  match fn fd with
  | result -> Unix.close fd;result
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    (try Unix.close fd with Unix.Unix_error _ -> ());
    Printexc.raise_with_backtrace exn backtrace
let verify_record_bytes path fd stat bytes =
  let _offset=Unix.lseek fd 0 Unix.SEEK_SET in
  let size=stat.Unix.st_size in
  let* verified=
    if size <= 2 * Sys.io_buffer_size then record_bytes fd size
    else
      (* Two reusable I/O buffers replace the second file-sized allocation.
         Keep the direct read when it needs no more memory than this pair.
         Neither scratch buffer aliases the immutable first observation. *)
      let observed=Bytes.create Sys.io_buffer_size in
      let expected=Bytes.create Sys.io_buffer_size in
      let rec fill offset length =
        if offset=length then Ok () else
        match Unix.read fd observed offset (length-offset) with
        | 0 -> Error "retained file shrank during read"
        | count -> fill (offset+count) length
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> fill offset length in
      let eof=Bytes.create 1 in
      let rec finish unchanged =
        match Unix.read fd eof 0 1 with
        | 0 -> if unchanged then Ok bytes else Error "retained file changed during sync"
        | _ -> Error "retained file grew during read"
        | exception Unix.Unix_error (Unix.EINTR,_,_) -> finish unchanged in
      let rec compare offset unchanged =
        if offset=size then finish unchanged else
        let count=min (Bytes.length observed) (size-offset) in
        let* ()=fill 0 count in
        Bytes.blit_string bytes offset expected 0 count;
        (* A short final chunk leaves equal tails from the preceding full
           comparison whenever [unchanged] is true. A prior mismatch stays
           false; still read through EOF to retain shrink/growth failures. *)
        let unchanged=unchanged && Bytes.equal observed expected in
        compare (offset+count) unchanged in
      compare 0 true in
  if verified<>bytes then Error "retained file changed during sync"
  else if same_file stat (Unix.stat path) then Ok (Confirmed bytes)
  else Ok Republished
let settle_verified_record ~sync_file ~sync_parent path fd stat bytes parent_fd =
  let parent=Filename.dirname path in
  let parent_stat=Unix.fstat parent_fd in
  if parent_stat.Unix.st_kind<>Unix.S_DIR then Error "retained file parent is not a directory"
  else (
    sync_file fd;sync_parent parent_fd;
    let* read=verify_record_bytes path fd stat bytes in
    if same_file parent_stat (Unix.stat parent) then Ok read
    else Error "retained file parent changed during sync")
let read_verified_record ~sync_file ~sync_parent ~verification path fd stat =
  let* bytes=record_bytes fd stat.Unix.st_size in
  match verification with
  | Visible -> verify_record_bytes path fd stat bytes
  | Durable ->
    let parent=Filename.dirname path in
    with_record_fd parent (settle_verified_record ~sync_file ~sync_parent path fd stat bytes)
let changed_during_verification = function
  | Confirmed bytes -> Ok bytes
  | Republished -> Error "retained file changed during verification"
let bounded_file_with ~sync_file ~sync_parent ~verification ~max_bytes path = protect (fun () ->
  with_record_fd path (fun fd ->
    let stat = Unix.fstat fd in
    if stat.Unix.st_kind <> Unix.S_REG then Error "retained file is not a regular file"
    else if stat.Unix.st_size > max_bytes then Error "retained file exceeds its read envelope"
    else Result.bind (read_verified_record ~sync_file ~sync_parent ~verification path fd stat)
        changed_during_verification))
let bounded_file = bounded_file_with ~sync_file:Unix.fsync ~sync_parent:Unix.fsync ~verification:Durable
type record_observation =
  | Record_missing
  | Record_current of Yojson.Safe.t
  | Record_republished
(* A keyed record is replaced whole by a rename (save_record_with). The size
   comes from the opened file, so a rename between a path stat and the open
   cannot pass for growth; growth of the opened file fails [record_bytes]. *)
let observe_record_with ~what ~sync_file ~sync_parent t relative = protect (fun () ->
  let path = Filename.concat t.root relative in
  match Fs_compat.exact_path_kind path with
  | Fs_compat.Exact_missing -> Ok Record_missing
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
      with_record_fd path (fun fd ->
        let stat = Unix.fstat fd in
        if stat.Unix.st_kind <> Unix.S_REG then Error (what ^ " is not a regular file")
        else
          let* read = read_verified_record ~sync_file ~sync_parent ~verification:Durable path fd stat in
          match read with
          | Confirmed bytes -> Ok (Record_current (Yojson.Safe.from_string bytes))
          | Republished -> Ok Record_republished))
let load_record_with ~what ~sync_file ~sync_parent t relative =
  let* observed = observe_record_with ~what ~sync_file ~sync_parent t relative in
  match observed with
  | Record_missing -> Ok None
  | Record_current json -> Ok (Some json)
  | Record_republished -> Error "retained file changed during verification"
let load_action_with ~sync_file ~sync_parent t ~instance_id ~request_id =
  load_record_with ~what:"action receipt" ~sync_file ~sync_parent t (action_path ~instance_id ~request_id)
let load_action = load_action_with ~sync_file:Unix.fsync ~sync_parent:Unix.fsync
(* The run that owns an exact request republishes it at each of its
   transitions while observers read it without the run's claim. A read that
   ends on a republished file reads the newer record. Every repeat needs
   another publication, and a run publishes a bounded number of transitions. *)
let rec load_exact_request_with ~sync_file ~sync_parent t ~declaration_id ~request_id =
  let* observed = observe_record_with ~what:"exact request record" ~sync_file ~sync_parent t
      (exact_request_path ~declaration_id ~request_id) in
  match observed with
  | Record_missing -> Ok None
  | Record_current json -> Ok (Some json)
  | Record_republished -> load_exact_request_with ~sync_file ~sync_parent t ~declaration_id ~request_id
let load_exact_request = load_exact_request_with ~sync_file:Unix.fsync ~sync_parent:Unix.fsync

let owned_result value = Result.map_error Fs_compat.owned_regular_file_read_error_to_string value
(* One scope directory of [namespace] (records or request bodies). The caller
   holds the per-scope serializer that publication uses. *)
let read_tool_request_scope ~namespace ~sync_parent t ~scope fn =
  let* result = Fs_compat.with_owned_inventory_root (Filename.dirname t.root) (fun anchor ->
    let result =
      let owner_uid = Unix.geteuid () in
      let parent = Fs_compat.owned_inventory_root_path anchor in
      let root = Filename.concat parent (Filename.basename t.root) in
      let directory = Filename.concat root (Filename.concat namespace (digest scope)) in
      let* observed = Fs_compat.with_owned_directory_inventory_if_present ~owner_uid
        ~inventory_root:anchor ~sync_directory:sync_parent directory (fun held names ->
          let* value = fn ~owner_uid held names in
          let* current = Fs_compat.read_owned_directory ~owner_uid ~inventory_root:held
            ~ownership_root:directory directory |> owned_result in
          if current <> names then Error "original request directory changed during inventory"
          else Ok value) |> owned_result in
      match observed with
      | None -> Ok None
      | Some result -> Result.map Option.some result in
    Ok result) |> owned_result in
  result
(* Run [work] under the scope serializer, on a system thread for an Eio
   caller. The thread is the system-thread host's ([Systhread_host]): [work]
   decodes, hashes and re-serializes whole records, and the Librarian calls
   this from a fiber of the main domain, whose lock a thread of its own would
   hold meanwhile. *)
let serialized_tool_request_read t ~scope work =
  let blocking () = protect (fun () -> with_tool_request_owner_serialization t ~scope work) in
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> blocking ()
  | Fs_compat.Eio_fiber ->
    let result = Systhread_host.run ~label:"addon-original-request-read" blocking in
    Eio.Fiber.check (); result
let with_tool_request_scope ~namespace ~sync_parent t ~scope fn =
  serialized_tool_request_read t ~scope (fun () -> read_tool_request_scope ~namespace ~sync_parent t ~scope fn)
let with_tool_request_owner_scope ~sync_parent t ~scope fn =
  with_tool_request_scope ~namespace:tool_request_owners_directory ~sync_parent t ~scope fn
let read_owned_tool_request_bytes ~sync_file ~sync_parent ~owner_uid held name =
  let path = Filename.concat (Fs_compat.owned_inventory_root_path held) name in
  let* relative = Fs_compat.owned_relative_path [name] in
  let* result = Fs_compat.with_owned_inventory_regular_file ~owner_uid held relative
    (fun ~file ~parent ~stat -> protect (fun () ->
      let* bytes = record_bytes file stat.Unix.st_size in
      let* read = settle_verified_record ~sync_file ~sync_parent path file stat bytes parent in
      changed_during_verification read)) |> owned_result in
  result
let read_owned_tool_request ~sync_file ~sync_parent ~owner_uid held name =
  let* bytes = read_owned_tool_request_bytes ~sync_file ~sync_parent ~owner_uid held name in
  protect (fun () -> Ok (Yojson.Safe.from_string bytes))
let read_startup_tool_request ~owner_uid held name =
  let* relative = Fs_compat.owned_relative_path [name] in
  let* result = Fs_compat.with_owned_inventory_regular_file ~owner_uid held relative
    (fun ~file ~parent ~stat:_ -> protect (fun () ->
      Unix.fsync file;
      Unix.fsync parent;
      let copy = Unix.dup ~cloexec:true file in
      let input = Unix.in_channel_of_descr copy in
      let json = Fun.protect ~finally:(fun () -> close_in input)
        (fun () -> Yojson.Safe.from_channel input) in
      Unix.fsync file;
      Unix.fsync parent;
      Ok json)) |> owned_result in
  result
let inspect_staged_tool_request ~owner_uid held name =
  let* relative = Fs_compat.owned_relative_path [name] in
  Fs_compat.with_owned_inventory_regular_file ~owner_uid held relative
    (fun ~file ~parent ~stat:_ -> Unix.fsync file; Unix.fsync parent) |> owned_result
let inspect_tool_request_body ~owner_uid held name =
  let* relative = Fs_compat.owned_relative_path [name] in
  let* stat = Fs_compat.with_owned_inventory_regular_file ~owner_uid held relative
    (fun ~file ~parent ~stat -> Unix.fsync file; Unix.fsync parent; stat) |> owned_result in
  (* Stream the digest through the held inventory root, without allocating the
     request size. Tie that observation back to the owned single-link file
     whose descriptor and parent were just synced. *)
  let* digest = Fs_compat.owned_inventory_entry_digest held relative |> owned_result in
  let snapshot = digest.Fs_compat.snapshot in
  if snapshot.device <> stat.Unix.st_dev || snapshot.inode <> stat.st_ino
     || snapshot.owner_uid <> stat.st_uid || snapshot.permissions <> (stat.st_perm land 0o7777)
     || snapshot.file_size <> stat.st_size || snapshot.modified_at <> stat.st_mtime
     || snapshot.changed_at <> stat.st_ctime then
    Error "original request body changed during inventory"
  else Ok (digest.sha256,stat)
let tool_request_owner_record t ~scope ~request_id =
  let name = digest request_id ^ ".json" in
  let* result = read_tool_request_scope ~namespace:tool_request_owners_directory ~sync_parent:Unix.fsync t ~scope
    (fun ~owner_uid held names ->
      if not (List.mem name names) then Ok None
      else read_owned_tool_request ~sync_file:Unix.fsync ~sync_parent:Unix.fsync ~owner_uid held name
        |> Result.map Option.some) in
  Ok (Option.join result)
let load_tool_request_owner t ~scope ~request_id =
  serialized_tool_request_read t ~scope (fun () -> tool_request_owner_record t ~scope ~request_id)
let tool_request_body_path ~scope ~request_digest =
  Filename.concat tool_request_bodies_directory (Filename.concat (digest scope) (request_digest ^ ".json"))
let tool_request_body t ~scope ~request_digest =
  let* () = if String_util.is_lowercase_sha256_hex request_digest then Ok ()
    else Error "a request body is named by a SHA-256 digest" in
  let name = request_digest ^ ".json" in
  let* body = read_tool_request_scope ~namespace:tool_request_bodies_directory ~sync_parent:Unix.fsync t ~scope
    (fun ~owner_uid held names ->
      if not (List.mem name names) then Ok None
      else read_owned_tool_request_bytes ~sync_file:Unix.fsync ~sync_parent:Unix.fsync ~owner_uid held name
        |> Result.map Option.some) in
  Ok (Option.join body)
let load_tool_request_body t ~scope ~request_digest =
  serialized_tool_request_read t ~scope (fun () -> tool_request_body t ~scope ~request_digest)
(* The record and the body it names under one hold of the serializer that a
   settle moves both under, so an original is read whole or found gone. *)
let load_tool_request t ~scope ~request_id ~name_body =
  serialized_tool_request_read t ~scope (fun () ->
    let* record = tool_request_owner_record t ~scope ~request_id in
    match record with
    | None -> Ok None
    | Some json ->
      let* record,request_digest = name_body json in
      let* body = tool_request_body t ~scope ~request_digest in
      Ok (Some (record,body)))
(* A body is named by the digest of its bytes, so writing it again publishes
   the same file; each write is atomic and synced with its directory. *)
let save_tool_request_body t ~scope ~request_digest bytes =
  let* () = if String.equal (digest bytes) request_digest then Ok ()
    else Error "a request body must be named by the digest of its bytes" in
  protect (fun () -> with_tool_request_owner_serialization t ~scope (fun () ->
    write_with ~sync_parent:sync_parent_directory t (tool_request_body_path ~scope ~request_digest) bytes))
(* Settled originals: each record and the body it names, under the date its
   chain began. Only the startup body sweep lists and reads it, and only when a
   live body is not protected by a live record. *)
let tool_request_archive_directory = "tool-request-owners-settled"
(* A day names a directory, so only [YYYY-MM-DD] is accepted. *)
let settled_day date =
  let digit index = match date.[index] with '0' .. '9' -> true | _ -> false in
  if String.length date = 10 && date.[4] = '-' && date.[7] = '-'
     && List.for_all digit [0; 1; 2; 3; 5; 6; 8; 9] then Ok ()
  else Error "a settled date is written YYYY-MM-DD"
let tool_request_archive_path ~scope ~date kind name =
  Filename.concat tool_request_archive_directory
    (Filename.concat (digest scope) (Filename.concat date (Filename.concat kind name)))
let tool_request_archive_record_path ~scope ~date ~request_id =
  tool_request_archive_path ~scope ~date "records" (digest request_id ^ ".json")
let tool_request_archive_body_path ~scope ~date ~request_digest =
  tool_request_archive_path ~scope ~date "bodies" (request_digest ^ ".json")
let owned_regular_file (stat : Unix.stats) =
  stat.st_kind = Unix.S_REG && stat.st_nlink = 1 && stat.st_uid = Unix.geteuid ()
(* Move one published file into the archive, or find it already there. Both
   directories are synced after the rename. *)
let move_into_archive t ~source ~target =
  let source = Filename.concat t.root source and target = Filename.concat t.root target in
  match Unix.lstat source with
  | stat when owned_regular_file stat ->
    durable_directory t ~sync_parent:sync_parent_directory (Filename.dirname target);
    Unix.rename source target;
    sync_parent_directory (Filename.dirname target);
    sync_parent_directory (Filename.dirname source);
    Ok ()
  | _ -> Error ("an original request file to settle is not a regular file this process owns: " ^ source)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
    match Unix.lstat target with
    | stat when owned_regular_file stat -> Ok ()
    | _ -> Error ("a settled original request file is not a regular file this process owns: " ^ target)
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
      Error ("an original request file is in neither its scope nor the settled archive: " ^ source)
let settle_tool_request t ~scope ~date ~request_id ~request_digest ~check_record =
  let* () = settled_day date in
  let* outcome = with_tool_request_settlement_barrier t (fun () ->
    protect (fun () -> with_tool_request_owner_serialization t ~scope (fun () ->
    let* record = tool_request_owner_record t ~scope ~request_id in
    let* matches = check_record record in
    if not matches then Ok false else
    (* The record first, the reverse of publication: an interrupted settle
       leaves a body no record names, as an interrupted retain does, never a
       record without its body. *)
    let* () = move_into_archive t ~source:(tool_request_owner_path ~scope ~request_id)
        ~target:(tool_request_archive_record_path ~scope ~date ~request_id) in
    let* () = move_into_archive t ~source:(tool_request_body_path ~scope ~request_digest)
      ~target:(tool_request_archive_body_path ~scope ~date ~request_digest) in
    Ok true))) in
  outcome
let tool_request_settled t ~scope ~date ~request_id =
  let* () = settled_day date in
  protect (fun () ->
  let path = Filename.concat t.root (tool_request_archive_record_path ~scope ~date ~request_id) in
  match Unix.lstat path with
  | stat when owned_regular_file stat -> Ok true
  | _ -> Error ("a settled original request record is not a regular file this process owns: " ^ path)
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false)

type namespace_entry = Record_entry | Staged_entry | Unknown_entry
let tool_request_owner_entry name =
  if Fs_compat.is_atomic_orphan_name name then Staged_entry
  else if Filename.check_suffix name ".json" then Record_entry
  else Unknown_entry
let tool_request_owner_inventory_with ~after_listing ~sync_file ~sync_parent t ~scope =
  let* result = with_tool_request_owner_scope ~sync_parent t ~scope
    (fun ~owner_uid held names ->
      after_listing (Fs_compat.owned_inventory_root_path held);
      let rec read records = function
        | [] -> Ok (List.rev records)
        | name :: rest ->
          match tool_request_owner_entry name with
          | Staged_entry -> read records rest
          | Unknown_entry -> Error "unknown entry in original request namespace"
          | Record_entry ->
            let* json = read_owned_tool_request ~sync_file ~sync_parent ~owner_uid held name in
            read ((name,json) :: records) rest in
      read [] names) in
  Ok (match result with None -> [] | Some records -> records)
let tool_request_owner_inventory = tool_request_owner_inventory_with
  ~after_listing:(fun _ -> ()) ~sync_file:Unix.fsync ~sync_parent:Unix.fsync

let fold_tool_request_owner_inventory_all_with ~check_staged ~serialize_scopes t ~init ~f =
  let blocking () = protect (fun () ->
    let* result=Fs_compat.with_owned_inventory_root (Filename.dirname t.root) (fun anchor ->
      let owner_uid=Unix.geteuid () in
      let root=Filename.concat (Fs_compat.owned_inventory_root_path anchor) (Filename.basename t.root) in
      let directory=Filename.concat root tool_request_owners_directory in
      let observed=Fs_compat.with_owned_directory_inventory_if_present ~owner_uid ~inventory_root:anchor
        ~sync_directory:Unix.fsync directory (fun namespace names ->
          let rec scopes acc = function
            | [] ->
              let* current=Fs_compat.read_owned_directory ~owner_uid ~inventory_root:namespace
                ~ownership_root:directory directory |> owned_result in
              if current=names then Ok acc
              else Error "original request scope membership changed during inventory"
            | directory_name::rest ->
              if not (String_util.is_lowercase_sha256_hex directory_name) then
                Error "unknown directory in original request scope namespace"
              else
                let read_scope () =
                let path=Filename.concat (Fs_compat.owned_inventory_root_path namespace) directory_name in
                let* observed=Fs_compat.with_owned_directory_inventory_if_present ~owner_uid
                  ~inventory_root:namespace ~sync_directory:Unix.fsync path (fun held files ->
                    let rec read acc = function
                      | [] ->
                        let* current=Fs_compat.read_owned_directory ~owner_uid ~inventory_root:held
                          ~ownership_root:path path |> owned_result in
                        if current=files then Ok acc
                        else Error "original request scope changed during inventory"
                      | file_name::tail -> match tool_request_owner_entry file_name with
                        | Staged_entry ->
                          let* () = if check_staged then inspect_staged_tool_request ~owner_uid held file_name else Ok () in
                          read acc tail
                        | Unknown_entry -> Error "unknown entry in original request namespace"
                        | Record_entry ->
                          let* json = if serialize_scopes then
                              read_owned_tool_request ~sync_file:Unix.fsync ~sync_parent:Unix.fsync ~owner_uid held file_name
                            else read_startup_tool_request ~owner_uid held file_name in
                          let* acc=f acc ~directory_name ~file_name json in
                          read acc tail in
                    read acc files) |> owned_result in
                let* acc=match observed with
                  | None -> Error "listed original request scope disappeared during inventory"
                  | Some result -> result in
                Ok acc in
                let* acc = if serialize_scopes then
                    with_tool_request_owner_directory_serialization t ~directory_name read_scope
                  else read_scope () in
                scopes acc rest in
          scopes init names) |> owned_result in
      Ok observed) |> owned_result in
    let* result=result in
    match result with None -> Ok init | Some result -> result) in
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> blocking ()
  | Fs_compat.Eio_fiber ->
    let result=Systhread_host.run ~label:"addon-original-request-sweep" blocking in
    Eio.Fiber.check ();result

let fold_tool_request_owner_inventory_all t ~init ~f =
  fold_tool_request_owner_inventory_all_with ~check_staged:false ~serialize_scopes:true t ~init ~f

let fold_startup_tool_request_owners t ~init ~f =
  fold_tool_request_owner_inventory_all_with ~check_staged:true ~serialize_scopes:false t ~init ~f

let tool_request_owner_inventory_all t =
  let* rows =
    fold_tool_request_owner_inventory_all t ~init:[]
      ~f:(fun rows ~directory_name ~file_name json ->
        Ok ((directory_name,file_name,json)::rows))
  in
  Ok (List.rev rows)

(* These inventories are used only while the caller excludes all original
   request writers. The complete read finishes before any cleanup effect. *)
let inventory_directory ~owner_uid ~parent ~path f =
  let* observed = Fs_compat.with_owned_directory_inventory_if_present ~owner_uid
    ~inventory_root:parent ~sync_directory:Unix.fsync path (fun held names ->
      let* value = f held names in
      let* current = Fs_compat.read_owned_directory ~owner_uid ~inventory_root:held
        ~ownership_root:path path |> owned_result in
      if current = names then Ok value else Error "original request inventory changed")
    |> owned_result in
  match observed with None -> Ok None | Some result -> Result.map Option.some result

let require_inventory = function
  | None -> Error "a listed original request directory disappeared"
  | Some value -> Ok value

let inventory_blocking ~label work =
  let blocking () = protect work in
  match Fs_compat.execution_context () with
  | Fs_compat.Non_eio -> blocking ()
  | Fs_compat.Eio_fiber ->
    let result = Systhread_host.run ~label blocking in
    Eio.Fiber.check (); result

let fold_archived_tool_request_owners t ~init ~f =
  inventory_blocking ~label:"addon-archived-original-inventory" (fun () ->
    let* result = Fs_compat.with_owned_inventory_root (Filename.dirname t.root) (fun anchor ->
      let owner_uid = Unix.geteuid () in
      let root = Filename.concat (Fs_compat.owned_inventory_root_path anchor) (Filename.basename t.root) in
      let archive = Filename.concat root tool_request_archive_directory in
      let result = inventory_directory ~owner_uid ~parent:anchor ~path:archive (fun scopes names ->
        let rec scan_scopes acc = function
          | [] -> Ok acc
          | scope_name :: rest ->
            if not (String_util.is_lowercase_sha256_hex scope_name) then
              Error "unknown directory in settled original request namespace"
            else
              let path = Filename.concat (Fs_compat.owned_inventory_root_path scopes) scope_name in
              let* days = inventory_directory ~owner_uid ~parent:scopes ~path (fun scope dates ->
                let rec scan_days acc = function
                  | [] -> Ok acc
                  | date :: tail ->
                    let* () = settled_day date in
                    let path = Filename.concat (Fs_compat.owned_inventory_root_path scope) date in
                    let* day = inventory_directory ~owner_uid ~parent:scope ~path (fun held entries ->
                      let* () = if List.for_all (fun name -> name = "records" || name = "bodies") entries
                        then Ok () else Error "unknown directory in settled original request day" in
                      let* () = if not (List.mem "bodies" entries) then Ok () else
                        let bodies = Filename.concat (Fs_compat.owned_inventory_root_path held) "bodies" in
                        let* result = inventory_directory ~owner_uid ~parent:held ~path:bodies (fun _ _ -> Ok ()) in
                        require_inventory result in
                      if not (List.mem "records" entries) then Ok acc else
                      let records = Filename.concat (Fs_compat.owned_inventory_root_path held) "records" in
                      let* result = inventory_directory ~owner_uid ~parent:held ~path:records (fun files names ->
                        let rec scan_records acc = function
                          | [] -> Ok acc
                          | name :: remaining ->
                            (match tool_request_owner_entry name with
                             | Staged_entry ->
                               let* () = inspect_staged_tool_request ~owner_uid files name in
                               scan_records acc remaining
                             | Unknown_entry -> Error "unknown entry in settled original request records"
                             | Record_entry ->
                               let* json = read_startup_tool_request ~owner_uid files name in
                               let* acc = f acc ~directory_name:scope_name ~file_name:name json in
                               scan_records acc remaining) in
                        scan_records acc names) in
                      require_inventory result) in
                    let* acc = require_inventory day in
                    scan_days acc tail in
                scan_days acc dates) in
              let* acc = require_inventory days in
              scan_scopes acc rest in
        scan_scopes init names) in
      Ok result) |> owned_result in
    let* result = result in
    match result with None -> Ok init | Some value -> Ok value)

type tool_request_body_entry = {
  scope_directory : string;
  request_digest : string;
  snapshot : Unix.stats;
}

let tool_request_body_inventory_all t =
  inventory_blocking ~label:"addon-original-body-inventory" (fun () ->
    let* result = Fs_compat.with_owned_inventory_root (Filename.dirname t.root) (fun anchor ->
      let owner_uid = Unix.geteuid () in
      let root = Filename.concat (Fs_compat.owned_inventory_root_path anchor) (Filename.basename t.root) in
      let directory = Filename.concat root tool_request_bodies_directory in
      let result = inventory_directory ~owner_uid ~parent:anchor ~path:directory (fun scopes names ->
        let rec scan_scopes acc = function
          | [] -> Ok (List.rev acc)
          | scope_directory :: rest ->
            if not (String_util.is_lowercase_sha256_hex scope_directory) then
              Error "unknown directory in original request body namespace"
            else
              let path = Filename.concat (Fs_compat.owned_inventory_root_path scopes) scope_directory in
              let* scope = inventory_directory ~owner_uid ~parent:scopes ~path (fun held names ->
                let rec scan_files acc = function
                  | [] -> Ok acc
                  | name :: tail when Fs_compat.is_atomic_orphan_name name ->
                    let* () = inspect_staged_tool_request ~owner_uid held name in
                    scan_files acc tail
                  | name :: tail ->
                    let* request_digest = match Filename.chop_suffix_opt ~suffix:".json" name with
                      | Some digest when String_util.is_lowercase_sha256_hex digest -> Ok digest
                      | Some _ | None -> Error "unknown file in original request body namespace" in
                    let* content_digest,snapshot = inspect_tool_request_body ~owner_uid held name in
                    if not (String.equal content_digest request_digest) then
                      Error "original request body does not match its digest"
                    else scan_files ({scope_directory;request_digest;snapshot} :: acc) tail in
                scan_files acc names) in
              let* acc = require_inventory scope in
              scan_scopes acc rest in
        scan_scopes [] names) in
      Ok result) |> owned_result in
    let* result = result in
    match result with None -> Ok [] | Some value -> Ok value)

let remove_inventoried_tool_request_body t entry =
  inventory_blocking ~label:"addon-original-body-remove" (fun () ->
    let* relative = Fs_compat.owned_relative_path [Filename.basename t.root;
      tool_request_bodies_directory;entry.scope_directory;entry.request_digest ^ ".json"] in
    Fs_compat.with_owned_inventory_root (Filename.dirname t.root) (fun anchor ->
      Fs_compat.remove_owned_inventory_regular_file ~expected:entry.snapshot anchor relative) |> owned_result)

let host_result_path ~instance_id ~request_id =
  Filename.concat "host-results" (Filename.concat (digest instance_id) (digest request_id ^ ".json"))
let save_host_result t ~instance_id ~request_id json =
  write t (host_result_path ~instance_id ~request_id) (Yojson.Safe.to_string json)
let load_host_result t ~instance_id ~request_id =
  load_record_with ~what:"host result link" ~sync_file:Unix.fsync ~sync_parent:Unix.fsync t
    (host_result_path ~instance_id ~request_id)

type observation_write_error =
  | Observation_rejected of string
  | Publication_failed of { failure : Fs_compat.atomic_replace_failure;
      verification_error : string option }
let observation_write_error_to_string = function
  | Observation_rejected detail -> detail
  | Publication_failed {failure;verification_error} ->
      let detail=Fs_compat.atomic_replace_failure_to_string failure in
      match verification_error with None -> detail
      | Some error -> detail ^ "; publication verification: " ^ error
let append_observation_with ~replace_file t ~instance_id ~seq ~sources output =
  let json = `Assoc ["sources", sources; "output", output_to_json output] in
  let bytes = Yojson.Safe.to_string json in
  let relative = Filename.concat (observation_dir instance_id) (Printf.sprintf "%020d.json" seq) in
  let* path = protect (fun () ->
    let path = Filename.concat t.root relative in
    if Fs_compat.file_exists path then Error "observation sequence already committed"
    else (Fs_compat.mkdir_p (Filename.dirname path); Ok path))
    |> Result.map_error (fun detail -> Observation_rejected detail) in
  match replace_file path bytes with
  | Ok () -> Ok ()
  | Error (failure : Fs_compat.atomic_replace_failure) ->
    match failure.Fs_compat.stage with
    | Fs_compat.Before_rename -> Error (Publication_failed {failure;verification_error=None})
    | Fs_compat.After_rename ->
      let verification_error = match bounded_file_with ~sync_file:Unix.fsync ~sync_parent:Unix.fsync
          ~verification:Visible ~max_bytes:(String.length bytes) path with
        | Ok visible when visible=bytes -> None
        | Ok _ -> Some "published bytes differ from the proposed observation"
        | Error detail -> Some detail in
      Error (Publication_failed {failure;verification_error})
let append_observation = append_observation_with ~replace_file:Fs_compat.save_file_atomic_strict_staged
(* The sequence is part of the row identity issued by the host, so evidence
   selection can read exactly its files without scanning unrelated history. *)
let sequence_of_row ~instance_id id =
  let prefix = instance_id ^ "/" in
  if not (String.starts_with ~prefix id) then Error "row belongs to a different instance"
  else
    let offset = String.length prefix in
    match String.index_from_opt id offset '/' with
    | None -> Error "row identity has no observation sequence"
    | Some ending ->
        let digits = String.sub id offset (ending - offset) in
        (match int_of_string_opt digits with
         | Some seq when seq > 0 && digits = string_of_int seq && ending + 1 < String.length id -> Ok seq
         | _ -> Error "row identity has an invalid observation sequence")
let load_sampling_request_bounded_with ~sync_file ~sync_parent ~budget t ~instance_id ~request_id = bounded_protect (fun () ->
  let path_in directory = Filename.concat t.root
    (Filename.concat (directory instance_id) (digest request_id ^ ".json")) in
  let outcome_path = path_in sampling_outcome_directory in
  let path = match Fs_compat.exact_path_kind outcome_path with
    | Fs_compat.Exact_missing -> path_in sampling_directory
    | Fs_compat.Exact_unknown | Fs_compat.Exact_kind _ -> outcome_path in
  match Fs_compat.exact_path_kind path with
  | Fs_compat.Exact_missing -> Ok None
  | Fs_compat.Exact_unknown | Fs_compat.Exact_kind _ -> let* bytes = with_record_fd path (fun fd ->
        let stat = Unix.fstat fd in
        if stat.Unix.st_kind <> Unix.S_REG then
          Error (Read_failed "retained file is not a regular file")
        else if stat.Unix.st_size > budget.remaining then Error Read_limit_exceeded
        else begin
          budget.remaining <- budget.remaining - stat.Unix.st_size;
          Result.bind (read_verified_record ~sync_file ~sync_parent ~verification:Durable path fd stat)
            changed_during_verification
          |> Result.map_error (fun detail -> Read_failed detail)
        end) in
      try Ok (Some (Yojson.Safe.from_string bytes))
      with Yojson.Json_error detail -> Error (Read_failed detail))
let load_sampling_request_bounded =
  load_sampling_request_bounded_with ~sync_file:Unix.fsync ~sync_parent:Unix.fsync

let record_path t instance_id seq =
  Filename.concat t.root (Filename.concat (observation_dir instance_id) (Printf.sprintf "%020d.json" seq))
let decode_record bytes =
  protect (fun () ->
    match Yojson.Safe.from_string bytes with
    | `Assoc fields ->
        (match List.assoc_opt "sources" fields, List.assoc_opt "output" fields with
         | Some sources, Some json ->
             let* output = output_of_json json in Ok (sources, output)
         | _ -> Error "invalid retained observation")
    | _ -> Error "invalid retained observation")
(* The records a binding names. Sequences are dense from 1 and a binding names
   only committed ones, so they are read by name without listing the
   directory (RFC lane-addon-observation-commits-at-the-binding). *)
let observations t ~instance_id ~through =
  let rec loop acc seq =
    if seq > through then Ok (List.rev acc)
    else
      let* bytes = protect (fun () -> Ok (Fs_compat.load_file (record_path t instance_id seq))) in
      let* record = decode_record bytes in
      loop (record :: acc) (seq + 1) in
  loop [] 1
type unreadable_binding = { path : string; detail : string; contents : Yojson.Safe.t option }
type binding_reading = { readable : Yojson.Safe.t list; unreadable : unreadable_binding list }
(* The binding's sequence is the instance's committed observation: the binding
   replace is the commit, so readers stop there and never list observation
   directories. Each file is read on its own: a file that is not JSON, is not
   an object, or lacks an instance id or sequence is listed in [unreadable] and
   never hides its siblings. Only a directory that cannot be listed or synced
   fails the whole reading. *)
let binding_sequence = function
  | `Assoc fields ->
      (match List.assoc_opt "instance_id" fields, List.assoc_opt "observation_seq" fields with
       | Some (`String instance_id), Some (`Int sequence) when sequence >= 0 -> Ok (instance_id, sequence, fields)
       | _ -> Error "invalid retained binding sequence")
  | _ -> Error "invalid retained binding"
(* One binding file, classified the same way for the whole and the
   single-instance reading. A binding removed between a listing and this read
   is absent, the same as one never listed. *)
let read_binding_file path =
  let unreadable ?contents detail = Some (Error { path; detail; contents }) in
  match protect (fun () -> Ok (Fs_compat.load_file_opt path)) with
  | Error detail -> unreadable detail
  | Ok None -> None
  | Ok (Some bytes) ->
      (match Yojson.Safe.from_string bytes with
       | exception Yojson.Json_error detail -> unreadable detail
       | json ->
           (match binding_sequence json with
            | Ok (_, _, _) -> Some (Ok json)
            | Error detail -> unreadable ~contents:json detail))
(* A reading also authorizes reconciliation. On a cold process, confirm the
   publication of terminal records/absence before admitting replacement. *)
let confirm_bindings_directory t =
  protect (fun () ->
    sync_existing_parent ~sync_parent:sync_parent_directory (Filename.concat t.root bindings_directory);
    Ok ())
let read_bindings t =
  let directory = Filename.concat t.root bindings_directory in
  let* names = protect (fun () ->
    match Fs_compat.exact_path_kind directory with
    | Fs_compat.Exact_missing -> Ok []
    | Fs_compat.Exact_unknown | Fs_compat.Exact_kind _ -> Ok (Fs_compat.read_dir directory |> List.sort String.compare)) in
  let reading = List.fold_left (fun reading name ->
    if not (Filename.check_suffix name ".json") then reading
    else match read_binding_file (Filename.concat directory name) with
      | None -> reading
      | Some (Ok value) -> { reading with readable = value :: reading.readable }
      | Some (Error issue) -> { reading with unreadable = issue :: reading.unreadable })
    { readable = []; unreadable = [] } names in
  let* () = confirm_bindings_directory t in
  Ok { readable = List.rev reading.readable; unreadable = List.rev reading.unreadable }
(* The binding path is fixed by the instance id, so a caller that needs one
   instance opens only its file. *)
let read_binding t ~instance_id =
  let directory = Filename.concat t.root bindings_directory in
  (* A binding directory that cannot be listed fails the whole reading, so it
     fails this one too instead of passing for an absent binding. *)
  let* present = match Fs_compat.exact_path_kind directory with
    | Fs_compat.Exact_missing -> Ok false
    | Fs_compat.Exact_kind Unix.S_DIR | Fs_compat.Exact_unknown -> Ok true
    | Fs_compat.Exact_kind (Unix.S_REG | Unix.S_LNK | Unix.S_CHR | Unix.S_BLK | Unix.S_FIFO | Unix.S_SOCK) ->
        Error (directory ^ ": binding directory is not a directory") in
  let reading = if not present then None
    else read_binding_file (Filename.concat t.root (binding_path instance_id)) in
  let reading = match reading with
    | None -> { readable = []; unreadable = [] }
    | Some (Ok value) -> { readable = [value]; unreadable = [] }
    | Some (Error issue) -> { readable = []; unreadable = [issue] } in
  let* () = confirm_bindings_directory t in
  Ok reading
(* The whole-store reading for a caller that cannot use a partial one. *)
let bindings t =
  let* reading = read_bindings t in
  match reading.unreadable with
  | [] -> Ok reading.readable
  | issue :: _ -> Error (issue.path ^ ": " ^ issue.detail)
let retained_read_limit max_bytes =
  let envelope_bytes = String.length {|{"sources":,"output":}|} in
  if max_bytes <= 0 || max_bytes > (max_int - envelope_bytes) / 2
  then Error "invalid retained record byte envelope"
  (* Ingress sources and namespaced output each have the declared bound. *)
  else Ok (2 * max_bytes + envelope_bytes)
let read_observation_with ~sync_file ~sync_parent ~instance_id ~seq ~max_bytes t =
  if seq <= 0 then Error "observation sequence must be positive" else
  let* max_record_bytes = retained_read_limit max_bytes in
  let* bytes = bounded_file_with ~sync_file ~sync_parent ~verification:Durable
    ~max_bytes:max_record_bytes (record_path t instance_id seq) in
  let* _,output = decode_record bytes in
  Ok output
let read_observation = read_observation_with ~sync_file:Unix.fsync ~sync_parent:Unix.fsync
let query_observations t ~instance_id ~expected_seq ~max_bytes ~since ~until ~lane_id =
  let* max_record_bytes = retained_read_limit max_bytes in
  (* [expected_seq] is the binding's committed sequence; a file above it is
     not committed and is not read. *)
  let maximum = expected_seq in
  let matches (row : row) =
    Option.fold ~none:true ~some:(String.equal row.lane_id) lane_id
    && Option.fold ~none:true ~some:(fun time -> row.observed_at >= time) since
    && Option.fold ~none:true ~some:(fun time -> row.observed_at <= time) until in
  let time = function None -> "unbounded" | Some value -> string_of_float value in
  let query_coverage ~last ~rows_complete ~coverage_complete ~readable = {
    source_id = "retained:" ^ instance_id; incarnation = instance_id;
    cursor = Some (Printf.sprintf "scanned:%d/of:%d" last maximum);
    complete = rows_complete && coverage_complete && readable;
    detail = Some (Printf.sprintf
      "window [%s, %s]; rows and source coverage inspected through %d/of:%d; %s; %s; %s"
      (time since) (time until) last maximum
      (if rows_complete then "no matching row records omitted"
       else "matching row records omitted by byte envelope")
      (if coverage_complete then "all inspected source coverage returned"
       else "source coverage omitted by byte envelope")
      (if readable then "retained observations readable"
       else "a retained observation is unreadable")) } in
  (* Reserve the longest coverage receipt before accepting any rows. *)
  let reserve = String.length (Yojson.Safe.to_string
    (output_to_json { rows = []; coverage = [query_coverage ~last:maximum
      ~rows_complete:false ~coverage_complete:false ~readable:false] })) in
  if max_bytes <= reserve then Error "query byte envelope cannot contain its coverage receipt"
  else
    let read seq = Result.bind
      (bounded_file ~max_bytes:max_record_bytes (record_path t instance_id seq)) decode_record in
    let encoded_size output = String.length (Yojson.Safe.to_string (output_to_json output)) in
    (* Coverage from old, unselected records must not consume the row budget.
       Rows remain a bounded prefix of the matching retained records. *)
    let rec scan_rows seq remaining rows readable =
      if seq > maximum then maximum, remaining, rows, true, readable
      else
        match read seq with
        | Error _ -> scan_rows (seq + 1) remaining rows false
        | Ok (_, output) ->
            let selected = List.filter matches output.rows in
            if selected = [] then scan_rows (seq + 1) remaining rows readable
            else
              let bytes = encoded_size { rows = selected; coverage = [] } in
              if bytes > remaining then
                seq - 1, remaining, rows, false, readable
              else scan_rows (seq + 1) (remaining - bytes)
                (List.rev_append selected rows) readable in
    let last, remaining, rows, rows_complete, readable =
      scan_rows 1 (max_bytes - reserve) [] true in
    (* Both buffers are bounded independently by the remaining response space.
       A later selected record can therefore retain its coverage even when old
       diagnostics fill the deferred buffer. Whole JSON envelopes are counted
       conservatively for each entry, including array separators. *)
    let retain_coverage buffer entries =
      List.fold_left (fun (remaining, retained, complete) entry ->
        let bytes = encoded_size { rows = []; coverage = [entry] } in
        if bytes > remaining then remaining, retained, false
        else remaining - bytes, entry :: retained, complete) buffer entries in
    let rec scan_coverage seq selected deferred readable =
      if seq > last then selected, deferred, readable
      else match read seq with
        | Error _ -> scan_coverage (seq + 1) selected deferred false
        | Ok (_, output) ->
            if List.exists matches output.rows then
              scan_coverage (seq + 1) (retain_coverage selected output.coverage) deferred readable
            else
              scan_coverage (seq + 1) selected (retain_coverage deferred output.coverage) readable in
    let (remaining, selected, selected_complete), (_, deferred, deferred_complete), readable =
      scan_coverage 1 (remaining, [], true) (remaining, [], true) readable in
    let _, coverage, coverage_complete = retain_coverage
      (remaining, selected, selected_complete && deferred_complete) (List.rev deferred) in
    Ok { rows = List.rev rows; coverage = List.rev coverage @
      [query_coverage ~last ~rows_complete ~coverage_complete ~readable] }
module Row_ids = Set.Make (String)
let retained_reference = function
  | `Assoc fields ->
      (match List.assoc_opt "uri" fields, List.assoc_opt "sha256" fields with
       | Some (`String uri), Some (`String hash) -> Ok { uri; sha256 = Some hash }
       | _ -> Error "retained evidence requires its URI and SHA-256")
  | _ -> Error "retained evidence requires an object"

(* Traverse only the selected record's structured references, never the bodies
   of referenced source files. File/HTTP URIs and plugin paths are data. *)
let rec source_references ?(declared_evidence=false) json =
  match json with
  | `Assoc fields ->
      (match List.assoc_opt "uri" fields with
       | Some (`String uri) when String.starts_with ~prefix:"lane-evidence:" uri
           || (declared_evidence && String.starts_with ~prefix:"lane-sequence:" uri) ->
           let* reference = retained_reference json in Ok [reference]
       | _ -> List.fold_left (fun acc (key, value) ->
           let* acc = acc in
           let* references = match key, value with
             | "evidence", `List values -> references_in_values ~declared_evidence:true values
             | _ -> source_references value in
           Ok (List.rev_append references acc)) (Ok []) fields)
  | `List values -> references_in_values values
  | _ -> Ok []
and references_in_values ?(declared_evidence=false) values =
  List.fold_left (fun acc value ->
    let* acc = acc in let* references = source_references ~declared_evidence value in
    Ok (List.rev_append references acc)) (Ok []) values

let freeze t ~instance_id ~binding ~row_ids =
  let requested = Row_ids.of_list row_ids in
  let* max_bytes =
    match binding with
    | `Assoc fields ->
        (match List.assoc_opt "package" fields with
         | Some (`Assoc package) ->
             (match List.assoc_opt "resources" package with
              | Some (`Assoc resources) ->
                  (match List.assoc_opt "max_reply_bytes" resources with
                   | Some (`Int bytes) when bytes > 0 -> Ok bytes
                   | _ -> Error "missing evidence query byte envelope")
              | _ -> Error "missing retained package resources")
         | _ -> Error "missing retained package")
    | _ -> Error "invalid retained binding" in
  let* max_record_bytes = retained_read_limit max_bytes in
  (* A row id names its sequence, so a caller could name a file the binding
     has not committed. Only committed sequences are evidence. *)
  let* committed = match binding with
    | `Assoc fields -> (match List.assoc_opt "observation_seq" fields with
        | Some (`Int seq) when seq >= 0 -> Ok seq
        | _ -> Error "missing retained binding sequence")
    | _ -> Error "invalid retained binding" in
  let rec sequences acc = function
    | [] -> Ok (List.sort_uniq Int.compare acc)
    | id :: rest -> let* seq = sequence_of_row ~instance_id id in
        if seq > committed then Error "selected row is not committed by the binding"
        else sequences (seq :: acc) rest in
  let* sequences = sequences [] row_ids in
  let base_bundle observations = `Assoc ["instance_id", `String instance_id; "binding", binding;
    "row_ids", `List (List.map (fun id -> `String id) row_ids); "observations", `List observations] in
  let base_size = String.length (Yojson.Safe.to_string (base_bundle [])) in
  if row_ids = [] then Error "select at least one row"
  else if List.length row_ids <> Row_ids.cardinal requested then Error "duplicate selected row identity"
  else if base_size > max_bytes then Error "selected evidence metadata exceeds package byte envelope"
  else
    let validated_sequences = Hashtbl.create 16 in
    let rec selected_records acc found remaining = function
      | [] -> Ok (List.rev acc, found)
      | seq :: rest ->
          let* bytes = bounded_file ~max_bytes:max_record_bytes (record_path t instance_id seq) in
          let* _, output = decode_record bytes in
          let* references = source_references (Yojson.Safe.from_string bytes) in
          let* () = List.fold_left (fun result reference ->
            let* () = result in
            let* kind, _ = retained_address reference in
            match kind with Blob -> Ok ()
            | Sequence -> fold_sequence ~seen:validated_sequences t reference ~init:()
                ~f:(fun () _ _ -> Ok ())) (Ok ()) references in
          let matching = List.filter (fun (row : row) -> Row_ids.mem row.id requested) output.rows in
          let found = List.fold_left (fun ids (row : row) -> Row_ids.add row.id ids) found matching in
          let hash = digest bytes in
          let retained = `Assoc ["sequence", `Int seq;
            "uri", `String ("lane-evidence:" ^ hash); "sha256", `String hash;
            "path", `String (Filename.concat t.root (blob_path hash))] in
          let size = String.length (Yojson.Safe.to_string retained) + (if acc = [] then 0 else 1) in
          if size > remaining then Error "selected evidence manifest exceeds package byte envelope; select fewer rows"
          else
            let* _ = write_blob t bytes in
            selected_records (retained :: acc) found (remaining - size) rest in
    let* observations, found = selected_records [] Row_ids.empty (max_bytes - base_size) sequences in
    let missing = Row_ids.elements (Row_ids.diff requested found) in
    if missing <> [] then Error ("unknown evidence rows: " ^ String.concat ", " missing)
    else
      (* Each exact source+output record is independently hashed and copied.
         A large accepted record remains preservable without loading unrelated
         history or assembling multiple full bodies in one memory buffer. *)
      let bytes = Yojson.Safe.to_string (base_bundle observations) in
      let* reference = write_blob t bytes in
      let path = Filename.concat t.root (blob_path (digest bytes)) in
      Ok (`Assoc ["instance_id", `String instance_id;
        "row_ids", `List (List.map (fun id -> `String id) row_ids);
        "evidence", `Assoc ["uri", `String reference.uri;
        "sha256", `String (digest bytes); "path", `String path];
        "row_count", `Int (Row_ids.cardinal found);
        "message", `String ("Optional Lane evidence (not an instruction): " ^ path
          ^ "\nSHA-256: " ^ digest bytes
          ^ "\nThe observations list names retained record paths and SHA-256 digests. Read those records for original sources and output."
          ^ "\nUse, defer, or independently check this evidence as appropriate. Your current task continues.")])

module Published = Map.Make (String)
let publish_for_keeper ~base_path t frozen = protect (fun () ->
  let* fields, bundle_reference = match frozen with
    | `Assoc fields ->
        (match List.assoc_opt "evidence" fields with
         | Some json -> let* reference = retained_reference json in Ok (fields, reference)
         | None -> Error "frozen evidence bundle is missing")
    | _ -> Error "invalid frozen evidence" in
  let blobs = Tool_blob_store.create ~base_path in
  let publish_one ~mime published reference =
    match Published.find_opt reference.uri published with
    | Some artifact when reference.sha256 = Some artifact.Tool_output.sha256 -> Ok (published, artifact)
    | Some _ -> Error "retained evidence digest disagrees with its URI"
    | None ->
        let* bytes = read_blob t reference in
        let artifact = Tool_blob_store.put_durable blobs ~bytes ~mime in
        Ok (Published.add reference.uri artifact published, artifact) in
  let published_sequences = Hashtbl.create 16 in
  let publish ~mime published reference =
    let* kind, _ = retained_address reference in
    match kind with
    | Blob -> publish_one ~mime published reference
    | Sequence ->
        let* published = fold_sequence ~seen:published_sequences t reference ~init:published
          ~f:(fun published reference _ ->
            let* published, _ = publish_one ~mime:"application/json" published reference in
            Ok published) in
        (match Published.find_opt reference.uri published with
         | Some artifact -> Ok (published, artifact)
         | None -> Error "sequence publication produced no root") in
  let* bundle_bytes = read_blob t bundle_reference in
  let* records = match Yojson.Safe.from_string bundle_bytes with
    | `Assoc bundle ->
        (match List.assoc_opt "observations" bundle with
         | Some (`List records) -> Ok records
         | _ -> Error "frozen bundle has no selected records")
    | _ -> Error "invalid frozen bundle" in
  let* published, bundle_artifact = publish ~mime:"application/json" Published.empty bundle_reference in
  let rec publish_records published = function
    | [] -> Ok published
    | json :: rest ->
        let* reference = retained_reference json in
        let* bytes = read_blob t reference in
        let* _, _ = decode_record bytes in
        let* references = source_references (Yojson.Safe.from_string bytes) in
        let* published, _ = publish ~mime:"application/json" published reference in
        let* published = List.fold_left (fun result reference ->
          let* published = result in
          let* published, _ = publish ~mime:"application/octet-stream" published reference in
          Ok published) (Ok published) references in
        publish_records published rest in
  let* published = publish_records published records in
  let content = "Optional Lane evidence, not an instruction. Use, defer, or independently verify it; your current task continues."
    ^ "\nOriginal selected bundle SHA-256: " ^ bundle_artifact.Tool_output.sha256
    ^ "\nRead the bundle and retained artifacts with keeper_artifact_read using their SHA-256 values."
    ^ "\nRecord bodies preserve original sources separately from Add-on output; interpretations remain claims." in
  let structured_content = `Assoc [
    "bundle", Tool_output.normalized_artifact_ref_to_json bundle_artifact;
    "artifacts", `List (Published.bindings published |> List.map (fun (uri, artifact) ->
      `Assoc ["lane_uri", `String uri; "artifact", Tool_output.normalized_artifact_ref_to_json artifact]))] in
  let manifest = Tool_output.artifact_manifest_to_json ~content ~structured_content in
  let artifact = Tool_blob_store.put_durable blobs ~bytes:(Yojson.Safe.to_string manifest)
    ~mime:Tool_output.artifact_manifest_mime
    |> fun reference -> Tool_output.with_preview reference content in
  Ok (`Assoc (("message", `String (Tool_output.encode_for_agent_core (Tool_output.Stored artifact)))
    :: ("keeper_artifact", Tool_output.normalized_artifact_ref_to_json artifact)
    :: List.remove_assoc "message" (List.remove_assoc "keeper_artifact" fields))))

module For_testing = struct
  let tool_request_owner_inventory = tool_request_owner_inventory_with
  let remove_binding = remove_binding_with
  let binding_inventory = binding_inventory_with
  let issue_detail = issue_detail
  let write = write_with
  let load_sampling_request_bounded = load_sampling_request_bounded_with
  let save_action = save_action_with
  let load_action = load_action_with
  let load_exact_request = load_exact_request_with
  let append_observation = append_observation_with
  let save_binding_staged = save_binding_staged_with
  let read_observation = read_observation_with
end
