(** Closed classification of a resolved Execute effect. *)

type t =
  | Confined
  | External

val classify
  :  sandbox_profile:Keeper_types_profile_sandbox.sandbox_profile
  -> network_mode:Keeper_types_profile_sandbox.network_mode
  -> target:Masc_exec.Sandbox_target.t
  -> t

val to_string : t -> string
