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

let starts_with_triple_quote (s : string) : bool =
  let t = String.trim s in
  String.length t >= 3
  && t.[0] = '"' && t.[1] = '"' && t.[2] = '"'

let extract_after_triple_quote (s : string) : string =
  let t = String.trim s in
  String.sub t 3 (String.length t - 3)

let strip_trailing_cr (s : string) : string =
  let len = String.length s in
  if len > 0 && s.[len - 1] = '\r' then String.sub s 0 (len - 1) else s

let parse_toml (content : string) : (toml_doc, string) result =
  let lines = String.split_on_char '\n' content in
  let current_table = ref "" in
  let acc = ref [] in
  let error = ref None in
  let line_num = ref 0 in
  (* Multiline string accumulation state *)
  let ml_key = ref "" in
  let ml_buf = Buffer.create 256 in
  let ml_active = ref false in
  let ml_start_line = ref 0 in
  let emit_kv full_key v =
    acc := (full_key, v) :: !acc
  in
  List.iter (fun raw_line ->
    incr line_num;
    if Option.is_none !error then begin
      if !ml_active then begin
        (* Inside a multiline basic string: accumulate until closing triple-quote *)
        let line_cr = strip_trailing_cr raw_line in
        let trimmed = String.trim line_cr in
        (* Check if this line contains the closing triple-quote *)
        match String.index_opt trimmed '"' with
        | Some _ when String.length trimmed >= 3 ->
          (* Look for triple-quote anywhere in the line *)
          let len = String.length line_cr in
          let rec find_close i =
            if i + 2 >= len then None
            else if line_cr.[i] = '"' && line_cr.[i+1] = '"' && line_cr.[i+2] = '"' then
              Some i
            else find_close (i + 1)
          in
          (match find_close 0 with
           | Some pos ->
             if Buffer.length ml_buf > 0 then Buffer.add_char ml_buf '\n';
             Buffer.add_string ml_buf (String.sub line_cr 0 pos);
             let value = Buffer.contents ml_buf in
             (* Validate no unexpected content after closing triple-quote *)
             let trailing = String.sub line_cr (pos + 3) (len - pos - 3) |> String.trim in
             if trailing <> "" && (String.length trailing = 0 || trailing.[0] <> '#') then
               error := Some (Printf.sprintf "line %d: unexpected characters after closing multiline delimiter" !line_num)
             else begin
               emit_kv !ml_key (Toml_string value);
               ml_active := false;
               Buffer.clear ml_buf
             end
           | None ->
             if Buffer.length ml_buf > 0 then Buffer.add_char ml_buf '\n';
             Buffer.add_string ml_buf line_cr)
        | _ ->
          if Buffer.length ml_buf > 0 then Buffer.add_char ml_buf '\n';
          Buffer.add_string ml_buf line_cr
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
              let full_key =
                if !current_table = "" then key
                else !current_table ^ "." ^ key
              in
              if starts_with_triple_quote value_raw then begin
                (* Start multiline basic string *)
                let after = extract_after_triple_quote value_raw in
                (* Check if closing triple-quote is on the same line *)
                let rec find_close_in s i =
                  if i + 2 >= String.length s then None
                  else if s.[i] = '"' && s.[i+1] = '"' && s.[i+2] = '"' then Some i
                  else find_close_in s (i + 1)
                in
                match find_close_in after 0 with
                | Some pos ->
                  let value = String.sub after 0 pos in
                  let trailing_start = pos + 3 in
                  let trailing = String.sub after trailing_start (String.length after - trailing_start) |> String.trim in
                  if trailing <> "" && (String.length trailing = 0 || trailing.[0] <> '#') then
                    error := Some (Printf.sprintf "line %d: unexpected characters after closing multiline delimiter" !line_num)
                  else
                    emit_kv full_key (Toml_string value)
                | None ->
                  ml_key := full_key;
                  ml_active := true;
                  ml_start_line := !line_num;
                  Buffer.clear ml_buf;
                  Buffer.add_string ml_buf after
              end
              else
                match parse_value value_raw with
                | Ok v -> emit_kv full_key v
                | Error e ->
                  error := Some (Printf.sprintf "line %d: %s" !line_num e)
        end
      end
    end
  ) lines;
  if !ml_active && Option.is_none !error then
    error := Some (Printf.sprintf "line %d: unterminated multiline string for key '%s'" !ml_start_line !ml_key);
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
