(** Keeper instruction comparison used by runtime reconciliation. *)

let normalized value =
  Keeper_config.normalize_prompt_text
    ~max_bytes:Keeper_config.prompt_render_max_bytes
    value

let text_equal left right = String.equal (normalized left) (normalized right)
