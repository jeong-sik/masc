(** Silent_dashboard_actor_outcome — closed sum for the [outcome] label
    on [metric_silent_dashboard_actor_fallback].

    Replaces 2 hardcoded literals (`"none"` / `"error"`) in
    [server_auth.ml].  The [error] arm is paired with the typed
    [Auth_error_kind] enum in an adjacent label ([err_kind]); this
    closes the remaining hardcoded string. *)

type t =
  | None_resolved (** Bearer token resolved to no agent (token unknown). *)
  | Error_classified
  (** Token resolution raised a classified [Auth_error_kind]; the
          companion [err_kind] label carries the closed-sum
          classification. *)

val to_label : t -> string
