(** Tool_walph - Walph transition handlers *)

type 'a context = {
  config: Room.config;
  agent_name: string;
  clock: 'a Eio.Time.clock;
}

val schemas : Types.tool_schema list

(** Dispatch handler. Returns Some (success, result) if handled, None otherwise *)
val dispatch : 'a context -> name:string -> args:Yojson.Safe.t -> (bool * string) option

(** Handle masc_walph_control *)
val handle_walph_control : 'a context -> Yojson.Safe.t -> bool * string

(** Handle masc_walph_natural *)
val handle_walph_natural : 'a context -> Yojson.Safe.t -> bool * string

(** Handle masc_walph_status *)
val handle_walph_status : 'a context -> Yojson.Safe.t -> bool * string
