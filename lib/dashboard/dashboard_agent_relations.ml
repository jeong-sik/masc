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
    match Graphql_client.query ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Graphql ()) ~query:collaborators_query ~variables () with
    | Ok data ->
      let m key = Option.value ~default:`Null (Json_util.assoc_member_opt key data) in
      (match m "agentCollaborationNetworkByName" with
       | `List items ->
         items |> List.map (fun edge ->
           let em key = Option.value ~default:`Null (Json_util.assoc_member_opt key edge) in
           `Assoc [
             ("name", em "name");
             ("collaborations", em "collaborations");
             ("last_collab", em "lastCollab");
           ])
       | _ -> [])
    | Error _ -> []
  in
  let agent_data =
    let variables = `Assoc [("name", `String agent_name)] in
    match Graphql_client.query ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Graphql ()) ~query:trusts_query ~variables () with
    | Ok data ->
      let agent = Option.value ~default:`Null (Json_util.assoc_member_opt "agent" data) in
      if agent = `Null then None
      else Some agent
    | Error _ -> None
  in
  let interests = match agent_data with
    | Some agent ->
      Safe_ops.protect ~default:[] (fun () ->
        match Option.value ~default:`Null (Json_util.assoc_member_opt "interests" agent) with
        | `List items -> items
        | _ -> [])
    | None -> []
  in
  let relations = match agent_data with
    | Some agent ->
      Safe_ops.protect ~default:[] (fun () ->
        let am key = Option.value ~default:`Null (Json_util.assoc_member_opt key agent) in
        match am "relations" with
        | `Assoc _ ->
          let edges = (match Option.value ~default:`Null (Json_util.assoc_member_opt "edges" (am "relations")) with `List xs -> xs | _ -> []) in
          edges |> List.map (fun edge ->
            let em key = Option.value ~default:`Null (Json_util.assoc_member_opt key edge) in
            let node = em "node" in
            let nm key = Option.value ~default:`Null (Json_util.assoc_member_opt key node) in
            let participants =
              let participant_edges = (match nm "participants" with `Assoc _ -> (match Option.value ~default:`Null (Json_util.assoc_member_opt "edges" (nm "participants")) with `List xs -> xs | _ -> []) | _ -> []) in
              participant_edges |> List.map (fun p ->
                let pn = Option.value ~default:`Null (Json_util.assoc_member_opt "node" p) in
                let pm key = Option.value ~default:`Null (Json_util.assoc_member_opt key pn) in
                `Assoc [
                  ("kind", pm "kind");
                  ("display_name", pm "displayName");
                  ("role", pm "role");
                ])
          in
          `Assoc [
            ("type", nm "type");
            ("category", nm "category");
            ("confidence", nm "confidence");
            ("note", nm "note");
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
