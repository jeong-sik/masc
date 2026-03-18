val replay_events :
  rule:(module Rule.S) ->
  initial_state:Yojson.Safe.t ->
  events:Engine_event.t list ->
  Yojson.Safe.t

val derive_state :
  rule:(module Rule.S) ->
  config:Yojson.Safe.t ->
  events:Engine_event.t list ->
  Yojson.Safe.t
