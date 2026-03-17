(** Council tools - Multi-agent debate and consensus system *)

type context = {
  base_path: string;
  agent_name: string;
  room_config: Room.config option;
}

type result = bool * string

val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option

val definitions : Yojson.Safe.t list
