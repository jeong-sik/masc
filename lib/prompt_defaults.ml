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
   syncs: the rest of .masc/config (runtime.toml, keeper manifests, …) is
   operator-edited in place and must never be auto-overwritten. *)

let prompts_asset_prefix = "prompts/"
let managed_assets_manifest = "prompts/managed-assets.json"

module String_set = Set.Make (String)

type sync_result = {
  copied : string list;
  overwritten : string list;
  removed : string list;
  failed : (string * string) list;
}

let read_file_opt = Fs_compat.load_file_opt

let relative_asset_path rel =
  let parts = String.split_on_char '/' rel in
  rel <> ""
  && Filename.is_relative rel
  && List.for_all
       (fun part -> part <> "" && part <> "." && part <> "..")
       parts

let managed_asset_paths content =
  try
    match Yojson.Safe.from_string content with
    | `Assoc fields ->
      (match List.assoc_opt "schema" fields, List.assoc_opt "paths" fields with
       | Some (`String "masc.prompt-managed-assets.v1"), Some (`List values) ->
         let rec collect seen = function
           | [] -> Ok seen
           | `String rel :: rest when relative_asset_path rel ->
             if String_set.mem rel seen
             then Error (Printf.sprintf "duplicate managed prompt asset: %s" rel)
             else collect (String_set.add rel seen) rest
           | `String rel :: _ ->
             Error (Printf.sprintf "unsafe managed prompt asset path: %s" rel)
           | _ -> Error "managed prompt asset paths must be strings"
         in
         collect String_set.empty values
       | Some (`String schema), _ ->
         Error (Printf.sprintf "unsupported managed prompt asset schema: %s" schema)
       | _ -> Error "managed prompt asset manifest is missing schema or paths")
    | _ -> Error "managed prompt asset manifest must be a JSON object"
  with
  | Yojson.Json_error msg -> Error ("invalid managed prompt asset manifest: " ^ msg)

let current_prompt_assets files =
  let prefix_len = String.length prompts_asset_prefix in
  List.filter_map
    (fun rel ->
      if String.equal rel managed_assets_manifest
         || not (String.starts_with ~prefix:prompts_asset_prefix rel)
      then None
      else
        Some
          ( rel
          , String.sub rel prefix_len (String.length rel - prefix_len) ))
    files

let sync_prompt_assets ~read ~files ~prompts_dir () =
  let current_assets = current_prompt_assets files in
  let initial = { copied = []; overwritten = []; removed = []; failed = [] } in
  let synced =
    List.fold_left
    (fun acc rel ->
      let embedded_rel, runtime_rel = rel in
      if not (relative_asset_path runtime_rel)
      then
        { acc with
          failed =
            (embedded_rel, "unsafe embedded prompt asset path") :: acc.failed
        }
      else
        match read embedded_rel with
        | None ->
          { acc with
            failed =
              (embedded_rel, "embedded asset unreadable") :: acc.failed
          }
        | Some content ->
          let dest = Filename.concat prompts_dir runtime_rel in
          let existing = read_file_opt dest in
          (match existing with
           | Some current when String.equal current content -> acc
           | _ ->
             (try
                Fs_compat.mkdir_p (Filename.dirname dest);
                Fs_compat.save_file dest content;
                if Option.is_some existing
                then
                  { acc with overwritten = embedded_rel :: acc.overwritten }
                else { acc with copied = embedded_rel :: acc.copied }
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | Sys_error msg ->
                { acc with failed = (embedded_rel, msg) :: acc.failed })))
    initial
    current_assets
  in
  match read managed_assets_manifest with
  | None ->
    { synced with
      failed =
        (managed_assets_manifest, "embedded managed-assets manifest unreadable")
        :: synced.failed
    }
  | Some content ->
    (match managed_asset_paths content with
     | Error msg ->
       { synced with
         failed = (managed_assets_manifest, msg) :: synced.failed
       }
     | Ok managed ->
       let current =
         List.fold_left
           (fun acc (_, rel) -> String_set.add rel acc)
           String_set.empty
           current_assets
       in
       let untracked_current = String_set.diff current managed in
       if not (String_set.is_empty untracked_current)
       then
         { synced with
           failed =
             ( managed_assets_manifest
             , Printf.sprintf
                 "current embedded prompt assets missing from managed manifest: %s"
                 (String.concat ", " (String_set.elements untracked_current)) )
             :: synced.failed
         }
       else
         String_set.fold
           (fun runtime_rel acc ->
             if String_set.mem runtime_rel current
             then acc
             else
               let embedded_rel = prompts_asset_prefix ^ runtime_rel in
               let dest = Filename.concat prompts_dir runtime_rel in
               (try
                  if not (Sys.file_exists dest)
                  then acc
                  else if Sys.is_directory dest
                  then
                    { acc with
                      failed =
                        (embedded_rel, "managed prompt asset resolved to a directory")
                        :: acc.failed
                    }
                  else (
                    Sys.remove dest;
                    { acc with removed = embedded_rel :: acc.removed })
                with
                | Eio.Cancel.Cancelled _ as e -> raise e
                | Sys_error msg ->
                  { acc with failed = (embedded_rel, msg) :: acc.failed }))
           managed
           synced)

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
