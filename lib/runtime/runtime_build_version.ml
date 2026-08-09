(** Build version owner shared by runtime adapters and protocol servers. *)

let current =
  match Build_info.V1.version () with
  | None -> "dev"
  | Some version -> Build_info.V1.Version.to_string version
;;
