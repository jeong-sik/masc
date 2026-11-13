(** Async Agent — Eio fiber-based concurrent agent execution.

    @since 0.55.0 *)

let log = Log.create ~module_name:"async_agent" ()

let internal_agent_exception exn =
  Log.debug
    log
    "agent execution raised"
    [ Log.S ("exception", Stdlib.Printexc.to_string exn) ];
  Error.Internal "agent execution failed"
;;

(* ── Agent name extraction ────────────────────────────────────── *)

let agent_name agent = (Agent.state agent).config.name

let run_agent_result ~sw ?clock agent prompt =
  try Agent.run ~sw ?clock agent prompt with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | Out_of_memory -> raise Out_of_memory
  | Stack_overflow -> raise Stack_overflow
  | Stdlib.Sys.Break -> raise Stdlib.Sys.Break
  | exn -> Error (internal_agent_exception exn)
;;

(* ── Combinators ──────────────────────────────────────────────── *)

let all ~sw ?clock ?max_fibers agents =
  let run_one (agent, prompt) =
    let name = agent_name agent in
    let result = run_agent_result ~sw ?clock agent prompt in
    name, result
  in
  match max_fibers with
  | Some n -> Eio.Fiber.List.map ~max_fibers:n run_one agents
  | None -> Eio.Fiber.List.map run_one agents
;;
