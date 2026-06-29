(** Runtime resolution shared by Memory OS LLM producers. *)

let runtime_id_for_librarian ~runtime_id =
  match Env_config.KeeperMemoryOs.librarian_runtime_id () with
  | Some value -> value
  | None ->
    (match Runtime.librarian_runtime_id () with
     | Some id -> id
     | None -> runtime_id)
;;

let provider_for_runtime ~runtime_id =
  match Runtime.get_runtime_by_id runtime_id with
  | Some rt -> Ok rt.Runtime.provider_config
  | None ->
    (match Runtime.get_default_runtime () with
     | Some rt -> Ok rt.Runtime.provider_config
     | None -> Error "no runtime configured for memory LLM producer")
;;
