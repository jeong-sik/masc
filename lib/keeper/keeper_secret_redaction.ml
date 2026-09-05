type t =
  { patterns : Re.re list
  ; exact_values : string list
  ; max_exact_value_len : int
  }

type stream_state =
  { redaction : t
  ; pending_line : Buffer.t
  ; mutable next_bounded_flush_at : int
  }

let empty = { patterns = []; exact_values = []; max_exact_value_len = 0 }

let min_secret_len = 8
let max_secret_file_bytes = 64 * 1024
let stream_emit_bytes = 4 * 1024
let structural_pattern_overlap_bytes = 4 * 1024

let ssh_remote_token_file ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Filename.concat (Common.masc_dir_from_base_path ~base_path) "ssh")
       "redaction")
    (Workspace_utils.safe_filename keeper_name ^ ".token")
;;

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

(* A snapshot is a function of the bytes of its source files. Building one
   reads every file and compiles one regex per value, and a fresh [Re.re]
   starts with an empty DFA that [Re.replace_string] fills again on first
   use. Chat loads, connector deliveries and stream projections asked for a
   snapshot per call, and on 2026-09-05 regex compilation was 35% of the
   main domain's busy time (RFC main-domain-scheduler-latency §8.8). The
   walk is therefore split in two: enumerating the regular files with the
   stat that identifies their bytes, then reading them. A call always
   enumerates; it reads and compiles only when a stamp differs from the one
   memoised for the same request key on the same domain. *)
type extraction =
  | Whole_and_lines
  | Whole_lines_and_mapping_scalars

type source =
  { source_path : string
  ; extraction : extraction
  ; st : Unix.stats
  }

let regular_file_source extraction path acc =
  match lstat_opt path with
  | Some st when st.Unix.st_kind = Unix.S_REG -> { source_path = path; extraction; st } :: acc
  | _ -> acc

let strip_matching_quotes value =
  let len = String.length value in
  if len >= 2
     && ((Char.equal value.[0] '"' && Char.equal value.[len - 1] '"')
         || (Char.equal value.[0] '\'' && Char.equal value.[len - 1] '\''))
  then String.sub value 1 (len - 2)
  else value

(* Scalar mining is what catches a bare credential printed without its key
   line — `gh auth status` shows the token alone. The key half decides what
   a scalar is: credential-shaped keys always mine, identity keys (a `user:`
   login) only when [redact_identity_scalars] is set. The default mined
   every scalar, so a GitHub account name — public in every repo URL — was
   masked as [REDACTED] throughout chat text (2026-08-29, keeper edgar.a.poe). *)
let credential_shaped_key key =
  List.exists
    (fun marker -> String_util.contains_substring_ci key marker)
    [ "token"; "secret"; "password"; "passwd"; "credential"; "passphrase" ]

let add_mapping_scalar_values ~(redact_identity_scalars : bool) value acc =
  value
  |> String.split_on_char '\n'
  |> List.fold_left
       (fun acc line ->
          match String.index_opt line ':' with
          | None -> acc
          | Some separator ->
            let key = String.trim (String.sub line 0 separator) in
            let value_start = separator + 1 in
            let scalar =
              String.sub line value_start (String.length line - value_start)
              |> String.trim
              |> strip_matching_quotes
            in
            if redact_identity_scalars || credential_shaped_key key
            then add_value scalar acc
            else acc)
       acc

let env_sources env_root acc =
  if not (path_exists env_root) then acc
  else
    match lstat_opt env_root with
    | Some st when st.Unix.st_kind = Unix.S_DIR ->
        (try
           Sys.readdir env_root
           |> Array.to_list
           |> List.fold_left
                (fun acc name ->
                   regular_file_source Whole_and_lines (Filename.concat env_root name) acc)
                acc
         with
         | Sys_error _ -> acc)
    | _ -> acc

let files_tree_sources files_root acc =
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
        { source_path = path; extraction = Whole_and_lines; st } :: acc
    | _ -> acc
  in
  if path_exists files_root then walk files_root acc else acc

let sources ~additional_secret_files ~base_path ~keeper_name =
  Keeper_secret_projection.secret_roots ~base_path ~keeper_name
  |> List.fold_left
       (fun acc info ->
          let env_root = Filename.concat info.Keeper_secret_projection.root "env" in
          let files_root = Filename.concat info.Keeper_secret_projection.root "files" in
          acc |> env_sources env_root |> files_tree_sources files_root)
       []
  |> regular_file_source Whole_and_lines (ssh_remote_token_file ~base_path ~keeper_name)
  |> fun acc ->
  List.fold_left
    (fun acc path -> regular_file_source Whole_lines_and_mapping_scalars path acc)
    acc
    additional_secret_files

let values_of_source ~(redact_identity_scalars : bool) { source_path; extraction; st } acc =
  match read_regular_file source_path st with
  | None -> acc
  | Some value ->
      let acc = acc |> add_value (strip_one_final_newline value) |> add_lines value in
      (match extraction with
       | Whole_and_lines -> acc
       | Whole_lines_and_mapping_scalars ->
           add_mapping_scalar_values ~redact_identity_scalars value acc)

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

let build ~redact_identity_scalars sources =
  let values =
    List.fold_left
      (fun acc source -> values_of_source ~redact_identity_scalars source acc)
      []
      sources
    |> dedupe
  in
  let patterns = List.map (fun value -> Re.compile (Re.str value)) values in
  let max_exact_value_len =
    List.fold_left (fun longest value -> max longest (String.length value)) 0 values
  in
  { patterns; exact_values = values; max_exact_value_len }

(* The memo is per domain: a compiled [Re.re] fills its DFA tables lazily
   while matching, so one must not be shared between domains. Fibers of one
   domain interleave only at suspension points and matching has none. *)
type memo_key =
  { key_base_path : string
  ; key_keeper_name : string
  ; key_redact_identity_scalars : bool
  ; key_additional_secret_files : string list
  }

type source_stamp =
  { stamp_path : string
  ; device : int
  ; inode : int
  ; size : int
  ; mtime : float
  }

type memo_entry =
  { key : memo_key
  ; stamps : source_stamp list
  ; snapshot : t
  }

let key_equal a b =
  String.equal a.key_base_path b.key_base_path
  && String.equal a.key_keeper_name b.key_keeper_name
  && Bool.equal a.key_redact_identity_scalars b.key_redact_identity_scalars
  && List.equal String.equal a.key_additional_secret_files b.key_additional_secret_files

let stamp_equal a b =
  String.equal a.stamp_path b.stamp_path
  && Int.equal a.device b.device
  && Int.equal a.inode b.inode
  && Int.equal a.size b.size
  && Float.equal a.mtime b.mtime

let memo : memo_entry list ref Domain.DLS.key = Domain.DLS.new_key (fun () -> ref [])

let stamp_of_source { source_path; st; extraction = _ } =
  { stamp_path = source_path
  ; device = st.Unix.st_dev
  ; inode = st.Unix.st_ino
  ; size = st.Unix.st_size
  ; mtime = st.Unix.st_mtime
  }

let snapshot_with_additional_secret_files
      ~(redact_identity_scalars : bool)
      ~additional_secret_files
      ~base_path
      ~keeper_name
  =
  let sources = sources ~additional_secret_files ~base_path ~keeper_name in
  let key =
    { key_base_path = base_path
    ; key_keeper_name = keeper_name
    ; key_redact_identity_scalars = redact_identity_scalars
    ; key_additional_secret_files = additional_secret_files
    }
  in
  let stamps = List.map stamp_of_source sources in
  let entries = Domain.DLS.get memo in
  match List.find_opt (fun entry -> key_equal entry.key key) !entries with
  | Some entry when List.equal stamp_equal entry.stamps stamps -> entry.snapshot
  | Some _ | None ->
      let snapshot = build ~redact_identity_scalars sources in
      entries
        := { key; stamps; snapshot }
           :: List.filter (fun entry -> not (key_equal entry.key key)) !entries;
      snapshot

let snapshot ~base_path ~keeper_name =
  snapshot_with_additional_secret_files
    ~redact_identity_scalars:true
    ~additional_secret_files:[]
    ~base_path
    ~keeper_name
;;

let redact_text t text =
  let text =
    List.fold_left
      (fun acc pattern -> Re.replace_string pattern ~by:"[REDACTED]" acc)
      text
      t.patterns
  in
  Observability_redact.redact_text text

let stream_overlap_bytes redaction =
  max structural_pattern_overlap_bytes (max 0 (redaction.max_exact_value_len - 1))
;;

let stream_flush_threshold redaction =
  stream_overlap_bytes redaction + stream_emit_bytes
;;

let create_stream_state redaction =
  { redaction
  ; pending_line = Buffer.create 256
  ; next_bounded_flush_at = stream_flush_threshold redaction
  }
;;

let exact_value_starts_at text ~index value =
  let value_len = String.length value in
  let rec equal offset =
    offset = value_len
    || (Char.equal text.[index + offset] value.[offset] && equal (offset + 1))
  in
  index + value_len <= String.length text
  && Char.equal text.[index] value.[0]
  && equal 1
;;

let exact_value_at redaction text index =
  List.find_opt (exact_value_starts_at text ~index) redaction.exact_values
;;

let emit_bounded_prefix state emitted stop =
  let pending = Buffer.contents state.pending_line in
  let safely_redacted = Buffer.create stop in
  let cursor = ref 0 in
  while !cursor < stop do
    match exact_value_at state.redaction pending !cursor with
    | Some value ->
      Buffer.add_string safely_redacted "[REDACTED]";
      cursor := !cursor + String.length value
    | None ->
      Buffer.add_char safely_redacted pending.[!cursor];
      incr cursor
  done;
  Buffer.add_string
    emitted
    (Observability_redact.redact_text (Buffer.contents safely_redacted));
  Buffer.clear state.pending_line;
  Buffer.add_substring
    state.pending_line
    pending
    !cursor
    (String.length pending - !cursor)
;;

let flush_complete_record state emitted =
  Buffer.add_string emitted (redact_text state.redaction (Buffer.contents state.pending_line));
  Buffer.clear state.pending_line;
  state.next_bounded_flush_at <- stream_flush_threshold state.redaction
;;

let flush_bounded_prefix_if_needed state emitted =
  let pending_len = Buffer.length state.pending_line in
  if pending_len >= state.next_bounded_flush_at
  then (
    let overlap = stream_overlap_bytes state.redaction in
    let stop = pending_len - overlap in
    emit_bounded_prefix state emitted stop;
    state.next_bounded_flush_at <- stream_flush_threshold state.redaction)
;;

let redact_stream_chunk state chunk =
  let emitted = Buffer.create (String.length chunk) in
  String.iter
    (fun char ->
       Buffer.add_char state.pending_line char;
       if Char.equal char '\n' || Char.equal char '\r'
       then flush_complete_record state emitted
       else flush_bounded_prefix_if_needed state emitted)
    chunk;
  Buffer.contents emitted
;;

let redact_stream_finish state =
  let trailing = redact_text state.redaction (Buffer.contents state.pending_line) in
  Buffer.clear state.pending_line;
  state.next_bounded_flush_at <- stream_flush_threshold state.redaction;
  trailing
;;

(* Keys as well as values. A secret can be the key -- a header name, a
   parameter used as a dict key, {"<secret>": "x"} straight from a tool
   argument -- and a traversal that only rewrites leaves emits it (#22941).
   Doing both here rather than in one caller means every boundary that reaches
   for the redactor gets the same policy; the alternative left two of three
   callers redacting values only, without saying so. *)
let rec redact_json_exact t = function
  | `String s -> `String (redact_text t s)
  | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) -> (redact_text t key, redact_json_exact t value))
           fields)
  | `List items -> `List (List.map (redact_json_exact t) items)
  | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _) as json -> json

let redact_json t json =
  json |> redact_json_exact t |> Observability_redact.redact_json_strings

module For_testing = struct
  let shares_compiled_patterns a b = a.patterns == b.patterns
end
