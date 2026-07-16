(** LLM-backed Keeper context compaction. The exact caller-supplied Runtime
    produces a structured {!compaction_plan}; unavailable providers and invalid
    plans fail explicitly as [None]. *)

type compaction_plan

type observation =
  { selected_runtime_id : string option
  ; summarized_message_count : int
  ; dropped_message_count : int
  }

type planning_outcome =
  | Planned of compaction_plan
  | No_compaction

(** [None] means unavailable/invalid. [No_compaction] is reserved as a valid
    terminal LLM judgment and must not fall through to another Runtime. *)
type summarizer = messages:Agent_sdk.Types.message list -> planning_outcome option

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

val plan_of_json
  :  messages:Agent_sdk.Types.message list
  -> Yojson.Safe.t
  -> (compaction_plan, string) result

val apply : compaction_plan -> Agent_sdk.Types.message list
(** Rebuild the bound source chronologically and append its protected suffix. *)

val observation : compaction_plan -> observation

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

  (** Eligible Runtime ids for a Runtime/Lane assignment, in exact declaration
      order. Provider configs are intentionally not exposed. *)
  val candidate_runtime_ids_for_assignment
    :  keeper_name:string
    -> runtime_id:string
    -> string list option
end
