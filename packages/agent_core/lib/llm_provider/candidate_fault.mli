(** Closed judgment: is this failure this candidate's own affair?

    Both walks (exact and Keeper) answer "may the next candidate serve the
    same input?" from this single judgment. See
    [RFC-one-slot-fault-judgment-for-every-walk](https://github.com/jeong-sik/masc/blob/main/docs/rfc/RFC-one-slot-fault-judgment-for-every-walk.md)
    and issue #38472.

    The judgment answers only whose affair the failure is. Whether to advance
    is the walk's decision ([Exact_output.execution_failure_may_advance] and
    the Keeper lane predicates).

    @stability Internal
    @since 0.39.0 *)

(** A fact that belongs to this candidate alone: the provider·model·
    credential·account bundle, not to the request it carried. *)
type binding_fact =
  | Credential
      (** HTTP 401. The key is dead. The next candidate carries its own key. *)
  | Account_access
      (** HTTP 403. The provider accepted who is calling and refused the
          account: a spent subscription window, a missing entitlement, a
          client the plan does not admit, or a suspended account. The status
          alone does not say which. The next candidate carries its own
          account. Kept apart from [Credential] because the Keeper walk reads
          provider usage after this fact and not after a 401; with one
          constructor that split had to be re-derived from the raw error,
          a second table beside this one (#38975, task-1773). *)
  | Account
      (** HTTP 402. This account cannot pay. The next candidate may bill a
          different account; the same quota scope sees this fact together. *)
  | Model_absent
      (** HTTP 404. This candidate has no such model. The next candidate may
          have it. *)
  | Rate_limit
      (** HTTP 429. This candidate asks the caller to slow down. It does not
          say what ran out. *)
  | Capacity
      (** HTTP 529, a provider capacity-pool refusal. *)
  | Server
      (** 5xx. A complete server-failure response from this candidate. *)
  | Window
      (** Context overflow, or an empty answer that stopped at the window.
          The window is a property of this candidate. *)
  | Body_limit
      (** HTTP 413. The body-size limit this binding accepts. A candidate with
          a larger limit takes the same body. *)
  | Admission
      (** Before dispatch this candidate's stage refused the prepared request:
          the declared input capacity was exceeded, the input could not be
          measured, or the prepared request was rejected. Another binding may
          accept it. *)
  | Deadline
      (** After dispatch, the header or total deadline ran out. How long a
          binding takes is a property of the binding. *)
  | Output_dialect
      (** The answer landed in a non-content field. The output dialect is a
          property of this binding. *)
  | Refusal_unread
      (** The refusal status arrived but the refusal body did not arrive in
          the caller's window, so the reason was not heard. *)

type t =
  | Binding of binding_fact
      (** This binding's affair. The next candidate may serve the same input. *)
  | Unattributed
      (** A refusal arrived, but the response does not say whose affair it is
          in a machine-readable shape. *)
  | Unknown_after_dispatch
      (** Dispatched, and the result is unknown. Whether re-sending is allowed
          is the walk's effect rule, not this judgment. *)

(** Whether the request was dispatched. Exact_output lowers its
    [generation_dispatch_fact] to this type; because Exact_output reads this
    module, the fact it lowers lives below this type. *)
type dispatch =
  | Not_dispatched
  | Dispatched

val of_api_error : Retry.api_error -> t

val of_transport_error : Http_client.http_error -> dispatch:dispatch -> t
