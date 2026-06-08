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

(** Build the JSON response for agent relations.
    Combines collaboration network + trust edges + generic relations. *)
let json ~agent_name () : Yojson.Safe.t =
  let collaborators =
    let variables = `Assoc [("name", `String agent_name)] in
    match Graphql_client.query ~query:collaborators_query ~variables () with
    | Ok data ->
      (match Json_util.assoc_member_opt "agentCollaborationNetworkByName" data with
       | Some (`List items) -> items
       | _ -> [])
      |> List.map (fun edge ->
        let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key edge) in
        `Assoc [
          ("name", m "name");
          ("collaborations", m "collaborations");
          ("last_collab", m "lastCollab");
        ])
    | Error _ -> []
  in
  let agent_data =
    let variables = `Assoc [("name", `String agent_name)] in
    match Graphql_client.query ~query:trusts_query ~variables () with
    | Ok data ->
      (match Json_util.assoc_member_opt "agent" data with
       | Some `Null | None -> None
       | Some agent -> Some agent)
    | Error _ -> None
  in
  let interests = match agent_data with
    | Some agent ->
      Safe_ops.protect ~default:[] (fun () ->
        match Json_util.assoc_member_opt "interests" agent with
        | Some (`List items) -> items
        | _ -> [])
    | None -> []
  in
  let relations = match agent_data with
    | Some agent ->
      Safe_ops.protect ~default:[] (fun () ->
        let edges = match Json_util.assoc_member_opt "relations" agent with
          | Some rel -> (match Json_util.assoc_member_opt "edges" rel with
            | Some (`List e) -> e
            | _ -> [])
          | None -> []
        in
        edges |> List.map (fun edge ->
          let node = match Json_util.assoc_member_opt "node" edge with
            | Some n -> n
            | None -> `Null
          in
          let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key node) in
          let participants =
            let p_edges = match Json_util.assoc_member_opt "participants" node with
              | Some part -> (match Json_util.assoc_member_opt "edges" part with
                | Some (`List e) -> e
                | _ -> [])
              | None -> []
            in
            p_edges |> List.map (fun p ->
              let pn = match Json_util.assoc_member_opt "node" p with
                | Some n -> n
                | None -> `Null
              in
              let pm key = Option.value ~default:`Null (Json_util.assoc_member_opt key pn) in
              `Assoc [
                ("kind", pm "kind");
                ("display_name", pm "displayName");
                ("role", pm "role");
              ])
          in
          `Assoc [
            ("type", m "type");
            ("category", m "category");
            ("confidence", m "confidence");
            ("note", m "note");
            ("participants", `List participants);
          ]))
    | None -> []
  in
  `Assoc [
    ("dashboard_surface", `String dashboard_surface);
    ("source", `String dashboard_source);
    ("retention", dashboard_retention_json);
    ("generated_at_iso", `String (Masc_domain.now_iso ()));
    ("agent_name", `String agent_name);
    ("collaborators", `List collaborators);
    ("interests", `List interests);
    ("relations", `List relations);
  ]
