(** Dashboard Agent Relations — proxy to GraphQL for agent relationship data.

    Fetches COLLABORATED_WITH network and TRUSTS edges for an agent from
    the Second Brain GraphQL server and returns them as dashboard JSON.

    @since 2.113.0
*)

let collaborators_query = {|
  query($name: String!) {
    agentCollaborationNetworkByName(name: $name) {
      hash name collaborations lastCollab
    }
  }
|}

let trusts_query = {|
  query($name: String!) {
    agent(name: $name) {
      name
      interests
      relations(first: 20, visibility: "public") {
        edges { node {
          relationId type category confidence note
          participants(first: 5) {
            edges { node { kind displayName role agentUuid personUid } }
          }
        } }
      }
    }
  }
|}

let dashboard_surface = "/api/v1/agent-relations"
let dashboard_source = "second_brain_graphql"

let dashboard_retention_json =
  `Assoc
    [
      ("scope", `String "external_graphql_query");
      ("durable_store", `String "Second Brain GraphQL");
      ( "queries",
        `List
          [
            `String "agentCollaborationNetworkByName";
            `String "agent.relations";
          ] );
    ]

type read_error =
  { source : string
  ; message : string
  }

let read_error ~source ~message = { source; message }

let read_error_json err =
  `Assoc [ "source", `String err.source; "message", `String err.message ]

let collaborator_json edge =
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key edge) in
  `Assoc
    [ "name", m "name"
    ; "collaborations", m "collaborations"
    ; "last_collab", m "lastCollab"
    ]
;;

let collaborators_of_query_result = function
  | Error message ->
    ( []
    , false
    , [ read_error ~source:"agentCollaborationNetworkByName" ~message ] )
  | Ok data ->
    (match Json_util.assoc_member_opt "agentCollaborationNetworkByName" data with
     | Some (`List items) -> List.map collaborator_json items, true, []
     | Some _ | None ->
       ( []
       , false
       , [ read_error
             ~source:"agentCollaborationNetworkByName"
             ~message:"missing or non-list field"
         ] ))
;;

let agent_of_query_result = function
  | Error message ->
    None, false, [ read_error ~source:"agent.relations" ~message ]
  | Ok data ->
    (match Json_util.assoc_member_opt "agent" data with
     | Some `Null -> None, true, []
     | Some agent -> Some agent, true, []
     | None ->
       ( None
       , false
       , [ read_error ~source:"agent.relations" ~message:"missing agent field" ]
       ))
;;

let interests_of_agent ~agent_known agent =
  if not agent_known
  then [], false, []
  else (
    match agent with
    | None -> [], true, []
    | Some agent ->
      (match Json_util.assoc_member_opt "interests" agent with
       | Some (`List items) -> items, true, []
       | Some _ | None ->
         ( []
         , false
         , [ read_error ~source:"agent.interests" ~message:"missing or non-list field"
           ] )))
;;

let relation_participants node =
  match Json_util.assoc_member_opt "participants" node with
  | Some part ->
    (match Json_util.assoc_member_opt "edges" part with
     | Some (`List p_edges) ->
       p_edges
       |> List.map (fun p ->
         let pn =
           match Json_util.assoc_member_opt "node" p with
           | Some n -> n
           | None -> `Null
         in
         let pm key =
           Option.value ~default:`Null (Json_util.assoc_member_opt key pn)
         in
         `Assoc
           [ "kind", pm "kind"
           ; "display_name", pm "displayName"
           ; "role", pm "role"
           ])
     | _ -> [])
  | None -> []
;;

let relation_json edge =
  let node =
    match Json_util.assoc_member_opt "node" edge with
    | Some n -> n
    | None -> `Null
  in
  let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key node) in
  `Assoc
    [ "type", m "type"
    ; "category", m "category"
    ; "confidence", m "confidence"
    ; "note", m "note"
    ; "participants", `List (relation_participants node)
    ]
;;

let relations_of_agent ~agent_known agent =
  if not agent_known
  then [], false, []
  else (
    match agent with
    | None -> [], true, []
    | Some agent ->
      (match Json_util.assoc_member_opt "relations" agent with
       | Some rel ->
         (match Json_util.assoc_member_opt "edges" rel with
          | Some (`List edges) -> List.map relation_json edges, true, []
          | _ ->
            ( []
            , false
            , [ read_error ~source:"agent.relations" ~message:"missing or non-list edges"
              ] ))
       | None ->
         ( []
         , false
         , [ read_error ~source:"agent.relations" ~message:"missing relations field"
           ] )))
;;

let json_from_query_results
    ~agent_name
    ~generated_at_iso
    ~collaborators_result
    ~agent_result
  =
  let collaborators, collaborators_known, collaborator_errors =
    collaborators_of_query_result collaborators_result
  in
  let agent_data, agent_known, agent_errors = agent_of_query_result agent_result in
  let interests, interests_known, interest_errors =
    interests_of_agent ~agent_known agent_data
  in
  let relations, relations_known, relation_errors =
    relations_of_agent ~agent_known agent_data
  in
  let read_errors =
    collaborator_errors @ agent_errors @ interest_errors @ relation_errors
  in
  `Assoc
    [ "dashboard_surface", `String dashboard_surface
    ; "source", `String dashboard_source
    ; "retention", dashboard_retention_json
    ; "generated_at_iso", `String generated_at_iso
    ; "agent_name", `String agent_name
    ; "collaborators_known", `Bool collaborators_known
    ; "interests_known", `Bool interests_known
    ; "relations_known", `Bool relations_known
    ; "read_errors", `List (List.map read_error_json read_errors)
    ; "collaborators", `List collaborators
    ; "interests", `List interests
    ; "relations", `List relations
    ]
;;

(** Build the JSON response for agent relations.
    Combines collaboration network + trust edges + generic relations. *)
let json ~agent_name () : Yojson.Safe.t =
  let variables = `Assoc [ "name", `String agent_name ] in
  json_from_query_results
    ~agent_name
    ~generated_at_iso:(Masc_domain.now_iso ())
    ~collaborators_result:(Graphql_client.query ~query:collaborators_query ~variables ())
    ~agent_result:(Graphql_client.query ~query:trusts_query ~variables ())
;;

module For_testing = struct
  let json_from_query_results = json_from_query_results
end
