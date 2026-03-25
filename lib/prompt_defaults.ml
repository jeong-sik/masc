(** Prompt_defaults — Registers prompt metadata for external markdown sources.
    Call [init ()] during server startup to expose prompt keys to the registry. *)

let register ?(template_variables = []) ~key ~description ~category () =
  Prompt_registry.register_prompt ~key ~description ~category ~required_file:true
    ~template_variables ()

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

let init () =
  register ~key:"keeper.constitution"
    ~description:"keeper continuity rules and STATE block format"
    ~category:"keeper" ();
  register ~key:"keeper.world"
    ~description:"MASC world description (keeper system prompt <world> block)"
    ~category:"keeper" ();
  register ~key:"keeper.capabilities"
    ~description:"keeper tool usage instructions (system prompt <capabilities> block)"
    ~category:"keeper" ();
  register ~key:"keeper.proactive_turn"
    ~description:"keeper proactive autonomous turn prompt template"
    ~category:"keeper"
    ~template_variables:
      [ "idle_seconds"; "profile"; "goal"; "last_preview"; "continuity_snapshot"; "seed" ] ();
  register ~key:"keeper.proactive_retry"
    ~description:"keeper proactive retry steering template"
    ~category:"keeper"
    ~template_variables:[ "attempt_phrase"; "reason"; "directive" ] ();
  register ~key:"keeper.unified.system"
    ~description:"keeper unified loop system prompt template"
    ~category:"keeper"
    ~template_variables:
      [ "identity_header"; "trait_lines"; "instructions_block"; "goal_lines" ] ();
  register ~key:"keeper.deliberation"
    ~description:"keeper deliberation prompt for choosing the next action"
    ~category:"keeper"
    ~template_variables:
      [
        "keeper_name";
        "soul_profile";
        "goal";
        "triggers";
        "world_state";
        "multi_step_line";
        "multi_step_example";
      ] ();
  register ~key:"governance.deliberation"
    ~description:"governance deliberation agent system prompt"
    ~category:"governance" ();
  register ~key:"governance.dry_run"
    ~description:"governance analysis (DRY RUN) agent system prompt"
    ~category:"governance" ();
  register ~key:"dashboard.operator_judge"
    ~description:"resident operator judge prompt for dashboard command surface"
    ~category:"dashboard"
    ~template_variables:[ "facts_json" ] ();
  register ~key:"dashboard.governance_judge"
    ~description:"resident governance judge prompt for dashboard governance surface"
    ~category:"dashboard"
    ~template_variables:[ "facts_json" ]
    ()

let bootstrap_runtime ~workspace_path ~base_path =
  let prompt_markdown_dir =
    resolve_prompt_markdown_dir ~workspace_path ~base_path
  in
  let signature = (workspace_path, prompt_markdown_dir) in
  if !bootstrapped_signature <> Some signature then (
    Prompt_registry.set_markdown_dir prompt_markdown_dir;
    init ();
    (try Prompt_registry.restore_overrides workspace_path
     with
     | Eio.Cancel.Cancelled _ as e -> raise e
     | exn ->
         Log.Misc.error "prompt override restore failed: %s"
           (Printexc.to_string exn));
    bootstrapped_signature := Some signature);
  prompt_markdown_dir
