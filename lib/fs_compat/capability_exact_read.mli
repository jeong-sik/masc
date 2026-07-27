(** Capability-scoped observation of one immutable regular-file snapshot.

    This module owns no digest, schema, history, migration, scan, retry, repair,
    or deletion policy. It pins the supplied parent capability and dispatches
    exactly one single-component leaf open.

    Before allocation, [read] proves non-negative [expected_length <=
    max_length], representability, regular-file kind, one link, mode [0600]
    without special bits, the safety ceiling, and the exact expected size. It
    then reads exactly N bytes plus EOF and checks the opened descriptor's
    identity, link count, mode, and size again. Successful observations and
    non-fatal typed failures preserve child-close and parent-resource
    settlement warnings. [Out_of_memory], [Stack_overflow], and [Sys.Break]
    remain fatal: they are re-raised with their original backtrace and are
    outside the typed-outcome and settlement-warning preservation contract.

    Cancellation is linearized as follows: pending parent cancellation is
    checked when [read] starts. The child open dispatch, exact observation, and
    close settlement run in a protected cancellation scope. The completed
    typed outcome is never replaced by a later cancellation: cancellation
    observed during parent-resource settlement is retained as a typed
    [Settle_resources] warning rather than raised by a final check. *)

type operation =
  | Pin_parent
  | Open_parent_descriptor
  | Open_leaf
  | Inspect_opened
  | Allocate
  | Read_exact
  | Inspect_after_read
  | Close_leaf
  | Settle_parent_resources
  | Observe_parent_cancellation

type diagnostic =
  { operation : operation
  ; detail : string
  }

type settlement_warning =
  | Close_failed of diagnostic
  | Settle_resources of diagnostic

type error =
  | Invalid_leaf of string
  | Invalid_length_bounds of
      { expected_length : int64
      ; max_length : int64
      }
  | Length_not_representable of int64
  | Cancelled of diagnostic
  | Parent_descriptor_unavailable
  | Missing
  | Symbolic_link
  | Not_regular of Unix.file_kind
  | Unsafe_link_count of int
  | Unsafe_mode of int
  | Length_exceeds_max of
      { max_length : int64
      ; observed_length : int64
      }
  | Length_mismatch of
      { expected_length : int64
      ; observed_length : int64
      }
  | Changed_during_read
  | Io_error of diagnostic

type observation

val observation_bytes : observation -> string
val observation_length : observation -> int64
val observation_settlement_warnings : observation -> settlement_warning list

type failure = private
  { error : error
  ; settlement_warnings : settlement_warning list
  }

(** [read ~parent ~leaf ~expected_length ~max_length] observes only [leaf]
    relative to the pinned [parent] descriptor. [leaf] must be one valid path
    component. *)
val read :
  parent:Eio.Fs.dir_ty Eio.Path.t ->
  leaf:string ->
  expected_length:int64 ->
  max_length:int64 ->
  (observation, failure) result

module For_testing : sig
  type hooks

  val hooks :
    ?before_open:(unit -> unit) ->
    ?after_open_stat:(unit -> unit) ->
    ?before_allocate:(unit -> unit) ->
    ?after_exact_read:(unit -> unit) ->
    ?on_close:(unit -> unit) ->
    ?on_settle_resources:(unit -> unit) ->
    unit ->
    hooks

  val read :
    hooks:hooks ->
    parent:Eio.Fs.dir_ty Eio.Path.t ->
    leaf:string ->
    expected_length:int64 ->
    max_length:int64 ->
    (observation, failure) result
end
