type t =
  { docker_args : string list
  ; cleanup : unit -> unit
  }

type secret_root_info =
  { root : string
  ; source : string
  }

val secret_root_info : base_path:string -> keeper_name:string -> secret_root_info

val secret_root : base_path:string -> keeper_name:string -> string

val docker_args_for_keeper :
  base_path:string -> keeper_name:string -> container_name:string -> (t, string) result

val dashboard_status_json :
  base_path:string -> keeper_name:string -> Yojson.Safe.t
