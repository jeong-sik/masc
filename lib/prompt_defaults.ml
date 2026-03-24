(** Prompt_defaults — Registers prompt metadata for external markdown sources.
    Call [init ()] during server startup to expose prompt keys to the registry. *)

let register ?(template_variables = []) ~key ~description ~category () =
  Prompt_registry.register_prompt ~key ~description ~category ~required_file:true
    ~template_variables ()

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
