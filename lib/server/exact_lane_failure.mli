(** What one exact-lane failure says about trying the same request again. One
    answer per failure type, shared by every exact lane that walks slots: the
    Candle appraiser and a Lane Add-on package's exact outputs.

    This does not assert that an interrupted official-client turn had no
    effects. *)

type input_refusal =
  | Request_body
  | Invalid_request
  | Context_overflow
  | Input_capacity

type t =
  | Transient
      (** A transport failure or a cause that does not prove a refusal. The
          same request may pass later with nothing changed. So may one whose
          quota or billing refusal states when the account may be called
          again. *)
  | Auth_refused
      (** The credentials were refused. It may pass after they change. *)
  | Configuration_refused
      (** The slot, its runtime, its quota or its billing refused the call
          without stating when it may pass. It may pass after the operator
          changes them. A failure with no named
          cause is read the same way when its runtime's retry policy says the
          same call will not pass: nothing blamed this input, so something on
          the operator's side has to change. *)
  | Input_refused of input_refusal
      (** The provider refused this input itself. The same input cannot pass. *)
  | Output_unusable
      (** The provider answered, and the answer cannot be used. *)
  | Output_limit
      (** The provider specifically exhausted its output limit. It cannot
          answer this original attempt again. This is not an incomplete,
          malformed or oversized transport response. *)

val is_transient : t -> bool
(** Only [Transient]: the same request may be sent again unchanged. *)

val ending_input_refusal : t list -> input_refusal option
(** The input refusal a walk ends with, given its slots' failures. [None]
    when no slot refused the input. The answer does not depend on the order
    the slots were walked in.

    A refusal that names the size ([Context_overflow], [Input_capacity],
    [Request_body]) is chosen before [Invalid_request]. It states that a
    smaller input clears that slot's cause, which is what a consumer that
    subdivides its input reads the kind for; [Invalid_request] states no
    cause. Among the refusals that name the size, the order is the one
    [Keeper_librarian_input_refusal.rank] gives them. *)

val execution : Agent_core.Exact_output.execution_error_cause -> t
(** An HTTP slot's failed call. *)

val candidate : Agent_core.Exact_output.candidate_rejection_receipt -> t
(** An HTTP slot refused before the call was sent. Actual context/token input
    rejection is [Input_refused]; absent/expired/not-yet-valid measurement or
    capacity evidence is [Transient], not evidence that this input is too big. *)

val cli_failure : Keeper_lane_cli_oneshot.failure -> t
(** An official-client slot's failed one-shot turn. *)
