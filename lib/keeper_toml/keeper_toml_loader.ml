(** Keeper_toml_loader -- typed keeper projection and comment-preserving edits
    over the Otoml semantic parser in [Keeper_toml_parser]. *)

(* tla-lint: file-scope: line-editor state is confined to one update call and
   never observed as keeper FSM state. Every [:=] in this file mutates only
   comment-preserving edit accumulators. *)


(** Parser types and logic extracted to [Keeper_toml_parser].
    Accessors and mutation operations below. *)

include Keeper_toml_parser


(* ================================================================ *)
(* TOML -> keeper_profile_defaults conversion                        *)
(* ================================================================ *)

let toml_string_opt (doc : toml_doc) (key : string) : string option =
  match List.assoc_opt key doc with
  | Some (Toml_string s) -> Some s
  | Some
      ( Toml_int _ | Toml_float _ | Toml_bool _ | Toml_string_array _ | Toml_array _
      | Toml_table _ | Toml_inline_table _ | Toml_table_array _ | Toml_offset_datetime _
      | Toml_local_datetime _ | Toml_local_date _ | Toml_local_time _ )
  | None -> None
;;

let toml_int_opt (doc : toml_doc) (key : string) : int option =
  match List.assoc_opt key doc with
  | Some (Toml_int i) -> Some i
  | Some
      ( Toml_string _ | Toml_float _ | Toml_bool _ | Toml_string_array _ | Toml_array _
      | Toml_table _ | Toml_inline_table _ | Toml_table_array _ | Toml_offset_datetime _
      | Toml_local_datetime _ | Toml_local_date _ | Toml_local_time _ )
  | None -> None
;;

let toml_float_opt (doc : toml_doc) (key : string) : float option =
  match List.assoc_opt key doc with
  | Some (Toml_float f) -> Some f
  | Some (Toml_int i) -> Some (float_of_int i)
  | Some
      ( Toml_string _ | Toml_bool _ | Toml_string_array _ | Toml_array _ | Toml_table _
      | Toml_inline_table _ | Toml_table_array _ | Toml_offset_datetime _
      | Toml_local_datetime _ | Toml_local_date _ | Toml_local_time _ )
  | None -> None
;;

let toml_bool_opt (doc : toml_doc) (key : string) : bool option =
  match List.assoc_opt key doc with
  | Some (Toml_bool b) -> Some b
  | Some
      ( Toml_string _ | Toml_int _ | Toml_float _ | Toml_string_array _ | Toml_array _
      | Toml_table _ | Toml_inline_table _ | Toml_table_array _ | Toml_offset_datetime _
      | Toml_local_datetime _ | Toml_local_date _ | Toml_local_time _ )
  | None -> None
;;

let toml_string_list (doc : toml_doc) (key : string) : string list =
  match List.assoc_opt key doc with
  | Some (Toml_string_array xs) -> xs
  | Some
      ( Toml_string _ | Toml_int _ | Toml_float _ | Toml_bool _ | Toml_array _
      | Toml_table _ | Toml_inline_table _ | Toml_table_array _ | Toml_offset_datetime _
      | Toml_local_datetime _ | Toml_local_date _ | Toml_local_time _ )
  | None -> []
;;

(* ================================================================ *)
(* TOML writer — line-level field update                            *)
(* ================================================================ *)

let assignment_equals_index line =
  let rec loop index quote escaped =
    if index >= String.length line
    then None
    else
      let character = String.get line index in
      match quote, escaped, character with
      | Some '"', true, _ -> loop (index + 1) quote false
      | Some '"', false, '\\' -> loop (index + 1) quote true
      | Some '"', false, '"' -> loop (index + 1) None false
      | Some '\'', _, '\'' -> loop (index + 1) None false
      | Some _, _, _ -> loop (index + 1) quote false
      | None, _, '"' -> loop (index + 1) (Some '"') false
      | None, _, '\'' -> loop (index + 1) (Some '\'') false
      | None, _, '=' -> Some index
      | None, _, _ -> loop (index + 1) None false
  in
  loop 0 None false
;;

let assignment_key_of_line trimmed =
  match assignment_equals_index trimmed with
  | None -> None
  | Some equals_at ->
    let raw_key = String.sub trimmed 0 equals_at |> String.trim in
    if String.equal raw_key ""
    then None
    else
      match parse_toml (raw_key ^ " = true") with
      | Ok [ parsed_key, _ ] -> Some parsed_key
      | Ok _ | Error _ -> None
;;

let assignment_end lines start =
  let rec loop index candidate =
    if index >= Array.length lines
    then None
    else
      let candidate =
        if index = start
        then lines.(index)
        else candidate ^ "\n" ^ lines.(index)
      in
      match parse_toml candidate with
      | Ok [ _, _ ] -> Some index
      | Ok _ | Error _ -> loop (index + 1) candidate
  in
  loop start ""
;;

let is_table_header trimmed =
  String.length trimmed > 0 && Char.equal trimmed.[0] '['
;;

let rewrite_field_in_content
      ~(table : string)
      ~(key : string)
      ~(replacement : string option)
      (content : string)
  : (string, string) result
  =
  let lines =
    content
    |> String.split_on_char '\n'
    |> List.map String_util.strip_trailing_cr
    |> Array.of_list
  in
  let table_header = Printf.sprintf "[%s]" table in
  let output = ref [] in
  let add_line line = output := line :: !output in
  let add_range first last =
    let rec loop index =
      if index <= last
      then (
        add_line lines.(index);
        loop (index + 1))
    in
    loop first
  in
  let replacement_line () =
    match replacement with
    | Some rendered -> Some (Printf.sprintf "%s = %s" key rendered)
    | None -> None
  in
  let rec loop index in_target_table found =
    if index >= Array.length lines
    then
      let found =
        if in_target_table && not found
        then (
          match replacement_line () with
          | Some line -> add_line line; true
          | None -> found)
        else found
      in
      if (match replacement with Some _ -> not found | None -> false)
      then Error (Printf.sprintf "table [%s] not found in TOML" table)
      else Ok (String.concat "\n" (List.rev !output))
    else
      let line = lines.(index) in
      let trimmed = String.trim line in
      if String.equal trimmed table_header
      then (
        add_line line;
        loop (index + 1) true found)
      else if in_target_table && is_table_header trimmed
      then (
        let found =
          if not found
          then (
            match replacement_line () with
            | Some replacement_line -> add_line replacement_line; true
            | None -> found)
          else found
        in
        add_line line;
        loop (index + 1) false found)
      else if in_target_table
      then (
        match assignment_key_of_line trimmed with
        | None ->
          add_line line;
          loop (index + 1) true found
        | Some parsed_key ->
          (match assignment_end lines index with
           | None ->
             Error
               (Printf.sprintf
                  "unterminated TOML assignment while editing [%s].%s"
                  table
                  parsed_key)
           | Some last_index ->
             if (not found) && String.equal key parsed_key
             then (
               (match replacement_line () with
                | Some replacement_line -> add_line replacement_line
                | None -> ());
               loop (last_index + 1) true true)
             else (
               add_range index last_index;
               loop (last_index + 1) true found)))
      else (
        add_line line;
        loop (index + 1) false found)
  in
  loop 0 false false
;;

(** Update or insert a key under a [table] in a TOML file.
    Preserves comments, formatting, and other fields.
    Returns [Ok new_content] or [Error reason]. *)
let update_rendered_field_in_content ~table ~key ~rendered_value content =
  rewrite_field_in_content
    ~table
    ~key
    ~replacement:(Some rendered_value)
    content
;;

let update_field_in_content ~table ~key ~value content =
  update_rendered_field_in_content
    ~table
    ~key
    ~rendered_value:(Otoml.Printer.to_string (Otoml.TomlString value) |> String.trim)
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

let rec otoml_value_of_toml_value = function
  | Toml_string value -> Ok (Otoml.TomlString value)
  | Toml_int value -> Ok (Otoml.TomlInteger value)
  | Toml_float value -> Ok (Otoml.TomlFloat value)
  | Toml_bool value -> Ok (Otoml.TomlBoolean value)
  | Toml_string_array values ->
    Ok (Otoml.TomlArray (List.map (fun value -> Otoml.TomlString value) values))
  | Toml_array values ->
    List.fold_right
      (fun value result ->
        Result.bind (otoml_value_of_toml_value value) (fun value ->
          Result.map (fun values -> value :: values) result))
      values
      (Ok [])
    |> Result.map (fun values -> Otoml.TomlArray values)
  | Toml_inline_table fields ->
    List.fold_right
      (fun (key, value) result ->
        Result.bind (otoml_value_of_toml_value value) (fun value ->
          Result.map (fun fields -> (key, value) :: fields) result))
      fields
      (Ok [])
    |> Result.map (fun fields -> Otoml.TomlInlineTable fields)
  | Toml_offset_datetime value -> Ok (Otoml.TomlOffsetDateTime value)
  | Toml_local_datetime value -> Ok (Otoml.TomlLocalDateTime value)
  | Toml_local_date value -> Ok (Otoml.TomlLocalDate value)
  | Toml_local_time value -> Ok (Otoml.TomlLocalTime value)
  | Toml_table _ | Toml_table_array _ ->
    Error "standard tables and table arrays cannot be nested in assignment values"
;;

let render_toml_value = function
  | Toml_table _ | Toml_table_array _ ->
    Error "standard tables and table arrays cannot be rendered as key assignments"
  | ( Toml_string _ | Toml_int _ | Toml_float _ | Toml_bool _ | Toml_string_array _
    | Toml_array _ | Toml_inline_table _ | Toml_offset_datetime _ | Toml_local_datetime _
    | Toml_local_date _ | Toml_local_time _ ) as value ->
    Result.map
      (fun value -> Otoml.Printer.to_string value |> String.trim)
      (otoml_value_of_toml_value value)
;;

let remove_field_in_content ~(table : string) ~(key : string) content =
  rewrite_field_in_content ~table ~key ~replacement:None content
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
              Result.bind (render_toml_value value) (fun rendered_value ->
                update_rendered_field_in_content
                  ~table:"keeper"
                  ~key
                  ~rendered_value
                  current)
            | Remove ->
              remove_field_in_content ~table:"keeper" ~key current))
        (Ok content)
        fields
    in
    Result.bind updated (atomic_write_file ~path)
;;

let create_keeper_toml_file ~(path : string) fields =
  if Fs_compat.file_exists path
  then Error (Printf.sprintf "refusing to overwrite existing keeper TOML: %s" path)
  else
    let rendered_fields =
      List.fold_right
        (fun (key, value) result ->
          Result.bind (render_toml_value value) (fun rendered_value ->
            Result.map
              (fun rendered ->
                Printf.sprintf "%s = %s" key rendered_value :: rendered)
              result))
        fields
        (Ok [])
    in
    Result.bind rendered_fields (fun rendered_fields ->
      let content =
        [ "# Generated by masc_keeper_up."; "[keeper]" ]
        @ rendered_fields
        |> String.concat "\n"
        |> fun rendered -> rendered ^ "\n"
      in
      Fs_compat.mkdir_p (Filename.dirname path);
      Fs_compat.save_file_atomic path content)
;;

(* Higher-level functions (profile_defaults_of_toml, load_keeper_toml,
   discover_keepers) live in Keeper_types_profile to avoid a circular
   dependency: this module must not reference Keeper_types_profile. *)
