type writer_owner = {
  canonical_base_dir : string;
  append_lock : Cross_context_mutex.t;
  mutable latest_hash : string option;
}

type t = {
  base_dir : string;
  writer_owner : writer_owner;
}

module Writer_owner_key = struct
  type t = string

  let equal = String.equal
  let hash = Hashtbl.hash
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
  match List.rev (read_all_entries_from_base_dir base_dir) with
  | [] -> None
  | last :: _ -> Some (Envelope.hash_for_chain last)

let writer_owner_for_base_dir ~canonical_base_dir =
  (* Publish the canonical writer identity before reading its cursor. Every
     creator initializes under this owner's append lock below, so no append can
     overlap the first disk read and unrelated directories do not hold the
     process-wide registry mutex while doing I/O. *)
  Stdlib.Mutex.protect writer_owners_mutex (fun () ->
    match Writer_owner_table.find_opt writer_owners canonical_base_dir with
    | Some owner -> owner
    | None ->
      let owner =
        { canonical_base_dir
        ; append_lock = Cross_context_mutex.create ()
        ; latest_hash = None
        }
      in
      Writer_owner_table.clean writer_owners;
      Writer_owner_table.add writer_owners canonical_base_dir owner;
      owner)

let create ~base_dir =
  if not (Sys.file_exists base_dir) then Fs_compat.mkdir_p base_dir;
  let canonical_base_dir = Fs_compat.realpath base_dir in
  let writer_owner = writer_owner_for_base_dir ~canonical_base_dir in
  Cross_context_mutex.with_durable_lock writer_owner.append_lock (fun () ->
    writer_owner.latest_hash <- load_latest_hash ~base_dir:canonical_base_dir);
  { base_dir = canonical_base_dir; writer_owner }

let base_dir t = t.base_dir

let append t ~category ~payload =
  let owner = t.writer_owner in
  Cross_context_mutex.with_durable_lock owner.append_lock (fun () ->
    let entry = Envelope.make ~category ~payload ~prev_hash:owner.latest_hash in
    ignore
      (Jsonl_writer.append_dated_jsonl
         ~base_dir:owner.canonical_base_dir
         ~ts:entry.ts
         (Envelope.to_json entry)
        : Jsonl_writer.dated_path);
    owner.latest_hash <- Some (Envelope.hash_for_chain entry);
    entry)

let read_all_entries t =
  let owner = t.writer_owner in
  Cross_context_mutex.with_durable_lock owner.append_lock (fun () ->
    read_all_entries_from_base_dir owner.canonical_base_dir)

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
