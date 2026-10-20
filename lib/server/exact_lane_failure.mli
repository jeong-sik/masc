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
          same request may pass later with nothing changed. *)
  | Auth_refused
      (** The credentials were refused. It may pass after they change. *)
  | Configuration_refused
      (** The slot, its runtime, its quota or its billing refused the call. It
          may pass after the operator changes them. *)
  | Input_refused of input_refusal
      (** The provider refused this input itself. The same input cannot pass. *)
  | Output_unusable
      (** The provider answered, and the answer cannot be used. *)

val is_transient : t -> bool

val execution : Agent_core.Exact_output.execution_error_cause -> t
val candidate : Agent_core.Exact_output.candidate_rejection_receipt -> t
val cli_failure : Keeper_lane_cli_oneshot.failure -> t
