type t = { patterns : Re.re list }

let empty = { patterns = [] }

let min_secret_len = 8
let max_secret_file_bytes = 64 * 1024

let path_exists path =
  try Sys.file_exists path with
  | Sys_error _ -> false

let lstat_opt path =
  try Some (Unix.lstat path) with
  | Unix.Unix_error _ -> None

let read_regular_file path st =
  if st.Unix.st_size < 0 || st.Unix.st_size > max_secret_file_bytes then None
  else
    try
      let ic = open_in_bin path in
      Fun.protect
        ~finally:(fun () -> close_in_noerr ic)
        (fun () -> Some (really_input_string ic st.Unix.st_size))
    with
    | Sys_error _ | End_of_file -> None

let strip_one_final_newline value =
  let len = String.length value in
  if len >= 2 && Char.equal value.[len - 2] '\r' && Char.equal value.[len - 1] '\n'
  then String.sub value 0 (len - 2)
  else if len >= 1 && (Char.equal value.[len - 1] '\n' || Char.equal value.[len - 1] '\r')
  then String.sub value 0 (len - 1)
  else value

let add_value value acc =
  let trimmed = String.trim value in
  if String.length trimmed >= min_secret_len then trimmed :: acc else acc

let add_lines value acc =
  value
  |> String.split_on_char '\n'
  |> List.fold_left (fun acc line -> add_value line acc) acc

let values_from_file path acc =
  match lstat_opt path with
  | Some st when st.Unix.st_kind = Unix.S_REG ->
      (match read_regular_file path st with
       | None -> acc
       | Some value ->
           acc
           |> add_value (strip_one_final_newline value)
           |> add_lines value)
  | _ -> acc

let collect_env_values env_root acc =
  if not (path_exists env_root) then acc
  else
    match lstat_opt env_root with
    | Some st when st.Unix.st_kind = Unix.S_DIR ->
        (try
           Sys.readdir env_root
           |> Array.to_list
           |> List.fold_left
                (fun acc name -> values_from_file (Filename.concat env_root name) acc)
                acc
         with
         | Sys_error _ -> acc)
    | _ -> acc

let collect_file_values files_root acc =
  let rec walk path acc =
    match lstat_opt path with
    | Some st when st.Unix.st_kind = Unix.S_DIR ->
        (try
           Sys.readdir path
           |> Array.to_list
           |> List.fold_left
                (fun acc name -> walk (Filename.concat path name) acc)
                acc
         with
         | Sys_error _ -> acc)
    | Some st when st.Unix.st_kind = Unix.S_REG ->
        values_from_file path acc
    | _ -> acc
  in
  if path_exists files_root then walk files_root acc else acc

let dedupe values =
  let tbl = Hashtbl.create 32 in
  values
  |> List.filter (fun value ->
       if Hashtbl.mem tbl value then false
       else (
         Hashtbl.add tbl value ();
         true))
  |> List.sort (fun a b ->
       compare (String.length b, b) (String.length a, a))

let snapshot ~base_path ~keeper_name =
  let values =
    Keeper_secret_projection.secret_roots ~base_path ~keeper_name
    |> List.fold_left
         (fun acc info ->
            let env_root = Filename.concat info.Keeper_secret_projection.root "env" in
            let files_root =
              Filename.concat info.Keeper_secret_projection.root "files"
            in
            acc |> collect_env_values env_root |> collect_file_values files_root)
         []
    |> dedupe
  in
  let patterns =
    List.map (fun value -> Re.compile (Re.str value)) values
  in
  { patterns }

let redact_text t text =
  let text =
    List.fold_left
      (fun acc pattern -> Re.replace_string pattern ~by:"[REDACTED]" acc)
      text
      t.patterns
  in
  Observability_redact.redact_text text

(* Keep streaming redaction line-oriented so secrets split across process read
   boundaries are never published piecemeal.  The pending line is capped: a
   command can otherwise force quadratic copying (and unbounded retention) by
   printing a very large line without a newline.  Oversized lines are omitted
   wholesale because publishing any prefix could disclose a secret whose
   suffix has not arrived yet. *)
type stream_state =
  { pending : Buffer.t
  ; mutable dropping_oversized_line : bool
  }

let max_stream_line_bytes = max_secret_file_bytes
let oversized_line_marker = "[REDACTED: oversized output line]\n"

let create_stream_state () =
  { pending = Buffer.create 256; dropping_oversized_line = false }

let redact_stream_chunk t state chunk =
  let output = Buffer.create (String.length chunk) in
  let flush_line () =
    if state.dropping_oversized_line
    then state.dropping_oversized_line <- false
    else (
      Buffer.add_char state.pending '\n';
      Buffer.add_string output (redact_text t (Buffer.contents state.pending)));
    Buffer.clear state.pending
  in
  let append_segment start len =
    if not state.dropping_oversized_line
    then
      if Buffer.length state.pending + len > max_stream_line_bytes
      then (
        Buffer.clear state.pending;
        state.dropping_oversized_line <- true;
        Buffer.add_string output oversized_line_marker)
      else Buffer.add_substring state.pending chunk start len
  in
  let rec consume start pos =
    if pos = String.length chunk
    then append_segment start (pos - start)
    else if Char.equal chunk.[pos] '\n'
    then (
      append_segment start (pos - start);
      flush_line ();
      consume (pos + 1) (pos + 1))
    else consume start (pos + 1)
  in
  consume 0 0;
  Buffer.contents output

let redact_stream_finish t state =
  if state.dropping_oversized_line
  then (
    state.dropping_oversized_line <- false;
    "")
  else (
    let contents = Buffer.contents state.pending in
    Buffer.clear state.pending;
    if String.equal contents "" then "" else redact_text t contents)

let rec redact_json_exact t = function
  | `String s -> `String (redact_text t s)
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) -> (key, redact_json_exact t value))
           fields)
  | `List items -> `List (List.map (redact_json_exact t) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as json -> json

let rec redact_json_keys t = function
  | `String _ as value -> value
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) -> redact_text t key, redact_json_keys t value)
           fields)
  | `List items -> `List (List.map (redact_json_keys t) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as value -> value

let redact_json t json =
  json |> redact_json_exact t |> Observability_redact.redact_json_strings
