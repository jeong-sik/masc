(** LLM-backed Keeper context compaction. The exact caller-supplied Runtime
    produces a structured {!compaction_plan}; unavailable providers and invalid
    plans fail explicitly as [None]. *)

(** Source-bound unit plan; closed tool cycles are always kept. *)
type compaction_plan

(** [summarizer ~messages] returns [Some plan] when the LLM produced a valid
    plan over [messages], or [None] on any failure (provider error, empty
    or invalid structured response). Total and synchronous; the effect is
    hidden in the closure captured by {!make}. *)
type summarizer = messages:Agent_sdk.Types.message list -> compaction_plan option

(** The low-level provider completion the summarizer drives. Defaulted to
    {!Llm_provider.Complete.complete}; overridable in tests. *)
type complete_fn = Keeper_provider_subcall.complete_fn

(** [make ~runtime_id ~keeper_name ()] resolves [runtime_id] as a Runtime or
    Runtime Lane. A Runtime contributes its exact provider config; a Lane tries
    its configured Runtime candidates in declared order until one returns a
    valid plan. Missing, ineligible, and failed candidates are logged with
    their Runtime id. No default Runtime is substituted. [complete] overrides
    the Provider boundary in tests.

    The compaction owner imposes no wall-clock deadline. Cancellation belongs
    to the owning Keeper lane or to the Provider transport boundary. *)
val make
  :  ?complete:complete_fn
  -> runtime_id:string
  -> keeper_name:string
  -> unit
  -> summarizer option

(** Parse and validate unit indices against the exact U1 partition. *)
val plan_of_json
  :  messages:Agent_sdk.Types.message list
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

(** Rebuild the bound source with protected cycles exact. *)
val apply : compaction_plan -> Agent_sdk.Types.message list

val observation : compaction_plan -> string option * int * int

module For_testing : sig
  val with_make_override
    :  (runtime_id:string -> keeper_name:string -> unit -> summarizer option)
    -> (unit -> 'a)
    -> 'a

  (** Apply the compaction request policy while preserving the input provider
      config's exact temperature, including omission. *)
  val provider_for_plan
    :  Llm_provider.Provider_config.t
    -> Llm_provider.Provider_config.t

  val input_json
    :  messages:Agent_sdk.Types.message list
    -> (Yojson.Safe.t, string) result

  (** Eligible Runtime ids for a Runtime/Lane assignment, in exact declaration
      order. Provider configs are intentionally not exposed. *)
  val candidate_runtime_ids_for_assignment
    :  keeper_name:string
    -> runtime_id:string
    -> string list option
end
