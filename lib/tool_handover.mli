(** Handover tools - Cellular agent handover DNA *)

type context = {
  config: Room.config;
  agent_name: string;
  fs: Eio.Fs.dir_ty Eio.Path.t option;
  proc_mgr: Eio_unix.Process.mgr_ty Eio.Resource.t option;
  sw: Eio.Switch.t option;  (** Only needed when fs and proc_mgr are Some *)
}

type tool_result = bool * string

val handle_handover_create : context -> Yojson.Safe.t -> tool_result
val handle_handover_list : context -> Yojson.Safe.t -> tool_result
val handle_handover_claim : context -> Yojson.Safe.t -> tool_result
val handle_handover_get : context -> Yojson.Safe.t -> tool_result

val schemas : Types.tool_schema list

val dispatch : context -> name:string -> args:Yojson.Safe.t -> tool_result option
