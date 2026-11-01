(** Per-installation Ego Space selection. The executable remains the configured
    host executable; this binding grants no adoption, claim or takeover authority. *)
type target = Workspace_default | Installation_space of Browser_configuration.ego_space
val target : Yojson.Safe.t -> (target, string) result
(** Read optional [binding.space]: a name or an exact numeric ID. Absence alone
    selects the workspace default. Null, duplicate and invalid values fail. *)
val validate : Lane_addon_types.worker_service -> Yojson.Safe.t -> (unit, string) result
(** Validate Ego binding data before declaration publication or manual attach.
    Other services retain their package-defined binding contracts. *)
val resolve : default:Browser_configuration.live_ego -> target -> Browser_configuration.live_ego
(** Resolve once for launch; preserve the configured command in either case. *)
