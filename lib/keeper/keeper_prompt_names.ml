(** Keeper_prompt_names — SSOT for keeper prompt template identifiers.

    All prompt names used with [Prompt_registry.get_prompt] or
    [Prompt_registry.render_prompt_template] are defined here.
    Callers must reference these constants instead of string literals. *)

let constitution = "keeper.constitution"
let world = "keeper.world"
let capabilities = "keeper.capabilities"
let deliberation = "keeper.deliberation"
