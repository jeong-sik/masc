(** Multi-agent swarm runner with MASC coordination.

    Runs N Agent SDK instances as Eio fibers.
    Each agent joins a MASC room, executes its goal using LLM + tools,
    then leaves the room. *)

module Masc_log = Log
open Agent_sdk
module Log = Masc_log

type managed_task = {
  title_fragment: string;
  claim_marker: string;
  done_marker: string;
}

type agent_spec = {
  name: string;
  provider: Provider.config;
  system_prompt: string;
  tools: Tool.t list;
  max_tokens: int option;
  max_turns: int;
  temperature: float option;
  include_masc_tools: bool;
  managed_task: managed_task option;
  expected_final_marker: string option;
}

type swarm_config = {
  masc_url: string;
  agents: agent_spec list;
}

type completion_result = {
  response: Types.api_response;
  model_final_marker_seen: bool;
  final_marker_assisted: bool;
}

type agent_result = {
  agent_name: string;
  result: (completion_result, string) result;
}

let extract_text (response : Types.api_response) =
  response.content
  |> List.filter_map (function Types.Text text -> Some text | _ -> None)
  |> String.concat "\n"

let trimmed_nonempty_lines text =
  text
  |> String.split_on_char '\n'
  |> List.map String.trim
  |> List.filter (fun line -> not (String.equal line ""))

let last_nonempty_line text =
  match trimmed_nonempty_lines text |> List.rev with
  | line :: _ -> Some line
  | [] -> None

let final_marker_line text =
  match last_nonempty_line text with
  | Some line
    when String.length line >= 13
         && String.sub line 0 13 = "FINAL_MARKER[" ->
      Some line
  | _ -> None

let response_has_expected_final_marker (response : Types.api_response)
    ~(expected_final_marker : string option) =
  match expected_final_marker with
  | None -> true
  | Some marker ->
      let text = extract_text response in
      if String.equal marker "" then
        true
      else
        match last_nonempty_line text with
        | Some line -> String.equal line marker
        | None -> false

let validate_expected_final_marker (response : Types.api_response)
    ~(expected_final_marker : string option) =
  if response_has_expected_final_marker response ~expected_final_marker then
    Ok response
  else
    match expected_final_marker with
    | Some marker ->
        Error
          (Printf.sprintf
             "Missing expected final marker as final non-empty line: %s"
             marker)
    | None -> Ok response

let ensure_expected_final_marker (response : Types.api_response)
    ~(expected_final_marker : string option) =
  let model_final_marker_seen =
    response_has_expected_final_marker response ~expected_final_marker
  in
  match validate_expected_final_marker response ~expected_final_marker with
  | Ok validated ->
      Ok
        {
          response = validated;
          model_final_marker_seen;
          final_marker_assisted = false;
        }
  | Error _ -> (
      match expected_final_marker with
      | None ->
          Ok
            {
              response;
              model_final_marker_seen;
              final_marker_assisted = false;
            }
      | Some marker ->
          let text = extract_text response |> String.trim in
          if String.equal text "" then
            Error
              (Printf.sprintf
                 "Missing expected final marker as final non-empty line: %s"
                 marker)
          else
            Ok
              {
                response;
                model_final_marker_seen = false;
                final_marker_assisted = true;
              })

let contains_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then true
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then false
      else if String.sub haystack idx needle_len = needle then true
      else loop (idx + 1)
    in
    loop 0

let find_substring ~needle haystack =
  let needle_len = String.length needle in
  let haystack_len = String.length haystack in
  if needle_len = 0 then Some 0
  else
    let rec loop idx =
      if idx + needle_len > haystack_len then None
      else if String.sub haystack idx needle_len = needle then Some idx
      else loop (idx + 1)
    in
    loop 0

type listed_task = {
  task_id: string;
  title: string;
}

let rpc_first_text json =
  let open Yojson.Safe.Util in
  json
  |> member "content"
  |> to_list
  |> List.find_map (fun entry -> member "text" entry |> to_string_option)

let parse_task_board text =
  text
  |> String.split_on_char '\n'
  |> List.filter_map (fun raw_line ->
         let line = String.trim raw_line in
         match find_substring ~needle:"] " line with
         | None -> None
         | Some bracket_idx ->
             let after_idx = bracket_idx + 2 in
             if after_idx >= String.length line then
               None
             else
               let after =
                 String.sub line after_idx (String.length line - after_idx)
               in
               match find_substring ~needle:": " after with
               | None -> None
               | Some colon_idx ->
                   let task_id = String.sub after 0 colon_idx |> String.trim in
                   let title_idx = colon_idx + 2 in
                   let title =
                     String.sub after title_idx (String.length after - title_idx)
                     |> String.trim
                   in
                   if task_id = "" || title = "" then
                     None
                   else
                     Some { task_id; title })

type managed_task_binding = {
  task_id: string;
}

let prepare_managed_task ~sw masc spec =
  match spec.managed_task with
  | None -> Ok None
  | Some managed ->
      (match Agent_swarm_client.list_tasks ~sw masc with
      | Error e ->
          Error (Printf.sprintf "Task listing failed: %s" e)
      | Ok json ->
          (match rpc_first_text json with
          | None -> Error "Task listing returned no text payload"
          | Some text ->
              let tasks = parse_task_board text in
              (match
                 List.find_opt
                   (fun (task : listed_task) ->
                     contains_substring ~needle:managed.title_fragment task.title)
                   tasks
               with
              | None ->
                  Error
                    (Printf.sprintf "No task matched title fragment: %s"
                       managed.title_fragment)
              | Some task ->
                  (match Agent_swarm_client.claim ~sw masc ~task_id:task.task_id with
                  | Error e ->
                      Error
                        (Printf.sprintf "Task claim failed for %s: %s"
                           task.task_id e)
                  | Ok _ ->
                      (match
                         Agent_swarm_client.set_current_task ~sw masc
                           ~task_id:task.task_id
                       with
                      | Error e ->
                          Error
                            (Printf.sprintf
                               "Failed to bind current_task for %s: %s"
                               task.task_id e)
                      | Ok _ ->
                          (match Agent_swarm_client.heartbeat ~sw masc with
                          | Error e ->
                              Error
                                (Printf.sprintf
                                   "Heartbeat failed after binding task %s: %s"
                                   task.task_id e)
                          | Ok _ ->
                              ignore
                                (Agent_swarm_client.broadcast ~sw masc
                                   ~message:
                                     (Printf.sprintf "%s agent=%s task_id=%s"
                                        managed.claim_marker spec.name
                                        task.task_id));
                              Ok (Some { task_id = task.task_id })))))))

let finalize_managed_task ~sw masc spec binding =
  match spec.managed_task with
  | None -> Ok ()
  | Some managed -> (
      match Agent_swarm_client.heartbeat ~sw masc with
      | Error e ->
          Error
            (Printf.sprintf
               "Heartbeat failed before completing task %s: %s"
               binding.task_id e)
      | Ok _ -> (
          match Agent_swarm_client.done_task ~sw masc ~task_id:binding.task_id with
          | Error e ->
              Error
                (Printf.sprintf "Task completion failed for %s: %s"
                   binding.task_id e)
          | Ok _ ->
              ignore
                (Agent_swarm_client.broadcast ~sw masc
                   ~message:
                     (Printf.sprintf "%s agent=%s task_id=%s"
                        managed.done_marker spec.name binding.task_id));
              Ok ()))

(** Run a single agent: join MASC, run LLM loop, leave MASC.
    [extra_tools] are appended after MASC tools (e.g., dev_tools from Fleet). *)
let run_agent ~sw ~net ~clock ~masc_url ?(extra_tools=[]) spec ~goal =
  let masc =
    Agent_swarm_client.create_managed ~net ~base_url:masc_url
      ~agent_name:spec.name
  in
  match Agent_swarm_client.join ~sw masc with
  | Error e ->
    { agent_name = spec.name;
      result = Error (Printf.sprintf "MASC join failed: %s" e) }
  | Ok _ -> (
      match prepare_managed_task ~sw masc spec with
      | Error e ->
          (match Agent_swarm_client.leave ~sw masc with
           | Ok _ -> ()
           | Error warn ->
               Log.Swarm.warn "%s: MASC leave warning: %s" spec.name warn);
          { agent_name = spec.name; result = Error e }
      | Ok managed_task ->
          let result =
            Eio.Switch.run (fun inner_sw ->
              Eio.Fiber.fork_daemon ~sw:inner_sw (fun () ->
                let base_interval = 30.0 in
                let max_interval = 300.0 in
                let max_consecutive_failures = 10 in
                let rec loop consecutive_failures =
                  let interval =
                    if consecutive_failures = 0 then base_interval
                    else
                      Float.min max_interval
                        (base_interval *. (2.0 ** Float.of_int (min consecutive_failures 5)))
                  in
                  Eio.Time.sleep clock interval;
                  match Agent_swarm_client.heartbeat ~sw:inner_sw masc with
                  | Ok _ ->
                      if consecutive_failures > 0 then
                        Log.Swarm.info "%s: heartbeat recovered after %d failures"
                          spec.name consecutive_failures;
                      loop 0
                  | Error e ->
                      let failures = consecutive_failures + 1 in
                      Log.Swarm.error "%s: heartbeat error (%d/%d, next in %.0fs): %s"
                        spec.name failures max_consecutive_failures interval e;
                      if failures >= max_consecutive_failures then (
                        Log.Swarm.error "%s: heartbeat: %d consecutive failures, declaring dead"
                          spec.name failures;
                        `Stop_daemon)
                      else
                        loop failures
                in
                (try loop 0
                 with
                 | Eio.Cancel.Cancelled _ -> `Stop_daemon
                 | End_of_file -> `Stop_daemon)
              );
              let masc_tools =
                if spec.include_masc_tools then
                  Agent_swarm_tools.make_tools masc ~sw:inner_sw
                else
                  []
              in
              let all_tools = spec.tools @ masc_tools @ extra_tools in
              let config = {
                Types.default_config with
                name = spec.name;
                model = Types.Custom spec.provider.model_id;
                system_prompt = Some spec.system_prompt;
                max_tokens =
                  Option.value spec.max_tokens
                    ~default:Types.default_config.max_tokens;
                max_turns = spec.max_turns;
                temperature = spec.temperature;
              } in
              let agent =
                Agent.create ~net ~config ~tools:all_tools
                  ~options:{ Agent.default_options with
                             provider = Some spec.provider } ()
              in
              Agent.run ~sw:inner_sw agent goal
            )
          in
          let result =
            match result with
            | Ok response ->
                ensure_expected_final_marker response
                  ~expected_final_marker:spec.expected_final_marker
            | Error err -> Error (Agent_sdk__Error.to_string err)
          in
          let result =
            match result, managed_task with
            | Ok completion, Some binding -> (
                match finalize_managed_task ~sw masc spec binding with
                | Ok () -> Ok completion
                | Error e -> Error e)
            | _ -> result
          in
          (match result with
           | Ok completion -> (
               let marker =
                 match spec.expected_final_marker with
                 | Some expected when completion.model_final_marker_seen ->
                     Some expected
                 | Some expected when completion.final_marker_assisted ->
                     Some
                       (Printf.sprintf
                          "RUNTIME_ASSISTED_FINAL_MARKER expected=%s agent=%s"
                          expected spec.name)
                 | Some _ -> None
                 | None -> final_marker_line (extract_text completion.response)
               in
               match marker with
               | Some value ->
                   ignore
                     (Agent_swarm_client.broadcast ~sw masc
                        ~message:(Printf.sprintf "%s agent=%s" value spec.name))
               | None -> ())
           | Error _ -> ());
          (match Agent_swarm_client.leave ~sw masc with
           | Ok _ -> ()
           | Error e -> Log.Swarm.warn "%s: MASC leave warning: %s" spec.name e);
          { agent_name = spec.name; result })

(** Run all agents in parallel using Eio fibers.
    A heartbeat daemon fiber runs alongside the agents and sends keepalive pings
    to the MASC room every 30 seconds. The heartbeat fiber is automatically
    cancelled when all agent fibers complete (daemon fibers are cancelled
    when the Switch.run body returns).
    If the coordinator fails to join MASC, heartbeat and post-run
    broadcast/leave are skipped. *)
let run ~sw ~net ~clock config ~goal =
  let masc = Agent_swarm_client.create_managed ~net
    ~base_url:config.masc_url
    ~agent_name:"swarm-coordinator" in
  let coordinator_joined =
    match Agent_swarm_client.join ~sw masc with
    | Ok _ ->
      ignore (Agent_swarm_client.broadcast ~sw masc
        ~message:(Printf.sprintf "Fleet starting: %s" goal));
      true
    | Error e ->
      Log.Swarm.warn "MASC join warning: %s" e;
      false
  in
  let results =
    Eio.Switch.run (fun inner_sw ->
      (* Heartbeat fiber: only started if coordinator joined successfully. *)
      if coordinator_joined then
        Eio.Fiber.fork_daemon ~sw:inner_sw (fun () ->
          let rec loop () =
            Eio.Time.sleep clock 30.0;
            (match Agent_swarm_client.heartbeat ~sw:inner_sw masc with
             | Ok _ -> ()
             | Error e ->
               Log.Swarm.error "heartbeat error: %s" e);
            loop ()
          in
          (try loop ()
           with
           | Eio.Cancel.Cancelled _ -> `Stop_daemon
           | End_of_file -> `Stop_daemon)
        );
      (* Agent fibers: run all agents in parallel, then inner_sw exits and
         cancels the heartbeat fiber. *)
      Eio.Fiber.List.map (fun spec ->
        run_agent ~sw:inner_sw ~net ~clock ~masc_url:config.masc_url spec ~goal
      ) config.agents
    )
  in
  if coordinator_joined then begin
    (match Agent_swarm_client.broadcast ~sw masc ~message:"Fleet complete" with
     | Ok _ -> ()
     | Error e ->
       Log.Swarm.error "broadcast error: %s" e);
    (match Agent_swarm_client.leave ~sw masc with
     | Ok _ -> ()
     | Error e ->
       Log.Swarm.warn "MASC leave warning: %s" e)
  end;
  results
