(** Dashboard Agent Relations — agent relationship view.
    Second Brain GraphQL integration has been retired; returns deterministic empty relation view.
*)

let dashboard_surface = "/api/v1/agent-relations"
let dashboard_source = "local"

let dashboard_retention_json =
  `Assoc
    [
      ("scope", `String "retired_graphql_query");
      ("durable_store", `String "none");
      ("queries", `List []);
    ]

(** Build the JSON response for agent relations without blocking on retired GraphQL. *)
let json ~agent_name () : Yojson.Safe.t =
  `Assoc [
    ("dashboard_surface", `String dashboard_surface);
    ("source", `String dashboard_source);
    ("retention", dashboard_retention_json);
    ("generated_at_iso", `String (Masc_domain.now_iso ()));
    ("agent_name", `String agent_name);
    ("collaborators", `List []);
    ("interests", `List []);
    ("relations", `List []);
  ]
