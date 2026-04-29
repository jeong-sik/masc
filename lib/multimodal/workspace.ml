(* Workspace — Cycle 24-25 / Tier A7 first half.
   See workspace.mli for design rationale. *)

module Aid = Shared_types.Artifact_id

type t = {
  artifacts : (Aid.t * Artifact.any) list;
      (* keyed assoc; latest add replaces existing key *)
  dag : Multimodal_hydrator.provenance_dag;
}

let empty = { artifacts = []; dag = Multimodal_hydrator.empty_dag }

let add ws (artifact : Artifact.any) =
  let id = Artifact.any_id artifact in
  let without =
    List.filter (fun (k, _) -> not (Aid.equal k id)) ws.artifacts
  in
  { ws with artifacts = without @ [ (id, artifact) ] }

let has_id ws id =
  List.exists (fun (k, _) -> Aid.equal k id) ws.artifacts

let add_edge ws ~from_id ~to_id =
  if (not (has_id ws from_id)) || not (has_id ws to_id) then ws
  else
    {
      ws with
      dag = Multimodal_hydrator.add_edge ws.dag ~from_id ~to_id;
    }

let remove ws id =
  let filtered =
    List.filter (fun (k, _) -> not (Aid.equal k id)) ws.artifacts
  in
  { ws with artifacts = filtered }

let find_by_id ws id =
  List.find_map
    (fun (k, v) -> if Aid.equal k id then Some v else None)
    ws.artifacts

let all ws =
  List.sort
    (fun (a, _) (b, _) -> Aid.compare a b)
    ws.artifacts
  |> List.map snd

let size ws = List.length ws.artifacts

let list_by_kind_tag ws tag =
  List.filter_map
    (fun (_, any) ->
      let any_kind = Artifact.any_kind_of any in
      if Artifact.any_kind_to_tag any_kind = tag then Some any
      else None)
    ws.artifacts

let timeline ws =
  let with_ts =
    List.map
      (fun (_, any) ->
        let (Artifact.Any a) = any in
        (a.Artifact.provenance.Provenance_stub.created_at, any))
      ws.artifacts
  in
  List.sort (fun (a, _) (b, _) -> Float.compare a b) with_ts
  |> List.map snd

let search_metadata_key ws key =
  List.filter_map
    (fun (_, any) ->
      let (Artifact.Any a) = any in
      match a.Artifact.metadata with
      | `Assoc kv when List.mem_assoc key kv -> Some any
      | _ -> None)
    ws.artifacts

let provenance_dag ws = ws.dag

let origins_of ws id = Multimodal_hydrator.origins_of ws.dag id

let descendants_of ws id = Multimodal_hydrator.descendants_of ws.dag id

let to_json ws =
  `Assoc
    [
      ( "artifacts",
        `List (List.map (fun (_, any) -> Artifact.any_to_json any) ws.artifacts) );
      ("dag", Multimodal_hydrator.dag_to_json ws.dag);
    ]
