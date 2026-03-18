(** Relation Materializer — automatically records agent relationships
    to Neo4j via GraphQL when MASC lifecycle events occur.

    All calls run in a detached Eio fiber: failures are logged but never
    block the caller.  This ensures the main MASC event loop is not
    affected by GraphQL latency or downtime.

    @since 2.112.0
*)

(** {1 Internal helpers} *)

let log_err tag msg =
  Printf.eprintf "[relation-materializer] %s failed: %s\n%!" tag msg

let collab_mutation = {|
  mutation($a1: String!, $a2: String!, $ctx: String!) {
    recordCollaborationByName(agent1Name: $a1, agent2Name: $a2, context: $ctx) {
      success message
    }
  }
|}

(** Record collaboration for a single pair. Synchronous, logs errors. *)
let record_one ~tag ~context ~agent ~peer =
  let variables = `Assoc [
    ("a1", `String agent); ("a2", `String peer);
    ("ctx", `String context);
  ] in
  match Graphql_client.mutate ~timeout_sec:5.0 ~mutation:collab_mutation ~variables () with
  | Ok _ -> ()
  | Error msg -> log_err tag msg

(** Send collaboration mutations in a detached Eio fiber when possible.
    Each pair gets its own GraphQL call (the server does MERGE, so
    duplicates are safe). Returns immediately when Eio switch is available. *)
let record_collaborations_async ~tag ~context ~agent ~peers =
  match Eio_context.get_switch_opt () with
  | None ->
    (* No Eio runtime — synchronous best-effort *)
    List.iter (fun peer -> record_one ~tag ~context ~agent ~peer) peers
  | Some sw ->
    (* Detach into an Eio fiber — returns immediately *)
    Eio.Fiber.fork_daemon ~sw (fun () ->
      List.iter (fun peer -> record_one ~tag ~context ~agent ~peer) peers;
      `Stop_daemon
    )

(** {1 Collaboration — agent leave} *)

(** When an agent leaves a room, record [COLLABORATED_WITH] edges
    between the departing agent and every other active agent.
    Runs asynchronously — returns immediately. *)
let on_agent_leave ~leaving_agent ~active_agents =
  let peers = List.filter (fun name -> name <> leaving_agent) active_agents in
  if peers <> [] then
    record_collaborations_async
      ~tag:"collab"
      ~context:(Printf.sprintf "co-present in MASC room at %s" (Types.now_iso ()))
      ~agent:leaving_agent ~peers

(** {1 Task completion} *)

(** When a task is completed, record collaboration between the
    assignee and all active agents in the room.
    Skipped if the assignee already appeared in a recent leave event
    (since leave also records co-presence). *)
let on_task_done ~assignee ~active_agents =
  let peers = List.filter (fun name -> name <> assignee) active_agents in
  if peers <> [] then
    record_collaborations_async
      ~tag:"task-collab"
      ~context:(Printf.sprintf "task collaboration at %s" (Types.now_iso ()))
      ~agent:assignee ~peers
