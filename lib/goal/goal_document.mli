(** Goal document values, codecs and schema rejection, without store effects. *)

type goal = {
  id : string;
  criterion_revision : string;
  title : string;
  metric : string option;
  target_value : string option;
  due_date : string option;
  priority : int;
  phase : Goal_phase.t;
  last_review_note : string option;
  last_review_at : string option;
  created_at : string;
  updated_at : string;
}

type criterion = Criterion of {
  revision : string;
  title : string;
  metric : string option;
  target_value : string option;
}

type event_kind = Created | Updated | Phase | Edited

type pending_event = {
  event_id : string;
  goal_id : string;
  store_revision : int;
  recorded_at : string;
  kind : event_kind;
  payload : Yojson.Safe.t;
}

type notification_delivery =
  | Awaiting_recipients
  | Pending_recipients of Keeper_id.Keeper_name.t list

type pending_notification = {
  notification_id : string;
  goal_id : string;
  sender : string;
  content : string;
  delivery : notification_delivery;
}

type state = {
  version : int;
  updated_at : string;
  goals : goal list;
  pending_events : pending_event list;
  pending_notifications : pending_notification list;
}

type schema_rejection = { field : string; detail : string }

val criterion_of_goal : goal -> criterion
val criterion_equal : criterion -> criterion -> bool
val criterion_to_yojson : criterion -> Yojson.Safe.t
val criterion_of_yojson : Yojson.Safe.t -> (criterion, string) result

val event_kind_to_string : event_kind -> string
val pending_event_to_yojson : pending_event -> Yojson.Safe.t
val goal_to_yojson : goal -> Yojson.Safe.t

val state_to_yojson : state -> Yojson.Safe.t
val state_of_yojson : Yojson.Safe.t -> (state, schema_rejection) result
(** Decode Goals, pending events and pending notifications in order, retaining
    the first rejected member and its detail. *)

val validate_state_json : Yojson.Safe.t -> (unit, string) result
(** Render the same schema rejection for the public setup validator. *)

val clamp_priority : int -> int
(** Shared normalization for decoded rows and store mutation preparation. *)
