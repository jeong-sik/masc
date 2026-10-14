type unreachable =
  | Inline_ancestor of string list
  | Declared_another_way of string list

let unreachable_message ~table_path = function
  | Inline_ancestor ancestor ->
    Printf.sprintf
      "[%s] is written inline, which this command cannot add a table to. Add [%s] in \
       runtime.toml"
      (String.concat "." ancestor)
      (String.concat "." table_path)
  | Declared_another_way table ->
    Printf.sprintf
      "[%s] is written inline or with dotted keys, which this command does not edit. Change \
       it in runtime.toml"
      (String.concat "." table)

let standard_header_present ~table_path text =
  let path = String.concat "." table_path in
  let lines, _ = Toml_line_editor.split_lines text in
  List.exists2
    (fun line structural -> structural && Toml_line_editor.is_table ~path line)
    lines
    (Toml_line_editor.structural_lines lines)

let inline_ancestor ~ancestors text =
  match Otoml.Parser.from_string_result text with
  | Error _ -> None
  | Ok toml ->
    List.find_opt
      (fun path ->
         match Otoml.find_opt toml Fun.id path with
         | Some (Otoml.TomlInlineTable _) -> true
         | Some
             Otoml.(
               TomlString _ | TomlInteger _ | TomlFloat _ | TomlBoolean _
               | TomlOffsetDateTime _ | TomlLocalDateTime _ | TomlLocalDate _
               | TomlLocalTime _ | TomlArray _ | TomlTable _ | TomlTableArray _)
         | None -> false)
      ancestors

let check_editable ~table_path ~ancestors ~declared text =
  match inline_ancestor ~ancestors text with
  | Some ancestor -> Error (Inline_ancestor ancestor)
  | None ->
    if declared && not (standard_header_present ~table_path text)
    then Error (Declared_another_way table_path)
    else Ok ()

type 'e commit_error =
  | Changed_meanwhile
  | Edit_refused of 'e
  | Not_written of string

let revision_of_observation (observation : Runtime.config_observation) =
  Runtime.config_source_revision_to_string observation.source_revision

exception Stop of [ `Changed | `Refused ]

let commit ~runtime_config_path ~revision ~edit =
  let refusal = ref None in
  let edit_locked text =
    let current =
      revision_of_observation (Runtime.config_observation ~path:runtime_config_path text)
    in
    if not (String.equal current revision) then raise (Stop `Changed);
    match edit text with
    | Ok text -> text
    | Error error ->
      refusal := Some error;
      raise (Stop `Refused)
  in
  match Runtime.edit_config_text ~runtime_config_path edit_locked with
  | Ok _receipt -> Ok ()
  | Error reason -> Error (Not_written reason)
  | exception Stop `Changed -> Error Changed_meanwhile
  | exception Stop `Refused ->
    (match !refusal with
     | Some error -> Error (Edit_refused error)
     | None -> Error (Not_written "the edit was refused without a reason"))
