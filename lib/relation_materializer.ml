(** Relation Materializer — automatically records agent relationships
    to Neo4j via GraphQL when MASC lifecycle events occur.

    All calls are fire-and-forget: failures are logged but never block
    the caller.  This ensures the main MASC event loop is not affected
    by GraphQL latency or downtime.

    @since 2.112.0
*)

(** {1 Internal helpers} *)

let log_ok tag msg =
  Printf.eprintf "[relation-materializer] %s: %s\n%!" tag msg

let log_err tag msg =
  Printf.eprintf "[relation-materializer] %s failed: %s\n%!" tag msg

(** Fire-and-forget GraphQL mutation.  Logs result, never raises. *)
let fire_mutation ~tag ~mutation ?(variables=`Null) () =
  match Graphql_client.mutate ~timeout_sec:5.0 ~mutation ~variables () with
  | Ok _data -> log_ok tag "ok"
  | Error msg -> log_err tag msg

(** {1 Collaboration — agent leave} *)

(** When an agent leaves a room, record [COLLABORATED_WITH] edges
    between the departing agent and every other active agent. *)
let on_agent_leave ~leaving_agent ~active_agents =
  let peers = List.filter (fun name -> name <> leaving_agent) active_agents in
  List.iter (fun peer ->
    let mutation = {|
      mutation($a1: String!, $a2: String!, $ctx: String!) {
        recordCollaborationByName(agent1Name: $a1, agent2Name: $a2, context: $ctx) {
          success message
        }
      }
    |} in
    let variables = `Assoc [
      ("a1", `String leaving_agent);
      ("a2", `String peer);
      ("ctx", `String (Printf.sprintf "co-present in MASC room at %s" (Types.now_iso ())));
    ] in
    fire_mutation ~tag:"collab" ~mutation ~variables ()
  ) peers

(** {1 Task completion} *)

(** When a task is completed, record collaboration between the
    assignee and all active agents in the room. *)
let on_task_done ~assignee ~active_agents =
  let peers = List.filter (fun name -> name <> assignee) active_agents in
  List.iter (fun peer ->
    let mutation = {|
      mutation($a1: String!, $a2: String!, $ctx: String!) {
        recordCollaborationByName(agent1Name: $a1, agent2Name: $a2, context: $ctx) {
          success message
        }
      }
    |} in
    let variables = `Assoc [
      ("a1", `String assignee);
      ("a2", `String peer);
      ("ctx", `String (Printf.sprintf "task collaboration at %s" (Types.now_iso ())));
    ] in
    fire_mutation ~tag:"task-collab" ~mutation ~variables ()
  ) peers
