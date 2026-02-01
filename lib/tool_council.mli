(** Council tools - Multi-agent debate and consensus system *)

type context = {
  base_path: string;
  agent_name: string;
}

type result = bool * string

val dispatch : context -> name:string -> args:Yojson.Safe.t -> result option

val definitions : Yojson.Safe.t list
