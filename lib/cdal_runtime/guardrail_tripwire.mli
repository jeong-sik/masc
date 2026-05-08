(** Tripwire guardrails: fail-fast parallel validators.

    A tripwire runs concurrently with the main agent LLM call.
    If any tripwire fires before the action completes, the action's
    fiber is cancelled via Eio structured concurrency.

    Uses [Eio.Fiber.first] (not [both]) so the first completion
    cancels the other fiber.

    @stability Evolving
    @since 0.102.0 *)

(** {1 Types} *)

type tripwire =
  { name : string
  ; check : Types.message list -> (unit, string) result
    (** Blocking check. Return [Error reason] to trip. *)
  }

type tripwire_result =
  | All_clear
  | Tripped of
      { tripwire_name : string
      ; reason : string
      }

(** {1 Execution} *)

(** Run the action and all tripwires concurrently.
    If any tripwire fires (returns [Error]) before the action completes,
    the action fiber is cancelled and [Error (`Tripped ...)] is returned.
    If the action completes first, tripwire fibers are cancelled.

    With zero tripwires, runs the action directly (no fiber overhead). *)
val guarded_action
  :  tripwires:tripwire list
  -> messages:Types.message list
  -> action:(unit -> ('a, Error.sdk_error) result)
  -> ('a, [ `Tripped of tripwire_result | `Action of Error.sdk_error ]) result
