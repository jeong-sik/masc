(** Shared persona authoring contract.

    The persona generator schema, persona schema explanation, and
    generation logic must agree on archetype choices, choice effects,
    and draft defaults. Keep those values here so adding or renaming
    a choice is one edit instead of a schema/runtime mirror. *)

type archetype_choice_effect =
  { value : string
  ; effect_text : string
  ; generated_fields : string list
  ; default_tool_preset : string option
  }

type archetype_axis =
  { name : string
  ; choices : string list
  ; choice_effects : archetype_choice_effect list
  ; effect_text : string
  ; schema_description : string
  }

(** {1 Generation defaults} *)

val default_generation_language : string
val default_generation_cascade_name : string
val default_tool_preset : string
val default_temperature : float
val default_max_tokens : int
val default_proactive_enabled : bool

(** {1 JSON helpers} *)

val string_list_to_json : string list -> Yojson.Safe.t

(** [option_field name value] returns [[(name, json)]] when [value]
    is [Some json], [[]] otherwise — handy for building [`Assoc]
    fields conditionally. *)
val option_field :
  string -> Yojson.Safe.t option -> (string * Yojson.Safe.t) list

(** {1 Archetype choice effects} *)

val choice_effect :
  ?default_tool_preset:string ->
  value:string ->
  effect_text:string ->
  generated_fields:string list ->
  unit ->
  archetype_choice_effect

val choice_effect_fields :
  archetype_choice_effect -> (string * Yojson.Safe.t) list

val choice_effect_to_json : archetype_choice_effect -> Yojson.Safe.t
val choice_effects_to_json : archetype_choice_effect list -> Yojson.Safe.t
val choice_values : archetype_choice_effect list -> string list

val choice_effect_for :
  string -> archetype_choice_effect list -> archetype_choice_effect option

(** {1 Per-axis choice effects (SSOT)} *)

val alignment_choice_effects : archetype_choice_effect list
val operating_style_choice_effects : archetype_choice_effect list
val risk_posture_choice_effects : archetype_choice_effect list

val alignment_choices : string list
val operating_style_choices : string list
val risk_posture_choices : string list

(** {1 Archetype axes} *)

val alignment_axis : archetype_axis
val operating_style_axis : archetype_axis
val risk_posture_axis : archetype_axis

(** All archetype axes in declaration order. *)
val axes : archetype_axis list

val axis_to_json : archetype_axis -> Yojson.Safe.t
val archetype_axes_json : unit -> Yojson.Safe.t

(** Lookup an axis by [name]. Returns [None] if absent. *)
val axis_by_name : string -> archetype_axis option

(** Convenience: choices of the named axis, or [None] if absent. *)
val choices_for_axis : string -> string list option
