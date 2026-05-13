(** Policy-derived keeper tool guidance.

    Prompts must not advertise tools outside the active keeper policy.  The
    model already receives the real schema set from OAS; this module renders
    short human-readable hints by filtering curated affordances through that
    same allowed-name set.

    The hint inventory and prose blocks live in config/prompts/:
      - keeper.tool_hints.toml         — 17 hint records (loaded on first use via otoml)
      - keeper.tool_preferred_header.md
      - keeper.tool_preferred_empty.md
      - keeper.tool_workflow_gh_full.md
      - keeper.tool_workflow_gh_no_pr.md
      - keeper.tool_workflow_gh_minimal.md
      - keeper.tool_unknown_guard.md

    The only runtime substitution is masc_web_fetch's default timeout: TOML
    carries `{{web_fetch_timeout}}`, replaced at load time.

    Missing or malformed config raises [Failure] with the offending path so
    deployment drift surfaces immediately instead of silently rendering blank
    guidance to the model. *)

type hint =
  { name : string
  ; call : string
  ; description : string
  }

let web_fetch_timeout_placeholder = "{{web_fetch_timeout}}"
let web_fetch_timeout_re = Str.regexp_string web_fetch_timeout_placeholder

let substitute_web_fetch_timeout s =
  let value = string_of_int Tool_misc_web_fetch.default_timeout_sec in
  Str.global_replace web_fetch_timeout_re value s
;;

let hints_toml_path () =
  let dir =
    match Prompt_registry.get_markdown_dir () with
    | Some d -> d
    | None -> Config_dir_resolver.prompts_dir ()
  in
  Filename.concat dir "keeper.tool_hints.toml"
;;

let load_hints () =
  let path = hints_toml_path () in
  let doc =
    try Otoml.Parser.from_file path with
    | Sys_error msg ->
      failwith
        (Printf.sprintf
           "keeper_tool_guidance: cannot read TOML at %s: %s. Verify the file \
            ships with the binary (config/prompts/keeper.tool_hints.toml)."
           path msg)
    | Otoml.Parse_error (_, msg) ->
      failwith
        (Printf.sprintf
           "keeper_tool_guidance: malformed TOML at %s: %s"
           path msg)
  in
  let entries = Otoml.find doc (Otoml.get_array Fun.id) [ "hints" ] in
  List.map
    (fun entry ->
      { name = Otoml.find entry Otoml.get_string [ "name" ]
      ; call =
          substitute_web_fetch_timeout
            (Otoml.find entry Otoml.get_string [ "call" ])
      ; description = Otoml.find entry Otoml.get_string [ "description" ]
      })
    entries
;;

(* Deferred until first use so module load does not require the TOML file to
   exist at link time (e.g. for executables that never render keeper prompts).
   First [Lazy.force] must be sequentially serialized — masc-mcp's Eio
   single-domain model satisfies this. *)
let hints : hint list Lazy.t = lazy (load_hints ())

(* Empty prose is treated as a deployment error: a missing markdown file
   would otherwise silently drop guard text (e.g. render_unknown_tool_guard)
   into "" and the LLM would receive no warning. Fail loud at first use. *)
let load_prose key =
  let raw =
    match Prompt_registry.render_prompt_template key [] with
    | Ok value -> value
    | Error _ -> Prompt_registry.get_prompt key
  in
  let trimmed = String.trim raw in
  if trimmed = "" then
    failwith
      (Printf.sprintf
         "keeper_tool_guidance: prompt %S resolved to empty. Verify \
          config/prompts/%s.md exists and is non-empty."
         key key)
  else trimmed
;;

let allowed_lookup allowed_tool_names =
  let tbl = Hashtbl.create (List.length allowed_tool_names) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) allowed_tool_names;
  tbl
;;

let allowed_hints ~allowed_tool_names =
  let allowed = allowed_lookup allowed_tool_names in
  List.filter (fun hint -> Hashtbl.mem allowed hint.name) (Lazy.force hints)
;;

let line_of_hint hint = Printf.sprintf "  - %s - %s" hint.call hint.description

let render_preferred_tools ~allowed_tool_names =
  let lines = allowed_hints ~allowed_tool_names |> List.map line_of_hint in
  match lines with
  | [] -> load_prose Keeper_prompt_names.tool_preferred_empty
  | _ ->
    let header = load_prose Keeper_prompt_names.tool_preferred_header in
    header ^ "\n" ^ String.concat "\n" lines
;;

let has allowed_tool_names name = List.mem name allowed_tool_names

let render_gh_workflow ~allowed_tool_names =
  let has_shell = has allowed_tool_names "keeper_shell" in
  let has_worktree = has allowed_tool_names "masc_worktree_create" in
  let has_bash = has allowed_tool_names "keeper_bash" in
  let has_verify = has allowed_tool_names "keeper_task_submit_for_verification" in
  let has_pr_create = has allowed_tool_names "keeper_pr_create" in
  match has_shell, has_worktree, has_bash, has_verify, has_pr_create with
  | true, true, true, true, true ->
    Some (load_prose Keeper_prompt_names.tool_workflow_gh_full)
  | true, true, true, true, false ->
    Some (load_prose Keeper_prompt_names.tool_workflow_gh_no_pr)
  | true, _, _, _, _ ->
    Some (load_prose Keeper_prompt_names.tool_workflow_gh_minimal)
  | _ -> None
;;

let render_unknown_tool_guard () =
  load_prose Keeper_prompt_names.tool_unknown_guard
;;
