(** Turn directives — the instruction sentences the runtime appends to a
    keeper's turn prompt after the wake prompt.

    The wake prompt itself is operator-visible: it is registered in
    {!Keeper_runtime_setting_registry}, bounded, and reported by the settings
    projection. The sentences appended after it were literals at their
    emission sites, so an operator could neither read what a turn was
    instructed to do nor change it without a redeploy.

    Each directive here has a stable id, one documented default, and one
    override path. The variant is closed, so a new directive forces a compile
    error at {!key}, {!env_name}, and {!default} rather than reaching the model
    unregistered.

    A directive is text the model reads as instruction. Values carrying event
    data (approval ids, tool names) stay at their emission sites; only the
    fixed instruction text lives here. *)

type t =
  | Gate_replay_applied
      (** Host replay applied the approved operation before the turn. *)
  | Gate_replay_applied_with_warning
      (** Effect applied; post-effect bookkeeping failed. *)
  | Gate_replay_failed  (** Host replay did not apply the operation. *)
  | Gate_replay_indeterminate
      (** Host replay cannot prove whether the operation applied. *)
  | Gate_replay_authorization_consumed
      (** Authorization was consumed but the replay outcome is unavailable. *)

val all : t list
(** Every directive, for registry generation and exhaustiveness tests. *)

val key : t -> string
(** Dotted id used as the TOML key suffix, e.g. ["gate_replay.applied"]. *)

val of_key : string -> t option

val env_name : t -> string
(** Environment variable overriding this directive, derived from {!key}. *)

val toml_key : t -> string
(** Full TOML key, e.g. ["turn_directive.gate_replay.applied"]. *)

val default : t -> string
(** The wording used when no override is set. This is the single definition;
    emission sites read {!text} rather than restating it. *)

val description : t -> string
(** Operator-facing summary of when this directive reaches a turn prompt,
    reported by the settings registry. *)

val max_directive_bytes : int
(** Upper bound on an override. A directive is appended to the turn prompt
    that becomes the durable checkpoint, so its cost is replayed by every
    later turn in that history — the same reason the wake prompt is bounded. *)

val validate : string -> (string, string) result
(** [validate raw] trims and bounds an override. Blank is rejected rather
    than folded into the default, so "unset" and "set to nothing" stay
    distinguishable. *)

val text : t -> string
(** The override when one is set and valid, else {!default}. Read as a
    function: the value is steerable through the boot override store, and a
    keeper process outlives module-load time.

    @raise Env_config_core.Config_error if an override is set but invalid. *)
