(** Memory_jsonl — Session-based JSONL file backend for OAS Memory.long_term_backend.

    Each session gets its own .jsonl file under [base_dir/memory/<agent_name>/].
    Lines are append-only; latest entry for a key wins on read.
    Tombstones (value=null) mark removals.

    File structure:
    {v <base_dir>/memory/<agent_name>/<session_id>.jsonl v}

    Line format:
    {v {"key":"institution","value":{...},"ts":1774000000.0} v}

    Tombstone format:
    {v {"key":"institution","value":null,"ts":1774000000.0} v}

    @since 2.132.0 *)

(** Maximum file size before logging a warning (50 MB). *)
let max_file_size = 50 * 1024 * 1024

(** Maximum single value size before truncation (1 MB). *)
let max_value_size = 1 * 1024 * 1024

(** Build the file path for a session.
    Returns [<base_dir>/memory/<agent_name>/<session_id>.jsonl]. *)
let session_path ~base_dir ~agent_name ~session_id =
  Filename.concat
    (Filename.concat
       (Filename.concat base_dir "memory")
       agent_name)
    (session_id ^ ".jsonl")

(** Ensure the directory for the session file exists. *)
let ensure_dir ~base_dir ~agent_name =
  let dir =
    Filename.concat
      (Filename.concat base_dir "memory")
      agent_name
  in
  Fs_compat.mkdir_p dir

(** Get current timestamp as float. *)
let now () = Time_compat.now ()

(** Encode a JSONL line. Truncates value if over [max_value_size]. *)
let encode_line ~key ~(value : Yojson.Safe.t option) : string =
  let ts = now () in
  let value_json = match value with
    | None -> `Null
    | Some v ->
      let s = Yojson.Safe.to_string v in
      if String.length s > max_value_size then begin
        Log.Memory.warn "memory_jsonl: value for key=%s exceeds 1MB (%d bytes), truncating"
          key (String.length s);
        let truncated = String.sub s 0 max_value_size in
        (* Wrap truncated string so it is valid JSON *)
        `String truncated
      end else v
  in
  let obj = `Assoc [
    ("key", `String key);
    ("value", value_json);
    ("ts", `Float ts);
  ] in
  Yojson.Safe.to_string obj ^ "\n"

(** Parse a single JSONL line into (key, value option, ts).
    Returns None if the line is malformed. *)
let parse_line (line : string) : (string * Yojson.Safe.t option * float) option =
  let trimmed = String.trim line in
  if String.length trimmed = 0 then None
  else
    try
      let json = Yojson.Safe.from_string trimmed in
      match json with
      | `Assoc fields ->
        let key = match List.assoc_opt "key" fields with
          | Some (`String k) -> Some k
          | _ -> None
        in
        let value = match List.assoc_opt "value" fields with
          | Some `Null -> None
          | Some v -> Some v
          | None -> None
        in
        let ts = match List.assoc_opt "ts" fields with
          | Some (`Float f) -> f
          | Some (`Int n) -> Float.of_int n
          | _ -> 0.0
        in
        (match key with
         | Some k -> Some (k, value, ts)
         | None -> None)
      | _ -> None
    with Yojson.Json_error _ -> None

(** Read all lines from a session file.
    Returns empty list if file does not exist.
    Logs a warning if file exceeds [max_file_size]. *)
let read_lines ~path : (string * Yojson.Safe.t option * float) list =
  if not (Fs_compat.file_exists path) then []
  else begin
    (* Size guard *)
    (try
       let stat = Unix.stat path in
       let size = stat.Unix.st_size in
       if size > max_file_size then
         Log.Memory.warn "memory_jsonl: file %s is %d bytes (>50MB)" path size
     with Unix.Unix_error _ -> ());
    let content = Fs_compat.load_file path in
    let lines = String.split_on_char '\n' content in
    List.filter_map parse_line lines
  end

(** Create a session-based JSONL [long_term_backend].

    @param base_dir The .masc directory path
    @param agent_name Agent identifier
    @param session_id Session identifier (e.g. "acd905b7") *)
let make_backend ~base_dir ~agent_name ~session_id
  : Agent_sdk.Memory.long_term_backend =
  let path = session_path ~base_dir ~agent_name ~session_id in

  let persist ~key json =
    try
      ensure_dir ~base_dir ~agent_name;
      let line = encode_line ~key ~value:(Some json) in
      Fs_compat.append_file path line;
      Ok ()
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      let msg = Printf.sprintf "memory_jsonl persist(%s) failed: %s"
          key (Printexc.to_string exn) in
      Log.Memory.error "%s" msg;
      Error msg
  in

  let retrieve ~key =
    try
      let entries = read_lines ~path in
      (* Fold over all entries; last match wins (file is oldest-first) *)
      let last_value = List.fold_left (fun acc (k, v, _ts) ->
          if k = key then Some v else acc
        ) None entries
      in
      (* Some (Some v) = value, Some None = tombstone, None = not found *)
      match last_value with
      | Some (Some v) -> Some v
      | Some None -> None  (* tombstone *)
      | None -> None       (* key never written *)
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Memory.error "memory_jsonl retrieve(%s) failed: %s"
        key (Printexc.to_string exn);
      None
  in

  let remove ~key =
    try
      ensure_dir ~base_dir ~agent_name;
      let line = encode_line ~key ~value:None in
      Fs_compat.append_file path line;
      Ok ()
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      let msg = Printf.sprintf "memory_jsonl remove(%s) failed: %s"
          key (Printexc.to_string exn) in
      Log.Memory.error "%s" msg;
      Error msg
  in

  let batch_persist pairs =
    let errors = ref [] in
    List.iter (fun (key, json) ->
      match persist ~key json with
      | Ok () -> ()
      | Error msg -> errors := msg :: !errors
    ) pairs;
    match !errors with
    | [] -> Ok ()
    | errs ->
      let first_err = match errs with e :: _ -> e | [] -> "unknown" in
      let msg = Printf.sprintf "memory_jsonl batch_persist: %d/%d failed: %s"
          (List.length errs) (List.length pairs)
          first_err in
      Error msg
  in

  let query ~prefix ~limit =
    try
      let entries = read_lines ~path in
      (* De-duplicate by key (latest wins), skip tombstones *)
      let tbl = Hashtbl.create 32 in
      List.iter (fun (key, value, ts) ->
        if String.length key >= String.length prefix
           && String.sub key 0 (String.length prefix) = prefix then
          Hashtbl.replace tbl key (value, ts)
      ) entries;
      (* Collect non-tombstone entries *)
      let results = Hashtbl.fold (fun key (value, ts) acc ->
        match value with
        | Some v -> (key, v, ts) :: acc
        | None -> acc  (* tombstone *)
      ) tbl [] in
      (* Sort by ts descending *)
      let sorted = List.sort (fun (_, _, t1) (_, _, t2) ->
        Float.compare t2 t1
      ) results in
      (* Take up to limit, return (key, json) pairs *)
      let rec take n acc = function
        | [] -> List.rev acc
        | _ when n <= 0 -> List.rev acc
        | (k, v, _ts) :: rest -> take (n - 1) ((k, v) :: acc) rest
      in
      take limit [] sorted
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      Log.Memory.error "memory_jsonl query(%s) failed: %s"
        prefix (Printexc.to_string exn);
      []
  in

  { Agent_sdk.Memory.persist; retrieve; remove; batch_persist; query }
