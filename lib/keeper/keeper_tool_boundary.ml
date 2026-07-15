(** Boundary for calling keeper tools from non-keeper entrypoints. *)

type 'a context = {
  config : Workspace.config;
  agent_name : string;
  sw : Eio.Switch.t;
  clock : 'a Eio.Time.clock;
  proc_mgr : Eio_unix.Process.mgr_ty Eio.Resource.t option;
  net : [ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t option;
  publication_recovery_provider :
    Keeper_publication_recovery_availability.provider;
}

let create
      ~config
      ~agent_name
      ~sw
      ~clock
      ~proc_mgr
      ~net
      ~publication_recovery_provider
  =
  { config
  ; agent_name
  ; sw
  ; clock
  ; proc_mgr
  ; net
  ; publication_recovery_provider
  }

let to_tool_keeper_context (ctx : _ context) : _ Keeper_tool_surface.context =
  {
    Keeper_tool_surface.config = ctx.config;
    agent_name = ctx.agent_name;
    sw = ctx.sw;
    clock = ctx.clock;
    proc_mgr = ctx.proc_mgr;
    net = ctx.net;
    publication_recovery_provider = ctx.publication_recovery_provider;
  }

let dispatch ctx ~name ~args =
  Keeper_tool_surface.dispatch (to_tool_keeper_context ctx) ~name ~args

(* TEL-OK: this only closes over Keeper-owned context; dispatch remains observed downstream. *)
let delegated_dispatch
      ~config
      ~agent_name
      ~sw
      ~clock
      ~proc_mgr
      ~net
      ~publication_recovery_provider
  =
  let ctx =
    create
      ~config
      ~agent_name
      ~sw
      ~clock
      ~proc_mgr
      ~net
      ~publication_recovery_provider
  in
  fun ~name ~args -> dispatch ctx ~name ~args
;;

let dispatch_stream ?on_text_delta ?on_event ctx ~name ~args =
  Keeper_tool_surface.dispatch_stream ?on_text_delta ?on_event (to_tool_keeper_context ctx) ~name
    ~args
