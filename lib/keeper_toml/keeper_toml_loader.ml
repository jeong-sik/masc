(** Keeper_toml_loader -- load keeper configuration from TOML files.

    Minimal TOML parser: tables, strings (basic + multiline),
    integers, floats, booleans, and string arrays (single-line and
    multi-line).
    Enough to express all keeper_profile_defaults fields. *)

(* tla-lint: file-scope: parser local state — TOML lexer accumulators
   (line buffer, multiline-string buffer, current_table, key/value list)
   are confined to a single parse_lines call and never observed as
   keeper FSM state. Every [:=] / [<-] in this file mutates parser-
   internal scaffolding, not state-machine state. *)


(** Parser types and logic extracted to [Keeper_toml_parser].
    Accessors and mutation operations below. *)

include Keeper_toml_parser


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
  | Some (Toml_int i) -> Some (float_of_int i)
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

let line_assigns_key ~(key : string) (trimmed : string) =
  match String.index_opt trimmed '=' with
  | None -> false
  | Some equals_at ->
    String.equal
      key
      (String.sub trimmed 0 equals_at |> String.trim)
;;

(** Update or insert a key under a [table] in a TOML file.
    Preserves comments, formatting, and other fields.
    Returns [Ok new_content] or [Error reason]. *)
let update_rendered_field_in_content
      ~(table : string)
      ~(key : string)
      ~(rendered_value : string)
      (content : string)
  : (string, string) result
  =
  let lines = String.split_on_char '\n' content in
  let table_header = Printf.sprintf "[%s]" table in
  let in_target_table = ref false in
  let found = ref false in
  let result_lines = ref [] in
  let insert_before_next_table = ref false in
  List.iter
    (fun raw_line ->
       let line = String_util.strip_trailing_cr raw_line in
       let trimmed = String.trim line in
       if !insert_before_next_table && String.length trimmed > 0 && trimmed.[0] = '['
       then (
         (* New table started — insert the field before it *)
         result_lines := Printf.sprintf "%s = %s" key rendered_value :: !result_lines;
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
           result_lines := Printf.sprintf "%s = %s" key rendered_value :: !result_lines;
           found := true;
           insert_before_next_table := false);
         result_lines := line :: !result_lines)
       else if
         !in_target_table
         && (not !found)
         && line_assigns_key ~key trimmed
       then (
         result_lines := Printf.sprintf "%s = %s" key rendered_value :: !result_lines;
         found := true;
         insert_before_next_table := false)
       else result_lines := line :: !result_lines)
    lines;
  (* If we were in the target table at EOF and didn't find the key, append *)
  if (not !found) && !insert_before_next_table
  then (
    result_lines := Printf.sprintf "%s = %s" key rendered_value :: !result_lines;
    found := true);
  if not !found
  then Error (Printf.sprintf "table [%s] not found in TOML" table)
  else Ok (String.concat "\n" (List.rev !result_lines))
;;

let update_field_in_content ~table ~key ~value content =
  update_rendered_field_in_content
    ~table
    ~key
    ~rendered_value:(Printf.sprintf "\"%s\"" value)
    content
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

let update_keeper_toml_bool_fields ~(path : string) fields
  : (unit, string) result
  =
  match Safe_ops.read_file_safe path with
  | Error e -> Error (Printf.sprintf "cannot read %s: %s" path e)
  | Ok content ->
    let updated =
      List.fold_left
        (fun result (key, value) ->
          Result.bind result (fun current ->
            update_rendered_field_in_content
              ~table:"keeper"
              ~key
              ~rendered_value:(string_of_bool value)
              current))
        (Ok content)
        fields
    in
    (match updated with
     | Error _ as error -> error
     | Ok updated -> atomic_write_file ~path updated)
;;

type toml_edit =
  | Set of toml_value
  | Remove

let toml_escape_string value =
  let buffer = Buffer.create (String.length value + 8) in
  String.iter
    (function
      | '\\' -> Buffer.add_string buffer "\\\\"
      | '"' -> Buffer.add_string buffer "\\\""
      | '\n' -> Buffer.add_string buffer "\\n"
      | '\r' -> Buffer.add_string buffer "\\r"
      | '\t' -> Buffer.add_string buffer "\\t"
      | c -> Buffer.add_char buffer c)
    value;
  Buffer.contents buffer
;;

let render_toml_value = function
  | Toml_string value -> Printf.sprintf "\"%s\"" (toml_escape_string value)
  | Toml_int value -> string_of_int value
  | Toml_float value -> string_of_float value
  | Toml_bool value -> string_of_bool value
  | Toml_string_array values ->
    values
    |> List.map (fun value ->
         Printf.sprintf "\"%s\"" (toml_escape_string value))
    |> String.concat ", "
    |> Printf.sprintf "[%s]"
;;

let remove_field_in_content ~(table : string) ~(key : string) content =
  let table_header = Printf.sprintf "[%s]" table in
  let _, lines =
    content
    |> String.split_on_char '\n'
    |> List.fold_left
         (fun (in_target_table, acc) raw_line ->
           let line = String_util.strip_trailing_cr raw_line in
           let trimmed = String.trim line in
           let starts_table =
             String.length trimmed > 0 && Char.equal trimmed.[0] '['
           in
           let in_target_table =
             if String.equal trimmed table_header then true
             else if starts_table then false
             else in_target_table
           in
           let is_target_field =
             in_target_table
             && line_assigns_key ~key trimmed
           in
           if is_target_field
           then in_target_table, acc
           else in_target_table, line :: acc)
         (false, [])
  in
  String.concat "\n" (List.rev lines)
;;

let edit_keeper_toml_fields ~(path : string) fields =
  match Safe_ops.read_file_safe path with
  | Error error -> Error (Printf.sprintf "cannot read %s: %s" path error)
  | Ok content ->
    let updated =
      List.fold_left
        (fun result (key, edit) ->
          Result.bind result (fun current ->
            match edit with
            | Set value ->
              update_rendered_field_in_content
                ~table:"keeper"
                ~key
                ~rendered_value:(render_toml_value value)
                current
            | Remove ->
              Ok (remove_field_in_content ~table:"keeper" ~key current)))
        (Ok content)
        fields
    in
    Result.bind updated (atomic_write_file ~path)
;;

let create_keeper_toml_file ~(path : string) fields =
  if Fs_compat.file_exists path
  then Error (Printf.sprintf "refusing to overwrite existing keeper TOML: %s" path)
  else
    let content =
      [ "# Generated by masc_keeper_up."; "[keeper]" ]
      @ List.map
          (fun (key, value) ->
            Printf.sprintf "%s = %s" key (render_toml_value value))
          fields
      |> String.concat "\n"
      |> fun rendered -> rendered ^ "\n"
    in
    Fs_compat.mkdir_p (Filename.dirname path);
    Fs_compat.save_file_atomic path content
;;

(* Higher-level functions (profile_defaults_of_toml, load_keeper_toml,
   discover_keepers) live in Keeper_types_profile to avoid a circular
   dependency: this module must not reference Keeper_types_profile. *)
