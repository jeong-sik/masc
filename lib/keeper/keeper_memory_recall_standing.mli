(** Whether the recall judgment reaches a Keeper now, and if not, why
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md).

    {!Keeper_memory_recall_blocks} asks it before it reads a Keeper's facts,
    and the server's reading of the gate ([Server_memory_recall_standing])
    answers it for every Keeper, so what an operator is shown comes from the
    function a turn asks first. It reads the gate as loaded and the
    environment as it is: a runtime.toml edited on disk and not yet loaded
    changes nothing here.

    Two limits. {!Judged} says the gate admits the Keeper. A turn can still
    make no texts for it: it has no facts, or there is no clock. And a turn
    asks the gate a second time inside {!Keeper_memory_recall_turn.judge},
    without the environment switch, so a policy published between the two
    asks can answer differently. *)

type reason =
  | Environment_switch_off
      (** [MASC_KEEPER_MEMORY_OS_RECALL] turns recall off for the whole server;
          it is asked before the gate. *)
  | Recall_not_switched_on
      (** [\[typesafeai\] memory_recall = false], or the Keeper is outside the
          scope the switch names. *)
  | Keeper_excluded  (** The Keeper is named in [excluded_keepers]. *)
  | Lane_disabled  (** [\[typesafeai\] enabled = false]. *)
  | No_armed_destination
      (** None of the variables the destinations name holds a key. *)
  | Refused_by_another_gate
      (** The gate answered with the reason of another gate. The gate of recall
          never does; this says so instead of naming a reason it does not
          have. *)

type t =
  | Judged
  | Not_judged of reason

val of_keeper : keeper_id:string -> t

val is_judged : keeper_id:string -> bool
(** [of_keeper] is {!Judged}. *)

val reason_of_unavailable : Typesafeai_config.unavailable_reason -> reason
(** What a refusal of the gate of recall comes to: its own switch, the
    exclusion, or the lane. The reasons of the other gates come to
    {!Refused_by_another_gate}. *)

val lane_reason_of_unavailable : Typesafeai_config.unavailable_reason -> reason
(** What a refusal of the lane comes to: {!Lane_disabled},
    {!No_armed_destination}, or {!Refused_by_another_gate} for any other
    reason, which {!Typesafeai_config.lane_destinations} does not give. *)

val is_lane_reason : reason -> bool
(** The reasons {!lane_reason_of_unavailable} gives. *)

val all_reasons : reason list
(** Every {!reason}, derived from the type. *)

val judged_word : string
(** The word a reading of the gate puts on the wire for a Keeper that is
    {!Judged}. *)

val lane_armed_word : string
(** The word it puts for a lane that has a key. *)

val reason_to_string : reason -> string
(** The word a reading of the gate puts on the wire. Four use the word of a
    {!Typesafeai_config.unavailable_reason} ([memory_recall_disabled],
    [keeper_excluded], [lane_disabled], [no_armed_destination]); the other two
    are [environment_switch_off] and [another_gate_refused]. *)

val reason_of_string : string -> reason option
(** The inverse of {!reason_to_string} over {!all_reasons}. *)
