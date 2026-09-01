(** Prompt_defaults — Auto-discovers prompt metadata from markdown frontmatter.
    Call [bootstrap_runtime] during server startup to scan config/prompts/ and
    register all prompts that have YAML frontmatter (description, category,
    operator_surface, template_variables).  No OCaml code changes needed to add
    new prompts. *)

let install_prompt_registry_observers () =
  Prompt_registry.set_restore_failure_observer (fun () ->
      Otel_metric_store.inc_counter
        Keeper_metrics.(to_string PromptFailures)
        ~labels:[ ("prompt", "override_restore") ]
        ())

(* The candidate list this searched has been a single element for a while,
   and its fallback was that same element — the [Sys.file_exists] probe
   decided nothing. The directory is created on demand by the asset sync
   ([Managed_asset_sync], run by the server bootstrap), so absence at
   resolve time is not an error either. *)
let resolve_prompt_markdown_dir ~workspace_path:_ ~base_path:_ =
  Config_dir_resolver.prompts_dir ()

let bootstrapped_signature : (string * string) option ref = ref None

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
