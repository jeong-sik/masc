(** Descriptor-owned durable filesystem mutations.

    A mutation has one closed progress state. Once the final directory entry
    operation succeeds, later failures can only produce
    {!Committed_not_durable}; they can never be reported as retry-safe.

    The blocking and Eio entry points are intentionally separate. The Eio
    entry point protects the complete system-thread operation from
    cancellation, so a caller always receives the committed state. *)

module Segment : sig
  type t = private string

  type error =
    | Empty
    | Dot
    | Dot_dot
    | Contains_separator
    | Contains_nul

  val of_string : string -> (t, error) result
  val to_string : t -> string
end

type diagnostic_stage =
  | Temporary_close
  | Temporary_cleanup
  | Parent_close
  | Observer

type diagnostic =
  { stage : diagnostic_stage
  ; cause : exn
  ; backtrace : Printexc.raw_backtrace
  }

val diagnostic_to_string : diagnostic -> string

type 'a progress =
  | Not_committed of
      { cause : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Committed_not_durable of
      { value : 'a
      ; cause : exn
      ; backtrace : Printexc.raw_backtrace
      }
  | Durable of 'a

type 'a report =
  { progress : 'a progress
  ; diagnostics : diagnostic list
  }

val report_to_string : 'a report -> string
(** Human-readable evidence for logs and domain errors. Callers must still
    branch on [progress]; this function is not a policy or retry classifier. *)

val fold_report :
  'a report ->
  not_committed:('a report -> 'b) ->
  committed_not_durable:('a report -> 'b) ->
  durable:('a report -> 'b) ->
  'b
(** Exhaustive eliminator for a mutation report. Each caller must supply all
    three progress handlers, so retry and observability policy stays at the
    domain boundary instead of being flattened by the filesystem layer. *)

type observation =
  | Observed
  | Observer_failed of diagnostic

val is_temporary_name : string -> bool
(** [true] exactly for names minted by this mutation core. Recovery delegates
    to this predicate instead of duplicating the writer's naming contract. *)

type durability_confirmation =
  | Confirmed
  | Not_confirmed of
      { cause : exn
      ; backtrace : Printexc.raw_backtrace
      }

type durability_confirmation_report =
  { confirmation : durability_confirmation
  ; confirmation_diagnostics : diagnostic list
  }

val confirm_directory_durable_blocking :
  string -> durability_confirmation_report
(** Open a directory capability, fsync it, and close it through one auditable
    owner. [Confirmed] means a previous committed entry is now safe to use as a
    durability prerequisite. Open/fsync failure is [Not_confirmed]; a close
    failure after successful fsync is retained as a [Parent_close] diagnostic. *)

val confirm_directory_durable_eio :
  string -> durability_confirmation_report
(** Eio boundary for {!confirm_directory_durable_blocking}. The complete
    descriptor operation runs in one cancellation-protected systhread. *)

val atomic_replace_blocking :
  parent:string -> name:Segment.t -> perm:int -> string -> unit report
(** Open [parent] once as a directory capability, create and fsync an exclusive
    temporary file relative to it, rename that entry over [name], and fsync the
    same parent descriptor. The descriptor has one owner and one close path. *)

val atomic_replace_eio :
  parent:string -> name:Segment.t -> perm:int -> string -> unit report
(** Eio-safe counterpart of {!atomic_replace_blocking}. The whole blocking
    state machine runs in a protected system-thread call. There is no runtime
    detection or same-domain fallback. *)

val observe : ('a report -> unit) -> 'a report -> observation
(** Invoke an observer without allowing observer failure to replace or mutate
    the authoritative mutation report. Non-cancellation failure is returned
    explicitly; Eio cancellation remains a control signal and is re-raised. *)

val observe_and_retain : ('a report -> unit) -> 'a report -> 'a report
(** Run an observer and return the authoritative mutation report unchanged on
    success. Observer failure is appended as an [Observer] diagnostic instead
    of replacing the mutation progress; Eio cancellation still propagates. *)

val observe_confirmation_and_retain :
  (durability_confirmation_report -> unit) ->
  durability_confirmation_report ->
  durability_confirmation_report
(** Run an observer and retain the authoritative directory confirmation.
    Observer failure is appended to [confirmation_diagnostics]; Eio
    cancellation still propagates. *)

module For_testing : sig
  val run_state_machine :
    prepare:(unit -> unit) ->
    commit:(unit -> unit) ->
    publish:(unit -> unit) ->
    cleanup:(unit -> diagnostic list) ->
    unit report
  (** Deterministic seam for phase-transition and cancellation tests. Production
      mutations use this same state machine. *)
end
