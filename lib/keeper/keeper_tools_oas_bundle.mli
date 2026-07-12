(** Tool bundle assembly for keeper OAS execution. *)

(** Build the keeper's full [tool_bundle]: internal tools +
    alias-registered (public name) tools that translate input to
    internal payloads. The cleanup thunk releases per-turn sandbox
    runtimes (Docker case). *)
val make_tool_bundle
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_snapshot:Keeper_types.working_context
  -> ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> ?on_tool_called:(string -> unit)
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?continuation_channel:Keeper_continuation_channel.t
  -> unit
  -> Keeper_tools_oas.tool_bundle

(** Convenience over [make_tool_bundle] returning only [.tools]. *)
val make_tools
  :  config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_snapshot:Keeper_types.working_context
  -> ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> ?on_tool_called:(string -> unit)
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> unit
  -> Agent_sdk.Tool.t list
