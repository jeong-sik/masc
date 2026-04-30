(** Shared persona authoring contract.

    The persona generator schema, persona schema explanation, and generation
    logic must agree on archetype choices, choice effects, and draft defaults.
    Keep those values here so adding or renaming a choice is one edit instead
    of a schema/runtime mirror. *)

type archetype_choice_effect =
  { value : string
  ; effect_text : string
  ; generated_fields : string list
  }

type archetype_axis =
  { name : string
  ; choices : string list
  ; choice_effects : archetype_choice_effect list
  ; effect_text : string
  ; schema_description : string
  }

let default_generation_language = "ko"
let default_generation_cascade_name =
  Keeper_cascade_profile.cascade_name_for_use
    Keeper_cascade_profile.Persona_generation
let default_temperature = 0.7
let default_max_tokens = 2500
let default_proactive_enabled = false
let string_list_to_json values = `List (List.map (fun value -> `String value) values)

let option_field name value =
  match value with
  | Some json -> [ name, json ]
  | None -> []
;;

let choice_effect ~value ~effect_text ~generated_fields () =
  { value; effect_text; generated_fields }
;;

let choice_effect_fields choice =
  [ "value", `String choice.value
  ; "effect", `String choice.effect_text
  ; "generated_fields", string_list_to_json choice.generated_fields
  ]
;;

let choice_effect_to_json choice = `Assoc (choice_effect_fields choice)
let choice_effects_to_json effects = `List (List.map choice_effect_to_json effects)

let choice_values effects =
  List.map (fun (choice : archetype_choice_effect) -> choice.value) effects
;;

let choice_effect_for value effects =
  List.find_opt (fun choice -> String.equal choice.value value) effects
;;

let alignment_choice_effects =
  [ choice_effect
      ~value:"helpful"
      ~effect_text:
        "Biases the draft toward cooperative task support and clear next actions."
      ~generated_fields:[ "role"; "trait"; "keeper.goal"; "keeper.instructions" ]
      ()
  ; choice_effect
      ~value:"skeptical"
      ~effect_text:
        "Biases the draft toward critique, evidence checks, and assumption testing."
      ~generated_fields:[ "role"; "trait"; "keeper.goal"; "keeper.instructions" ]
      ()
  ; choice_effect
      ~value:"protective"
      ~effect_text:
        "Biases the draft toward guardrails, risk spotting, and escalation language."
      ~generated_fields:[ "role"; "trait"; "keeper.goal"; "keeper.instructions" ]
      ()
  ; choice_effect
      ~value:"chaotic"
      ~effect_text:
        "Biases the draft toward divergent options while keeping keeper goals executable."
      ~generated_fields:[ "role"; "trait"; "keeper.goal"; "keeper.instructions" ]
      ()
  ; choice_effect
      ~value:"ruthless"
      ~effect_text:
        "Biases the draft toward prioritization, pruning, and direct tradeoff calls."
      ~generated_fields:[ "role"; "trait"; "keeper.goal"; "keeper.instructions" ]
      ()
  ]
;;

let risk_posture_choice_effects =
  [ choice_effect
      ~value:"cautious"
      ~effect_text:
        "Biases the draft toward dry runs, explicit approvals, and low autonomy."
      ~generated_fields:[ "keeper.instructions"; "keeper.proactive_enabled" ]
      ()
  ; choice_effect
      ~value:"balanced"
      ~effect_text:
        "Biases the draft toward normal autonomous help with explicit escalation."
      ~generated_fields:[ "keeper.instructions"; "keeper.proactive_enabled" ]
      ()
  ; choice_effect
      ~value:"high-autonomy"
      ~effect_text:
        "Biases the draft toward proactive follow-through while concrete fields still \
         require validation."
      ~generated_fields:[ "keeper.instructions"; "keeper.proactive_enabled" ]
      ()
  ]
;;

let alignment_choices = choice_values alignment_choice_effects
let risk_posture_choices = choice_values risk_posture_choice_effects

let alignment_axis =
  { name = "alignment"
  ; choices = alignment_choices
  ; choice_effects = alignment_choice_effects
  ; effect_text =
      "Generation prompt input only. The saved effect appears through role, trait, goal, \
       and instructions."
  ; schema_description =
      "Optional archetype axis. Influences generated role, trait, goals, and \
       instructions. Call masc_persona_schema for per-choice effects."
  }
;;

let risk_posture_axis =
  { name = "risk_posture"
  ; choices = risk_posture_choices
  ; choice_effects = risk_posture_choice_effects
  ; effect_text =
      "Generation prompt input only. Save still validates concrete keeper fields."
  ; schema_description =
      "Optional archetype axis. Influences generated autonomy and safety language while \
       save still validates concrete fields. Call masc_persona_schema for per-choice \
       effects."
  }
;;

let axes = [ alignment_axis; risk_posture_axis ]

let axis_to_json axis =
  `Assoc
    [ "name", `String axis.name
    ; "choices", string_list_to_json axis.choices
    ; "choice_effects", choice_effects_to_json axis.choice_effects
    ; "effect", `String axis.effect_text
    ]
;;

let archetype_axes_json () = `List (List.map axis_to_json axes)
let axis_by_name name = List.find_opt (fun axis -> String.equal axis.name name) axes
let choices_for_axis name = Option.map (fun axis -> axis.choices) (axis_by_name name)
