(* Multimodal_keeper_bridge — Cycle 27 / Tier W3.
   See multimodal_keeper_bridge.mli for design rationale. *)

module A = Artifact

type raw_artifact = {
  id : string;
  kind_hint : string;
  payload_json : Yojson.Safe.t;
  metadata : Yojson.Safe.t;
}

let parse_kind_hint = function
  | "code" -> Some A.Tag_code
  | "image" -> Some A.Tag_image
  | "audio" -> Some A.Tag_audio
  | "doc" -> Some A.Tag_doc
  | _ -> None

let resolve_id raw =
  match Shared_types.Artifact_id.of_string raw.id with
  | Ok aid -> (aid, raw.metadata)
  | Error _ ->
      let fresh = Shared_types.Artifact_id.generate () in
      let extra =
        `Assoc
          [
            ("original_external_id", `String raw.id);
            ("regenerated_reason", `String "malformed external id");
          ]
      in
      let merged_metadata =
        match raw.metadata with
        | `Assoc kv -> `Assoc (kv @ [ ("hydration_note", extra) ])
        | other ->
            `Assoc
              [
                ("metadata_original", other);
                ("hydration_note", extra);
              ]
      in
      (fresh, merged_metadata)

let payload_of_json json =
  Payload.Lazy_payload (fun () -> Yojson.Safe.to_string json)

let make_provenance ~origin_artifact_ids ~created_by ~now =
  {
    Provenance_stub.origin_artifact_ids;
    created_by;
    created_at = now;
  }

let hydrate_one raw ~now ~created_by ~origin_artifact_ids =
  match parse_kind_hint raw.kind_hint with
  | None -> None
  | Some Tag_code ->
      let id, metadata = resolve_id raw in
      let art : A.code A.t =
        {
          id;
          kind = A.Code;
          payload = payload_of_json raw.payload_json;
          metadata;
          provenance =
            make_provenance ~origin_artifact_ids ~created_by ~now;
        }
      in
      Some (A.Any art)
  | Some Tag_image ->
      let id, metadata = resolve_id raw in
      let art : A.image A.t =
        {
          id;
          kind = A.Image;
          payload = payload_of_json raw.payload_json;
          metadata;
          provenance =
            make_provenance ~origin_artifact_ids ~created_by ~now;
        }
      in
      Some (A.Any art)
  | Some Tag_audio ->
      let id, metadata = resolve_id raw in
      let art : A.audio A.t =
        {
          id;
          kind = A.Audio;
          payload = payload_of_json raw.payload_json;
          metadata;
          provenance =
            make_provenance ~origin_artifact_ids ~created_by ~now;
        }
      in
      Some (A.Any art)
  | Some Tag_doc ->
      let id, metadata = resolve_id raw in
      let art : A.doc A.t =
        {
          id;
          kind = A.Doc;
          payload = payload_of_json raw.payload_json;
          metadata;
          provenance =
            make_provenance ~origin_artifact_ids ~created_by ~now;
        }
      in
      Some (A.Any art)

let hydrate_batch raws ~now ~created_by =
  List.filter_map
    (fun raw ->
      hydrate_one raw ~now ~created_by ~origin_artifact_ids:[])
    raws

let hydrate_with_workspace ws raws ~now ~created_by =
  let arts = hydrate_batch raws ~now ~created_by in
  let ws' = List.fold_left Workspace.add ws arts in
  (ws', arts)
