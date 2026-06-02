type value =
  | V_int of int
  | V_string of string
  | V_bool of bool
  | V_raw of string

type step = (string * value) list

type state = {
  spec_module : string;
  trace_file  : string;
  bindings    : (string * value) list;
  steps       : step list;
}

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  close_in ic;
  Bytes.unsafe_to_string buf

let module_name_re =
  Str.regexp "----[ \t]+MODULE[ \t]+\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]+----"

let extract_module_name source =
  if Str.string_match module_name_re source 0
     || (try ignore (Str.search_forward module_name_re source 0); true
         with Not_found -> false)
  then Some (Str.matched_group 1 source)
  else None

let inv_open_re =
  Str.regexp "_inv[ \t]*==[ \t\n]*~("

(* Extract the body of [_inv == ~( ... )]. OCaml's [Str] does not support
   lazy quantifiers, so a regex with [*?] will match too greedily and may
   slurp later operators (e.g. [_expression] subexpressions containing
   [s = 1]). We track balanced parentheses and skip string literals to find
   the matching close-paren. *)
let extract_inv_body source =
  match (try Some (Str.search_forward inv_open_re source 0)
         with Not_found -> None) with
  | None -> None
  | Some _ ->
      let start = Str.match_end () in
      let n = String.length source in
      let depth = ref 1 in
      let i = ref start in
      let in_string = ref false in
      let result = ref None in
      while !result = None && !i < n do
        let c = source.[!i] in
        if !in_string then begin
          if c = '"' then in_string := false;
          incr i
        end else if c = '"' then begin
          in_string := true; incr i
        end else if c = '(' then begin
          incr depth; incr i
        end else if c = ')' then begin
          decr depth;
          if !depth = 0 then result := Some !i
          else incr i
        end else
          incr i
      done;
      (match !result with
       | None -> None
       | Some e -> Some (String.sub source start (e - start)))

let parse_value raw =
  let s = String.trim raw in
  let s =
    if String.length s >= 2 && s.[0] = '(' && s.[String.length s - 1] = ')'
    then String.sub s 1 (String.length s - 2) |> String.trim
    else s
  in
  match s with
  | "TRUE"  -> Some (V_bool true)
  | "FALSE" -> Some (V_bool false)
  | s when String.length s >= 2 && s.[0] = '"' && s.[String.length s - 1] = '"' ->
      Some (V_string (String.sub s 1 (String.length s - 2)))
  | s ->
      (try Some (V_int (int_of_string s)) with Failure _ -> None)

let parse_value_with_raw raw =
  match parse_value raw with
  | Some v -> v
  | None   -> V_raw (String.trim raw)

let binding_re =
  Str.regexp
    "\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t]*=[ \t]*\
     \\(\"[^\"]*\"\\|TRUE\\|FALSE\\|([^)]*)\\|-?[0-9]+\\)"

let extract_bindings body =
  let acc = ref [] in
  let pos = ref 0 in
  (try
    while true do
      let p = Str.search_forward binding_re body !pos in
      let name = Str.matched_group 1 body in
      let raw  = Str.matched_group 2 body in
      (* Skip TLCGet("level") helper — not a state variable. *)
      if name <> "level" then begin
        match parse_value raw with
        | Some v -> acc := (name, v) :: !acc
        | None   -> ()
      end;
      pos := p + String.length (Str.matched_string body)
    done;
    assert false
  with Not_found -> ());
  List.rev !acc

(* --------------------------------------------------------------------- *)
(* _TETrace step sequence extraction                                     *)
(* --------------------------------------------------------------------- *)

(* Find the closing ">>" that matches the implicit "<<" depth-1 starting at
   [seq_start]. Tracks nested "<<...>>" tuples and string literals so
   record fields like [attempted |-> {<<0, "a">>}] do not unbalance the
   outer sequence. *)
let find_matching_double_gt source seq_start =
  let n = String.length source in
  let depth = ref 1 in
  let in_string = ref false in
  let i = ref seq_start in
  let result = ref None in
  while !result = None && !i < n do
    let c = source.[!i] in
    let next = if !i + 1 < n then source.[!i + 1] else '\000' in
    if !in_string then begin
      if c = '"' then in_string := false;
      incr i
    end else if c = '<' && next = '<' then begin
      incr depth; i := !i + 2
    end else if c = '>' && next = '>' then begin
      decr depth;
      if !depth = 0 then result := Some !i
      else i := !i + 2
    end else if c = '"' then begin
      in_string := true; incr i
    end else
      incr i
  done;
  !result

(* Find a balanced [...] starting at [start]. Returns (open, close+1) where
   source.[open] = '[' and source.[close] = ']'. Tracks nested {} () [] <<>>
   and strings so record values may contain set/tuple/paren tokens. *)
let find_record_at source start =
  let n = String.length source in
  if start >= n || source.[start] <> '[' then None
  else
    let depth = ref 0 in
    let in_string = ref false in
    let i = ref start in
    let result = ref None in
    while !result = None && !i < n do
      let c = source.[!i] in
      let next = if !i + 1 < n then source.[!i + 1] else '\000' in
      if !in_string then begin
        if c = '"' then in_string := false;
        incr i
      end else if c = '<' && next = '<' then begin
        incr depth; i := !i + 2
      end else if c = '>' && next = '>' then begin
        decr depth; i := !i + 2
      end else if c = '"' then begin
        in_string := true; incr i
      end else if c = '{' || c = '(' then begin
        incr depth; incr i
      end else if c = '}' || c = ')' then begin
        decr depth; incr i
      end else if c = '[' then begin
        incr depth; incr i
      end else if c = ']' then begin
        decr depth;
        if !depth = 0 then result := Some !i
        else incr i
      end else
        incr i
    done;
    match !result with
    | None -> None
    | Some e -> Some (start, e + 1)

(* Split [s] on top-level commas, ignoring commas inside nested brackets,
   tuples, or strings. Used to break a record body into its field=value
   entries. *)
let split_top_level_commas s =
  let n = String.length s in
  let parts = ref [] in
  let buf = Buffer.create 32 in
  let depth = ref 0 in
  let in_string = ref false in
  let i = ref 0 in
  while !i < n do
    let c = s.[!i] in
    let next = if !i + 1 < n then s.[!i + 1] else '\000' in
    if !in_string then begin
      if c = '"' then in_string := false;
      Buffer.add_char buf c;
      incr i
    end else if c = '<' && next = '<' then begin
      incr depth;
      Buffer.add_char buf '<'; Buffer.add_char buf '<';
      i := !i + 2
    end else if c = '>' && next = '>' then begin
      decr depth;
      Buffer.add_char buf '>'; Buffer.add_char buf '>';
      i := !i + 2
    end else if c = '"' then begin
      in_string := true;
      Buffer.add_char buf c;
      incr i
    end else if c = '{' || c = '[' || c = '(' then begin
      incr depth;
      Buffer.add_char buf c;
      incr i
    end else if c = '}' || c = ']' || c = ')' then begin
      decr depth;
      Buffer.add_char buf c;
      incr i
    end else if c = ',' && !depth = 0 then begin
      parts := Buffer.contents buf :: !parts;
      Buffer.clear buf;
      incr i
    end else begin
      Buffer.add_char buf c;
      incr i
    end
  done;
  if Buffer.length buf > 0 then
    parts := Buffer.contents buf :: !parts;
  List.rev !parts

let field_arrow_re =
  Str.regexp "[ \t\n]*\\([A-Za-z_][A-Za-z0-9_]*\\)[ \t\n]*|->[ \t\n]*"

let parse_step_body body =
  let parts = split_top_level_commas body in
  List.filter_map
    (fun raw_part ->
      let part = String.trim raw_part in
      if part = "" then None
      else if Str.string_match field_arrow_re part 0 then
        let name = Str.matched_group 1 part in
        let value_raw =
          String.trim (String.sub part (Str.match_end ())
                         (String.length part - Str.match_end ()))
        in
        Some (name, parse_value_with_raw value_raw)
      else None)
    parts

let tetrace_module_re =
  Str.regexp "----[ \t]+MODULE[ \t]+[A-Za-z_][A-Za-z0-9_]*_TETrace[ \t]+----"

let trace_open_re =
  Str.regexp "trace[ \t\n]*==[ \t\n]*<<"

(* Walk [region] (the body between the outer "<<" and ">>") and extract every
   top-level "[...]" record as a step. Skips characters between records so
   commas, parentheses, and whitespace are ignored. *)
let extract_steps_from_region region =
  let n = String.length region in
  let acc = ref [] in
  let i = ref 0 in
  let in_string = ref false in
  while !i < n do
    let c = region.[!i] in
    if !in_string then begin
      if c = '"' then in_string := false;
      incr i
    end else if c = '"' then begin
      in_string := true;
      incr i
    end else if c = '[' then begin
      match find_record_at region !i with
      | None -> i := n
      | Some (s, e) ->
          let inner = String.sub region (s + 1) (e - s - 2) in
          let step = parse_step_body inner in
          if step <> [] then acc := step :: !acc;
          i := e
    end else
      incr i
  done;
  List.rev !acc

let extract_steps source =
  match (try Some (Str.search_forward tetrace_module_re source 0)
         with Not_found -> None) with
  | None -> []
  | Some _ ->
      let after_header = Str.match_end () in
      (match (try Some (Str.search_forward trace_open_re source after_header)
              with Not_found -> None) with
       | None -> []
       | Some _ ->
           let seq_start = Str.match_end () in
           (match find_matching_double_gt source seq_start with
            | None -> []
            | Some seq_end ->
                let region = String.sub source seq_start (seq_end - seq_start) in
                extract_steps_from_region region))

let parse_file path =
  match Sys.file_exists path with
  | false -> Error (Printf.sprintf "file not found: %s" path)
  | true ->
    let source = read_file path in
    match extract_module_name source, extract_inv_body source with
    | None, _ -> Error "could not extract MODULE name"
    | _, None -> Error "could not extract _inv operator body"
    | Some spec_module, Some body ->
      let bindings = extract_bindings body in
      if bindings = [] then
        Error "no parseable bindings in _inv body"
      else
        let steps = extract_steps source in
        Ok { spec_module; trace_file = path; bindings; steps }
