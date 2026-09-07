(** Keeper_tool_name — the closed vocabulary of [masc_keeper_*] tool names.

    Routing parses the wire string once with {!of_string} and matches the
    constructors, so a constructor added here is a compile error at every site
    that must handle it: [Keeper_schema.schema_for] and both dispatchers in
    [Keeper_tool_surface].

    It lives outside [lib/tool] because keeper names are keeper-owned —
    [scripts/lint/masc-domain-boundary-ratchet.sh] holds [lib/tool] at zero
    [Keeper_*] identifiers. *)

type t =
  | Keeper_audit
  | Keeper_clear
  | Keeper_delegate
  | Keeper_delegate_cancel
  | Keeper_delegate_list
  | Keeper_delegate_status
  | Keeper_down
  | Keeper_list
  | Keeper_msg
  | Keeper_reset
  | Keeper_sandbox_start
  | Keeper_sandbox_stop
  | Keeper_status
  | Keeper_up
[@@deriving enumerate]

val to_string : t -> string
val of_string : string -> t option
val pp : Format.formatter -> t -> unit
