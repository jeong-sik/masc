(** Keeper_toml_loader -- load keeper configuration from TOML files.

    Minimal TOML parser: tables, strings (basic + multiline),
    integers, floats, booleans, and string arrays (single-line and
    multi-line).
    Enough to express all keeper_profile_defaults fields. *)

type toml_value =
  | Toml_string of string
  | Toml_int of int
  | Toml_float of float
  | Toml_bool of bool
  | Toml_string_array of string list

type toml_doc = (string * toml_value) list

(* ================================================================ *)
(* TOML parser                                                       *)
(* ================================================================ *)

let is_ws c = c = ' ' || c = '\t'

let strip_trailing_cr s =
  let len = String.length s in
  if len > 0 && s.[len - 1] = '\r' then String.sub s 0 (len - 1) else s
;;

let trim_leading_ws s =
  let len = String.length s in
  let rec scan i = if i >= len then len else if is_ws s.[i] then scan (i + 1) else i in
  let start = scan 0 in
  String.sub s start (len - start)
;;

let trim_initial_multiline_newline s =
  let len = String.length s in
  if len >= 2 && s.[0] = '\r' && s.[1] = '\n'
  then String.sub s 2 (len - 2)
  else if len >= 1 && s.[0] = '\n'
  then String.sub s 1 (len - 1)
  else s
;;

let multiline_suffix_is_valid suffix =
  let len = String.length suffix in
  let rec skip_ws i =
    if i >= len then len else if is_ws suffix.[i] then skip_ws (i + 1) else i
  in
  let i = skip_ws 0 in
  i >= len || suffix.[i] = '#'
;;

(* TOML allows up to two `"` chars immediately after the closing `"""` to be
   part of the string content.  Extract those and return (trailing, rest). *)
let extract_trailing_quotes suffix =
  let n = String.length suffix in
  let count =
    if n > 0 && suffix.[0] = '"' then if n > 1 && suffix.[1] = '"' then 2 else 1 else 0
  in
  String.make count '"', String.sub suffix count (n - count)
;;

let has_closing_bracket s =
  let len = String.length s in
  let rec scan i in_str =
    if i >= len
    then false
    else if in_str
    then
      if s.[i] = '"'
      then scan (i + 1) false
      else if s.[i] = '\\' && i + 1 < len
      then scan (i + 2) true
      else scan (i + 1) true
    else if s.[i] = '"'
    then scan (i + 1) true
    else if s.[i] = ']'
    then true
    else scan (i + 1) false
  in
  scan 0 false
;;

let strip_comment (line : string) : string =
  (* Find # that is not inside a quoted string. *)
  let len = String.length line in
  let rec scan i in_str =
    if i >= len
    then line
    else (
      let c = line.[i] in
      if in_str
      then
        if c = '"'
        then scan (i + 1) false
        else if c = '\\' && i + 1 < len
        then scan (i + 2) true
        else scan (i + 1) true
      else if c = '"'
      then scan (i + 1) true
      else if c = '#'
      then String.sub line 0 i |> String.trim
      else scan (i + 1) false)
  in
  scan 0 false
;;

let parse_basic_string (s : string) : (string, string) result =
  (* Expects input WITHOUT surrounding quotes. Handles escape sequences. *)
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len
    then Ok (Buffer.contents buf)
    else if s.[i] = '\\'
    then
      if i + 1 >= len
      then Error "unterminated escape sequence"
      else (
        match s.[i + 1] with
        | 'n' ->
          Buffer.add_char buf '\n';
          loop (i + 2)
        | 't' ->
          Buffer.add_char buf '\t';
          loop (i + 2)
        | 'r' ->
          Buffer.add_char buf '\r';
          loop (i + 2)
        | '\\' ->
          Buffer.add_char buf '\\';
          loop (i + 2)
        | '"' ->
          Buffer.add_char buf '"';
          loop (i + 2)
        | '\n' | '\r' ->
          (* TOML multiline line-ending backslash: trim the backslash, the
             newline, and any subsequent whitespace/newlines. *)
          let rec skip_ws j =
            if j >= len
            then j
            else if s.[j] = ' ' || s.[j] = '\t' || s.[j] = '\n' || s.[j] = '\r'
            then skip_ws (j + 1)
            else j
          in
          loop (skip_ws (i + 2))
        | c -> Error (Printf.sprintf "unknown escape \\%c" c))
    else (
      Buffer.add_char buf s.[i];
      loop (i + 1))
  in
  loop 0
;;

let extract_quoted_string (raw : string) : (string, string) result =
  let len = String.length raw in
  if len < 2 || raw.[0] <> '"'
  then Error "expected quoted string"
  else (
    (* Find closing quote, handling escapes *)
    let rec find_end i =
      if i >= len
      then Error "unterminated string"
      else if raw.[i] = '\\'
      then find_end (i + 2)
      else if raw.[i] = '"'
      then Ok i
      else find_end (i + 1)
    in
    match find_end 1 with
    | Error e -> Error e
    | Ok end_pos -> parse_basic_string (String.sub raw 1 (end_pos - 1)))
;;

let parse_value (raw : string) : (toml_value, string) result =
  let s = String.trim raw in
  if s = ""
  then Error "empty value"
  else if s = "true"
  then Ok (Toml_bool true)
  else if s = "false"
  then Ok (Toml_bool false)
  else if s.[0] = '"'
  then Result.map (fun v -> Toml_string v) (extract_quoted_string s)
  else if s.[0] = '['
  then (
    (* Parse string array: ["a", "b", "c"] *)
    let len = String.length s in
    if len < 2 || s.[len - 1] <> ']'
    then Error "unterminated array"
    else (
      let inner = String.sub s 1 (len - 2) |> String.trim in
      if inner = ""
      then Ok (Toml_string_array [])
      else (
        (* Split on commas outside quotes *)
        let items = ref [] in
        let buf = Buffer.create 64 in
        let ok = ref true in
        let ilen = String.length inner in
        let rec split i in_str =
          if i >= ilen
          then ()
          else (
            let c = inner.[i] in
            if in_str
            then (
              Buffer.add_char buf c;
              if c = '\\' && i + 1 < ilen
              then (
                (* Escaped char: add next char and skip it *)
                Buffer.add_char buf inner.[i + 1];
                split (i + 2) true)
              else if c = '"'
              then split (i + 1) false
              else split (i + 1) true)
            else if c = ','
            then (
              items := Buffer.contents buf :: !items;
              Buffer.clear buf;
              split (i + 1) false)
            else if c = '"'
            then (
              Buffer.add_char buf c;
              split (i + 1) true)
            else if is_ws c
            then split (i + 1) false
            else (
              ok := false;
              split (i + 1) false))
        in
        split 0 false;
        if Buffer.length buf > 0 then items := Buffer.contents buf :: !items;
        if not !ok
        then Error "array elements must be quoted strings"
        else (
          let parsed =
            List.rev !items
            |> List.map (fun item -> extract_quoted_string (String.trim item))
          in
          let errors = List.filter Result.is_error parsed in
          if errors <> []
          then Error "failed to parse array element"
          else
            Ok
              (Toml_string_array
                 (List.filter_map
                    (fun r ->
                       match r with
                       | Ok v -> Some v
                       | Error _ -> None)
                    parsed))))))
  else (
    (* Try int, then float *)
    match int_of_string_opt s with
    | Some i -> Ok (Toml_int i)
    | None ->
      (match float_of_string_opt s with
       | Some f -> Ok (Toml_float f)
       | None -> Error (Printf.sprintf "cannot parse value: %s" s)))
;;

let starts_with_triple_quote s =
  let len = String.length s in
  len >= 3 && s.[0] = '"' && s.[1] = '"' && s.[2] = '"'
;;

let find_closing_triple_quote s start =
  let len = String.length s in
  (* Scan forward, tracking the number of consecutive backslashes immediately
     preceding the current index (parity determines whether a quote is escaped).
     This keeps the overall search O(n) rather than O(n^2). *)
  let rec scan i backslashes =
    if i + 2 >= len
    then None
    else (
      let escaped = backslashes mod 2 = 1 in
      if s.[i] = '"' && s.[i + 1] = '"' && s.[i + 2] = '"' && not escaped
      then Some i
      else (
        let next_backslashes = if s.[i] = '\\' then backslashes + 1 else 0 in
        scan (i + 1) next_backslashes))
  in
  scan start 0
;;

type multiline_string_state =
  { key : string
  ; buf : Buffer.t
  ; start_line : int
  }

type multiline_array_state =
  { key : string
  ; buf : Buffer.t
  ; start_line : int
  }

type parse_state =
  { mutable current_table : string
  ; mutable acc : toml_doc
  ; mutable error : string option
  ; mutable line_num : int
  ; mutable multiline_string : multiline_string_state option
  ; mutable multiline_array : multiline_array_state option
  }

let create_parse_state () =
  { current_table = ""
  ; acc = []
  ; error = None
  ; line_num = 0
  ; multiline_string = None
  ; multiline_array = None
  }
;;

let add_entry state key value = state.acc <- (key, value) :: state.acc
let set_error state message = state.error <- Some message

let parse_toml (content : string) : (toml_doc, string) result =
  let lines = String.split_on_char '\n' content in
  let state = create_parse_state () in
  let full_key key =
    if state.current_table = "" then key else state.current_table ^ "." ^ key
  in
  let line_error message =
    set_error state (Printf.sprintf "line %d: %s" state.line_num message)
  in
  let handle_multiline_string (ml : multiline_string_state) raw_line =
    match find_closing_triple_quote raw_line 0 with
    | Some close_pos ->
      let prefix = String.sub raw_line 0 close_pos in
      let suffix =
        String.sub raw_line (close_pos + 3) (String.length raw_line - close_pos - 3)
      in
      let trailing_quotes, suffix_remainder = extract_trailing_quotes suffix in
      if not (multiline_suffix_is_valid suffix_remainder)
      then line_error "unexpected content after closing multiline string"
      else (
        if Buffer.length ml.buf > 0 then Buffer.add_char ml.buf '\n';
        Buffer.add_string ml.buf prefix;
        Buffer.add_string ml.buf trailing_quotes;
        let raw_str = Buffer.contents ml.buf in
        (match parse_basic_string raw_str with
         | Ok v -> add_entry state ml.key (Toml_string v)
         | Error e ->
           set_error
             state
             (Printf.sprintf "line %d: multiline string: %s" ml.start_line e));
        state.multiline_string <- None)
    | None ->
      if Buffer.length ml.buf > 0 then Buffer.add_char ml.buf '\n';
      Buffer.add_string ml.buf raw_line
  in
  let handle_multiline_array (arr : multiline_array_state) raw_line =
    let line = strip_comment raw_line in
    let trimmed = String.trim line in
    if trimmed <> ""
    then (
      if Buffer.length arr.buf > 0 then Buffer.add_char arr.buf ' ';
      Buffer.add_string arr.buf trimmed);
    if has_closing_bracket trimmed
    then (
      let assembled = Buffer.contents arr.buf in
      (match parse_value assembled with
       | Ok v -> add_entry state arr.key v
       | Error e -> set_error state (Printf.sprintf "line %d: %s" arr.start_line e));
      state.multiline_array <- None)
  in
  let start_multiline_string key after_open =
    let buf = Buffer.create 256 in
    let stripped = trim_initial_multiline_newline after_open in
    if stripped <> "" then Buffer.add_string buf stripped;
    state.multiline_string <- Some { key; buf; start_line = state.line_num }
  in
  let start_multiline_array key trimmed =
    let buf = Buffer.create 256 in
    Buffer.add_string buf trimmed;
    state.multiline_array <- Some { key; buf; start_line = state.line_num }
  in
  let parse_single_line_multiline_string key after_open close_pos =
    let inner = String.sub after_open 0 close_pos in
    let suffix =
      String.sub after_open (close_pos + 3) (String.length after_open - close_pos - 3)
    in
    let trailing_quotes, suffix_remainder = extract_trailing_quotes suffix in
    if not (multiline_suffix_is_valid suffix_remainder)
    then line_error "unexpected content after closing multiline string"
    else (
      match parse_basic_string (inner ^ trailing_quotes) with
      | Ok v -> add_entry state key (Toml_string v)
      | Error e -> line_error e)
  in
  let handle_value key value_raw =
    let trimmed = trim_leading_ws value_raw in
    if starts_with_triple_quote trimmed
    then (
      let after_open = String.sub trimmed 3 (String.length trimmed - 3) in
      match find_closing_triple_quote after_open 0 with
      | Some close_pos -> parse_single_line_multiline_string key after_open close_pos
      | None -> start_multiline_string key after_open)
    else if
      String.length trimmed > 0 && trimmed.[0] = '[' && not (has_closing_bracket trimmed)
    then start_multiline_array key trimmed
    else (
      match parse_value value_raw with
      | Ok v -> add_entry state key v
      | Error e -> line_error e)
  in
  let handle_table trimmed_line =
    let len = String.length trimmed_line in
    if trimmed_line.[len - 1] <> ']'
    then line_error "unterminated table header"
    else (
      let table_name = String.sub trimmed_line 1 (len - 2) |> String.trim in
      if table_name = ""
      then line_error "empty table name"
      else state.current_table <- table_name)
  in
  let handle_key_value line =
    match String.index_opt line '=' with
    | None -> line_error "expected key = value"
    | Some eq_pos ->
      let key = String.sub line 0 eq_pos |> String.trim in
      let value_raw = String.sub line (eq_pos + 1) (String.length line - eq_pos - 1) in
      if key = "" then line_error "empty key" else handle_value (full_key key) value_raw
  in
  let handle_normal_line raw_line =
    let line = strip_comment raw_line in
    let trimmed_line = String.trim line in
    if trimmed_line = ""
    then ()
    else if trimmed_line.[0] = '['
    then handle_table trimmed_line
    else handle_key_value line
  in
  List.iter
    (fun raw_line ->
       state.line_num <- state.line_num + 1;
       let raw_line = strip_trailing_cr raw_line in
       if Option.is_none state.error
       then (
         match state.multiline_string, state.multiline_array with
         | Some ml, _ -> handle_multiline_string ml raw_line
         | None, Some arr -> handle_multiline_array arr raw_line
         | None, None -> handle_normal_line raw_line))
    lines;
  (match state.multiline_string with
   | Some ml when Option.is_none state.error ->
     set_error
       state
       (Printf.sprintf "line %d: unterminated multiline string" ml.start_line)
   | _ -> ());
  (match state.multiline_array with
   | Some arr when Option.is_none state.error ->
     set_error
       state
       (Printf.sprintf "line %d: unterminated multiline array" arr.start_line)
   | _ -> ());
  match state.error with
  | Some e -> Error e
  | None -> Ok (List.rev state.acc)
;;

(* ================================================================ *)
(* TOML -> keeper_profile_defaults conversion                        *)
(* ================================================================ *)

let toml_string_opt (doc : toml_doc) (key : string) : string option =
  match List.assoc_opt key doc with
  | Some (Toml_string s) -> Some s
  | _ -> None
;;

let toml_int_opt (doc : toml_doc) (key : string) : int option =
  match List.assoc_opt key doc with
  | Some (Toml_int i) -> Some i
  | _ -> None
;;

let toml_float_opt (doc : toml_doc) (key : string) : float option =
  match List.assoc_opt key doc with
  | Some (Toml_float f) -> Some f
  | _ -> None
;;

let toml_bool_opt (doc : toml_doc) (key : string) : bool option =
  match List.assoc_opt key doc with
  | Some (Toml_bool b) -> Some b
  | _ -> None
;;

let toml_string_list (doc : toml_doc) (key : string) : string list =
  match List.assoc_opt key doc with
  | Some (Toml_string_array xs) -> xs
  | _ -> []
;;

(* ================================================================ *)
(* TOML writer — line-level field update                            *)
(* ================================================================ *)

(** Update or insert a key under a [table] in a TOML file.
    Preserves comments, formatting, and other fields.
    Returns [Ok new_content] or [Error reason]. *)
let update_field_in_content
      ~(table : string)
      ~(key : string)
      ~(value : string)
      (content : string)
  : (string, string) result
  =
  let lines = String.split_on_char '\n' content in
  let table_header = Printf.sprintf "[%s]" table in
  let key_prefix = key ^ " " in
  let key_prefix_eq = key ^ "=" in
  let in_target_table = ref false in
  let found = ref false in
  let result_lines = ref [] in
  let insert_before_next_table = ref false in
  List.iter
    (fun raw_line ->
       let line = strip_trailing_cr raw_line in
       let trimmed = String.trim line in
       if !insert_before_next_table && String.length trimmed > 0 && trimmed.[0] = '['
       then (
         (* New table started — insert the field before it *)
         result_lines := Printf.sprintf "%s = \"%s\"" key value :: !result_lines;
         found := true;
         insert_before_next_table := false);
       if String.trim trimmed = table_header
       then (
         in_target_table := true;
         insert_before_next_table := true;
         result_lines := line :: !result_lines)
       else if !in_target_table && String.length trimmed > 0 && trimmed.[0] = '['
       then (
         in_target_table := false;
         if !insert_before_next_table && not !found
         then (
           result_lines := Printf.sprintf "%s = \"%s\"" key value :: !result_lines;
           found := true;
           insert_before_next_table := false);
         result_lines := line :: !result_lines)
       else if
         !in_target_table
         && (not !found)
         && ((String.length trimmed >= String.length key_prefix
              && String.sub trimmed 0 (String.length key_prefix) = key_prefix)
             || (String.length trimmed >= String.length key_prefix_eq
                 && String.sub trimmed 0 (String.length key_prefix_eq) = key_prefix_eq))
       then (
         result_lines := Printf.sprintf "%s = \"%s\"" key value :: !result_lines;
         found := true;
         insert_before_next_table := false)
       else result_lines := line :: !result_lines)
    lines;
  (* If we were in the target table at EOF and didn't find the key, append *)
  if (not !found) && !insert_before_next_table
  then (
    result_lines := Printf.sprintf "%s = \"%s\"" key value :: !result_lines;
    found := true);
  if not !found
  then Error (Printf.sprintf "table [%s] not found in TOML" table)
  else Ok (String.concat "\n" (List.rev !result_lines))
;;

(** Atomic file write: write to temp file then rename.
    Rename is atomic on POSIX — prevents partial reads during concurrent access. *)
let atomic_write_file ~(path : string) (content : string) : (unit, string) result =
  let tmp = path ^ ".tmp" in
  try
    Fs_compat.save_file tmp content;
    Fs_compat.rename tmp path;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as e ->
    Safe_ops.protect ~default:() (fun () -> Sys.remove tmp);
    raise e
  | exn ->
    Safe_ops.protect ~default:() (fun () -> Sys.remove tmp);
    Error (Printf.sprintf "atomic write failed: %s" (Printexc.to_string exn))
;;

(** Update a field in a keeper TOML file on disk.
    Uses atomic write (temp file + rename) to prevent corruption
    from concurrent reads during the supervisor sweep.
    Returns [Ok ()] or [Error reason]. *)
let update_keeper_toml_field ~(path : string) ~(key : string) ~(value : string)
  : (unit, string) result
  =
  match Safe_ops.read_file_safe path with
  | Error e -> Error (Printf.sprintf "cannot read %s: %s" path e)
  | Ok content ->
    (match update_field_in_content ~table:"keeper" ~key ~value content with
     | Error e -> Error e
     | Ok updated -> atomic_write_file ~path updated)
;;

(* Higher-level functions (profile_defaults_of_toml, load_keeper_toml,
   discover_keepers) live in Keeper_types_profile to avoid a circular
   dependency: this module must not reference Keeper_types_profile. *)
