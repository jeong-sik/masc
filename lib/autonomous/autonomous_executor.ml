(* Autonomous_executor — Cycle 27 / Tier W1.
   See autonomous_executor.mli for design rationale. *)

module A = Multimodal.Artifact
module P = Multimodal.Payload
module Pv = Multimodal.Provenance_stub
module W = Multimodal.Workspace

type tool_call = {
  name : string;
  args : Yojson.Safe.t;
}

let prefix_of name =
  match String.index_opt name '_' with
  | Some i -> Some (String.sub name 0 i)
  | None -> Some name

let classify_tool name =
  match prefix_of name with
  | Some "code" -> Some A.Tag_code
  | Some "image" -> Some A.Tag_image
  | Some "audio" -> Some A.Tag_audio
  | Some "doc" -> Some A.Tag_doc
  | _ -> None

let payload_of_args args =
  let lazy_text () = Yojson.Safe.to_string args in
  P.Lazy_payload lazy_text

let metadata_of_call name args =
  `Assoc
    [
      ("tool_name", `String name);
      ("args", args);
    ]

let provenance_for ~now ~created_by =
  {
    Pv.origin_artifact_ids = [];
    created_by;
    created_at = now;
  }

let translate tc ~now ~created_by =
  match classify_tool tc.name with
  | None -> None
  | Some Tag_code ->
      let id = Shared_types.Artifact_id.generate () in
      let art : A.code A.t =
        {
          id;
          kind = A.Code;
          payload = payload_of_args tc.args;
          metadata = metadata_of_call tc.name tc.args;
          provenance = provenance_for ~now ~created_by;
        }
      in
      Some (A.Any art)
  | Some Tag_image ->
      let id = Shared_types.Artifact_id.generate () in
      let art : A.image A.t =
        {
          id;
          kind = A.Image;
          payload = payload_of_args tc.args;
          metadata = metadata_of_call tc.name tc.args;
          provenance = provenance_for ~now ~created_by;
        }
      in
      Some (A.Any art)
  | Some Tag_audio ->
      let id = Shared_types.Artifact_id.generate () in
      let art : A.audio A.t =
        {
          id;
          kind = A.Audio;
          payload = payload_of_args tc.args;
          metadata = metadata_of_call tc.name tc.args;
          provenance = provenance_for ~now ~created_by;
        }
      in
      Some (A.Any art)
  | Some Tag_doc ->
      let id = Shared_types.Artifact_id.generate () in
      let art : A.doc A.t =
        {
          id;
          kind = A.Doc;
          payload = payload_of_args tc.args;
          metadata = metadata_of_call tc.name tc.args;
          provenance = provenance_for ~now ~created_by;
        }
      in
      Some (A.Any art)

let accumulate ws calls ~now ~created_by =
  List.fold_left
    (fun (ws_acc, arts_acc) tc ->
      match translate tc ~now ~created_by with
      | None -> (ws_acc, arts_acc)
      | Some any ->
          let ws_acc' = W.add ws_acc any in
          (ws_acc', any :: arts_acc))
    (ws, []) calls
  |> fun (ws_final, arts_rev) -> (ws_final, List.rev arts_rev)
