(** Current keeper metrics-ledger row identity.

    The discriminator is mandatory on both writers and readers. Rows without
    it belong to the retired versionless ledger contract and are not decoded. *)

type kind =
  | Turn
  | Heartbeat

let schema = "keeper.metrics.v1"

let kind_to_string = function
  | Turn -> "turn"
  | Heartbeat -> "heartbeat"

let fields kind =
  [ ("schema", `String schema)
  ; ("record_kind", `String (kind_to_string kind))
  ]

let kind_of_json json =
  match
    Json_util.assoc_member_opt "schema" json,
    Json_util.assoc_member_opt "record_kind" json
  with
  | Some (`String candidate_schema), Some (`String "turn")
    when String.equal candidate_schema schema ->
      Some Turn
  | Some (`String candidate_schema), Some (`String "heartbeat")
    when String.equal candidate_schema schema ->
      Some Heartbeat
  | _ -> None
