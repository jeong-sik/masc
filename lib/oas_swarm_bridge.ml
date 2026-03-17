(** OAS Swarm bridge — connects MASC coordination to OAS swarm engine.

    Converts between MASC's LLM client (completion_request/response)
    and OAS Swarm (agent_entry, swarm_config, swarm_result).

    MASC responsibilities preserved:
    - LLM semaphore (global rate limiting via Llm_client_providers.complete)
    - Task queue (claim/done lifecycle)
    - Room broadcast (status updates)

    OAS responsibilities delegated:
    - Fiber-level concurrency (Eio.Fiber)
    - Convergence loop (metric-driven iteration)
    - State management (Eio.Mutex)

    @since 2.103.0 *)

module ST = Agent_sdk_swarm.Swarm_types

(* ── MASC → OAS conversion ──────────────────────────────────────── *)

(** Create an OAS swarm agent_entry from a MASC model spec.
    The run function calls MASC's Llm_client_providers.complete internally,
    which respects the global LLM semaphore. *)
let entry_of_masc_spec
    ~name
    ~role
    (spec : Llm_client_core.model_spec)
  : ST.agent_entry =
  { ST.name;
    run = (fun ~sw:_ prompt ->
      let request : Llm_client_core.completion_request = {
        model = spec;
        messages = [{ role = User; content = prompt;
                      name = None; tool_call_id = None }];
        temperature = 0.7;
        max_tokens = 4096;
        tools = [];
        response_format = `Text;
      } in
      match Llm_client_providers.complete request with
      | Ok response ->
        let usage = {
          Agent_sdk.Types.input_tokens = response.Llm_client_core.usage.input_tokens;
          output_tokens = response.usage.output_tokens;
          cache_creation_input_tokens = response.usage.cache_creation_input_tokens;
          cache_read_input_tokens = response.usage.cache_read_input_tokens;
        } in
        Ok {
          Agent_sdk.Types.id = "masc-bridge";
          model = response.model_used;
          stop_reason = Agent_sdk.Types.EndTurn;
          content = [Agent_sdk.Types.Text response.content];
          usage = Some usage;
        }
      | Error msg ->
        Error (Agent_sdk.Error.Internal msg));
    role }

(** Build an OAS swarm config from MASC agent specs. *)
let swarm_config
    ~prompt
    ~(specs : (string * ST.agent_role * Llm_client_core.model_spec) list)
    ?(mode = ST.Decentralized)
    ?(max_parallel = 4)
    ?convergence
    ?timeout_sec
    ?(budget : ST.resource_budget =
        { max_total_tokens = None; max_total_time_sec = None; max_total_api_calls = None })
    ()
  : ST.swarm_config =
  let entries = List.map (fun (name, role, spec) ->
    entry_of_masc_spec ~name ~role spec
  ) specs in
  { ST.entries; mode; convergence; max_parallel; prompt; timeout_sec; budget }

(* ── OAS → MASC conversion ──────────────────────────────────────── *)

(** Convert OAS swarm result to a MASC-friendly summary string. *)
let summary_of_result (result : ST.swarm_result) : string =
  let buf = Buffer.create 256 in
  Buffer.add_string buf
    (Printf.sprintf "Swarm: %d iterations, converged=%b, elapsed=%.1fs\n"
       (List.length result.iterations)
       result.converged
       result.total_elapsed);
  (match result.final_metric with
   | Some v -> Buffer.add_string buf (Printf.sprintf "Metric: %.4f\n" v)
   | None -> ());
  Buffer.add_string buf
    (Printf.sprintf "Tokens: %d in + %d out\n"
       result.total_usage.total_input_tokens
       result.total_usage.total_output_tokens);
  (match List.rev result.iterations with
   | last :: _ ->
     List.iter (fun (name, status) ->
       let s = match status with
         | ST.Done_ok { elapsed; _ } -> Printf.sprintf "ok (%.2fs)" elapsed
         | ST.Done_error { error; _ } -> Printf.sprintf "error: %s" error
         | ST.Idle -> "idle"
         | ST.Working -> "working"
       in
       Buffer.add_string buf (Printf.sprintf "  %s: %s\n" name s)
     ) last.ST.agent_results
   | [] -> ());
  Buffer.contents buf

(* ── MASC callbacks ─────────────────────────────────────────────── *)

(** Create swarm callbacks that broadcast status to a MASC room. *)
let masc_callbacks
    ~(broadcast : string -> unit)
    ~(agent_name : string)
  : ST.swarm_callbacks =
  { on_iteration_start = Some (fun iter ->
      broadcast (Printf.sprintf "[%s] swarm iter %d" agent_name iter));
    on_iteration_end = Some (fun record ->
      let metric_str = match record.ST.metric_value with
        | Some v -> Printf.sprintf " metric=%.4f" v
        | None -> ""
      in
      broadcast (Printf.sprintf "[%s] iter %d done%s"
        agent_name record.ST.iteration metric_str));
    on_agent_start = None;
    on_agent_done = None;
    on_converged = Some (fun _state ->
      broadcast (Printf.sprintf "[%s] swarm converged" agent_name));
    on_error = Some (fun msg ->
      broadcast (Printf.sprintf "[%s] swarm error: %s" agent_name msg));
  }
