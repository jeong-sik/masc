(** Keeper_toml_loader -- load keeper configuration from TOML files.

    Minimal TOML parser: tables, strings (basic + multiline),
    integers, floats, booleans, and string arrays.
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
        let in_str = ref false in
        let ok = ref true in
        for i = 0 to String.length inner - 1 do
          let c = inner.[i] in
          if !in_str then begin
            Buffer.add_char buf c;
            if c = '"' then in_str := false
            else if c = '\\' && i + 1 < String.length inner then
              () (* next char consumed naturally *)
          end
          else if c = ',' then begin
            items := Buffer.contents buf :: !items;
            Buffer.clear buf
          end
          else if c = '"' then begin
            in_str := true;
            Buffer.add_char buf c
          end
          else if is_ws c then ()
          else begin
            ok := false
          end
        done;
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
  String.length s >= 3 && s.[0] = '"' && s.[1] = '"' && s.[2] = '"'

let ends_with_triple_quote s =
  let len = String.length s in
  len >= 3 && s.[len-3] = '"' && s.[len-2] = '"' && s.[len-1] = '"'

let parse_toml (content : string) : (toml_doc, string) result =
  let lines = String.split_on_char '\n' content in
  let current_table = ref "" in
  let acc = ref [] in
  let error = ref None in
  let line_num = ref 0 in
  (* Multiline basic string (""" ... """) state *)
  let in_multiline = ref false in
  let ml_key = ref "" in
  let ml_buf = Buffer.create 256 in
  List.iter (fun raw_line ->
    incr line_num;
    if Option.is_none !error then begin
      if !in_multiline then begin
        (* Inside """ block — accumulate until closing """ *)
        let trimmed = String.trim raw_line in
        if ends_with_triple_quote trimmed then begin
          let before = String.sub trimmed 0 (String.length trimmed - 3) in
          if before <> "" then begin
            if Buffer.length ml_buf > 0 then Buffer.add_char ml_buf '\n';
            Buffer.add_string ml_buf before
          end;
          let full_key =
            if !current_table = "" then !ml_key
            else !current_table ^ "." ^ !ml_key
          in
          acc := (full_key, Toml_string (Buffer.contents ml_buf)) :: !acc;
          in_multiline := false;
          Buffer.clear ml_buf
        end else begin
          if Buffer.length ml_buf > 0 then Buffer.add_char ml_buf '\n';
          Buffer.add_string ml_buf raw_line
        end
      end
      else begin
        let line = String.trim raw_line in
        let line = strip_comment line in
        if line = "" then ()
        else if line.[0] = '[' then begin
          (* Table header *)
          let len = String.length line in
          if line.[len - 1] <> ']' then
            error := Some (Printf.sprintf "line %d: unterminated table header" !line_num)
          else begin
            let table_name =
              String.sub line 1 (len - 2) |> String.trim
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
              let trimmed_val = String.trim value_raw in
              if starts_with_triple_quote trimmed_val then begin
                (* Multiline basic string opening *)
                ml_key := key;
                Buffer.clear ml_buf;
                let after = String.sub trimmed_val 3 (String.length trimmed_val - 3) in
                let after = String.trim after in
                if after <> "" && ends_with_triple_quote after then begin
                  (* Single-line form: key = """content""" *)
                  let content_str = String.sub after 0 (String.length after - 3) in
                  let full_key =
                    if !current_table = "" then key
                    else !current_table ^ "." ^ key
                  in
                  acc := (full_key, Toml_string content_str) :: !acc
                end else begin
                  if after <> "" then
                    Buffer.add_string ml_buf after;
                  in_multiline := true
                end
              end else begin
                let full_key =
                  if !current_table = "" then key
                  else !current_table ^ "." ^ key
                in
                match parse_value value_raw with
                | Ok v -> acc := (full_key, v) :: !acc
                | Error e ->
                  error := Some (Printf.sprintf "line %d: %s" !line_num e)
              end
        end
      end
    end
  ) lines;
  if !in_multiline && Option.is_none !error then
    Error (Printf.sprintf "unterminated multiline string for key %s" !ml_key)
  else
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

(* Higher-level functions (profile_defaults_of_toml, load_keeper_toml,
   discover_keepers) live in Keeper_types_profile to avoid a circular
   dependency: this module must not reference Keeper_types_profile. *)
