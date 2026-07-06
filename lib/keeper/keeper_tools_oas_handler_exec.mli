(** Core execution body for keeper tool OAS handler. *)

(** Execute a keeper tool call with full observability: telemetry,
    failure classification, retry-state management, and exception
    handling.  Called from [Keeper_tools_oas_handler] after validation,
    circuit-breaking, and workflow-rejection checks have passed.

    All parameters that were previously captured from the outer
    [make_keeper_tool_handler] closure are passed explicitly. *)
val execute_with_observers
  :  name:string
  -> config:Workspace.config
  -> meta:Keeper_meta_contract.keeper_meta
  -> ctx_snapshot:Keeper_types.working_context
  -> ?turn_sandbox_factory:Keeper_sandbox_factory.t
  -> exec_cache:Masc_exec.Exec_cache.t option
  -> ?search_fn:(query:string -> max_results:int -> Yojson.Safe.t)
  -> ?on_tool_called:(string -> unit)
  -> ?sw:Eio.Switch.t
  -> ?clock:float Eio.Time.clock_ty Eio.Resource.t
  -> ?proc_mgr:Eio_unix.Process.mgr_ty Eio.Resource.t
  -> ?net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t
  -> ?mcp_session_id:string
  -> failure_counts:Keeper_tools_oas.failure_counts
  -> key:string
  -> input:Yojson.Safe.t
  -> unit
  -> Tool_result.result

module For_testing : sig
  type result_cwd_decode =
    | Result_cwd_found of string
    | Result_cwd_absent
    | Result_cwd_not_object of string
    | Result_cwd_parse_error of string

  val result_cwd_decode : string -> result_cwd_decode
  val result_cwd : string -> string option
end
