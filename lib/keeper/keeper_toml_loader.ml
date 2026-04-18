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

let trim_leading_ws s =
  let len = String.length s in
  let rec scan i =
    if i >= len then len
    else if is_ws s.[i] then scan (i + 1)
    else i
  in
  let start = scan 0 in
  String.sub s start (len - start)

let trim_initial_multiline_newline s =
  let len = String.length s in
  if len >= 2 && s.[0] = '\r' && s.[1] = '\n' then
    String.sub s 2 (len - 2)
  else if len >= 1 && s.[0] = '\n' then
    String.sub s 1 (len - 1)
  else
    s

let multiline_suffix_is_valid suffix =
  let len = String.length suffix in
  let rec skip_ws i =
    if i >= len then len
    else if is_ws suffix.[i] then skip_ws (i + 1)
    else i
  in
  let i = skip_ws 0 in
  i >= len || suffix.[i] = '#'

(* TOML allows up to two `"` chars immediately after the closing `"""` to be
   part of the string content.  Extract those and return (trailing, rest). *)
let extract_trailing_quotes suffix =
  let n = String.length suffix in
  let count =
    if n > 0 && suffix.[0] = '"' then
      if n > 1 && suffix.[1] = '"' then 2
      else 1
    else 0
  in
  (String.make count '"', String.sub suffix count (n - count))

let has_closing_bracket s =
  let len = String.length s in
  let rec scan i in_str =
    if i >= len then false
    else if in_str then
      if s.[i] = '"' then scan (i + 1) false
      else if s.[i] = '\\' && i + 1 < len then scan (i + 2) true
      else scan (i + 1) true
    else if s.[i] = '"' then scan (i + 1) true
    else if s.[i] = ']' then true
    else scan (i + 1) false
  in
  scan 0 false

let strip_comment (line : string) : string =
  (* Find # that is not inside a quoted string. *)
  let len = String.length line in
  let rec scan i in_str =
    if i >= len then line
    else
      let c = line.[i] in
      if in_str then
        if c = '"' then scan (i + 1) false
        else if c = '\\' && i + 1 < len then scan (i + 2) true
        else scan (i + 1) true
      else if c = '"' then scan (i + 1) true
      else if c = '#' then String.sub line 0 i |> String.trim
      else scan (i + 1) false
  in
  scan 0 false

let parse_basic_string (s : string) : (string, string) result =
  (* Expects input WITHOUT surrounding quotes. Handles escape sequences. *)
  let len = String.length s in
  let buf = Buffer.create len in
  let rec loop i =
    if i >= len then Ok (Buffer.contents buf)
    else if s.[i] = '\\' then begin
      if i + 1 >= len then Error "unterminated escape sequence"
      else
        match s.[i + 1] with
        | 'n' -> Buffer.add_char buf '\n'; loop (i + 2)
        | 't' -> Buffer.add_char buf '\t'; loop (i + 2)
        | 'r' -> Buffer.add_char buf '\r'; loop (i + 2)
        | '\\' -> Buffer.add_char buf '\\'; loop (i + 2)
        | '"' -> Buffer.add_char buf '"'; loop (i + 2)
        | '\n' | '\r' ->
          (* TOML multiline line-ending backslash: trim the backslash, the
             newline, and any subsequent whitespace/newlines. *)
          let rec skip_ws j =
            if j >= len then j
            else if s.[j] = ' ' || s.[j] = '\t' || s.[j] = '\n' || s.[j] = '\r'
            then skip_ws (j + 1)
            else j
          in
          loop (skip_ws (i + 2))
        | c -> Error (Printf.sprintf "unknown escape \\%c" c)
    end
    else begin
      Buffer.add_char buf s.[i];
      loop (i + 1)
    end
  in
  loop 0

let extract_quoted_string (raw : string) : (string, string) result =
  let len = String.length raw in
  if len < 2 || raw.[0] <> '"' then Error "expected quoted string"
  else
    (* Find closing quote, handling escapes *)
    let rec find_end i =
      if i >= len then Error "unterminated string"
      else if raw.[i] = '\\' then find_end (i + 2)
      else if raw.[i] = '"' then Ok i
      else find_end (i + 1)
    in
    match find_end 1 with
    | Error e -> Error e
    | Ok end_pos ->
      parse_basic_string (String.sub raw 1 (end_pos - 1))

let parse_value (raw : string) : (toml_value, string) result =
  let s = String.trim raw in
  if s = "" then Error "empty value"
  else if s = "true" then Ok (Toml_bool true)
  else if s = "false" then Ok (Toml_bool false)
  else if s.[0] = '"' then
    Result.map (fun v -> Toml_string v) (extract_quoted_string s)
  else if s.[0] = '[' then begin
    (* Parse string array: ["a", "b", "c"] *)
    let len = String.length s in
    if len < 2 || s.[len - 1] <> ']' then
      Error "unterminated array"
    else
      let inner = String.sub s 1 (len - 2) |> String.trim in
      if inner = "" then Ok (Toml_string_array [])
      else
        (* Split on commas outside quotes *)
        let items = ref [] in
        let buf = Buffer.create 64 in
        let ok = ref true in
        let ilen = String.length inner in
        let rec split i in_str =
          if i >= ilen then ()
          else
            let c = inner.[i] in
            if in_str then begin
              Buffer.add_char buf c;
              if c = '\\' && i + 1 < ilen then begin
                (* Escaped char: add next char and skip it *)
                Buffer.add_char buf inner.[i + 1];
                split (i + 2) true
              end
              else if c = '"' then split (i + 1) false
              else split (i + 1) true
            end
            else if c = ',' then begin
              items := Buffer.contents buf :: !items;
              Buffer.clear buf;
              split (i + 1) false
            end
            else if c = '"' then begin
              Buffer.add_char buf c;
              split (i + 1) true
            end
            else if is_ws c then split (i + 1) false
            else begin
              ok := false;
              split (i + 1) false
            end
        in
        split 0 false;
        if Buffer.length buf > 0 then
          items := Buffer.contents buf :: !items;
        if not !ok then
          Error "array elements must be quoted strings"
        else
          let parsed =
            List.rev !items
            |> List.map (fun item ->
                 extract_quoted_string (String.trim item))
          in
          let errors = List.filter Result.is_error parsed in
          if errors <> [] then
            Error "failed to parse array element"
          else
            Ok (Toml_string_array
                  (List.filter_map
                     (fun r -> match r with Ok v -> Some v | Error _ -> None)
                     parsed))
  end
  else begin
    (* Try int, then float *)
    match int_of_string_opt s with
    | Some i -> Ok (Toml_int i)
    | None ->
      match float_of_string_opt s with
      | Some f -> Ok (Toml_float f)
      | None -> Error (Printf.sprintf "cannot parse value: %s" s)
  end

let starts_with_triple_quote s =
  let len = String.length s in
  len >= 3 && s.[0] = '"' && s.[1] = '"' && s.[2] = '"'

let find_closing_triple_quote s start =
  let len = String.length s in
  (* Scan forward, tracking the number of consecutive backslashes immediately
     preceding the current index (parity determines whether a quote is escaped).
     This keeps the overall search O(n) rather than O(n^2). *)
  let rec scan i backslashes =
    if i + 2 >= len then None
    else
      let escaped = (backslashes mod 2) = 1 in
      if s.[i] = '"' && s.[i+1] = '"' && s.[i+2] = '"' && not escaped then
        Some i
      else
        let next_backslashes = if s.[i] = '\\' then backslashes + 1 else 0 in
        scan (i + 1) next_backslashes
  in
  scan start 0

let parse_toml (content : string) : (toml_doc, string) result =
  let lines = String.split_on_char '\n' content in
  let current_table = ref "" in
  let acc = ref [] in
  let error = ref None in
  let line_num = ref 0 in
  (* Multiline string accumulation state *)
  let ml_key = ref "" in
  let ml_buf = ref (Buffer.create 0) in
  let ml_active = ref false in
  let ml_start_line = ref 0 in
  (* Multiline array accumulation state *)
  let arr_key = ref "" in
  let arr_buf = ref (Buffer.create 0) in
  let arr_active = ref false in
  let arr_start_line = ref 0 in
  List.iter (fun raw_line ->
    incr line_num;
    let raw_line = strip_trailing_cr raw_line in
    if Option.is_none !error then begin
      if !ml_active then begin
        (* Inside a multiline string -- look for closing triple-quote *)
        match find_closing_triple_quote raw_line 0 with
        | Some close_pos ->
          let prefix = String.sub raw_line 0 close_pos in
          let suffix =
            String.sub raw_line (close_pos + 3)
              (String.length raw_line - close_pos - 3)
          in
          let trailing_quotes, suffix_remainder = extract_trailing_quotes suffix in
          if not (multiline_suffix_is_valid suffix_remainder) then
            error := Some
              (Printf.sprintf "line %d: unexpected content after closing multiline string"
                 !line_num)
          else begin
            if Buffer.length !ml_buf > 0 then Buffer.add_char !ml_buf '\n';
            Buffer.add_string !ml_buf prefix;
            Buffer.add_string !ml_buf trailing_quotes;
            let raw_str = Buffer.contents !ml_buf in
            (match parse_basic_string raw_str with
             | Ok v -> acc := (!ml_key, Toml_string v) :: !acc
             | Error e ->
               error := Some
                 (Printf.sprintf "line %d: multiline string: %s" !ml_start_line e));
            ml_active := false
          end
        | None ->
          if Buffer.length !ml_buf > 0 then Buffer.add_char !ml_buf '\n';
          Buffer.add_string !ml_buf raw_line
      end
      else if !arr_active then begin
        (* Inside a multiline array -- accumulate until closing ] *)
        let line = strip_comment raw_line in
        let trimmed = String.trim line in
        if trimmed <> "" then begin
          if Buffer.length !arr_buf > 0 then Buffer.add_char !arr_buf ' ';
          Buffer.add_string !arr_buf trimmed
        end;
        if has_closing_bracket trimmed then begin
          let assembled = Buffer.contents !arr_buf in
          (match parse_value assembled with
           | Ok v -> acc := (!arr_key, v) :: !acc
           | Error e ->
             error := Some (Printf.sprintf "line %d: %s" !arr_start_line e));
          arr_active := false
        end
      end
      else begin
        let line = strip_comment raw_line in
        let trimmed_line = String.trim line in
        if trimmed_line = "" then ()
        else if trimmed_line.[0] = '[' then begin
          (* Table header *)
          let len = String.length trimmed_line in
          if trimmed_line.[len - 1] <> ']' then
            error := Some (Printf.sprintf "line %d: unterminated table header" !line_num)
          else begin
            let table_name =
              String.sub trimmed_line 1 (len - 2) |> String.trim
            in
            if table_name = "" then
              error := Some (Printf.sprintf "line %d: empty table name" !line_num)
            else
              current_table := table_name
          end
        end
        else begin
          (* key = value *)
          match String.index_opt line '=' with
          | None ->
            error := Some (Printf.sprintf "line %d: expected key = value" !line_num)
          | Some eq_pos ->
            let key = String.sub line 0 eq_pos |> String.trim in
            let value_raw = String.sub line (eq_pos + 1) (String.length line - eq_pos - 1) in
            if key = "" then
              error := Some (Printf.sprintf "line %d: empty key" !line_num)
            else
              let full_key =
                if !current_table = "" then key
                else !current_table ^ "." ^ key
              in
              let trimmed = trim_leading_ws value_raw in
              if starts_with_triple_quote trimmed then begin
                (* Start of multiline basic string *)
                let after_open = String.sub trimmed 3 (String.length trimmed - 3) in
                match find_closing_triple_quote after_open 0 with
                | Some close_pos ->
                  (* Single-line: triple-quoted on one line *)
                  let inner = String.sub after_open 0 close_pos in
                  let suffix =
                    String.sub after_open (close_pos + 3)
                      (String.length after_open - close_pos - 3)
                  in
                  let trailing_quotes, suffix_remainder = extract_trailing_quotes suffix in
                  if not (multiline_suffix_is_valid suffix_remainder) then
                    error := Some
                      (Printf.sprintf "line %d: unexpected content after closing multiline string"
                         !line_num)
                  else
                    (match parse_basic_string (inner ^ trailing_quotes) with
                     | Ok v -> acc := (full_key, Toml_string v) :: !acc
                     | Error e ->
                       error := Some (Printf.sprintf "line %d: %s" !line_num e))
                | None ->
                  (* Multiline continues on next lines.
                     TOML spec: newline after opening delimiter is trimmed,
                     so we start with empty buffer. *)
                  ml_key := full_key;
                  ml_buf := Buffer.create 256;
                  let stripped = trim_initial_multiline_newline after_open in
                  if stripped <> "" then
                    Buffer.add_string !ml_buf stripped;
                  ml_active := true;
                  ml_start_line := !line_num
              end
              else if String.length trimmed > 0 && trimmed.[0] = '['
                      && not (has_closing_bracket trimmed) then begin
                (* Start of multiline array *)
                arr_key := full_key;
                arr_buf := Buffer.create 256;
                Buffer.add_string !arr_buf trimmed;
                arr_active := true;
                arr_start_line := !line_num
              end
              else
                match parse_value value_raw with
                | Ok v -> acc := (full_key, v) :: !acc
                | Error e ->
                  error := Some (Printf.sprintf "line %d: %s" !line_num e)
        end
      end
    end
  ) lines;
  if !ml_active && Option.is_none !error then
    error := Some (Printf.sprintf "line %d: unterminated multiline string" !ml_start_line);
  if !arr_active && Option.is_none !error then
    error := Some (Printf.sprintf "line %d: unterminated multiline array" !arr_start_line);
  match !error with
  | Some e -> Error e
  | None -> Ok (List.rev !acc)

(* ================================================================ *)
(* TOML -> keeper_profile_defaults conversion                        *)
(* ================================================================ *)

let toml_string_opt (doc : toml_doc) (key : string) : string option =
  match List.assoc_opt key doc with
  | Some (Toml_string s) -> Some s
  | _ -> None

let toml_int_opt (doc : toml_doc) (key : string) : int option =
  match List.assoc_opt key doc with
  | Some (Toml_int i) -> Some i
  | _ -> None

let toml_bool_opt (doc : toml_doc) (key : string) : bool option =
  match List.assoc_opt key doc with
  | Some (Toml_bool b) -> Some b
  | _ -> None

let toml_string_list (doc : toml_doc) (key : string) : string list =
  match List.assoc_opt key doc with
  | Some (Toml_string_array xs) -> xs
  | _ -> []

(* ================================================================ *)
(* TOML writer — line-level field update                            *)
(* ================================================================ *)

(** Update or insert a key under a [table] in a TOML file.
    Preserves comments, formatting, and other fields.
    Returns [Ok new_content] or [Error reason]. *)
let update_field_in_content ~(table : string) ~(key : string)
    ~(value : string) (content : string) : (string, string) result =
  let lines = String.split_on_char '\n' content in
  let table_header = Printf.sprintf "[%s]" table in
  let key_prefix = key ^ " " in
  let key_prefix_eq = key ^ "=" in
  let in_target_table = ref false in
  let found = ref false in
  let result_lines = ref [] in
  let insert_before_next_table = ref false in
  List.iter (fun raw_line ->
    let line = strip_trailing_cr raw_line in
    let trimmed = String.trim line in
    if !insert_before_next_table && String.length trimmed > 0
       && trimmed.[0] = '[' then begin
      (* New table started — insert the field before it *)
      result_lines := (Printf.sprintf "%s = \"%s\"" key value) :: !result_lines;
      found := true;
      insert_before_next_table := false
    end;
    if String.trim trimmed = table_header then begin
      in_target_table := true;
      insert_before_next_table := true;
      result_lines := line :: !result_lines
    end
    else if !in_target_table && String.length trimmed > 0
            && trimmed.[0] = '[' then begin
      in_target_table := false;
      if !insert_before_next_table && not !found then begin
        result_lines := (Printf.sprintf "%s = \"%s\"" key value) :: !result_lines;
        found := true;
        insert_before_next_table := false
      end;
      result_lines := line :: !result_lines
    end
    else if !in_target_table && not !found
            && (String.length trimmed >= String.length key_prefix
                && String.sub trimmed 0 (String.length key_prefix) = key_prefix
                || String.length trimmed >= String.length key_prefix_eq
                && String.sub trimmed 0 (String.length key_prefix_eq) = key_prefix_eq) then begin
      result_lines := (Printf.sprintf "%s = \"%s\"" key value) :: !result_lines;
      found := true;
      insert_before_next_table := false
    end
    else
      result_lines := line :: !result_lines
  ) lines;
  (* If we were in the target table at EOF and didn't find the key, append *)
  if not !found && !insert_before_next_table then begin
    result_lines := (Printf.sprintf "%s = \"%s\"" key value) :: !result_lines;
    found := true
  end;
  if not !found then
    Error (Printf.sprintf "table [%s] not found in TOML" table)
  else
    Ok (String.concat "\n" (List.rev !result_lines))

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

(** Update a field in a keeper TOML file on disk.
    Uses atomic write (temp file + rename) to prevent corruption
    from concurrent reads during the supervisor sweep.
    Returns [Ok ()] or [Error reason]. *)
let update_keeper_toml_field ~(path : string) ~(key : string)
    ~(value : string) : (unit, string) result =
  match Safe_ops.read_file_safe path with
  | Error e -> Error (Printf.sprintf "cannot read %s: %s" path e)
  | Ok content ->
    match update_field_in_content ~table:"keeper" ~key ~value content with
    | Error e -> Error e
    | Ok updated -> atomic_write_file ~path updated

(* Higher-level functions (profile_defaults_of_toml, load_keeper_toml,
   discover_keepers) live in Keeper_types_profile to avoid a circular
   dependency: this module must not reference Keeper_types_profile. *)
