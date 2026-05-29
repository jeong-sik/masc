(** Routing-affecting reason for skipping a cascade candidate before
    provider dispatch.

    This is intentionally separate from [Cascade_preflight_state.reason], which
    controls health log-cadence only and does not own routing semantics. *)

type t =
  | Required_tool_unsupported of { missing : string list }
  | Capacity_constrained of { provider_key : string }
  | Health_cooldown_active of { provider_key : string; cooldown_reason : string }
  | Capacity_full of
      { capacity_key : string
      ; capacity_kind : [ `Client | `Admission ]
      ; retry_after_sec : float option
      }
  | Accept_rejected of { reason : string }

val to_manifest_tag : t -> string
val to_yojson : candidate:string -> t -> Yojson.Safe.t
