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

let owned_parent_state ~prompts_dir dest =
  let parent = Filename.dirname dest in
  match Fs_compat.inspect_owned_directory_chain ~ownership_root:prompts_dir parent with
  | Error rejection ->
    Error (Fs_compat.owned_directory_chain_rejection_to_string rejection)
  | Ok Fs_compat.Owned_directory_missing -> Ok `Missing
  | Ok (Fs_compat.Owned_directory _) -> Ok `Directory

let prepare_owned_parent ~prompts_dir dest =
  match owned_parent_state ~prompts_dir dest with
  | Error _ as error -> error
  | Ok `Directory -> Ok ()
  | Ok `Missing ->
    Fs_compat.mkdir_p (Filename.dirname dest);
    (match owned_parent_state ~prompts_dir dest with
     | Ok `Directory -> Ok ()
     | Ok `Missing -> Error "managed prompt asset parent remained missing after creation"
     | Error _ as error -> error)

let writable_leaf_state dest =
  match Fs_compat.exact_path_kind ~follow:false dest with
  | Fs_compat.Exact_missing -> Ok `Missing
  | Fs_compat.Exact_kind Unix.S_REG -> Ok `Regular
  | Fs_compat.Exact_kind Unix.S_LNK -> Ok `Symlink
  | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
    Error "managed prompt asset leaf is not a regular file"

let remove_runtime_asset ~prompts_dir runtime_rel acc =
  let embedded_rel = prompts_asset_prefix ^ runtime_rel in
  let dest = Filename.concat prompts_dir runtime_rel in
  try
    match owned_parent_state ~prompts_dir dest with
    | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
    | Ok `Missing -> acc
    | Ok `Directory ->
      (match Fs_compat.exact_path_kind ~follow:false dest with
       | Fs_compat.Exact_missing -> acc
       | Fs_compat.Exact_kind Unix.S_REG
       | Fs_compat.Exact_kind Unix.S_LNK ->
         Sys.remove dest;
         { acc with removed = embedded_rel :: acc.removed }
       | Fs_compat.Exact_kind _ | Fs_compat.Exact_unknown ->
         { acc with
           failed =
             ( embedded_rel
             , "managed prompt asset leaf is neither a regular file nor a symbolic link" )
             :: acc.failed
         })
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
  | Unix.Unix_error (error, operation, argument) ->
    { acc with
      failed =
        ( embedded_rel
        , Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error) )
        :: acc.failed
    }

let write_runtime_manifest ~prompts_dir content acc =
  let dest = Filename.concat prompts_dir "managed-assets.json" in
  try
    match prepare_owned_parent ~prompts_dir dest with
    | Error msg -> { acc with failed = (managed_assets_manifest, msg) :: acc.failed }
    | Ok () ->
      (match writable_leaf_state dest with
       | Error msg -> { acc with failed = (managed_assets_manifest, msg) :: acc.failed }
       | Ok _ ->
         (match read_file_opt dest with
          | Some current when String.equal current content -> acc
          | _ ->
            (match Fs_compat.save_file_atomic dest content with
             | Ok () -> acc
             | Error msg ->
               { acc with failed = (managed_assets_manifest, msg) :: acc.failed })))
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Sys_error msg -> { acc with failed = (managed_assets_manifest, msg) :: acc.failed }
  | Unix.Unix_error (error, operation, argument) ->
    { acc with
      failed =
        ( managed_assets_manifest
        , Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error) )
        :: acc.failed
    }

let runtime_prompt_asset_paths ~prompts_dir =
  let rec collect relative acc =
    let path =
      if String.equal relative "" then prompts_dir
      else Filename.concat prompts_dir relative
    in
    match Unix.lstat path with
    | { Unix.st_kind = Unix.S_DIR; _ } ->
      Sys.readdir path
      |> Array.to_list
      |> List.sort String.compare
      |> List.fold_left
           (fun result name ->
             match result with
             | Error _ as error -> error
             | Ok acc ->
               let child =
                 if String.equal relative "" then name
                 else Filename.concat relative name
               in
               collect child acc)
           (Ok acc)
    | { Unix.st_kind = (Unix.S_REG | Unix.S_LNK); _ } ->
      if String.equal relative "managed-assets.json" then Ok acc
      else if relative_asset_path relative then Ok (String_set.add relative acc)
      else Error (Printf.sprintf "unsafe runtime prompt asset path: %s" relative)
    | _ -> Error (Printf.sprintf "runtime prompt asset is not a file: %s" relative)
    | exception Unix.Unix_error (Unix.ENOENT, _, _) when String.equal relative "" ->
      Ok acc
    | exception Unix.Unix_error (error, operation, argument) ->
      Error
        (Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error))
  in
  collect "" String_set.empty

let sync_current_asset ~read ~prompts_dir acc (embedded_rel, runtime_rel) =
  if not (relative_asset_path runtime_rel)
  then
    { acc with failed = (embedded_rel, "unsafe embedded prompt asset path") :: acc.failed }
  else
    match read embedded_rel with
    | None ->
      { acc with failed = (embedded_rel, "embedded asset unreadable") :: acc.failed }
    | Some content ->
      let dest = Filename.concat prompts_dir runtime_rel in
      (try
         match prepare_owned_parent ~prompts_dir dest with
         | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
         | Ok () ->
           (match writable_leaf_state dest with
            | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
            | Ok (`Missing | `Regular | `Symlink as leaf_state) ->
              let existing = read_file_opt dest in
              (match existing with
               | Some current when String.equal current content -> acc
               | _ ->
                 (match Fs_compat.save_file_atomic dest content with
                  | Error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
                  | Ok () ->
                    if leaf_state = `Missing
                    then { acc with copied = embedded_rel :: acc.copied }
                    else { acc with overwritten = embedded_rel :: acc.overwritten })))
       with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | Sys_error msg -> { acc with failed = (embedded_rel, msg) :: acc.failed }
       | Unix.Unix_error (error, operation, argument) ->
         { acc with
           failed =
             ( embedded_rel
             , Printf.sprintf "%s(%s): %s" operation argument (Unix.error_message error) )
             :: acc.failed
         })

let sync_prompt_assets ~read ~files ~prompts_dir () =
  let current_assets = current_prompt_assets files in
  let initial = { copied = []; overwritten = []; removed = []; failed = [] } in
  match read managed_assets_manifest with
  | None ->
    { initial with
      failed = [ managed_assets_manifest, "embedded managed-assets manifest unreadable" ]
    }
  | Some content ->
    (match managed_asset_paths content with
     | Error msg -> { initial with failed = [ managed_assets_manifest, msg ] }
     | Ok managed ->
       let current =
         List.fold_left
           (fun acc (_, rel) -> String_set.add rel acc)
           String_set.empty
           current_assets
       in
       if String_set.is_empty current
       then
         { initial with
           failed =
             [ managed_assets_manifest, "embedded prompt asset set is empty" ]
         }
       else
       let missing = String_set.diff current managed in
       let extra = String_set.diff managed current in
       if not (String_set.is_empty missing && String_set.is_empty extra)
       then
         { initial with
           failed =
             [ ( managed_assets_manifest
               , Printf.sprintf
                   "embedded managed manifest differs from current prompt assets (missing: %s; extra: %s)"
                   (String.concat ", " (String_set.elements missing))
                   (String.concat ", " (String_set.elements extra)) )
             ]
         }
       else
         (match runtime_prompt_asset_paths ~prompts_dir with
          | Error msg -> { initial with failed = [ managed_assets_manifest, msg ] }
          | Ok runtime ->
            let removable = String_set.diff runtime current in
            let purged =
              String_set.fold (remove_runtime_asset ~prompts_dir) removable initial
            in
            List.fold_left
              (sync_current_asset ~read ~prompts_dir)
              purged
              current_assets
            |> write_runtime_manifest ~prompts_dir content))

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
