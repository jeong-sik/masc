(** In-process runtime handlers for descriptor-backed coordination tools. *)

let handle_time_now ~args:_ =
  let now_unix = Time_compat.now () in
  let now_iso = Masc_domain.now_iso () in
  Yojson.Safe.to_string
    (`Assoc [ "now_iso", `String now_iso; "now_unix", `Float now_unix ])
;;

let handle_stay_silent ~args:_ =
  Yojson.Safe.to_string (`Assoc [ "status", `String "silent" ])
;;

let handle_tools_list ~meta ~args:_ =
  Keeper_exec_shared.keeper_tools_list_json ~meta
;;
