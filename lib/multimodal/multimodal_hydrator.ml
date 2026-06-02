(* Multimodal_hydrator — Cycle 24 / Tier B9.
   See multimodal_hydrator.mli for design rationale. *)

module Aid = Shared_types.Artifact_id

type edge = Aid.t * Aid.t

type provenance_dag = { edges : edge list }

let empty_dag = { edges = [] }

let edge_eq (a1, b1) (a2, b2) = Aid.equal a1 a2 && Aid.equal b1 b2

let add_edge dag ~from_id ~to_id =
  let candidate = (from_id, to_id) in
  if List.exists (edge_eq candidate) dag.edges then dag
  else { edges = dag.edges @ [ candidate ] }

let edges dag = dag.edges

let origins_of dag id =
  List.filter_map
    (fun (from_id, to_id) ->
      if Aid.equal to_id id then Some from_id else None)
    dag.edges

let descendants_of dag id =
  List.filter_map
    (fun (from_id, to_id) ->
      if Aid.equal from_id id then Some to_id else None)
    dag.edges

let dag_to_json dag =
  `Assoc
    [
      ( "edges",
        `List
          (List.map
             (fun (from_id, to_id) ->
               `Assoc
                 [
                   ("from", Aid.to_json from_id);
                   ("to", Aid.to_json to_id);
                 ])
             dag.edges) );
    ]

let dag_of_json = function
  | `Assoc kv -> (
      match List.assoc_opt "edges" kv with
      | Some (`List xs) ->
          let rec loop acc = function
            | [] -> Ok { edges = List.rev acc }
            | `Assoc kv :: rest -> (
                match
                  ( List.assoc_opt "from" kv,
                    List.assoc_opt "to" kv )
                with
                | Some j_from, Some j_to -> (
                    match (Aid.of_json j_from, Aid.of_json j_to) with
                    | Ok from_id, Ok to_id ->
                        loop ((from_id, to_id) :: acc) rest
                    | Error e, _ | _, Error e -> Error e)
                | _ ->
                    Error
                      "edge entry must contain 'from' and 'to' fields")
            | _ -> Error "each edge must be a JSON object"
          in
          loop [] xs
      | None -> Ok { edges = [] }
      | _ -> Error "'edges' field must be a JSON list")
  | _ -> Error "provenance_dag must be a JSON object"

(* ── Hydrate ──────────────────────────────────────────────────── *)

type hydrated = {
  artifact : Artifact.any;
  origins : Aid.t list;
  descendants : Aid.t list;
}

let hydrate ~fetch_artifact ~dag ~ids =
  List.filter_map
    (fun id ->
      match fetch_artifact id with
      | None -> None
      | Some artifact ->
          Some
            {
              artifact;
              origins = origins_of dag id;
              descendants = descendants_of dag id;
            })
    ids
