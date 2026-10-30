(** Shared presence projections for the HTTP servers. *)

let last_seen_ms ~context (agent : Masc_domain.agent) =
  match Masc_domain.parse_iso8601_opt agent.last_seen with
  | Some seconds -> Int64.of_float (seconds *. 1000.0)
  | None ->
    Log.Server.warn
      "%s mapped invalid last_seen timestamp to 0 agent=%s value=%S"
      context
      agent.name
      agent.last_seen;
    0L
;;
