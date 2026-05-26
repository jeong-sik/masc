(* Fleet readiness JSON helpers for the dashboard composite endpoint. *)

let keeper_activation_readiness_json (meta : Keeper_types.keeper_meta) =
  Keeper_activation_readiness.(of_meta meta |> to_yojson)
;;
