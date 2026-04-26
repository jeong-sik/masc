(** Resource Subscriptions - MCP 2025-11-25 Spec Compliance *)

(** {1 Types} *)

type resource_type =
  | Tasks
  | Agents
  | Messages
  | Votes
  | Custom of string

val resource_type_to_string : resource_type -> string
val resource_type_of_string : string -> resource_type

type change_type =
  | Created
  | Updated
  | Deleted

val change_type_to_string : change_type -> string

type subscription =
  { id : string
  ; subscriber : string
  ; resource : resource_type
  ; filter : string option
  ; created_at : float
  }

type notification =
  { subscription_id : string
  ; resource : resource_type
  ; change : change_type
  ; resource_id : string
  ; data : Yojson.Safe.t
  ; timestamp : float
  }

(** {1 Subscription Store} *)

module SubscriptionStore : sig
  val subscribe
    :  subscriber:string
    -> resource:resource_type
    -> ?filter:string
    -> unit
    -> subscription

  val unsubscribe : string -> bool
  val get : string -> subscription option
  val find_matching : resource:resource_type -> resource_id:string -> subscription list
  val get_for_subscriber : string -> subscription list
  val queue_notification : string -> notification -> unit
  val pop_notifications : string -> notification list
  val list_all : unit -> subscription list
  val count : unit -> int
end

(** {1 Session Push Bridge} *)

val set_session_push_fn : (Yojson.Safe.t -> int) -> unit
val push_event_to_sessions : Yojson.Safe.t -> unit

(** {1 Change Notifications} *)

val notify_change
  :  resource:resource_type
  -> change:change_type
  -> resource_id:string
  -> data:Yojson.Safe.t
  -> int

val notify_task_change
  :  change:change_type
  -> task_id:string
  -> data:Yojson.Safe.t
  -> unit

val notify_agent_change
  :  change:change_type
  -> agent_name:string
  -> data:Yojson.Safe.t
  -> unit

val notify_message : message_id:string -> data:Yojson.Safe.t -> unit

(** {1 Serialization} *)

val subscription_to_json : subscription -> Yojson.Safe.t
val notification_to_json : notification -> Yojson.Safe.t

(** {1 Tool Handler} *)

val handle_subscription_tool : Yojson.Safe.t -> bool * string
