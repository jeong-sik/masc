(** MASC package identity exposed by the internal agent core. *)

let version =
  match Build_info.V1.version () with
  | None -> "dev"
  | Some version -> Build_info.V1.Version.to_string version
;;

let core_name = "masc.agent_core"
