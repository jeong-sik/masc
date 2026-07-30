(** Current Keeper context-observation wire projection. *)

val missing_measurement_json : unit -> Yojson.Safe.t
(** Typed reason emitted while no runtime owner supplies current context
    occupancy. *)

val missing_context_fields :
  unit ->
  (string * Yojson.Safe.t) list
(** Null context fields plus {!missing_measurement_json}. Checkpoint inventory
    is a separate endpoint and is not loaded by fleet context observation. *)

val last_turn_usage_json_of_meta :
  Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** Provider-reported usage from the latest successful usage observation.
    Its timestamp is independent from [last_turn_ts], which also advances on
    failed turns. *)
(** Provider-reported usage for the latest completed turn. This is not
    context occupancy and must never feed context pressure or compaction
    decisions. *)

val last_turn_usage_json :
  base_path:string ->
  Keeper_meta_contract.keeper_meta ->
  Yojson.Safe.t
(** Process-local provider usage for the same persisted Keeper identity.
    Persisted token counters are never promoted when the live registry has no
    typed observation. *)
