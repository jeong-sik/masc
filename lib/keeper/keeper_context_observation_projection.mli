(** Current Keeper context-observation wire projection. *)

val missing_measurement_json : unit -> Yojson.Safe.t
(** Typed reason emitted while no runtime owner supplies current context
    occupancy. *)

type checkpoint_metadata =
  | No_checkpoint
  | Checkpoint of
      { serialized_bytes : int
      ; message_count : int
      }

val missing_context_fields :
  ?checkpoint:checkpoint_metadata ->
  unit ->
  (string * Yojson.Safe.t) list
(** Null context fields plus {!missing_measurement_json}. A direct checkpoint
    observation may add storage size and message count, but never occupancy. *)

val last_turn_usage_json_of_meta :
  Keeper_meta_contract.keeper_meta -> Yojson.Safe.t
(** Provider-reported usage for the latest completed turn. This is not
    context occupancy and must never feed context pressure or compaction
    decisions. *)
