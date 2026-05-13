(** Keeper-owned cascade execution boundary.

    Keepers resolve and iterate named cascade providers in MASC, then hand OAS
    a single-provider agent run for each attempt.  This module makes that
    boundary an explicit value so runtime manifests and tests do not rely only
    on source-text guards. *)

type oas_dispatch_mode = Single_provider_agent_run

type t

val keeper_managed : t
val to_string : t -> string
val oas_dispatch_mode : t -> oas_dispatch_mode
val oas_dispatch_mode_to_string : oas_dispatch_mode -> string
val allows_oas_internal_cascade : t -> bool
val guard_keeper_hot_path : t -> (unit, string) result

(** Fields suitable for splicing into runtime-manifest decision JSON. *)
val manifest_fields : t -> (string * Yojson.Safe.t) list
