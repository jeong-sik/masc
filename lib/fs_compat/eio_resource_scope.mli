(** A resource-only [Eio.Switch] boundary which preserves the callback outcome
    independently from switch release failures.

    The callback may attach resources to the supplied switch, but must not
    attach fibers. This restriction makes any exception raised after the
    callback outcome was captured unambiguously a resource-release failure. *)

type raised =
  { exception_ : exn
  ; backtrace : Printexc.raw_backtrace
  }

type cancelled =
  { reason : exn
  ; backtrace : Printexc.raw_backtrace
  }

type 'a callback_outcome =
  | Returned of 'a
  | Raised of raised
  | Cancelled of cancelled

type 'a t =
  { callback : 'a callback_outcome option
  ; scope_failure : raised option
  ; parent_cancellation : cancelled option
  }

val on_release : Eio.Switch.t -> (unit -> unit) -> unit
(** Register a release callback which reports its exception and original
    backtrace through [Eio.Switch.fail]. The switch still owns cancellation
    protection and composition of multiple release failures. *)

val track_close : sw:Eio.Switch.t -> [> Eio.Resource.close_ty] Eio.Resource.t -> unit
(** Register [Eio.Resource.close] with {!on_release} after attaching a resource
    to the switch. Its close implementation must disable or neutralize the
    original release hook even when closing raises, as Eio POSIX files do.
    Register before erasing the [Close] capability. This does not support the
    POSIX directory resource, whose handler does not expose [Close]. *)

(** [run_resource_only f] runs [f] in a fresh switch and captures its outcome
    before the switch releases attached resources. [callback = None] means
    that the parent cancellation context rejected entry before [f] ran. When
    [callback] is present, [scope_failure] is the exact exception raised while
    the switch released resources. [parent_cancellation] records cancellation
    observed after release without discarding a returned callback value.

    [f] must not attach fibers to the switch. *)
val run_resource_only : (Eio.Switch.t -> 'a) -> 'a t
