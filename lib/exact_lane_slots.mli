(** The slots of one exact lane as {!Exact_lane_walk} walks them, and the
    visit of each kind.

    RFC exact-lane-walks-one-slot-list sections 3.3 to 3.6. An HTTP slot is
    visited as an AGENT_CORE flow of one candidate, sent under the seat the
    walk took. A CLI slot is visited as one official client one-shot, run
    while the walk holds a seat of the client's account. *)

type t =
  | Http_slot of Runtime_exact_output_registry.selected_slot
  | Cli_slot of
      { runtime_id : string
      ; runtime : Runtime_instance.t option
          (** [None]: no configured runtime holds the id. *)
      }

val of_resolved_lane : Runtime_exact_output_registry.resolved_lane -> t list
(** The lane's HTTP slots, then its CLI slots, each in declared order, as
    the registry lists them until the hard cut. A CLI slot's runtime is
    read here, once. *)

val id : t -> string
val kind : t -> Exact_lane_walk.kind
val quota_scope_of : t -> Runtime_quota_window.scope option
val candidate_backpressure_of : t -> Runtime_candidate_backpressure.candidate option

val seats : admission_class:Llm_provider.Admission_class.t -> t -> Exact_lane_walk.seats
(** An HTTP slot takes a seat of its endpoint
    ({!Agent_core.Exact_output.target_seats}). A target whose credential
    failed is [Seatless]: its flow is refused before any request. A CLI
    slot takes a seat of its account ({!Runtime_official_client_seats}). A
    CLI slot with no runtime, a runtime that is not an official client, or
    an account that published no seats is [Seatless], and its visit fails
    without running a client. A wait for a seat queues as
    [admission_class]. *)

(** What a CLI slot is asked: the lane's request written as one prompt. *)
type cli_request =
  { system_prompt : string
  ; prompt : string
  }

type ('accepted, 'rejection) answer =
  | Http_answered of
      { slot_id : string
      ; success : ('accepted, 'rejection) Agent_core.Exact_output.validated_flow_success
      }
  | Cli_answered of
      { runtime_id : string
      ; accepted : 'accepted
      }

type ('rejection, 'record_error) failure =
  | Http_failed of
      { slot_id : string
      ; error : ('record_error, 'rejection) Agent_core.Exact_output.validated_flow_error
      }
      (** The flow ended on a failure that would have advanced to another
          candidate ({!Agent_core.Exact_output.flow_execution_terminal_kind}),
          or the lane rejected its answer. *)
  | Cli_failed of
      { runtime_id : string
      ; failure : Keeper_lane_cli_oneshot.failure
      }
  | Cli_rejected of
      { runtime_id : string
      ; rejection : 'rejection
      }
      (** The client answered one JSON value and the lane rejected it. *)
  | Cli_unfit of { runtime_id : string }
      (** The lane's request cannot be written as one prompt, so no client
          was run. *)
  | Cli_seats_unpublished of
      { runtime_id : string
      ; provider_id : string
      }
      (** An official client whose account published no seats, so no
          client was run. *)

type ('rejection, 'record_error) stop =
  | Http_unstartable of
      { slot_id : string
      ; reason : string
      }
      (** masc could not start the flow of one candidate. *)
  | Http_stopped of
      { slot_id : string
      ; error : ('record_error, 'rejection) Agent_core.Exact_output.validated_flow_error
      }
      (** The flow stopped on masc's own failure: a record callback, a
          replayed flow, or an identity it could not allocate. *)
  | Record_failed of 'record_error
      (** The lane failed to record a CLI visit or a move to the next
          slot. *)

val rests : ('rejection, 'record_error) failure -> bool
(** [true] when the failure is a refusal of the account's standing, which
    says nothing about the request: every HTTP candidate the flow visited
    refused so ({!Agent_core.Exact_output.flow_execution_binding_standing}),
    or the client refused so ({!Keeper_lane_cli_oneshot.refused_for_binding_rest}). *)

type ('accepted, 'rejection, 'record_error) walk_result =
  ( t
    , ('accepted, 'rejection) answer
    , ('rejection, 'record_error) failure
    , ('rejection, 'record_error) stop )
    Exact_lane_walk.walk_result

(** Walk [slots] with {!Exact_lane_walk.walk}, ordering at [Eio.Time.now clock].

    {b HTTP visit.} A flow of the one candidate is sent with [messages] and
    [requirement] under the seat the walk took, with the lane's
    measurement and dispatch callbacks and [validate_http]. Its outcome is
    recorded on the slot's frozen runtime observation
    ({!Runtime_exact_lane_backpressure.observe}). A flow that ended on a
    failure another candidate could have served moves on; one that ended
    on masc's own failure stops the walk.

    {b CLI visit.} Without [cli_request] the slot is [Cli_unfit]. Otherwise
    [before_cli_visit] records the visit, then the client runs once and
    [validate_cli] reads its JSON value. A refusal of the account's
    standing notes a rate limit on the runtime's own cell, as an HTTP 429
    does, so the next order rests the slot; an answer clears the cell.

    [on_advance] records a move after a failed slot, as in
    {!Exact_lane_walk.walk}. *)
val walk
  :  ?runner:Keeper_lane_cli_oneshot.runner
  -> net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> clock:_ Eio.Time.clock
  -> base_dir:string
  -> admission_class:Llm_provider.Admission_class.t
  -> messages:Llm_provider.Types.message list
  -> requirement:Agent_core.Exact_output.output_requirement
  -> cli_request:cli_request option
  -> before_measurement_dispatch:
       (Agent_core.Exact_output.flow_measurement_receipt -> (unit, 'record_error) result)
  -> on_measurement_terminal:
       (Agent_core.Exact_output.flow_measurement_receipt -> (unit, 'record_error) result)
  -> before_dispatch:
       (Agent_core.Exact_output.flow_attempt_receipt -> (unit, 'record_error) result)
  -> validate_http:
       (Agent_core.Exact_output.flow_success
        -> ('accepted, 'rejection) Agent_core.Exact_output.semantic_verdict)
  -> validate_cli:(Yojson.Safe.t -> ('accepted, 'rejection) result)
  -> before_cli_visit:(runtime_id:string -> (unit, 'record_error) result)
  -> on_advance:
       (failed:('rejection, 'record_error) failure -> next:t -> (unit, 'record_error) result)
  -> t list
  -> ('accepted, 'rejection, 'record_error) walk_result
