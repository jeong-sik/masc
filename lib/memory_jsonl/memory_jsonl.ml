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

(** Observability hook fired on every [parse_line] silent drop with a
    closed-vocabulary reason label.  The leaf [masc_mcp_memory_jsonl]
    sub-library cannot depend on [Prometheus] (cycle), so emission is
    wired from [lib/coord.ml] at startup via this Atomic ref (mirrors
    [File_lock_eio.on_lock_attempt_fn] / [on_cas_retry_fn] pattern).

    [reason] is one of [no_key | not_assoc | json_parse_error] — bounded
    closed vocabulary.  Empty lines are intentionally not counted (file
    end newlines are benign).  RFC-0109 §5.1 Option A canary. *)
let on_parse_drop_fn : (reason:string -> unit) Atomic.t =
  Atomic.make (fun ~reason:_ -> ())

let observe_parse_drop ~reason =
  try (Atomic.get on_parse_drop_fn) ~reason
  with Eio.Cancel.Cancelled _ as e -> raise e | _ -> ()

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

(** Length of the inline preview embedded in the truncation marker (1 KB). *)
let truncation_preview_len = 1024

(** Classify a [Yojson.Safe.t] by its top-level constructor name.

    Used by [encode_line] when constructing a truncation marker so
    downstream decoders can recover what shape the original payload
    had before serialisation exceeded [max_value_size]. *)
let original_type_of_json (v : Yojson.Safe.t) : string =
  match v with
  | `Assoc _ -> "Assoc"
  | `List _ -> "List"
  | `String _ -> "String"
  | `Int _ -> "Int"
  | `Float _ -> "Float"
  | `Bool _ -> "Bool"
  | `Null -> "Null"
  | `Intlit _ -> "Intlit"

(** Encode a JSONL line. Truncates value if over [max_value_size]. *)
let encode_line ~key ~(value : Yojson.Safe.t option) : string =
  let ts = now () in
  let value_json = match value with
    | None -> `Null
    | Some v ->
      let s = Yojson.Safe.to_string v in
      if String.length s > max_value_size then begin
        (* Iter 6 (PR #15668) added the warn line below.  Iter 25
           closes the structural half by replacing the bare
           [`String truncated] payload — which silently violated the
           caller's value-type contract — with a typed-marker
           [`Assoc] that downstream decoders can recognise via
           [value_is_truncated_marker].  The marker carries the
           original constructor name, the original byte size, and a
           bounded preview so operators can correlate downstream
           parse failures with truncation events on persist. *)
        let original_type = original_type_of_json v in
        Log.Memory.warn
          "memory_jsonl: value for key=%s exceeds 1MB (%d bytes); \
           wrapping in typed truncation marker \
           (_truncated:true, _original_type=%s) — decoders must \
           branch via value_is_truncated_marker"
          key
          (String.length s)
          original_type;
        let preview_len = min (String.length s) truncation_preview_len in
        let preview = String.sub s 0 preview_len in
        `Assoc [
          ("_truncated", `Bool true);
          ("_original_type", `String original_type);
          ("_original_size_bytes", `Int (String.length s));
          ("_preview", `String preview);
        ]
      end else v
  in
  let obj = `Assoc [
    ("key", `String key);
    ("value", value_json);
    ("ts", `Float ts);
  ] in
  Yojson.Safe.to_string obj ^ "\n"

(** Recognise a typed truncation marker produced by [encode_line] when
    the serialised value exceeded [max_value_size].

    A marker is an [`Assoc] whose [_truncated] field is exactly
    [`Bool true].  Legacy bare-[`String] truncated entries written
    before iter 25 will NOT be recognised — those continue to decode
    as plain strings, which matches their existing handling on read.

    Discrimination is purely structural (Yojson constructor + Bool
    field equality) — no substring matching on payload content. *)
let value_is_truncated_marker (v : Yojson.Safe.t) : bool =
  match v with
  | `Assoc fields ->
    (match List.assoc_opt "_truncated" fields with
     | Some (`Bool true) -> true
     | _ -> false)
  | _ -> false

(** Return the inline preview (first ~[truncation_preview_len] bytes
    of the original serialised payload) if [v] is a truncation
    marker, [None] otherwise. *)
let truncation_marker_preview (v : Yojson.Safe.t) : string option =
  if not (value_is_truncated_marker v) then None
  else
    match v with
    | `Assoc fields ->
      (match List.assoc_opt "_preview" fields with
       | Some (`String s) -> Some s
       | _ -> None)
    | _ -> None

(** Return the original payload's top-level constructor name
    ("Assoc"/"List"/"String"/...) if [v] is a truncation marker,
    [None] otherwise. *)
let truncation_marker_original_type (v : Yojson.Safe.t) : string option =
  if not (value_is_truncated_marker v) then None
  else
    match v with
    | `Assoc fields ->
      (match List.assoc_opt "_original_type" fields with
       | Some (`String s) -> Some s
       | _ -> None)
    | _ -> None

(** Return the original payload's serialised byte size if [v] is a
    truncation marker, [None] otherwise. *)
let truncation_marker_original_size_bytes (v : Yojson.Safe.t) : int option =
  if not (value_is_truncated_marker v) then None
  else
    match v with
    | `Assoc fields ->
      (match List.assoc_opt "_original_size_bytes" fields with
       | Some (`Int n) -> Some n
       | _ -> None)
    | _ -> None

(** Bound the snippet length we log when a JSONL line is malformed
    so a single huge garbled line cannot blow up the log file. *)
let parse_drop_snippet_max = 80

let snippet_of_line (line : string) : string =
  if String.length line <= parse_drop_snippet_max then line
  else String.sub line 0 parse_drop_snippet_max ^ "…"

(** Parse a single JSONL line into (key, value option, ts).
    Returns None if the line is malformed.  Every silent-drop branch
    now emits a warn so operators can spot data-corruption events; the
    snippet is bounded by [parse_drop_snippet_max] to keep log size
    manageable. *)
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
         | None ->
           Log.Memory.warn
             "memory_jsonl: dropping JSONL line — [key] field missing \
              or not a string (snippet: %S)"
             (snippet_of_line trimmed);
           observe_parse_drop ~reason:"no_key";
           None)
      | _ ->
        Log.Memory.warn
          "memory_jsonl: dropping JSONL line — top-level JSON is not \
           an Assoc record (snippet: %S)"
          (snippet_of_line trimmed);
        observe_parse_drop ~reason:"not_assoc";
        None
    with Yojson.Json_error err ->
      Log.Memory.warn
        "memory_jsonl: dropping JSONL line — Yojson parse error %s \
         (snippet: %S)"
        err
        (snippet_of_line trimmed);
      observe_parse_drop ~reason:"json_parse_error";
      None

(** Stream parsed rows from a session file.
    Missing files produce zero rows. Logs a warning if the file exceeds
    [max_file_size]. *)
let warn_if_large_file path =
  try
    let stat = Unix.stat path in
    let size = stat.Unix.st_size in
    if size > max_file_size then
      Log.Memory.warn "memory_jsonl: file %s is %d bytes (>50MB)" path size
  with Unix.Unix_error _ -> ()

let iter_lines ~path f =
  if Fs_compat.file_exists path then begin
    warn_if_large_file path;
    (try
       let ic = open_in_bin path in
       Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
         try
           while true do
             match parse_line (input_line ic) with
             | Some row -> f row
             | None -> ()
           done
         with End_of_file -> ())
     with Sys_error _ -> ())
  end

(** Create a session-based JSONL [long_term_backend].

    @param base_dir The .masc directory path
    @param agent_name Agent identifier
    @param session_id Session identifier (e.g. "acd905b7") *)
let make_backend_with_query_observer ~on_query_result ~base_dir ~agent_name
    ~session_id
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
      let last_value = ref None in
      iter_lines ~path (fun (k, v, _ts) ->
        if k = key then last_value := Some v);
      (* Some (Some v) = value, Some None = tombstone, None = not found *)
      match !last_value with
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
    let result =
      try
        (* De-duplicate by key (latest wins), skip tombstones *)
        let tbl = Hashtbl.create 32 in
        iter_lines ~path (fun (key, value, ts) ->
          if String.length key >= String.length prefix
             && String.sub key 0 (String.length prefix) = prefix then
            Hashtbl.replace tbl key (value, ts)
        );
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
        Ok (take limit [] sorted)
      with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
        let msg =
          Printf.sprintf
            "memory_jsonl query(%s) failed: %s"
            prefix
            (Printexc.to_string exn)
        in
        Log.Memory.error "%s" msg;
        Error msg
    in
    on_query_result result;
    match result with
    | Ok rows -> rows
    | Error _ -> []
  in

  { Agent_sdk.Memory.persist; retrieve; remove; batch_persist; query }

let make_backend ~base_dir ~agent_name ~session_id =
  make_backend_with_query_observer
    ~on_query_result:(fun _ -> ())
    ~base_dir
    ~agent_name
    ~session_id
