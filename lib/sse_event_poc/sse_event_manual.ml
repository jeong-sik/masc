(* Phase A0.1 PoC — hand-coded variant of agent_started_payload.

   Sibling to atd-generated [Sse_event_t.agent_started_payload].
   Same shape, same field order, same JSON emit path (Yojson.Safe.to_string
   over an explicit `Assoc).  Used by the byte-equal probe in
   [test/test_sse_event_poc.ml] to compare against the atdgen output. *)

type agent_started_payload =
  { agent_name : string
  ; task_id : string
  }

let agent_started_payload_to_yojson (p : agent_started_payload) : Yojson.Safe.t =
  `Assoc
    [ "agent_name", `String p.agent_name
    ; "task_id", `String p.task_id
    ]
;;

let agent_started_payload_to_string (p : agent_started_payload) : string =
  Yojson.Safe.to_string (agent_started_payload_to_yojson p)
;;
