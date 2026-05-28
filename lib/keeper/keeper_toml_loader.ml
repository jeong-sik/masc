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
       let line = String_util.strip_trailing_cr raw_line in
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
         && ((String.starts_with trimmed ~prefix:key_prefix)
             || (String.starts_with trimmed ~prefix:key_prefix_eq))
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
