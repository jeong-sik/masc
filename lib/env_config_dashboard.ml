(** Dashboard and operator environment configuration.

    Centralizes MASC_DASHBOARD_*, MASC_OPERATOR_*, and related
    operator-facing env vars. *)

open Env_config_core

(** {1 Dashboard Fixtures} *)

module Fixtures = struct
  let enabled =
    get_bool ~default:false "MASC_DASHBOARD_FIXTURES_ENABLED"

  let fixture_name_opt () =
    Sys.getenv_opt "MASC_DASHBOARD_FIXTURE" |> trim_opt
end

(** {1 Governance Judge} *)

module GovernanceJudge = struct
  let enabled =
    get_bool ~default:true "MASC_DASHBOARD_GOVERNANCE_JUDGE_ENABLED"

  let interval_sec =
    max 15 (get_int ~default:60 "MASC_DASHBOARD_GOVERNANCE_JUDGE_INTERVAL_SEC")
end

(** {1 Operator Judge} *)

module OperatorJudge = struct
  let enabled =
    get_bool ~default:true "MASC_OPERATOR_JUDGE_ENABLED"

  let interval_sec =
    max 15 (get_int ~default:60 "MASC_OPERATOR_JUDGE_INTERVAL_SEC")

  let session_ttl_sec =
    max 30 (get_int ~default:300 "MASC_OPERATOR_JUDGE_SESSION_TTL_SEC")

  let room_ttl_sec =
    max 15 (get_int ~default:60 "MASC_OPERATOR_JUDGE_ROOM_TTL_SEC")
end

(** {1 Operator Cache} *)

module OperatorCache = struct
  let ttl_sec =
    get_float ~default:30.0 "MASC_OPERATOR_CACHE_TTL"
end

(** {1 Alert Configuration} *)

module Alert = struct
  let dedup_window_sec =
    max 5.0 (get_float ~default:60.0 "MASC_ALERT_DEDUP_WINDOW_SEC")
end

(** {1 Relay Calibration} *)

module Relay = struct
  let calibration_enabled =
    get_bool ~default:true "MASC_RELAY_CALIBRATION_ENABLED"
end

(** {1 Orchestrator} *)

module Orchestrator = struct
  let agent_opt () =
    Sys.getenv_opt "MASC_ORCHESTRATOR_AGENT" |> trim_opt
end
