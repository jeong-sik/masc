(** Keeper_turn_driver_wrappers — convenience wrappers extracted from
    [Keeper_turn_driver].

    These are sibling entry points to {!Keeper_turn_driver.run_named}:
    - [run_model_by_label]: explicit model-label variant
    - [run_named_with_masc_tools]: runtime variant + MASC tool bridging

    Extracted from keeper_turn_driver.ml as RFC-0048 PR-2 to reduce the
    1347-LOC hotspot file.

    @since RFC-0048 PR-2 *)

open Result.Syntax
include Keeper_turn_driver

(* RFC-0206: re-homed from the deleted Runtime_config_builder.  Resolves a model
   label to its provider config and builds a Runtime_agent.config; no runtime
   catalog involved. *)
(* RFC-0206: the runtime CLI-preflight wrapper is gone; run the attempt
   directly.  Kept as a thin pass-through so the two call sites read unchanged. *)
let run_named_with_masc_tools
    ~runtime_id
    ?(keeper_name = "")
    ~goal
    ~base_path
    ?(system_prompt = "")
    ~(masc_tools : Masc_domain.tool_schema list)
    ~(dispatch : name:string -> args:Yojson.Safe.t -> Tool_result.result)
    ?stream_idle_timeout_s
    ?temperature
    ?(accept = fun (_ : Agent_core.Types.api_response) -> true)
    ?hooks
    ?raw_trace
    ?on_event
    ?on_yield
    ?on_resume
    ?on_runtime_attempt_error
    ?transport
    ?(yield_on_tool = false)
    ?provider_config_transform
    ?sw
    ?net
    ()
  : (Runtime_agent.run_result, Agent_core.Error.t) result =
  let bridged_tools = List.map (fun (td : Masc_domain.tool_schema) ->
    Tool_bridge.agent_core_tool_of_masc
      ~base_path
      ~name:td.name ~description:td.description
      ~input_schema:td.input_schema
      (fun input -> dispatch ~name:td.name ~args:input)
  ) masc_tools in
  let+ selected =
    Keeper_turn_driver.run_named
      ~runtime_id
      ~keeper_name
      ~goal
      ~base_path
      ~system_prompt
      ~tools:bridged_tools
      ~agent_core_tools:bridged_tools
      ?temperature
      ?stream_idle_timeout_s
      ?hooks
      ~accept
      ?raw_trace
      ?on_event
      ?on_yield
      ?on_resume
      ?on_runtime_attempt_error
      ?transport
      ~yield_on_tool
      ?provider_config_transform
      ?sw
      ?net
      ()
  in
  selected.run_result
