(** Active-guidance layer for operator digest.

    Resolves whether a fresh operator judgment exists for the given
    surface and builds the guidance fields accordingly.  Without one,
    exposes only the deterministic observation summary. *)

module U = Yojson.Safe.Util

type projection = {
  fields : (string * Yojson.Safe.t) list;
  recommended_actions : Yojson.Safe.t list;
  recommendation_summary : Yojson.Safe.t;
}

let fresh_operator_judgment config ~target_type ~target_id =
  match Operator_judgment.target_type_of_string target_type with
  | None -> None
  | Some target_type ->
    let latest =
      Operator_judgment.latest_active config ~surface:"command.namespace"
        ~target_type ~target_id
    in
    (match latest with
    | Some value when Operator_judgment.is_fresh value ->
        Some (Operator_judgment.to_yojson value)
    | _ -> None)

let judgment_summary_json judgment_json =
  `Assoc
    [
      ("summary", judgment_json |> U.member "summary");
      ("confidence", judgment_json |> U.member "confidence");
      ("provenance", `String "judgment");
      ("authoritative", `Bool true);
      ("surface", judgment_json |> U.member "surface");
      ("fresh_until", judgment_json |> U.member "fresh_until");
      ("keeper_name", judgment_json |> U.member "keeper_name");
      ("fallback_used", judgment_json |> U.member "fallback_used");
      ("disagreement_with_truth", judgment_json |> U.member "disagreement_with_truth");
    ]

let judgment_recommendation_summary_json actions =
  `Assoc
    [
      ("count", `Int (List.length actions));
      ( "top_action",
        match actions with
        | action :: _ -> action
        | [] -> `Null );
      ("provenance", `String "judgment");
      ("authoritative", `Bool true);
    ]

(* Judgment records retain the decision as written. The public action
   projection uses the operator vocabulary consumed by Mission and Briefing.
   Translate the existing judgment's workspace-pause spelling at this boundary;
   leave malformed objects intact so an observation cannot turn them into an
   apparent absence of recommendations. *)
let project_recommended_action = function
  | `Assoc fields as raw ->
      (match Json_util.reject_unknown_fields ~surface:"recommended action"
               ~allowed:(List.map fst fields) fields with
      | Error _ -> raw
      | Ok () ->
      match List.assoc_opt "action_type" fields, List.assoc_opt "action_kind" fields with
      | None, Some (`String "pause_workspace") ->
          let action = Operator_action_catalog.Namespace_pause in
          let fields = List.remove_assoc "action_kind" fields in
          let fields = List.remove_assoc "confirm_required" fields in
          let fields =
            match List.assoc_opt "suggested_payload" fields,
                  List.assoc_opt "payload_preview" fields with
            | None, Some (`Assoc _ as payload) -> ("suggested_payload", payload) :: fields
            | _ -> fields
          in
          `Assoc
            (("action_type", `String (Operator_action_catalog.to_string action))
             :: ("confirm_required", `Bool true)
             :: List.remove_assoc "payload_preview" fields)
      | _ -> raw)
  | raw -> raw

(* Only an operator judgment — an LLM's own recorded decision — may carry a
   recommended action. The read-model fallback used to synthesise one in
   OCaml (action_type="keeper_probe", reason="Inspect pending external
   attention") and hand it to the model as though a decision had been made;
   the summary below states the observed condition instead. *)
let active_guidance ~config ~target_type ~target_id ~fallback_observation_summary
    ~empty_recommendation_summary =
  match fresh_operator_judgment config ~target_type ~target_id with
  | Some judgment_json ->
      let recommended_actions =
        match Json_util.get_object judgment_json "recommended_action" with
        | Some value -> [ project_recommended_action value ]
        | None -> []
      in
      let recommendation_summary =
        judgment_recommendation_summary_json recommended_actions
      in
      {
        fields =
          [
            ("judgment_owner", `String "operator_keeper");
            ("authoritative_judgment_available", `Bool true);
            ("judgment", judgment_json);
            ("active_guidance_layer", `String "judgment");
            ("active_summary", judgment_summary_json judgment_json);
            ("active_recommended_actions", `List recommended_actions);
            ("active_recommendation_summary", recommendation_summary);
          ];
        recommended_actions;
        recommendation_summary;
      }
  | None ->
      {
        fields =
          [
            ("judgment_owner", `String "fallback_read_model");
            ("authoritative_judgment_available", `Bool false);
            ("judgment", `Null);
            ("active_guidance_layer", `String "fallback");
            ("active_summary", fallback_observation_summary);
            ("active_recommended_actions", `List []);
            ("active_recommendation_summary", empty_recommendation_summary);
          ];
        recommended_actions = [];
        recommendation_summary = empty_recommendation_summary;
      }
