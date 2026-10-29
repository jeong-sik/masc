(** Whether the recall judgment reaches a Keeper now, and if not, why
    (docs/rfc/RFC-keeper-recall-reaches-the-turn.md).

    One definition for the two that ask. {!Keeper_memory_recall_blocks} asks
    it before it reads a Keeper's facts, and the server's reading of the gate
    ([Server_memory_recall_standing]) answers it for every Keeper, so what an
    operator is shown is the answer a turn gets. It reads the gate as loaded
    and the environment as it is: a runtime.toml edited on disk and not yet
    loaded changes nothing here. *)

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

type t =
  | Judged
  | Not_judged of reason

val of_keeper : keeper_id:string -> t

val is_judged : keeper_id:string -> bool
(** [of_keeper] is {!Judged}. *)

val reason_of_unavailable : Typesafeai_config.unavailable_reason -> reason
(** What a refusal of the gate comes to. The gate of recall answers with its
    own switch, the exclusion and the lane; the reasons of the other gates
    are not answers of it, and come to {!Recall_not_switched_on}. *)

val all_reasons : reason list

val judged_word : string
(** The word a reading of the gate puts on the wire for a Keeper that is
    {!Judged}. *)

val lane_armed_word : string
(** The word it puts for a lane that has a key. *)

val reason_to_string : reason -> string
(** The word a reading of the gate puts on the wire. The three that name a
    {!Typesafeai_config.unavailable_reason} use its word:
    ["memory_recall_disabled"], ["keeper_excluded"], ["lane_disabled"],
    ["no_armed_destination"]; and ["environment_switch_off"]. *)

val reason_of_string : string -> reason option
(** The inverse of {!reason_to_string} over {!all_reasons}. *)
