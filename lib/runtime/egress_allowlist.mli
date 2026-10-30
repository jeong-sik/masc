(** One keeper's egress allowlist, as declared in runtime.toml.

    The allowlist lives here rather than in the keeper TOML for the same
    reason an SSH endpoint does: it is operator policy about what a keeper
    may reach, not part of the keeper's own declaration. A keeper names a
    mode ([network_mode = "policy"]); what that mode permits is decided
    beside the endpoint registry.

    Rules are parsed at config load, so an entry a resolver could read
    differently than {!Egress_host} does fails the load rather than sitting
    in a live allowlist waiting to be matched against. *)

type t =
  { keeper_name : string
  ; allow : Egress_host.rule list
  }
[@@deriving show, eq]

val allow_strings : t -> string list
(** The normalized spelling of each rule, for a status projection or a
    config receipt. *)

val for_keeper : t list -> keeper_name:string -> t option
(** The entry for one keeper, or [None] when the registry declares none.

    [None] is not permission: a keeper in the policy lane with no entry has
    an empty allowlist, and {!Egress_host.admits} refuses everything against
    one. The caller decides whether to refuse the keeper outright or serve
    it a listener that admits nothing; both are closed, and neither is the
    open internet. *)
