(** Relation Materializer — automatically records agent relationships
    to Neo4j via GraphQL when MASC lifecycle events occur.

    Uses GraphQL alias batching to send ALL collaboration pairs in a
    single HTTP request.  Runs in a detached Eio fiber so the caller
    is never blocked.

    @since 2.112.0
*)

(** {1 Internal helpers} *)

let log_err tag msg = Log.Misc.error "relation-materializer %s failed: %s" tag msg

(** Build a single batched GraphQL mutation using aliases.
    20 peers → 1 HTTP request with 20 aliased fields.

    Example output:
    {[
      mutation {
        c0: recordCollaborationByName(agent1Name: "a", agent2Name: "b", context: "ctx") { success }
        c1: recordCollaborationByName(agent1Name: "a", agent2Name: "c", context: "ctx") { success }
      }
    ]}
*)
let build_batch_mutation ~agent ~peers ~context =
  let escape s =
    (* Minimal escape for GraphQL string literals *)
    let parts = String.split_on_char '"' s in
    String.concat "\\\"" parts
  in
  let fields =
    List.mapi
      (fun i peer ->
         Printf.sprintf
           "c%d: recordCollaborationByName(agent1Name: \"%s\", agent2Name: \"%s\", \
            context: \"%s\") { success }"
           i
           (escape agent)
           (escape peer)
           (escape context))
      peers
  in
  "mutation { " ^ String.concat " " fields ^ " }"
;;

(** Send all collaboration pairs in one batched HTTP request.
    Detaches to an Eio fiber when runtime is available. *)
let record_collaborations_async ~tag ~context ~agent ~peers =
  let do_batch () =
    let mutation = build_batch_mutation ~agent ~peers ~context in
    match Graphql_client.mutate ~timeout_sec:10.0 ~mutation () with
    | Ok _ -> ()
    | Error msg -> log_err tag msg
  in
  match Eio_context.get_switch_opt () with
  | None ->
    (* No Eio runtime — synchronous best-effort *)
    do_batch ()
  | Some sw ->
    (* Detach into an Eio fiber — returns immediately *)
    Eio.Fiber.fork_daemon ~sw (fun () ->
      do_batch ();
      `Stop_daemon)
;;

(** {1 Collaboration — agent leave} *)

(** When an agent leaves a room, record [COLLABORATED_WITH] edges
    between the departing agent and every other active agent.
    Runs asynchronously — returns immediately.
    20 peers = 1 HTTP request (alias batching). *)
let on_agent_leave ~leaving_agent ~active_agents =
  let peers = List.filter (fun name -> name <> leaving_agent) active_agents in
  if peers <> []
  then
    record_collaborations_async
      ~tag:"collab"
      ~context:(Printf.sprintf "co-present in MASC room at %s" (Types.now_iso ()))
      ~agent:leaving_agent
      ~peers
;;

(** {1 Task completion} *)

(** When a task is completed, record collaboration between the
    assignee and all active agents in the room.
    20 peers = 1 HTTP request (alias batching). *)
let on_task_done ~assignee ~active_agents =
  let peers = List.filter (fun name -> name <> assignee) active_agents in
  if peers <> []
  then
    record_collaborations_async
      ~tag:"task-collab"
      ~context:(Printf.sprintf "task collaboration at %s" (Types.now_iso ()))
      ~agent:assignee
      ~peers
;;
