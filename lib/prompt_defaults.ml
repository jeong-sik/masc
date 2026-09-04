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

(** agent_core is config-free by layering: it cannot read
    config/prompts/agent_core.md itself, so the host renders those managed
    templates and installs them into [Agent_core.Tool_guidance_text] here.
    When the slot set is incomplete the defaults stay installed — they are
    the last-resort copy of the same sentences — and the miss is logged
    once. A per-call render failure falls back to that field's default
    sentence, never to prose written here. *)
let install_agent_core_tool_guidance () =
  let module T = Agent_core.Tool_guidance_text in
  let keys =
    [ Prompt_names.agent_core_unknown_tool_not_found
    ; Prompt_names.agent_core_unknown_tool_not_found_no_tools
    ; Prompt_names.agent_core_unknown_tool_closest_registered
    ; Prompt_names.agent_core_unknown_tool_extra_characters
    ; Prompt_names.agent_core_unknown_tool_not_bare_with_closest
    ; Prompt_names.agent_core_unknown_tool_not_bare
    ; Prompt_names.agent_core_handoff_description
    ; Prompt_names.agent_core_handoff_prompt_param_description
    ; Prompt_names.agent_core_agent_tool_prompt_param_description
    ]
  in
  let missing =
    List.filter
      (fun key ->
         String.trim (Prompt_registry.resolve_prompt key).Prompt_registry.effective = "")
      keys
  in
  if missing <> []
  then
    Log.Misc.warn
      "agent_core tool guidance templates missing (%s); keeping the agent_core defaults"
      (String.concat ", " missing)
  else (
    let render key vars ~fallback =
      match Prompt_registry.render_prompt_template key vars with
      | Ok text -> String.trim text
      | Error detail ->
        Log.Misc.warn "agent_core tool guidance %s did not render: %s" key detail;
        fallback
    in
    let defaults = T.defaults in
    T.configure
      { T.unknown_tool_not_found =
          (fun ~requested ->
            render
              Prompt_names.agent_core_unknown_tool_not_found
              [ "requested", requested ]
              ~fallback:(defaults.unknown_tool_not_found ~requested))
      ; unknown_tool_not_found_no_tools =
          (fun ~requested ->
            render
              Prompt_names.agent_core_unknown_tool_not_found_no_tools
              [ "requested", requested ]
              ~fallback:(defaults.unknown_tool_not_found_no_tools ~requested))
      ; unknown_tool_closest_registered =
          (fun ~name ->
            render
              Prompt_names.agent_core_unknown_tool_closest_registered
              [ "name", name ]
              ~fallback:(defaults.unknown_tool_closest_registered ~name))
      ; unknown_tool_extra_characters =
          (fun ~prefix ->
            render
              Prompt_names.agent_core_unknown_tool_extra_characters
              [ "prefix_quoted", Printf.sprintf "%S" prefix ]
              ~fallback:(defaults.unknown_tool_extra_characters ~prefix))
      ; unknown_tool_not_bare_with_closest =
          (fun ~name ->
            render
              Prompt_names.agent_core_unknown_tool_not_bare_with_closest
              [ "name", name ]
              ~fallback:(defaults.unknown_tool_not_bare_with_closest ~name))
      ; unknown_tool_not_bare =
          render
            Prompt_names.agent_core_unknown_tool_not_bare
            []
            ~fallback:defaults.unknown_tool_not_bare
      ; handoff_description =
          (fun ~name ~description ->
            render
              Prompt_names.agent_core_handoff_description
              [ "name", name; "description", description ]
              ~fallback:(defaults.handoff_description ~name ~description))
      ; handoff_prompt_param_description =
          render
            Prompt_names.agent_core_handoff_prompt_param_description
            []
            ~fallback:defaults.handoff_prompt_param_description
      ; agent_tool_prompt_param_description =
          render
            Prompt_names.agent_core_agent_tool_prompt_param_description
            []
            ~fallback:defaults.agent_tool_prompt_param_description
      })
;;

(** Scan the current markdown dir and register all prompts with frontmatter.
    Called by [bootstrap_runtime]; also usable in tests after [set_markdown_dir]. *)
let init () =
  install_prompt_registry_observers ();
  match Prompt_registry.get_markdown_dir () with
  | Some dir ->
    Prompt_registry.load_prompts_from_directory dir;
    install_agent_core_tool_guidance ()
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
    (* Install after [restore_overrides]: the three string fields of
       [Tool_guidance_text] render eagerly here, so they must see the
       workspace overrides the six lazily-rendered function fields already
       track at call time. *)
    install_agent_core_tool_guidance ();
    bootstrapped_signature := Some signature);
  prompt_markdown_dir
