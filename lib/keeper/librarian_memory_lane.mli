(** The lane the Librarian asks through, as one comparable value (RFC
    librarian-call-only-proposes §4, §7.4, §7.5, §9.2 「선언 변경」).

    The lane is the built-in table [runtime.exact_output_lanes.librarian_memory]
    ({!Standalone_lane.Librarian_memory}). It is not the working-context
    pass's [librarian_exact]: the two ask different questions with different
    output sizes, and operators already declare different slots for them.

    The value is what decides whether an answer or a size fact still holds:
    the question side (prompt, answer schema, output reserve, thinking) and
    every admitted slot resolved to its key. Two publications that declare
    the same slots in the same order give equal values: the order is the
    order the lane walks, so a reorder gives a different value, and so does
    a slot whose resolved window changes. *)

(** What a slot calls. *)
type target =
  | Http of
      { provider_id : string option
      ; model_id : string
      ; provider_kind : Llm_provider.Provider_kind.t
      ; endpoint : string
      ; reserve : int
            (** The lane's [max_output_tokens], which the registry puts on
                this target as the request's [max_tokens]. A provider fits a
                question when input + this reserve is inside its window,
                whether masc counts before sending or the provider refuses
                after. *)
      }
      (** The admitted target's credential-free binding
          ({!Agent_core.Exact_output.admitted_target_binding}). *)
  | Cli of
      { runtime_id : string
      ; api_name : string
      }
      (** The official-client runtime and the model it starts. The client is
          never sent [max_tokens], so a CLI target has no reserve: the client
          picks its own output budget, which this value does not see. *)
[@@deriving eq, show]

type slot_key =
  { id : string  (** The declared slot id. *)
  ; target : target
  ; window : int
        (** {!Runtime_instance.resolve_max_context_of_runtime} of the runtime
            the id names: binding, then provider, then model, then the
            capability catalog. An HTTP slot reads the window the registry
            froze beside its target at publication
            ({!Runtime_exact_output_registry.runtime_observation}), so the
            target and the window come from one materialization. A CLI slot
            reads the runtime table active when {!resolve} runs, which is the
            table its call reads too. Config load refuses a [slots] id on this
            lane that names no runtime ([Runtime.runtime_slot_references]). *)
  }
[@@deriving eq, show]

type question_side =
  { prompt : string  (** The first part of every question's text. *)
  ; answer_schema : Yojson.Safe.t  (** The schema every answer must match. *)
  ; max_output_tokens : int  (** The lane's declared output reserve. *)
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
  | Lane_unconfigured  (** The registry has no [librarian_memory] table. *)
  | Lane_off  (** The table says [enabled = false]. *)
  | No_admitted_slots  (** No HTTP slot was admitted and no CLI slot is declared. *)
  | Reserve_undeclared
      (** The table declares no [max_output_tokens]. Config load refuses such
          an enabled table, so only a registry published from hand-built
          declarations carries it. *)
  | Window_unknown of { slot : string }
      (** The first slot, in declared order, whose window cannot be read: an
          HTTP target the registry froze without a runtime window (a
          replacement catalog's targets carry none), or a CLI id that names
          no runtime in the active table. The caller reads this as a lane
          with no declaration. *)
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
    thinking setting, the slots and the HTTP windows come from the registry.
    CLI windows and model names come from the runtime table active when this
    is called, so a caller resolves again after every publication it acts
    on. *)

val lane_held : now:float -> Runtime_exact_output_registry.resolved_lane -> bool
(** Every slot of [lane] (the admitted HTTP slots and the declared CLI slots)
    is one its provider holds until a stated time at [now] (RFC §7.5). A
    declared HTTP slot the registry did not admit is not in [lane] and is not
    read. Both orders of [lane] are read at [now] and
    {!Runtime_exact_lane_backpressure.held_until} answers. A lane with nothing
    to walk and nothing held is not resting; asking it ends in the ask's own
    result. *)
