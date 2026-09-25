(** Runtime configuration request decoding for the dashboard routes.

    Parse incoming JSON into the closed operations the HTTP handlers execute.
    Lane names are checked against the current Runtime registry, but this
    module does not write configuration or send HTTP responses. *)

type runtime_route_lane =
  | Runtime_default
  | Runtime_media_failover
  | Runtime_named_lane of string
  | Runtime_exact_lane of Runtime.exact_lane

type runtime_route_body =
  | Runtime_route_runtime_id of runtime_route_lane * string option
  | Runtime_route_runtime_ids of runtime_route_lane * string list
  | Runtime_route_lane_created of string * string list
  | Runtime_route_lane_removed of string
  | Runtime_route_lane_renamed of string * string
  | Runtime_route_exact_slot_appended of Runtime.exact_lane * string
  | Runtime_route_exact_slot_dropped of Runtime.exact_lane * string
  | Runtime_route_exact_slot_moved of
      Runtime.exact_lane * string * Runtime.exact_slot_move

val runtime_route_lane_to_string : runtime_route_lane -> string

val parse_runtime_route_body :
  string -> (runtime_route_body, string) result
(** Decode a routing write. Error text is returned to the HTTP caller. *)

val parse_runtime_assignment_body :
  string ->
  (string * string option * Runtime.keeper_assignment_revision, string) result
(** Decode a Keeper assignment write and its expected revision. *)
