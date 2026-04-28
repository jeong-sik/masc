type value =
  | V_int of int
  | V_string of string
  | V_bool of bool

type state = {
  spec_module : string;
  trace_file  : string;
  bindings    : (string * value) list;
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

let inv_block_re =
  Str.regexp "_inv[ \t]*==[ \t\n]*~([ \t\n]*\\(\\(.\\|\n\\)*?\\))"

let extract_inv_body source =
  try
    let _ = Str.search_forward inv_block_re source 0 in
    Some (Str.matched_group 1 source)
  with Not_found -> None

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
        Ok { spec_module; trace_file = path; bindings }
