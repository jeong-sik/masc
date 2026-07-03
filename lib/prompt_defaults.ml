(** Prompt_defaults — Auto-discovers prompt metadata from markdown frontmatter.
    Call [bootstrap_runtime] during server startup to scan config/prompts/ and
    register all prompts that have YAML frontmatter (description, category,
    template_variables).  No OCaml code changes needed to add new prompts. *)

let existing_dir path =
  Sys.file_exists path && Sys.is_directory path

let prompt_markdown_dir_candidates ~workspace_path ~base_path =
  let _ = workspace_path, base_path in
  [ Config_dir_resolver.prompts_dir () ]

let install_prompt_registry_observers () =
  Prompt_registry.set_restore_failure_observer (fun () ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string PromptFailures)
        ~labels:[ ("prompt", "override_restore") ]
        ())

let resolve_prompt_markdown_dir ~workspace_path ~base_path =
  match
    List.find_opt existing_dir
      (prompt_markdown_dir_candidates ~workspace_path ~base_path)
  with
  | Some dir -> dir
  | None -> Config_dir_resolver.prompts_dir ()

let bootstrapped_signature : (string * string) option ref = ref None

(* ── Binary-embedded prompt asset sync (#20929) ─────────────────────────
   The binary embeds the repo's config/ tree (lib/embedded_config); the
   runtime markdown dir under <base>/.masc/config/prompts is derived
   distribution state.  Operator customization has its own layer
   (prompt_overrides.json, replayed after directory load), so prompt
   markdown that differs from the embedded asset is stale, not customized
   — overwriting is the correct convergence.  Only the prompts/ subtree
   syncs: the rest of .masc/config (runtime.toml, keepers/, personas/, …) is
   operator-edited in place and must never be auto-overwritten. *)

let prompts_asset_prefix = "prompts/"

type sync_result = {
  copied : string list;
  overwritten : string list;
  failed : (string * string) list;
}

let read_file_opt = Fs_compat.load_file_opt

let sync_prompt_assets ~read ~files ~prompts_dir () =
  let prefix_len = String.length prompts_asset_prefix in
  List.fold_left
    (fun acc rel ->
      if not (String.starts_with ~prefix:prompts_asset_prefix rel) then acc
      else
        match read rel with
        | None ->
            { acc with failed = (rel, "embedded asset unreadable") :: acc.failed }
        | Some content ->
            let dest =
              Filename.concat prompts_dir
                (String.sub rel prefix_len (String.length rel - prefix_len))
            in
            let existing = read_file_opt dest in
            (match existing with
             | Some current when String.equal current content -> acc
             | _ -> (
                 try
                   Fs_compat.mkdir_p (Filename.dirname dest);
                   Fs_compat.save_file dest content;
                   if Option.is_some existing then
                     { acc with overwritten = rel :: acc.overwritten }
                   else { acc with copied = rel :: acc.copied }
                 with
                 | Eio.Cancel.Cancelled _ as e -> raise e
                 | Sys_error msg ->
                     { acc with failed = (rel, msg) :: acc.failed })))
    { copied = []; overwritten = []; failed = [] }
    files

(** Scan the current markdown dir and register all prompts with frontmatter.
    Called by [bootstrap_runtime]; also usable in tests after [set_markdown_dir]. *)
let init () =
  install_prompt_registry_observers ();
  match Prompt_registry.get_markdown_dir () with
  | Some dir -> Prompt_registry.load_prompts_from_directory dir
  | None -> ()

let bootstrap_runtime ~workspace_path ~base_path =
  install_prompt_registry_observers ();
  Config_dir_resolver.log_warnings ~context:"PromptDefaults" ();
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
