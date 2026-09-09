(** Keeper_tool_name — the closed vocabulary of [masc_keeper_*] tool names.

    [all] is derived by [@@deriving enumerate], [to_string] is an exhaustive
    match, and [of_string] is derived from [all], so it cannot fall behind a
    constructor.

    This lives outside [lib/tool] because keeper names are keeper-owned:
    [scripts/lint/masc-domain-boundary-ratchet.sh] holds [lib/tool] at zero
    [Keeper_*] identifiers, and [Tool_name]'s own header reserves that module
    for domain vocabularies rather than every [masc_*] name. *)

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

let to_string = function
  | Keeper_audit -> "masc_keeper_audit"
  | Keeper_clear -> "masc_keeper_clear"
  | Keeper_delegate -> "masc_keeper_delegate"
  | Keeper_delegate_cancel -> "masc_keeper_delegate_cancel"
  | Keeper_delegate_list -> "masc_keeper_delegate_list"
  | Keeper_delegate_status -> "masc_keeper_delegate_status"
  | Keeper_down -> "masc_keeper_down"
  | Keeper_list -> "masc_keeper_list"
  | Keeper_msg -> "masc_keeper_msg"
  | Keeper_reset -> "masc_keeper_reset"
  | Keeper_sandbox_start -> "masc_keeper_sandbox_start"
  | Keeper_sandbox_stop -> "masc_keeper_sandbox_stop"
  | Keeper_status -> "masc_keeper_status"
  | Keeper_up -> "masc_keeper_up"
;;

let of_string value = List.find_opt (fun name -> String.equal value (to_string name)) all
let pp fmt t = Format.pp_print_string fmt (to_string t)
