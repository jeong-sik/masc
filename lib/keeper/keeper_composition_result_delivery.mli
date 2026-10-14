(** Correlate actual async status results with their original prepared run.
    Source authority and physical transport identities remain separate. *)

type binding
type presentation = Inline_result | Manifest_reference
type observation = private
  { binding : binding
  ; physical_turn_ref : Ids.Turn_ref.t
  ; runtime_id : string
  ; boundary : Keeper_skill_activation_ledger.delivery_boundary
  ; transport_receipt : Keeper_skill_activation_ledger.tool_result_receipt
  ; presentation : presentation
  }

type error =
  | Invalid_context of string
  | Canonical_request_failed of Keeper_msg_async.canonical_terminal_error
  | Request_changed
  | Journal_failed of Keeper_tool_execution_journal.error
  | Activation_failed of Keeper_composition_draft.error
  | Manifest_read_failed of Tool_blob_store.fetch_error
  | Invalid_manifest of string
  | Invalid_result of string
  | Invocation_collision of string

val error_to_string : error -> string
val source : binding -> Keeper_tool_execution_journal.source
val original_recorder : binding -> Keeper_skill_activation_recorder.bound_context
val request_id : binding -> string
val status_invocation : binding -> Agent_core.Tool_contract.Invocation.t
val observation_to_json : observation -> Yojson.Safe.t

type t
val create : base_path:string -> physical_turn_ref:Ids.Turn_ref.t -> t

val record_status : t ->
  entry:Keeper_msg_async.entry ->
  invocation:Agent_core.Tool_contract.Invocation.t ->
  result:Tool_result.result -> (unit, error) result
(** Called only by the typed status producer, after manifest persistence.
    Done prepared runs restore authority with strict read-only reads. Named
    runs, nonterminal states and prepared runs without children add no binding.
    Original authority includes actual current or prior journal membership.
    The full SDK invocation identifies an occurrence. A later occurrence may
    reuse an ID and replace its slot. A failed or ineligible lookup evicts the
    old slot; the same occurrence cannot bind a different canonical result.
    A successful lookup by itself is not a delivery observation. *)

val clear_pending : t -> unit
(** Drop the pending provider request on a new turn or runtime attempt.
    Producer bindings remain available for their exact retained ToolResults. *)

val stage_provider : t -> runtime_id:string -> agent_core_turn:int ->
  tool_results:(string * string) list -> unit
(** Stage actual trailing ToolResult IDs and unmodified wire content, capturing
    the current producer occurrence. Later ID reuse or slot eviction cannot
    retarget an already staged result. Historical transcript occurrences that
    were not staged are outside this observer's scope. *)

val commit_provider_response : t -> agent_core_turn:int ->
  observe:(observation -> unit) -> on_error:(error -> unit) -> unit
(** Observe only the matching successful response. Re-read original canonical
    authority before publishing the observation. A marker proves a reference
    handoff, never receipt of the locally fetched manifest body. *)

val observe_official_result : t -> runtime_id:string ->
  invocation:Agent_core.Tool_contract.Invocation.t -> content:string ->
  observe:(observation -> unit) -> on_error:(error -> unit) -> unit
(** Consume the actual official-client result-content callback only when its
    full SDK invocation equals the current producer occurrence. No activation,
    delivery ledger or action record is mutated by this module. *)
