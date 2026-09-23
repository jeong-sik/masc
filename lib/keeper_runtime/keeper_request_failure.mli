(** Why one keeper request failed (RFC-0454 D2).

    Every place that ends a keeper request with a failure builds one of these
    instead of formatting a sentence. The constructor names the producer, so a
    reader matches a value rather than searching the text for a phrase
    (RFC-0454 §1.3).

    No constructor takes a free-form reason. Leaf strings are text for people
    — a store's own error, a caught exception's rendering, agent-core's
    message — and no code reads them to decide anything. {!Raised} is built
    only from a caught exception and names its site.

    The module sits in [masc.keeper_runtime] because both the keeper library
    (which runs the turn) and the server library (which owns the chat stream)
    produce these values, and both already depend on this one. *)

(** Which turn resource the keeper registry could not hand over. *)
type turn_resource =
  | Registry_entry_missing
  | Registry_entry_unhealthy

(** Which durable continuation step failed. A turn that cannot write its
    continuation cannot be resumed, so the four steps are kept apart: the
    operator reading the row wants to know whether the turn failed before it
    started or after it produced work worth resuming. *)
type continuation_stage =
  | Continuation_load
  | Gate_suspend
  | Runtime_continuation_defer
  | Checkpoint_retain

(** Which part of the reply contract the terminal projection refused. *)
type reply_contract_field =
  | Reply_payload
  | Turn_outcome
  | Turn_ref
  | External_effect_target

(** Where a turn ended with nothing visible to show. The two producers answer
    different questions — one projects a terminal reply, the other delivers a
    queued message — and each states its own fact. *)
type visible_reply_stage =
  | Terminal_projection
  | Queued_delivery

(** The closed set of places that catch an exception and terminalize the
    request with it. A site is a code path, not a message. *)
type failure_site =
  | Stream_dispatch
  | Stream_streaming_call
  | Stream_turn_body
  | Stream_submit

type cause =
  | Core of Keeper_request_failure_core.t
      (** An agent-core failure this module has no arm of its own for.
          RFC-0454 §2.2's per-constructor table replaces this arm; the four
          shapes below are the ones a producer already rendered as its own
          sentence, and moving them here is what keeps that rendering from
          living above the value. *)
  | Masc of Keeper_internal_error.masc_internal_error
      (** A MASC error that arrived on the agent-core carrier, kept as the
          value it is. *)
  | Provider_network of
      { provider : string option
      ; kind : Llm_provider.Http_client.network_error_kind
      ; detail : string
      }
  | Context_overflow of { limit : int option }
  | Input_capacity
  | Operator_cancelled
  | Server_not_initialized
  | Server_restarted
      (** The server restarted while the request was in flight, so the turn
          that would have answered it died with the process. *)
  | Dispatch_unavailable
      (** The keeper message surface returned no dispatch at all. *)
  | Keeper_meta_unresolved of
      { keeper : string
      ; detail : string
      }
  | Keeper_not_registered of { keeper : string }
  | Invocation_rejected of { detail : string }
      (** The request naming the keeper was refused before any turn started. *)
  | Chat_identity_mismatch
  | Turn_resources_unavailable of
      { resource : turn_resource
      ; detail : string
      }
  | Runtime_selection_failed of { detail : string }
  | Turn_continuation_unpersisted of
      { stage : continuation_stage
      ; detail : string
      }
  | User_row_unpersisted of { detail : string }
  | Gate_session_full of
      { approval_id : string
      ; runtime_id : string
      ; session_id : string
      ; recovery_id : string
      ; activity : Keeper_internal_error.vendor_session_activity
      }
      (** A Gate continuation resumed its original official-client session and
          the vendor refused the resume because that session is full.
          [activity] says whether a response or tool effect was observed first.
          The continuation may only run in that session, so it ends for good. [recovery_id] names the durable
          session record that says so; that record lets the next ordinary
          turn start a new session. *)
  | Reply_contract_rejected of
      { field : reply_contract_field
      ; detail : string
      }
  | No_visible_reply of
      { stage : visible_reply_stage
      ; had_blocks : bool
      }
  | Raised of
      { site : failure_site
      ; exn : string
      }

type t = { cause : cause }

val of_core_error : Agent_core.Error.t -> t
(** Project an agent-core error into a request failure. A MASC error on the
    carrier becomes {!Masc}; the four shapes agent-core states in terms a
    person can act on become their own constructors; anything else becomes
    {!Core}. This is the one place that decides, so no producer renders an
    agent-core error itself. *)

val summary : t -> string
(** One line for people. Computed from the value, never stored: line breaks
    inside leaf text become spaces. *)

val to_yojson : t -> Yojson.Safe.t
(** [{"cause": {...}}], where the cause is an object tagged by ["kind"]. A
    nested MASC error is written as the object its own codec writes, so no arm
    puts a JSON document inside a JSON string. *)

val of_yojson : Yojson.Safe.t -> (t, string) result
(** Strict: an unknown kind, a missing or extra field, or a field of the wrong
    shape is [Error]. Nothing is filled with a default. *)
