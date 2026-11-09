(** Activity_graph_types — type definitions and JSON serde for activity graph. *)

(** Closed activity kinds whose payload describes one executed tool. Producers
    and timeline readers share this type rather than maintaining
    independent string lists. *)
type tool_execution_event_kind =
  | External_tool_called
  | Keeper_in_turn_tool_executed

val tool_execution_event_kind_to_string : tool_execution_event_kind -> string
val all_tool_execution_event_kinds : tool_execution_event_kind list

(** {1 Graph entities} *)

type entity_ref = {
  kind : string;
  id : string;
}

type event = {
  seq : int;
  ts_ms : int;
  ts_iso : string;
  kind : string;
  actor : entity_ref option;
  subject : entity_ref option;
  payload : Yojson.Safe.t;
  tags : string list;
}

(** {1 Constructors} *)

val entity : kind:string -> string -> entity_ref

(** {1 JSON serde}

    [_to_yojson] always succeeds; [_of_yojson] returns [None] on any
    missing required field. *)

val event_to_yojson : event -> Yojson.Safe.t

val event_of_yojson : Yojson.Safe.t -> event option

(** {1 Utilities} *)

(** Current wall-clock time in milliseconds (via [Time_compat.now]). *)
val now_ts_ms : unit -> int
