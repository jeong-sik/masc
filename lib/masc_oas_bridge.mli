(* lib/masc_oas_bridge.mli *)

(** Centralized boundary between MASC subsystems and the OAS Agent SDK.
    Enforces strict structural timeouts, cancellation safety, and type isolation. *)

(** Safe execution of a generic OAS operation with a mandatory timeout.
    Catches [Eio.Time.Timeout] and [Eio.Cancel.Cancelled] to perform functional rollback. *)
val run_safe :
  timeout_s:float ->
  (unit -> ('a, Oas.Error.sdk_error) result) ->
  ('a, Oas.Error.sdk_error) result
