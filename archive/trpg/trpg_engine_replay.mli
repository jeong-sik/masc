val replay_events :
  rule:(module Trpg_rule.S) ->
  initial_state:Yojson.Safe.t ->
  events:Trpg_engine_event.t list ->
  Yojson.Safe.t

val derive_state :
  rule:(module Trpg_rule.S) ->
  config:Yojson.Safe.t ->
  events:Trpg_engine_event.t list ->
  Yojson.Safe.t
