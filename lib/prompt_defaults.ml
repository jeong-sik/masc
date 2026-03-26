(** Prompt_defaults — Auto-discovers prompt metadata from markdown frontmatter.
    Call [bootstrap_runtime] during server startup to scan config/prompts/ and
    register all prompts that have YAML frontmatter (description, category,
    template_variables).  No OCaml code changes needed to add new prompts. *)

let existing_dir path =
  Sys.file_exists path && Sys.is_directory path

let dedupe_keep_order values =
  let rec loop acc = function
    | [] -> List.rev acc
    | value :: rest ->
        if List.mem value acc then loop acc rest
        else loop (value :: acc) rest
  in
  loop [] values

let prompt_markdown_dir_candidates ~workspace_path ~base_path =
  let workspace_candidate = Filename.concat workspace_path "config/prompts" in
  let base_candidate = Filename.concat base_path "config/prompts" in
  let cwd_candidate = Filename.concat (Sys.getcwd ()) "config/prompts" in
  let exe_candidate =
    let exe_dir = Filename.dirname Sys.executable_name in
    let root = Filename.dirname (Filename.dirname (Filename.dirname exe_dir)) in
    Filename.concat root "config/prompts"
  in
  let dune_candidate =
    match Sys.getenv_opt "DUNE_SOURCEROOT" with
    | Some root when String.trim root <> "" ->
        Some (Filename.concat root "config/prompts")
    | _ -> None
  in
  let candidates =
    workspace_candidate
    :: base_candidate
    :: (match dune_candidate with Some dir -> [ dir ] | None -> [])
    @ [ exe_candidate; cwd_candidate ]
  in
  dedupe_keep_order candidates

let resolve_prompt_markdown_dir ~workspace_path ~base_path =
  let candidates = prompt_markdown_dir_candidates ~workspace_path ~base_path in
  match List.find_opt existing_dir candidates with
  | Some dir -> dir
  | None -> Filename.concat base_path "config/prompts"

let bootstrapped_signature : (string * string) option ref = ref None

(** Scan the current markdown dir and register all prompts with frontmatter.
    Called by [bootstrap_runtime]; also usable in tests after [set_markdown_dir]. *)
let init () =
  match Prompt_registry.get_markdown_dir () with
  | Some dir -> Prompt_registry.load_prompts_from_directory dir
  | None -> ()

let bootstrap_runtime ~workspace_path ~base_path =
  let prompt_markdown_dir =
    resolve_prompt_markdown_dir ~workspace_path ~base_path
  in
  let signature = (workspace_path, prompt_markdown_dir) in
  if !bootstrapped_signature <> Some signature then (
    Prompt_registry.set_markdown_dir prompt_markdown_dir;
    Prompt_registry.load_prompts_from_directory prompt_markdown_dir;
    (try Prompt_registry.restore_overrides workspace_path
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Misc.error "prompt override restore failed: %s"
           (Printexc.to_string exn));
    bootstrapped_signature := Some signature);
  prompt_markdown_dir
