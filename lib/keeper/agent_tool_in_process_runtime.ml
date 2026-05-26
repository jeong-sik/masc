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

let handle_memory_write ~config ~meta ~args =
  Keeper_exec_memory.keeper_memory_write_json ~config ~meta ~args
;;

let handle_ide_annotate ~config ~meta ~args =
  Agent_tool_ide_runtime.handle_ide_annotate
    ~config
    ~keeper_name:meta.Keeper_types.name
    ~args
;;

let handle_voice ~meta ~name ~args =
  Agent_tool_voice_runtime.handle_voice_tool ~meta ~name ~args
;;

let handle_task ~config ~meta ~name ~args =
  Keeper_exec_task.handle_keeper_task_tool ~config ~meta ~name ~args
;;
