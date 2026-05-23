(* Resilience_runtime — Cycle 27 / Tier W2.
   See resilience_runtime.mli for design rationale. *)

type strategy_class = [ `Retry | `Fallback | `Handoff | `Abort ]

type input = {
  error_message : string;
  current_level : Degradation.any_level;
}

type output = {
  classified : Recovery.error_mode;
  strategy_class : strategy_class;
  strategy_summary : string;
  recommended_level : Degradation.any_level option;
}

let classify_only = Recovery.classify_string

let strategy_to_tag : type a.
    a Recovery.strategy -> strategy_class = function
  | Recovery.Retry _ -> `Retry
  | Recovery.Fallback _ -> `Fallback
  | Recovery.Handoff _ -> `Handoff
  | Recovery.Abort _ -> `Abort

let strategy_summary : type a. a Recovery.strategy -> string =
  function
  | Recovery.Retry { max_attempts; _ } ->
      Printf.sprintf "Retry (max %d attempts)" max_attempts
  | Recovery.Fallback { fallback_value; degrade_confidence_by } ->
      Printf.sprintf
        "Fallback (\"%s\", confidence -%.2f)"
        fallback_value degrade_confidence_by
  | Recovery.Handoff { operator_message; preserve_state } ->
      Printf.sprintf
        "Handoff (\"%s\", preserve_state=%b)"
        operator_message preserve_state
  | Recovery.Abort { reason; _ } ->
      Printf.sprintf "Abort (%s)" reason

let strategy_class_to_string = function
  | `Retry -> "retry"
  | `Fallback -> "fallback"
  | `Handoff -> "handoff"
  | `Abort -> "abort"

let error_mode_label = function
  | Recovery.TransientError _ -> "Transient"
  | Recovery.PermanentError _ -> "Permanent"
  | Recovery.ResourceExhausted _ -> "ResourceExhausted"
  | Recovery.AmbiguityError _ -> "Ambiguity"
  | Recovery.ConsensusError _ -> "Consensus"
  | Recovery.DegradationRequired _ -> "DegradationRequired"

let process input =
  let classified = classify_only input.error_message in
  let (Degradation.Any_level lev) = input.current_level in
  let strategy =
    Degradation.apply_level_to_strategy lev classified
  in
  let recommended_level =
    Degradation.of_recovery_recommended_level classified
  in
  {
    classified;
    strategy_class = strategy_to_tag strategy;
    strategy_summary = strategy_summary strategy;
    recommended_level;
  }

let output_to_json out =
  let recommended_field =
    match out.recommended_level with
    | None -> `Null
    | Some lev ->
        `String
          (Degradation.level_tag_to_string
             (Degradation.any_level_to_tag lev))
  in
  `Assoc
    [
      ("classified_mode", `String (error_mode_label out.classified));
      ( "strategy_class",
        `String (strategy_class_to_string out.strategy_class) );
      ("strategy_summary", `String out.strategy_summary);
      ("recommended_level", recommended_field);
    ]
