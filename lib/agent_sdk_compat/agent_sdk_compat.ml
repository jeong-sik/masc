(** MASC-side OAS compatibility projections.

    OAS owns provider/model identity and error detail. This module exposes only
    non-identifying, lane-scoped classifications that MASC is allowed to use for
    routing and observability. It never unwraps OAS-private error payloads. *)

(** Classify an OAS sdk_error into a non-identifying kind string suitable for
    runtime lane manifest logging. The mapping is structural over the public
    [Agent_sdk.Error.sdk_error] variant only. *)
let error_kind (e : Agent_sdk.Error.sdk_error) =
  match e with
  | Agent_sdk.Error.Api _ -> "api"
  | Agent_sdk.Error.Provider _ -> "provider"
  | Agent_sdk.Error.Agent _ -> "agent"
  | Agent_sdk.Error.Mcp _ -> "mcp"
  | Agent_sdk.Error.Config _ -> "config"
  | Agent_sdk.Error.Serialization _ -> "serialization"
  | Agent_sdk.Error.Io _ -> "io"
  | Agent_sdk.Error.Orchestration _ -> "orchestration"
  | Agent_sdk.Error.Internal _ -> "internal"
;;
