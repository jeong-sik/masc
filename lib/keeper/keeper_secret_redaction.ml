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

(* Streaming chunk redaction. [redact_text] is stateless: a single-line
   secret split across chunk N's tail and chunk N+1's head matches in
   neither call. [stream_state] buffers raw bytes up to the last ['\n'] so
   the containing line is reassembled before redaction. Multi-line secrets
   (a value containing ['\n'], e.g. a PEM block) may still partially
   surface if the buffer's last ['\n'] falls inside the secret; this is
   strictly better than the pre-fix behaviour where every cross-chunk split
   leaked. *)
type stream_state = { pending : Buffer.t }

let create_stream_state () = { pending = Buffer.create 256 }

let redact_stream_chunk t state chunk =
  Buffer.add_string state.pending chunk;
  let contents = Buffer.contents state.pending in
  match String.rindex_opt contents '\n' with
  | None -> ""
  | Some nl_pos ->
    let safe_len = nl_pos + 1 in
    let safe_raw = String.sub contents 0 safe_len in
    let held = String.sub contents safe_len (String.length contents - safe_len) in
    Buffer.clear state.pending;
    Buffer.add_string state.pending held;
    redact_text t safe_raw

let redact_stream_finish t state =
  let contents = Buffer.contents state.pending in
  Buffer.clear state.pending;
  if String.equal contents "" then "" else redact_text t contents

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
