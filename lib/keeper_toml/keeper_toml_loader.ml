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

let rec singleton_table_path = function
  | Otoml.TomlTable [] -> Some []
  | Otoml.TomlTable [ key, nested ] ->
    Option.map (fun path -> key :: path) (singleton_table_path nested)
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean _ | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray _ | Otoml.TomlTable (_ :: _) | Otoml.TomlInlineTable _
    | Otoml.TomlTableArray _ ) -> None
;;

let rec singleton_bool_path = function
  | Otoml.TomlBoolean true -> Some []
  | Otoml.TomlTable [ key, nested ] ->
    Option.map (fun path -> key :: path) (singleton_bool_path nested)
  | ( Otoml.TomlString _ | Otoml.TomlInteger _ | Otoml.TomlFloat _
    | Otoml.TomlBoolean false | Otoml.TomlOffsetDateTime _
    | Otoml.TomlLocalDateTime _ | Otoml.TomlLocalDate _ | Otoml.TomlLocalTime _
    | Otoml.TomlArray _ | Otoml.TomlTable [] | Otoml.TomlTable (_ :: _)
    | Otoml.TomlInlineTable _ | Otoml.TomlTableArray _ ) -> None
;;

type table_header =
  | Standard_table of string list
  | Other_table_header
  | Not_table_header

let table_header_of_line trimmed =
  if not (String.starts_with ~prefix:"[" trimmed)
  then Not_table_header
  else
    match Otoml.Parser.from_string_result trimmed with
    | Ok value ->
      (match singleton_table_path value with
       | Some path -> Standard_table path
       | None -> Other_table_header)
    | Error _ -> Other_table_header
;;

let assignment_path_of_line trimmed =
  match assignment_equals_index trimmed with
  | None -> None
  | Some equals_at ->
    let raw_key = String.sub trimmed 0 equals_at |> String.trim in
    if String.equal raw_key ""
    then None
    else
      match Otoml.Parser.from_string_result (raw_key ^ " = true") with
      | Ok value -> singleton_bool_path value
      | Error _ -> None
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

let rec path_is_prefix prefix path =
  match prefix, path with
  | [], _ -> true
  | prefix_head :: prefix_tail, path_head :: path_tail
    when String.equal prefix_head path_head -> path_is_prefix prefix_tail path_tail
  | _ -> false
;;

let rec drop_prefix prefix path =
  match prefix, path with
  | [], path -> Some path
  | prefix_head :: prefix_tail, path_head :: path_tail
    when String.equal prefix_head path_head -> drop_prefix prefix_tail path_tail
  | _ -> None
;;

let longest_target_table_path ~base_path ~target_path lines =
  let choose best path =
    if path_is_prefix base_path path
       && path_is_prefix path target_path
       && List.length path < List.length target_path
    then
      match best with
      | Some best when List.length best >= List.length path -> Some best
      | Some _ | None -> Some path
    else best
  in
  let rec loop index best =
    if index >= Array.length lines
    then Ok best
    else
      let trimmed = String.trim lines.(index) in
      match table_header_of_line trimmed with
      | Standard_table path -> loop (index + 1) (choose best path)
      | Other_table_header -> loop (index + 1) best
      | Not_table_header ->
        (match assignment_path_of_line trimmed with
         | None -> loop (index + 1) best
         | Some assignment_path ->
           (match assignment_end lines index with
            | Some last_index -> loop (last_index + 1) best
            | None ->
              Error
                (Printf.sprintf
                   "unterminated TOML assignment while locating %s"
                   (Otoml.string_of_path assignment_path))))
  in
  loop 0 None
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
  match
    ( (match table_header_of_line (Printf.sprintf "[%s]" table) with
       | Standard_table path -> Some path
       | Other_table_header | Not_table_header -> None)
    , assignment_path_of_line (key ^ " = true") )
  with
  | Some base_path, Some key_path ->
    let target_path = base_path @ key_path in
    (match longest_target_table_path ~base_path ~target_path lines with
     | Error _ as error -> error
     | Ok None -> Error (Printf.sprintf "table [%s] not found in TOML" table)
     | Ok (Some insertion_table_path) ->
       let insertion_key_path =
         match drop_prefix insertion_table_path target_path with
         | Some (_ :: _ as path) -> path
         | Some [] | None -> key_path
       in
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
       let replacement_line path =
         match replacement with
         | Some rendered ->
           Some
             (Printf.sprintf "%s = %s" (Otoml.string_of_path path) rendered)
         | None -> None
       in
       let insert_if_missing current_table_path found =
         if (not found) && current_table_path = Some insertion_table_path
         then
           match replacement_line insertion_key_path with
           | Some line -> add_line line; true
           | None -> found
         else found
       in
       let rec loop index current_table_path found =
         if index >= Array.length lines
         then (
           let found = insert_if_missing current_table_path found in
           if (match replacement with Some _ -> not found | None -> false)
           then Error (Printf.sprintf "table [%s] not found in TOML" table)
           else Ok (String.concat "\n" (List.rev !output)))
         else
           let line = lines.(index) in
           let trimmed = String.trim line in
           match table_header_of_line trimmed with
           | Standard_table next_table_path ->
             let found = insert_if_missing current_table_path found in
             add_line line;
             loop (index + 1) (Some next_table_path) found
           | Other_table_header ->
             let found = insert_if_missing current_table_path found in
             add_line line;
             loop (index + 1) None found
           | Not_table_header ->
             (match current_table_path, assignment_path_of_line trimmed with
              | Some table_path, Some assignment_path ->
                (match assignment_end lines index with
                 | None ->
                   Error
                     (Printf.sprintf
                        "unterminated TOML assignment while editing %s"
                        (Otoml.string_of_path (table_path @ assignment_path)))
                 | Some last_index ->
                   if (not found) && table_path @ assignment_path = target_path
                   then (
                     (match replacement_line assignment_path with
                      | Some line -> add_line line
                      | None -> ());
                     loop (last_index + 1) current_table_path true)
                   else (
                     add_range index last_index;
                     loop (last_index + 1) current_table_path found))
              | Some _, None | None, _ ->
                add_line line;
                loop (index + 1) current_table_path found)
       in
       loop 0 None false)
  | None, _ | _, None ->
    Error (Printf.sprintf "invalid TOML field path [%s].%s" table key)
;;

(** Update or insert a key under a [table] in a TOML file.
    Dotted keys follow their parsed TOML path, so an existing nested table is
    edited in place instead of creating a second definition in its parent.
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

let before_rename_failure ~path detail =
  { Fs_compat.path
  ; stage = Fs_compat.Before_rename
  ; exception_ = Failure detail
  ; backtrace = Printexc.get_callstack 16
  }
;;

let edit_keeper_toml_fields_strict_staged ~(path : string) fields =
  match Safe_ops.read_file_safe path with
  | Error error ->
    Error (before_rename_failure ~path (Printf.sprintf "cannot read %s: %s" path error))
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
    (match updated with
     | Error detail ->
       Error (before_rename_failure ~path detail)
     | Ok content -> Fs_compat.save_file_atomic_strict_staged path content)
;;

let edit_keeper_toml_fields ~path fields =
  edit_keeper_toml_fields_strict_staged ~path fields
  |> Result.map_error Fs_compat.atomic_replace_failure_to_string
;;

let create_keeper_toml_file_strict_staged ~(path : string) fields =
  if Fs_compat.file_exists path
  then
    Error
      (before_rename_failure
         ~path
         (Printf.sprintf "refusing to overwrite existing keeper TOML: %s" path))
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
    Result.bind
      (Result.map_error (before_rename_failure ~path) rendered_fields)
      (fun rendered_fields ->
      let content =
        [ "# Generated by masc_keeper_up."; "[keeper]" ]
        @ rendered_fields
        |> String.concat "\n"
        |> fun rendered -> rendered ^ "\n"
      in
      Fs_compat.mkdir_p (Filename.dirname path);
      Fs_compat.save_file_atomic_strict_staged path content)
;;

let create_keeper_toml_file ~path fields =
  create_keeper_toml_file_strict_staged ~path fields
  |> Result.map_error Fs_compat.atomic_replace_failure_to_string
;;

(* Higher-level functions (profile_defaults_of_toml, load_keeper_toml,
   discover_keepers) live in Keeper_types_profile to avoid a circular
   dependency: this module must not reference Keeper_types_profile. *)
