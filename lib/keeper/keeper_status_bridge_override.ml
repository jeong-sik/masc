type t =
  | Instructions of { default : string; live : string }
  | Mention_targets of { default : string list; live : string list }
  | Board_interests of { default : string list; live : string list }
  | Activation_mode of
      { default : Keeper_activation_mode.t
      ; live : Keeper_activation_mode.t
      }

let field_name = function
  | Instructions _ -> "prompt.instructions"
  | Mention_targets _ -> "workspace.mention_targets"
  | Board_interests _ -> "workspace.board_interests"
  | Activation_mode _ -> "activation_mode"
;;

let default_value_json = function
  | Instructions { default; _ } -> `String default
  | Mention_targets { default; _ } | Board_interests { default; _ } ->
    Json_util.json_string_list default
  | Activation_mode { default; _ } -> `String (Keeper_activation_mode.to_string default)
;;

let live_value_json = function
  | Instructions { live; _ } -> `String live
  | Mention_targets { live; _ } | Board_interests { live; _ } ->
    Json_util.json_string_list live
  | Activation_mode { live; _ } -> `String (Keeper_activation_mode.to_string live)
;;
