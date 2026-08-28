(** Model-visible boundary for exact Assembler proposal production. *)

val handle
  :  capability_surface:Keeper_capability_surface.t
  -> config:Workspace.config
  -> keeper_name:string
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> args:Yojson.Safe.t
  -> unit
  -> Keeper_tool_execution.t
(** Validate against the frozen surface, invoke the configured
    [assembler_exact] lane, and persist only the resulting proposal. *)

val handle_without_frozen_surface : unit -> Keeper_tool_execution.t
(** Typed compatibility-path refusal. Assembly cannot reconstruct turn
    authority from mutable metadata. *)
