(** Active-guidance layer for operator digest.

    Resolves whether a fresh operator judgment exists for the given
    target and builds the guidance fields accordingly.  Falls back to
    deterministic recommendations when no judgment is available. *)

module U = Yojson.Safe.Util

let judgment_surface_for_target_type = function
  | "room" | "namespace" -> "command.namespace"
  | _ -> "command.namespace"

let judgment_target_type_of_string = function
  | "room" | "namespace" -> Operator_judgment.Room
  | _ -> Operator_judgment.Room

let fresh_operator_judgment config ~target_type ~target_id =
  let judgment_target_type = judgment_target_type_of_string target_type in
  let surface = judgment_surface_for_target_type target_type in
  match
    Operator_judgment.latest_active config ~surface
      ~target_type:judgment_target_type ~target_id
  with
  | Some value when Operator_judgment.is_fresh value ->
      Some (Operator_judgment.to_yojson value)
  | _ -> None

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

let active_guidance_fields ~config ~actor ~target_type ~target_id
    ~fallback_recommendations ~fallback_summary =
  let fallback_recommendation_json =
    `List
      (List.map (Operator_digest_types.recommended_action_to_yojson ~actor)
         fallback_recommendations)
  in
  match fresh_operator_judgment config ~target_type ~target_id with
  | Some judgment_json ->
      let judgment_actions =
        match judgment_json |> U.member "recommended_action" with
        | `Assoc _ as value -> `List [ value ]
        | _ -> fallback_recommendation_json
      in
      let recommendation_source =
        match judgment_json |> U.member "recommended_action" with
        | `Assoc _ -> "judgment"
        | _ -> "fallback"
      in
      [
        ("judgment_owner", `String "operator_keeper");
        ("authoritative_judgment_available", `Bool true);
        ("judgment", judgment_json);
        ("active_guidance_layer", `String "judgment");
        ("active_summary", judgment_summary_json judgment_json);
        ("active_recommended_actions", judgment_actions);
        ("active_recommendation_source", `String recommendation_source);
        ("active_recommendation_summary", judgment_summary_json judgment_json);
        ("fallback_recommended_actions", fallback_recommendation_json);
      ]
  | None ->
      [
        ("judgment_owner", `String "fallback_read_model");
        ("authoritative_judgment_available", `Bool false);
        ("judgment", `Null);
        ("active_guidance_layer", `String "fallback");
        ("active_summary", fallback_summary);
        ("active_recommended_actions", fallback_recommendation_json);
        ("active_recommendation_source", `String "fallback");
        ("active_recommendation_summary", fallback_summary);
        ("fallback_recommended_actions", fallback_recommendation_json);
      ]
