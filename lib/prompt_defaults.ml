(** Prompt_defaults — Registers prompt metadata for external markdown sources.
    Call [init ()] during server startup to expose prompt keys to the registry. *)

let register ~key ~description ~category =
  Prompt_registry.register_prompt ~key ~description ~category ~required_file:true ()

let init () =
  register ~key:"keeper.constitution"
    ~description:"keeper continuity rules and STATE block format"
    ~category:"keeper";
  register ~key:"keeper.world"
    ~description:"MASC world description (keeper system prompt <world> block)"
    ~category:"keeper";
  register ~key:"keeper.capabilities"
    ~description:"keeper tool usage instructions (system prompt <capabilities> block)"
    ~category:"keeper";
  register ~key:"keeper.proactive_turn"
    ~description:"keeper proactive autonomous turn prompt template"
    ~category:"keeper";
  register ~key:"keeper.proactive_retry"
    ~description:"keeper proactive retry steering template"
    ~category:"keeper";
  register ~key:"keeper.unified.system"
    ~description:"keeper unified loop system prompt template"
    ~category:"keeper";
  register ~key:"keeper.deliberation"
    ~description:"keeper deliberation prompt for choosing the next action"
    ~category:"keeper";
  register ~key:"governance.deliberation"
    ~description:"governance deliberation agent system prompt"
    ~category:"governance";
  register ~key:"governance.dry_run"
    ~description:"governance analysis (DRY RUN) agent system prompt"
    ~category:"governance";
  register ~key:"dashboard.operator_judge"
    ~description:"resident operator judge prompt for dashboard command surface"
    ~category:"dashboard";
  register ~key:"dashboard.governance_judge"
    ~description:"resident governance judge prompt for dashboard governance surface"
    ~category:"dashboard"
