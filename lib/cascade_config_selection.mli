(** Cascade selection: weighted-shuffle, health-adjusted ordering, and the
    per-candidate decision trace that dashboards/telemetry consume.

    Extracted from [cascade_config.ml]. Types ({!candidate_info},
    {!selection_trace}) are defined here and aliased by {!Cascade_config}
    so the facade contract is unchanged.

    @stability Internal *)

val weighted_random_int : int -> int
(** Mutex-protected draw against the shared selection RNG. Safe to call
    from concurrent fibers AND from non-Eio contexts. *)

val weighted_shuffle :
  ?rand_int:(int -> int) ->
  Cascade_config_loader.weighted_entry list ->
  Cascade_config_loader.weighted_entry list

val provider_key_of_model_string : string -> string

val order_weighted_entries :
  ?rand_int:(int -> int) ->
  ?rotation_scope:string ->
  ?cascade:string ->
  Cascade_config_loader.weighted_entry list ->
  Cascade_config_loader.weighted_entry list

type candidate_info = {
  model_string : string;
  display_model_string : string;
  provider_name : string option;
  display_provider_name : string option;
  runtime_kind : string option;
  expanded_models : string list;
  config_weight : int;
  effective_weight : int;
  success_rate : float;
  in_cooldown : bool;
}

val candidate_info_of_weighted :
  Cascade_config_loader.weighted_entry -> candidate_info

val display_model_string : string -> string
