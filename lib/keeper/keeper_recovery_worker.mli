(** Callable one-run recovery worker. Uses the existing named runtime and Tool
    executor. Does not schedule work, install a projection, or resume partial
    semantic processing from a byte cursor. *)
module Work = Keeper_recovery_work

module Projection = Keeper_recovery_projection

type requirement_binding =
  { reference_id : string
  ; positions : Projection.requirement list
  }

type page_encoding = Keeper_artifact_read.page_encoding =
  | Utf_8
  | Base64
[@@deriving yojson]

(** Successful handler-page production, not provider receipt, whole-source
    coverage, semantic understanding, or a partial-work restart checkpoint. The content
    digest hashes the returned encoded content, not an implicitly decoded slice.
    [recovery_source_sha256] binds this work's canonical source; [artifact_sha256]
    identifies the actual page, which may be a referenced stored Tool result. *)
type read_receipt =
  { tool_use_id : string
  ; turn : int
  ; planned_index : int
  ; runtime_id : string option
  ; recovery_source_sha256 : string
  ; artifact_sha256 : string
  ; offset : int
  ; next_offset : int
  ; total_bytes : int
  ; encoding : page_encoding
  ; returned_content_sha256 : string
  }
[@@deriving yojson]

type proposal_receipt =
  { work_id : string
  ; owner_claim_id : string
  ; tool_use_id : string
  ; runtime_id : string option
  ; source_sha256 : string
  ; proposal_artifact_sha256 : string
  ; work_revision : string
  ; lock_release_error : string option
  }
[@@deriving yojson]

type observation =
  | Page_produced of read_receipt
  | Proposal_persisted of proposal_receipt

type cause =
  | Store_error of Work.error
  | Requirement_binding_invalid of string
  | Source_observation_failed of string
  | Invalid_submission of string
  | Projection_rejected of Projection.error
  | Runtime_error of Agent_core.Error.t
  | No_proposal_submitted

val cause_to_string : cause -> string

type failed =
  { cause : cause
  ; reads : read_receipt list
  ; terminal_record : (Work.t Work.mutation, Work.error) result option
  ; execution : (Keeper_turn_driver.named_run_result, Agent_core.Error.t) result option
  ; claim_lock_release_error : string option
  }

type submitted =
  { work : Work.t
  ; validated : Projection.validated
  ; receipt : proposal_receipt
  ; reads : read_receipt list
  ; execution : (Keeper_turn_driver.named_run_result, Agent_core.Error.t) result
  ; claim_lock_release_error : string option
  }

type outcome =
  | Proposal_recorded of submitted
  | Stopped of failed
  (** A durable proposal may exist even if final Tool result delivery fails;
    [execution] preserves that failure. Neither constructor claims successful
    application or completion of the original Keeper request. *)

(** [runtime_id] is an explicit configured runtime/lane resolved by run_named.
    Tools are required on each materialized candidate through the existing
    driver's typed requirement; a known unsupported candidate is not called.
    The existing Keeper Owner must own worker lifecycle and join any previous
    worker before reclaim. Requirement bindings are owner-authored, with every
    required reference mapped to nonempty source positions. The model cannot
    weaken these bindings or the pending-stimulus set.

    The initial prompt carries purpose, source/requirement refs and atom
    manifest, never canonical bytes. A manifest too large for the chosen
    runtime remains a typed runtime failure; no numeric truncation is imposed.
    The existing workspace artifact reader remains available for stored Tool
    results referenced by the canonical source. No additional SHA allowlist is imposed.

    Existing trace/event/wire callbacks pass through to the named runtime; page
    observations do not replace its model usage and Tool I/O evidence. Expected
    I/O exceptions from [observe_current_source] become typed source failures.

    Cancellation is re-raised after attempting typed cancellation settlement
    under cancellation protection. Publication after source observation is
    not an atomic CAS on the live checkpoint; application must do that later. *)
val run
  :  config:Workspace.config
  -> work_id:string
  -> expected_revision:string
  -> instance_id:string
  -> runtime_id:string
  -> purpose:string
  -> requirements:requirement_binding list
  -> observe_current_source:
       (unit -> (Keeper_checkpoint_store.exact_checkpoint_snapshot, string) result)
  -> ?on_observation:(observation -> unit)
  -> ?raw_trace:Agent_core.Raw_trace.t
  -> ?event_bus:Agent_core.Event_bus.t
  -> ?trace_link:string * string
  -> ?on_event:(Agent_core.Types.sse_event -> unit)
  -> ?on_runtime_observation:(Runtime_observation.runtime_observation -> unit)
  -> ?on_request_wire_observation:
       (runtime_id:string
        -> max_request_body_bytes:int option
        -> body_bytes:int
        -> serialized:Llm_provider.Request_wire_observer.observation option
        -> unit)
  -> ?on_request_attribution:
       (runtime_id:string
        -> tools:Agent_core.Tool.t list
        -> transmitted:Keeper_official_client_host.transmitted_model_input
        -> unit)
  -> ?on_official_client_result_handoff:
       (runtime_id:string
        -> invocation:Agent_core.Tool_contract.Invocation.t
        -> content:string
        -> unit)
  -> ?on_runtime_attempt_error:
       (runtime_id:string
        -> attempt:int
        -> dispatch:Keeper_attempt_dispatch.t
        -> Agent_core.Error.t
        -> unit)
  -> sw:Eio.Switch.t
  -> net:Eio_context.eio_net
  -> unit
  -> outcome
