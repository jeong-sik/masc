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
    carries `{{web_fetch_timeout}}`, replaced when hints are first loaded.

    Missing or malformed external config logs a config-drift warning and falls
    back to safe minimal guidance rather than crashing prompt rendering. *)

type hint =
  { name : string
  ; call : string
  ; description : string
  }

type hint_inventory =
  { hints : hint list
  ; config_drift_marker : string option
  }

let web_fetch_timeout_placeholder = "{{web_fetch_timeout}}"
let web_fetch_timeout_re = Str.regexp_string web_fetch_timeout_placeholder

let substitute_web_fetch_timeout s =
  let value = string_of_int Tool_misc_web_fetch.default_timeout_sec in
  Str.global_replace web_fetch_timeout_re value s
;;

let observe_guidance_config_drift ~label ~detail =
  Prometheus.inc_counter
    Keeper_metrics.metric_keeper_prompt_failures
    ~labels:[ "prompt", label ]
    ();
  Log.Keeper.warn "keeper tool guidance config drift: %s: %s" label detail
;;

let tool_hints_config_drift_marker =
  "Keeper tool guidance config drift: missing or malformed \
   config/prompts/keeper.tool_hints.toml. Preferred tool examples were \
   withheld; use only active runtime tool schemas and ask the operator to \
   restore the tool hints file."
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
  try
    let doc = Otoml.Parser.from_file path in
    let entries = Otoml.find doc (Otoml.get_array Fun.id) [ "hints" ] in
    { hints =
        List.map
          (fun entry ->
            { name = Otoml.find entry Otoml.get_string [ "name" ]
            ; call =
                substitute_web_fetch_timeout
                  (Otoml.find entry Otoml.get_string [ "call" ])
            ; description = Otoml.find entry Otoml.get_string [ "description" ]
            })
          entries
    ; config_drift_marker = None
    }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    observe_guidance_config_drift
      ~label:"keeper.tool_hints"
      ~detail:
        (Printf.sprintf "%s: %s" path (Printexc.to_string exn));
    { hints = []; config_drift_marker = Some tool_hints_config_drift_marker }
;;

(* Deferred until first use so module load does not require the TOML file to
   exist at link time (e.g. for executables that never render keeper prompts).
   First [Lazy.force] must be sequentially serialized — masc-mcp's Eio
   single-domain model satisfies this. *)
let hint_inventory : hint_inventory Lazy.t = lazy (load_hints ())

let fallback_prose key =
  if String.equal key Keeper_prompt_names.tool_preferred_header
  then
    Some
      "Preferred keeper tools currently allowed for you (copy the name and \
       schema verbatim):"
  else if String.equal key Keeper_prompt_names.tool_preferred_empty
  then
    Some
      "Preferred keeper tools: use only the tool schemas currently shown by \
       the runtime."
  else if String.equal key Keeper_prompt_names.tool_workflow_gh_full
  then
    Some
      "GitHub/code workflow: if you do not already hold a task, call \
       `keeper_task_claim` first; `keeper_shell op=gh` derives repo context \
       from the active task worktree/current_task_id. Then inspect with \
       `keeper_shell op=gh`; if code change is needed, `masc_worktree_create` \
       -> edit -> `keeper_bash` for `git add` / `git commit` / `git push` -> \
       `keeper_pr_create` with `draft=true` -> \
       `keeper_task_submit_for_verification` with notes and `pr_url`."
  else if String.equal key Keeper_prompt_names.tool_workflow_gh_no_pr
  then
    Some
      "GitHub/code workflow: if you do not already hold a task, call \
       `keeper_task_claim` first; inspect with `keeper_shell op=gh`; if code \
       change is needed, `masc_worktree_create` -> edit -> `keeper_bash` for \
       `git add` / `git commit` / `git push`. Do not create PRs through \
       `keeper_shell op=gh`; submit verification notes with the pushed branch \
       and request a dedicated draft-PR tool."
  else if String.equal key Keeper_prompt_names.tool_workflow_gh_minimal
  then
    Some
      "GitHub workflow: use `keeper_shell op=gh` only for commands supported \
       by your active tool policy. `keeper_shell op=gh` derives repo context \
       from the active task worktree/current_task_id; claim a task first when \
       repo context is required. Do not create PRs through `keeper_shell \
       op=gh`; use the dedicated draft-PR tool when it is listed."
  else if String.equal key Keeper_prompt_names.tool_unknown_guard
  then
    Some
      "Do not call tool names that are absent from the active runtime schema \
       list. Heartbeat is server-managed; public lifecycle/status tools such \
       as `masc_join`, `masc_who`, and `masc_heartbeat` are not keeper action \
       tools unless they are explicitly shown to you. Copy active schema names \
       exactly; do not substitute public `masc_*` aliases such as \
       `masc_board_list` for keeper-scoped tools."
  else None
;;

let load_prose key =
  let raw =
    match Prompt_registry.render_prompt_template key [] with
    | Ok value -> value
    | Error msg ->
      observe_guidance_config_drift ~label:key ~detail:msg;
      Prompt_registry.get_prompt key
  in
  let trimmed = String.trim raw in
  if String.equal trimmed ""
  then (
    observe_guidance_config_drift
      ~label:key
      ~detail:"prompt resolved to empty; using in-binary fallback prose";
    match fallback_prose key with
    | Some prose -> prose
    | None ->
      observe_guidance_config_drift
        ~label:key
        ~detail:
          "no in-binary fallback prose registered for this key; returning \
           empty string";
      "")
  else trimmed
;;

let allowed_lookup allowed_tool_names =
  let tbl = Hashtbl.create (List.length allowed_tool_names) in
  List.iter (fun name -> Hashtbl.replace tbl name ()) allowed_tool_names;
  tbl
;;

let allowed_hints ~allowed_tool_names =
  let allowed = allowed_lookup allowed_tool_names in
  List.filter
    (fun hint -> Hashtbl.mem allowed hint.name)
    (Lazy.force hint_inventory).hints
;;

let line_of_hint hint = Printf.sprintf "  - %s - %s" hint.call hint.description

let render_preferred_tools ~allowed_tool_names =
  let config_drift_marker = (Lazy.force hint_inventory).config_drift_marker in
  let lines = allowed_hints ~allowed_tool_names |> List.map line_of_hint in
  match lines with
  | [] ->
    (match config_drift_marker with
     | Some marker ->
       marker ^ "\n" ^ load_prose Keeper_prompt_names.tool_preferred_empty
     | None -> load_prose Keeper_prompt_names.tool_preferred_empty)
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
