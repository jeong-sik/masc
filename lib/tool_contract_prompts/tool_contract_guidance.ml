(** Tool_contract_guidance — externalized tool-contract prose.

    Contract prose lives under [config/prompts/] so operators can tune it
    without editing OCaml string literals.  Resolution order:

    1. Prompt_registry effective value, once startup has loaded prompt files or
       overrides.
    2. Active config prompt file resolved by Config_dir_resolver.
    3. Checked-in seed prompt file found from the current working directory.

    Missing content returns an explicit config-drift marker instead of a
    stale in-code fallback. *)

let strip_frontmatter content =
  let lines = String.split_on_char '\n' content in
  match lines with
  | first :: rest when String.trim first = "---" ->
    let rec drop_until_close = function
      | [] -> None
      | line :: remaining when String.trim line = "---" -> Some remaining
      | _ :: remaining -> drop_until_close remaining
    in
    (match drop_until_close rest with
     | Some ("" :: body_lines) -> String.concat "\n" body_lines
     | Some body_lines -> String.concat "\n" body_lines
     | None -> content)
  | _ -> content
;;

let read_prompt_file path =
  try
    if Sys.file_exists path && not (Sys.is_directory path)
    then
      let text = Fs_compat.load_file path |> strip_frontmatter |> String.trim in
      if String.equal text "" then None else Some text
    else None
  with
  | Sys_error _ -> None
;;

let prompt_filename key = key ^ ".md"

let prompt_path_in_dir dir key =
  Filename.concat dir (prompt_filename key)
;;

let rec find_seed_prompt_from dir key hops =
  if hops > 8
  then None
  else
    let candidate =
      Filename.concat (Filename.concat dir "config/prompts") (prompt_filename key)
    in
    if Sys.file_exists candidate
    then Some candidate
    else
      let parent = Filename.dirname dir in
      if String.equal parent dir
      then None
      else find_seed_prompt_from parent key (hops + 1)
;;

let seed_prompt_path key =
  let cwd_candidate = find_seed_prompt_from (Sys.getcwd ()) key 0 in
  match cwd_candidate with
  | Some _ as path -> path
  | None ->
    let exe_dir = Filename.dirname Sys.executable_name in
    find_seed_prompt_from exe_dir key 0
;;

let registry_prompt key =
  let value = Prompt_registry.get_prompt key |> String.trim in
  if String.equal value "" then None else Some value
;;

let active_config_prompt key =
  Config_dir_resolver.prompts_dir ()
  |> fun dir -> prompt_path_in_dir dir key
  |> read_prompt_file
;;

let seed_prompt key =
  match seed_prompt_path key with
  | None -> None
  | Some path -> read_prompt_file path
;;

let missing_marker key =
  Printf.sprintf "[Tool contract config drift: missing %s.md]" key
;;

let prompt_text key =
  match registry_prompt key with
  | Some text -> text
  | None ->
    (match active_config_prompt key with
     | Some text -> text
     | None ->
       (match seed_prompt key with
        | Some text -> text
        | None -> missing_marker key))
;;

let task_lifecycle_rule () =
  prompt_text Tool_contract_prompt_names.task_lifecycle_rule
;;

let task_lifecycle_workflow () =
  prompt_text Tool_contract_prompt_names.task_lifecycle_workflow
;;
