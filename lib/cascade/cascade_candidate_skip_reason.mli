(** Routing-affecting reason for skipping a cascade candidate before
    provider dispatch.

    This is intentionally separate from [Cascade_preflight_state.reason], which
    controls health log-cadence only and does not own routing semantics. *)

type t =
  | Required_tool_unsupported of { missing : string list }

val to_manifest_tag : t -> string
val to_yojson : candidate:string -> t -> Yojson.Safe.t
