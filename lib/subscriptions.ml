(** Resource Subscriptions - MCP 2025-11-25 Spec Compliance

    Implements resource change notifications and subscriptions.
    Clients can subscribe to resources (tasks, agents, etc.) and
    receive updates via SSE.

    MCP Spec MAY: Resource subscriptions for change notifications
*)

(** Subscription types *)
type resource_type =
  | Tasks
  | Agents
  | Messages
  | Votes
  | Custom of string

let resource_type_to_string = function
  | Tasks -> "tasks"
  | Agents -> "agents"
  | Messages -> "messages"
  | Votes -> "votes"
  | Custom s -> s

let resource_type_of_string = function
  | "tasks" -> Tasks
  | "agents" -> Agents
  | "messages" -> Messages
  | "votes" -> Votes
  | s -> Custom s

(** Change type *)
type change_type =
  | Created
  | Updated
  | Deleted

let change_type_to_string = function
  | Created -> "created"
  | Updated -> "updated"
  | Deleted -> "deleted"

(** Subscription record *)
type subscription = {
  id: string;
  subscriber: string;  (* agent_name or session_id *)
  resource: resource_type;
  filter: string option;  (* Optional filter, e.g., task_id *)
  created_at: float;
}

(** Change notification *)
type notification = {
  subscription_id: string;
  resource: resource_type;
  change: change_type;
  resource_id: string;
  data: Yojson.Safe.t;
  timestamp: float;
}

(** Subscription store *)
module SubscriptionStore = struct
  module StringMap = Map.Make (String)

  type state =
    { subscriptions : subscription StringMap.t
    ; pending_notifications : notification list StringMap.t
    }

  let state =
    Atomic.make
      { subscriptions = StringMap.empty
      ; pending_notifications = StringMap.empty
      }

  (** Generate subscription ID *)
  let generate_id () : string =
    Random_id.prefixed ~prefix:"sub_" ~bytes:8

  (** Subscribe to resource changes *)
  let subscribe ~(subscriber : string) ~(resource : resource_type) ?(filter : string option) () : subscription =
    let sub = {
      id = generate_id ();
      subscriber;
      resource;
      filter;
      created_at = Time_compat.now ();
    } in
    Atomic_util.update state (fun current ->
      { current with
        subscriptions = StringMap.add sub.id sub current.subscriptions
      });
    Log.Sub.info "%s subscribed to %s" subscriber (resource_type_to_string resource);
    sub

  (** Unsubscribe *)
  let unsubscribe (id : string) : bool =
    Lockfree_atomic.update_with_result state (fun current ->
      if StringMap.mem id current.subscriptions
      then
        ( { subscriptions = StringMap.remove id current.subscriptions
          ; pending_notifications =
              StringMap.remove id current.pending_notifications
          }
        , true )
      else current, false)

  (** Get subscription by ID *)
  let get (id : string) : subscription option =
    StringMap.find_opt id (Atomic.get state).subscriptions

  (** Find subscriptions for a resource change *)
  let find_matching ~(resource : resource_type) ~(resource_id : string) : subscription list =
    StringMap.fold
      (fun _ (sub : subscription) (acc : subscription list) ->
        if sub.resource = resource
        then
          match sub.filter with
          | None -> sub :: acc
          | Some f when f = resource_id -> sub :: acc
          | Some f when f = "*" -> sub :: acc
          | _ -> acc
        else acc)
      (Atomic.get state).subscriptions
      []

  (** Queue notification for a subscription - O(1) with Queue *)
  let queue_notification (sub_id : string) (notif : notification) : unit =
    Atomic_util.update state (fun current ->
      let pending =
        Option.value
          (StringMap.find_opt sub_id current.pending_notifications)
          ~default:[]
      in
      { current with
        pending_notifications =
          StringMap.add sub_id (notif :: pending) current.pending_notifications
      })

  (** Pop notifications for a subscription - returns all pending as list *)
  let pop_notifications (sub_id : string) : notification list =
    Lockfree_atomic.update_with_result state (fun current ->
      match StringMap.find_opt sub_id current.pending_notifications with
      | Some notifications ->
        ( { current with
            pending_notifications =
              StringMap.remove sub_id current.pending_notifications
          }
        , List.rev notifications )
      | None -> current, [])

end

(** Session registry bridge for notification harness.
    When set, notify_change also pushes events to all active agent sessions
    so agents can poll notifications without SSE subscription. *)
let session_registry : (Yojson.Safe.t -> int) option Atomic.t = Atomic.make None

(** One-shot gate for the "registry not wired" message below. Keeps the
    log from flooding when callers on a hot path (Task.Tool,
    mcp_tool_runtime_comm) invoke push_event_to_sessions before
    bootstrap wires the bridge — or in test harnesses that never wire
    it at all. *)
let unwired_warned = Atomic.make false

let set_session_push_fn (fn : Yojson.Safe.t -> int) =
  (match Atomic.exchange session_registry (Some fn) with
   | Some _ -> Log.Sub.warn "WARNING: session push fn already set, overwriting"
   | None -> ());
  (* Reset the one-shot gate so a future explicit unwire would warn again. *)
  Atomic.set unwired_warned false

(** Push a structured event to all active agent sessions.
    Used by modules (e.g. Task.Tool) that lack direct Session.registry access. *)
let push_event_to_sessions (event : Yojson.Safe.t) : unit =
  match Atomic.get session_registry with
  | Some push_fn ->
      (try let _ = push_fn event in ()
       with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Sub.error "push_event failed: %s" (Printexc.to_string exn))
  | None ->
      if Atomic.compare_and_set unwired_warned false true then
        Log.Sub.info
          "push_event_to_sessions: registry not wired \
           (further calls silenced until set_session_push_fn runs)"

(** Notify all subscribers of a resource change *)
let notify_change ~(resource : resource_type) ~(change : change_type)
    ~(resource_id : string) ~(data : Yojson.Safe.t) : int =
  let subs = SubscriptionStore.find_matching ~resource ~resource_id in
  let now = Time_compat.now () in
  List.iter (fun sub ->
    let notif = {
      subscription_id = sub.id;
      resource;
      change;
      resource_id;
      data;
      timestamp = now;
    } in
    SubscriptionStore.queue_notification sub.id notif
  ) subs;
  (* Bridge: also push to session queues for notification harness *)
  (match Atomic.get session_registry with
   | Some push_fn ->
       let event = `Assoc [
         ("type", `String "masc/notification");
         ("resource", `String (resource_type_to_string resource));
         ("change", `String (change_type_to_string change));
         ("resource_id", `String resource_id);
         ("data", data);
         ("timestamp", `Float now);
       ] in
       (try let _ = push_fn event in ()
        with Eio.Cancel.Cancelled _ as e -> raise e | exn -> Log.Sub.error "push_sub_event failed: %s" (Printexc.to_string exn))
   | None -> ());
  List.length subs

(** Subscription to JSON *)
let subscription_to_json (s : subscription) : Yojson.Safe.t =
  `Assoc [
    ("id", `String s.id);
    ("subscriber", `String s.subscriber);
    ("resource", `String (resource_type_to_string s.resource));
    ("filter", Json_util.string_opt_to_json s.filter);
    ("created_at", `Float s.created_at);
  ]

(** Notification to JSON *)
let notification_to_json (n : notification) : Yojson.Safe.t =
  `Assoc [
    ("subscription_id", `String n.subscription_id);
    ("resource", `String (resource_type_to_string n.resource));
    ("change", `String (change_type_to_string n.change));
    ("resource_id", `String n.resource_id);
    ("data", n.data);
    ("timestamp", `Float n.timestamp);
  ]

(** Hook function to notify task changes - call from Workspace module *)
let notify_task_change ~(change : change_type) ~(task_id : string) ~(data : Yojson.Safe.t) : unit =
  let _ = notify_change ~resource:Tasks ~change ~resource_id:task_id ~data in
  ()

(** Hook function to notify agent changes *)
let notify_agent_change ~(change : change_type) ~(agent_name : string) ~(data : Yojson.Safe.t) : unit =
  let _ = notify_change ~resource:Agents ~change ~resource_id:agent_name ~data in
  ()

(** Hook function to notify message changes *)
let notify_message ~(message_id : string) ~(data : Yojson.Safe.t) : unit =
  let _ = notify_change ~resource:Messages ~change:Created ~resource_id:message_id ~data in
  ()
