(** Consumer API — high-level agent execution with telemetry aggregation.

    @since 0.55.0 *)

type run_result =
  { response : (Types.api_response, Error.sdk_error) result
  ; trace_ref : Raw_trace.run_ref option
  ; harness_verdict : Harness.verdict option
  ; elapsed : float
  }

let agent_name agent = (Agent.state agent).config.name

let run_agent ~sw ?clock ?harness agent prompt =
  let t0 = Unix.gettimeofday () in
  let response =
    try Agent.run ~sw ?clock agent prompt with
    | Eio.Cancel.Cancelled _ as e -> raise e
    | exn -> Error (Error.Internal (Printexc.to_string exn))
  in
  let elapsed = Unix.gettimeofday () -. t0 in
  let trace_ref = Agent.last_raw_trace_run agent in
  let harness_verdict =
    match harness with
    | None -> None
    | Some expectation ->
      let obs = Harness.Behavioral.observe agent response in
      Some (Harness.Behavioral.evaluate obs expectation)
  in
  { response; trace_ref; harness_verdict; elapsed }
;;

let run_agents ~sw ?clock ?max_fibers agents =
  let run_one (agent, prompt) =
    let name = agent_name agent in
    let result = run_agent ~sw ?clock agent prompt in
    name, result
  in
  match max_fibers with
  | Some n -> Eio.Fiber.List.map ~max_fibers:n run_one agents
  | None -> Eio.Fiber.List.map run_one agents
;;
