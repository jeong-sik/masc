(** The lane the Librarian asks through, as one comparable value (RFC
    librarian-call-only-proposes §4, §7.4, §7.5, §9.2 「선언 변경」).

    The lane is the built-in table [runtime.exact_output_lanes.librarian_memory]
    ({!Standalone_lane.Librarian_memory}). It is not the working-context
    pass's [librarian_exact]: the two ask different questions with different
    output sizes, and operators already declare different slots for them.

    The value is what decides whether an answer or a size fact still holds:
    the question side (prompt, answer schema, output reserve, thinking) and
    every declared slot resolved to its key. Two publications that declare
    the same lane give equal values; a slot whose resolved window changes
    gives a different value. *)

type slot_key =
  { id : string  (** The declared slot id. *)
  ; target : string
        (** An HTTP slot's admitted target identity fingerprint; a CLI slot's
            runtime id, the identity it is called under. *)
  ; window : int
        (** {!Runtime_instance.resolve_max_context_of_runtime}: binding, then
            provider, then model. *)
  ; reserve : int option
        (** The output reserve the lane's requests carry as [max_tokens]: the
            lane's [max_output_tokens]. A provider fits a question when
            input + this reserve is inside its window, whether masc counts
            before sending or the provider refuses after, so every slot's size
            fact depends on it. [None] when the lane declares none and the
            provider's default applies. *)
  }
[@@deriving eq, show]

type question_side =
  { prompt : string  (** The system prompt every question carries. *)
  ; answer_schema : Yojson.Safe.t  (** The schema every answer must match. *)
  ; max_output_tokens : int option  (** The lane's declared output reserve. *)
  ; thinking : bool option  (** The lane's declared thinking setting. *)
  }
[@@deriving eq, show]

type t =
  { question : question_side
  ; http : slot_key list  (** Admitted HTTP slots, in declared order. *)
  ; cli : slot_key list  (** Declared CLI slots, in declared order. *)
  }
[@@deriving eq, show]

type unavailable =
  | Lane_unconfigured  (** runtime.toml declares no [librarian_memory] table. *)
  | Lane_off  (** The table says [enabled = false]. *)
  | No_admitted_slots  (** No HTTP slot was admitted and no CLI slot is declared. *)
  | Blank_slot_id  (** An admitted HTTP slot has a blank id. *)
  | Window_unknown of { slot : string }
      (** The slot names no active runtime, so its window cannot be resolved. *)
[@@deriving eq, show]

val lane_id : string
(** [Standalone_lane.to_id Librarian_memory]: the registry key. *)

val resolve
  :  prompt:string
  -> answer_schema:Yojson.Safe.t
  -> Runtime_exact_output_registry.t
  -> (t, unavailable) result
(** The lane value under one published registry. The prompt and the answer
    schema belong to the asking layer and are passed in; the reserve, the
    thinking setting and the slots come from the registry. Windows are read
    from the active runtime table. *)

val lane_held
  :  http:Runtime_exact_lane_backpressure.ordered
  -> cli:string Runtime_candidate_standing.exact_order
  -> bool
(** Every declared slot is one its provider holds until a stated time (RFC
    §7.5): no HTTP slot is left to walk in [http] and no CLI slot in [cli],
    and at least one slot is held. A lane with nothing to walk and nothing
    held is not resting; asking it ends in the ask's own result. Pure: the
    caller reads both orders at the same moment
    ({!Runtime_exact_lane_backpressure.order_at},
    [Keeper_lane_cli_oneshot.order_slots]). *)
