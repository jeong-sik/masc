type directory_identity = {
  device_id : int;
  inode_id : int;
}

type writer_owner_key = {
  canonical_base_dir : string;
  directory_identity : directory_identity;
}

type writer_owner = {
  key : writer_owner_key;
  append_lock : Cross_context_mutex.t;
  mutable latest_hash : string option;
}

type t = {
  base_dir : string;
  writer_owner : writer_owner;
}

external open_directory_nofollow : string -> Unix.file_descr
  = "caml_masc_shared_audit_open_directory"

external mkdirat_if_missing : Unix.file_descr -> string -> unit
  = "caml_masc_shared_audit_mkdirat_if_missing"

external openat_directory_nofollow :
  Unix.file_descr -> string -> Unix.file_descr
  = "caml_masc_shared_audit_openat_directory"

external openat_append_file_nofollow :
  Unix.file_descr -> string -> Unix.file_descr
  = "caml_masc_shared_audit_openat_append_file"

module Writer_owner_key = struct
  type t = writer_owner_key

  let equal left right =
    String.equal left.canonical_base_dir right.canonical_base_dir
    && left.directory_identity = right.directory_identity

  let hash key =
    Hashtbl.hash
      ( key.canonical_base_dir
      , key.directory_identity.device_id
      , key.directory_identity.inode_id )
end

module Writer_owner_table = Ephemeron.K1.Make (Writer_owner_key)

(* The key is also held by every live [writer_owner]. Ephemeron ownership lets
   an inactive base directory disappear without an arbitrary registry cap,
   while every store for a live canonical directory resolves to one cursor and
   one cross-context append lock. *)
let writer_owners : writer_owner Writer_owner_table.t = Writer_owner_table.create 0
let writer_owners_mutex = Stdlib.Mutex.create ()

exception Corrupt_jsonl of {
  path : string;
  line_number : int;
  detail : string;
}

exception Base_directory_replaced of {
  path : string;
  expected_device_id : int;
  expected_inode_id : int;
  actual_device_id : int option;
  actual_inode_id : int option;
}

type verify_report = {
  entries_checked : int;
  failure : (int * string) option;
}

let parse_jsonl_line line =
  try Yojson.Safe.from_string line |> Envelope.of_json with
  | Yojson.Json_error msg -> Error msg

let read_jsonl_file path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let entries = ref [] in
      let line_number = ref 0 in
      (try
         while true do
           let line = input_line ic in
           incr line_number;
           if String.length line > 0 then
             match parse_jsonl_line line with
             | Ok env -> entries := env :: !entries
             | Error detail ->
               raise (Corrupt_jsonl { path; line_number = !line_number; detail })
         done
       with End_of_file -> ());
      List.rev !entries)

let read_latest_jsonl_entry path =
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let latest = ref None in
      let line_number = ref 0 in
      (try
         while true do
           let line = input_line ic in
           incr line_number;
           if String.length line > 0 then
             match parse_jsonl_line line with
             | Ok env -> latest := Some env
             | Error detail ->
               raise (Corrupt_jsonl { path; line_number = !line_number; detail })
         done
       with End_of_file -> ());
      !latest)

let verify_chain entries =
  let rec check idx prev = function
    | [] -> Ok ()
    | (e : Envelope.t) :: rest ->
      if e.prev_hash <> prev then
        Error (idx, Printf.sprintf "prev_hash mismatch at index %d" idx)
      else
        let h = Envelope.hash_for_chain e in
        check (idx + 1) (Some h) rest
  in
  check 0 None entries

let read_all_entries_from_base_dir base_dir =
  if not (Sys.file_exists base_dir) then []
  else if not (Sys.is_directory base_dir) then []
  else
    let entries = ref [] in
    let months =
      Sys.readdir base_dir
      |> Array.to_list
      |> List.filter (fun s -> String.length s = 7 && s.[4] = '-')
      |> List.sort String.compare
    in
    List.iter (fun m ->
      let m_dir = Filename.concat base_dir m in
      if Sys.is_directory m_dir then begin
        let days =
          Sys.readdir m_dir
          |> Array.to_list
          |> List.filter (fun s -> Filename.check_suffix s ".jsonl")
          |> List.sort String.compare
        in
        List.iter (fun d ->
          let path = Filename.concat m_dir d in
          List.iter (fun e -> entries := e :: !entries) (read_jsonl_file path)
        ) days
      end
    ) months;
    List.rev !entries

let load_latest_hash ~base_dir =
  if not (Sys.file_exists base_dir) then None
  else if not (Sys.is_directory base_dir) then None
  else
    let months =
      Sys.readdir base_dir
      |> Array.to_list
      |> List.filter (fun name -> String.length name = 7 && name.[4] = '-')
      |> List.sort (fun left right -> String.compare right left)
    in
    let rec find_in_months = function
      | [] -> None
      | month :: remaining_months ->
        let month_dir = Filename.concat base_dir month in
        if not (Sys.is_directory month_dir) then find_in_months remaining_months
        else
          let days =
            Sys.readdir month_dir
            |> Array.to_list
            |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
            |> List.sort (fun left right -> String.compare right left)
          in
          let rec find_in_days = function
            | [] -> find_in_months remaining_months
            | day :: remaining_days ->
              let path = Filename.concat month_dir day in
              (match read_latest_jsonl_entry path with
               | Some entry -> Some (Envelope.hash_for_chain entry)
               | None -> find_in_days remaining_days)
          in
          find_in_days days
    in
    find_in_months months

let directory_identity path =
  let stats = Unix.stat path in
  if stats.st_kind <> Unix.S_DIR then
    raise (Unix.Unix_error (Unix.ENOTDIR, "stat", path));
  { device_id = stats.st_dev; inode_id = stats.st_ino }

let current_directory_identity path =
  try Some (directory_identity path) with
  | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR), _, _) -> None

let ensure_owner_directory_identity owner =
  let expected = owner.key.directory_identity in
  match current_directory_identity owner.key.canonical_base_dir with
  | Some actual when actual = expected -> ()
  | actual ->
    raise
      (Base_directory_replaced
         { path = owner.key.canonical_base_dir
         ; expected_device_id = expected.device_id
         ; expected_inode_id = expected.inode_id
         ; actual_device_id = Option.map (fun identity -> identity.device_id) actual
         ; actual_inode_id = Option.map (fun identity -> identity.inode_id) actual
         })

let raise_base_directory_replaced owner actual =
  let expected = owner.key.directory_identity in
  raise
    (Base_directory_replaced
       { path = owner.key.canonical_base_dir
       ; expected_device_id = expected.device_id
       ; expected_inode_id = expected.inode_id
       ; actual_device_id = Option.map (fun identity -> identity.device_id) actual
       ; actual_inode_id = Option.map (fun identity -> identity.inode_id) actual
       })

let close_noerr descriptor =
  try Unix.close descriptor with
  | Unix.Unix_error _ -> ()

let with_descriptor open_descriptor use_descriptor =
  let descriptor = open_descriptor () in
  Fun.protect
    ~finally:(fun () -> close_noerr descriptor)
    (fun () -> use_descriptor descriptor)

let open_validated_base_directory owner =
  let descriptor =
    try open_directory_nofollow owner.key.canonical_base_dir with
    | Unix.Unix_error ((Unix.ENOENT | Unix.ENOTDIR | Unix.ELOOP), _, _) ->
      raise_base_directory_replaced owner
        (current_directory_identity owner.key.canonical_base_dir)
  in
  let stats =
    match Unix.fstat descriptor with
    | stats -> stats
    | exception exn ->
      close_noerr descriptor;
      raise exn
  in
  let actual = { device_id = stats.st_dev; inode_id = stats.st_ino } in
  if actual = owner.key.directory_identity then descriptor
  else begin
    close_noerr descriptor;
    raise_base_directory_replaced owner (Some actual)
  end

let rec write_all descriptor content offset =
  if offset < String.length content then
    match
      Unix.write_substring descriptor content offset
        (String.length content - offset)
    with
    | 0 ->
      raise
        (Unix.Unix_error
           (Unix.EIO, "write", "shared audit append made no progress"))
    | written -> write_all descriptor content (offset + written)
    | exception Unix.Unix_error (Unix.EINTR, _, _) ->
      write_all descriptor content offset

let append_entry_at_validated_directory owner entry =
  let dated =
    Jsonl_writer.dated_path
      ~base_dir:owner.key.canonical_base_dir
      ~ts:entry.Envelope.ts
  in
  let line = Yojson.Safe.to_string (Envelope.to_json entry) ^ "\n" in
  with_descriptor
    (fun () -> open_validated_base_directory owner)
    (fun base_descriptor ->
      mkdirat_if_missing base_descriptor dated.month_dir;
      with_descriptor
        (fun () ->
          openat_directory_nofollow base_descriptor dated.month_dir)
        (fun month_descriptor ->
          with_descriptor
            (fun () ->
              openat_append_file_nofollow month_descriptor dated.day_file)
            (fun day_descriptor -> write_all day_descriptor line 0)))

let writer_owner_for_key key =
  (* Publish the canonical writer identity before reading its cursor. Every
     creator initializes under this owner's append lock below, so no append can
     overlap the first disk read and unrelated directories do not hold the
     process-wide registry mutex while doing I/O. *)
  Stdlib.Mutex.protect writer_owners_mutex (fun () ->
    match Writer_owner_table.find_opt writer_owners key with
    | Some owner -> owner
    | None ->
      let owner =
        { key
        ; append_lock = Cross_context_mutex.create ()
        ; latest_hash = None
        }
      in
      Writer_owner_table.clean writer_owners;
      Writer_owner_table.add writer_owners key owner;
      owner)

let create ~base_dir =
  if not (Sys.file_exists base_dir) then Fs_compat.mkdir_p base_dir;
  let canonical_base_dir = Fs_compat.realpath base_dir in
  let key =
    { canonical_base_dir
    ; directory_identity = directory_identity canonical_base_dir
    }
  in
  let writer_owner = writer_owner_for_key key in
  Cross_context_mutex.with_durable_lock writer_owner.append_lock (fun () ->
    ensure_owner_directory_identity writer_owner;
    writer_owner.latest_hash <- load_latest_hash ~base_dir:canonical_base_dir);
  { base_dir = canonical_base_dir; writer_owner }

let base_dir t = t.base_dir

let append t ~category ~payload =
  let owner = t.writer_owner in
  Cross_context_mutex.with_durable_lock owner.append_lock (fun () ->
    let entry = Envelope.make ~category ~payload ~prev_hash:owner.latest_hash in
    append_entry_at_validated_directory owner entry;
    owner.latest_hash <- Some (Envelope.hash_for_chain entry);
    entry)

let read_all_entries t =
  let owner = t.writer_owner in
  Cross_context_mutex.with_durable_lock owner.append_lock (fun () ->
    ensure_owner_directory_identity owner;
    read_all_entries_from_base_dir owner.key.canonical_base_dir)

let recent t ~n =
  let all = read_all_entries t in
  let len = List.length all in
  if len <= n then all
  else
    let rec drop k l =
      if k <= 0 then l
      else match l with
        | [] -> []
        | _ :: r -> drop (k - 1) r
    in
    drop (len - n) all

let since t ~ts =
  read_all_entries t
  |> List.filter (fun (e : Envelope.t) -> e.ts >= ts)

let verify t =
  let entries = read_all_entries t in
  match verify_chain entries with
  | Ok () ->
    { entries_checked = List.length entries; failure = None }
  | Error (idx, reason) ->
    { entries_checked = idx; failure = Some (idx, reason) }
