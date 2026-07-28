(** Keeper-owned provider tool-choice normalization. *)

let relax_strict_for_keeper = function
  | Some (Agent_sdk.Types.Any | Agent_sdk.Types.Tool _) ->
    Some Agent_sdk.Types.Auto
  | other -> other
;;
