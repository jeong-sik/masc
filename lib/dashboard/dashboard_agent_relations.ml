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

(** Build the JSON response for agent relations.
    Combines collaboration network + trust edges + generic relations. *)
let json ~agent_name () : Yojson.Safe.t =
  let collaborators =
    let variables = `Assoc [("name", `String agent_name)] in
    match Graphql_client.query ~timeout_sec:8.0 ~query:collaborators_query ~variables () with
    | Ok data ->
      let open Yojson.Safe.Util in
      data |> member "agentCollaborationNetworkByName" |> to_list
      |> List.map (fun edge ->
        `Assoc [
          ("name", member "name" edge);
          ("collaborations", member "collaborations" edge);
          ("last_collab", member "lastCollab" edge);
        ])
    | Error _ -> []
  in
  let agent_data =
    let variables = `Assoc [("name", `String agent_name)] in
    match Graphql_client.query ~timeout_sec:8.0 ~query:trusts_query ~variables () with
    | Ok data ->
      let open Yojson.Safe.Util in
      let agent = data |> member "agent" in
      if agent = `Null then None
      else Some agent
    | Error _ -> None
  in
  let interests = match agent_data with
    | Some agent ->
      let open Yojson.Safe.Util in
      Safe_ops.protect ~default:[] (fun () ->
        agent |> member "interests" |> to_list)
    | None -> []
  in
  let relations = match agent_data with
    | Some agent ->
      let open Yojson.Safe.Util in
      Safe_ops.protect ~default:[] (fun () ->
        agent |> member "relations" |> member "edges" |> to_list
        |> List.map (fun edge ->
          let node = edge |> member "node" in
          let participants =
            node |> member "participants" |> member "edges" |> to_list
            |> List.map (fun p ->
              let pn = p |> member "node" in
              `Assoc [
                ("kind", member "kind" pn);
                ("display_name", member "displayName" pn);
                ("role", member "role" pn);
              ])
          in
          `Assoc [
            ("type", member "type" node);
            ("category", member "category" node);
            ("confidence", member "confidence" node);
            ("note", member "note" node);
            ("participants", `List participants);
          ]))
    | None -> []
  in
  `Assoc [
    ("agent_name", `String agent_name);
    ("collaborators", `List collaborators);
    ("interests", `List interests);
    ("relations", `List relations);
  ]
