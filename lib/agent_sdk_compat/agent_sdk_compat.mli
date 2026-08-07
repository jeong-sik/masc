(** MASC-side OAS compatibility projections.

    OAS owns provider/model identity and error detail. This module exposes only
    non-identifying, lane-scoped classifications that MASC is allowed to use for
    routing and observability. It never unwraps OAS-private error payloads. *)

val error_kind : Agent_sdk.Error.sdk_error -> string
(** Non-identifying error kind for runtime lane manifest logging. *)
