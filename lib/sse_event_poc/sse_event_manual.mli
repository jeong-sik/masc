(** Hand-coded SSE event payload used by the byte-equality PoC. *)

type agent_started_payload =
  { agent_name : string
  ; task_id : string
  }

val agent_started_payload_to_yojson : agent_started_payload -> Yojson.Safe.t
val agent_started_payload_to_string : agent_started_payload -> string
