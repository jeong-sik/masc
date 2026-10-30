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
  | Recorder_failed of Keeper_skill_activation_recorder.error
  | Ledger_failed of Keeper_skill_activation_ledger.store_error

val error_to_string : error -> string
val source : binding -> Keeper_tool_execution_journal.source
val original_recorder : binding -> Keeper_skill_activation_recorder.bound_context
val request_id : binding -> string
val status_invocation : binding -> Agent_core.Tool_contract.Invocation.t
val observation_to_json : observation -> Yojson.Safe.t
val persist : config:Workspace.config -> observation ->
  (Keeper_skill_async_delivery.t option, error) result
(** Revalidate original authority, restore exact admitted original children,
    and append this physical handoff to their canonical Skill ledger. None
    means this original result has no admitted child. No activation or action
    is created, and reference evidence is never promoted to body delivery. *)
type status_snapshot
val observe_status : base_path:string -> ?invocation:Agent_core.Tool_contract.Invocation.t ->
  Keeper_msg_async.entry -> status_snapshot
val status_payload : status_snapshot -> Yojson.Safe.t
(** Capture physical fields once, plus a separate logical continuation reading:
    not applicable, observed original journal, or unavailable. Logical resolution
    never rewrites the physical outcome. Serialization and manifest admission use
    this exact snapshot, including the actual SDK occurrence when present. *)

val request_payload : status_snapshot -> Yojson.Safe.t
(** The same captured request/continuation data without a status-Tool kind
    marker. HTTP observation is not an SDK Tool invocation. *)

type t
val create : base_path:string -> physical_turn_ref:Ids.Turn_ref.t -> t

val record_status : t ->
  snapshot:status_snapshot ->
  invocation:Agent_core.Tool_contract.Invocation.t ->
  result:Tool_result.result -> (unit, error) result
(** Called only by the typed status producer, after manifest persistence.
    Done prepared runs restore authority with strict read-only reads. Named
    runs, nonterminal states and prepared runs without children add no binding.
    Original authority includes actual current or prior journal membership.
    The full SDK invocation identifies an occurrence. A later occurrence may
    reuse an ID and replace its slot. A failed or ineligible lookup evicts the
    old slot; the same occurrence cannot bind a different canonical result.
    The producer's captured payload is never rebuilt during manifest admission.
    The original logical observation must remain confirmed and unresolved at
    admission, physical delivery observation and ledger persistence checks.
    A successful lookup by itself is not a delivery observation. *)

val clear_pending : t -> unit
(** Drop the pending provider request on a new turn or runtime attempt.
    Producer bindings remain available for their exact retained ToolResults. *)

val discard_status : t -> invocation:Agent_core.Tool_contract.Invocation.t -> unit
(** A typed status lookup refused before recording a canonical result. Remove
    this ID's current slot without changing already staged provider results. *)

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
