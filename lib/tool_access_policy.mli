(** Tool_access_policy — shared allow/deny selector ADT for runtime tool policies.

    This module centralizes how runtime policy overlays select tool names.
    Different subsystems may still store their own policy shapes, but they
    should resolve through this ADT instead of re-implementing allowlist /
    denylist semantics independently. *)

type selector =
  | Empty
  | All
  | Names of string list
  | Surface of Tool_catalog.surface
  | Union of selector list
  | Inter of selector list
  | Diff of
      { base : selector
      ; exclude : selector
      }

type t =
  { allow : selector
  ; deny : selector
  }

val empty : t
val allow_all : t
val of_allowlist : ?deny:string list -> string list -> t
val with_deny_names : t -> string list -> t
val with_deny_selector : t -> selector -> t
val union : selector list -> selector
val inter : selector list -> selector
val diff : base:selector -> exclude:selector -> selector
val selector_matches_name : selector -> string -> bool
val allows_name : t -> string -> bool
val resolve_selector : ?candidates:string list -> selector -> string list
val resolve : ?candidates:string list -> t -> string list
