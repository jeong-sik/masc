type t =
  { docker_args : string list
  ; cleanup : unit -> unit
  }

val docker_args_for_keeper :
  base_path:string -> keeper_name:string -> container_name:string -> (t, string) result

val dashboard_status_json :
  base_path:string -> keeper_name:string -> Yojson.Safe.t
