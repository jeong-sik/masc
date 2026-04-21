open Dashboard_http_helpers

type digest_result =
  | Posted of string
  | Deduped
  | Skipped
  | Failed of string

let digest_hearth = Meta_cognition.digest_hearth
let digest_author = "meta-cognition-observer"
let digest_source = Meta_cognition.digest_source

let summary_json snapshot =
  json_assoc_field "summary" (json_assoc_field "meta_cognition" snapshot)

let focus_source snapshot =
  json_string_field_opt "source" (json_assoc_field "focus" snapshot)

let parse_snapshot_summary snapshot =
  Meta_cognition.parse_summary (summary_json snapshot)

let should_emit snapshot =
  match parse_snapshot_summary snapshot with
  | Ok summary ->
      let interpretation = Meta_cognition.interpret summary in
      interpretation.primary_salience <> Meta_cognition.Stable
  | Error err ->
      Log.Dashboard.debug "meta-cognition digest parse skipped in should_emit: %s" err;
      false

let post_digest_key = Meta_cognition.post_digest_key

let digest_posts_with_keys () =
  Board_dispatch.list_posts ~hearth:digest_hearth
    ~post_kind_filter:Board.Automation_post ~sort_by:Board_dispatch.Recent
    ~limit:20 ()
  |> List.filter_map (fun post ->
         Option.map (fun digest_key -> (post, digest_key)) (post_digest_key post))

let latest_digest_post () =
  match digest_posts_with_keys () with
  | head :: _ -> Some head
  | [] -> None

let already_posted digest_key =
  digest_posts_with_keys ()
  |> List.exists (fun (_post, existing) -> String.equal existing digest_key)

let title_of_interpretation (summary : Meta_cognition.summary_input)
    (interpretation : Meta_cognition.interpretation) =
  match interpretation.primary_salience with
  | Meta_cognition.Contested_belief ->
      "[meta-cognition] contested belief requires follow-up"
  | Meta_cognition.Operator_tension ->
      "[meta-cognition] operator-facing room tension detected"
  | Meta_cognition.Operator_desire ->
      "[meta-cognition] room is asking for operator action"
  | Meta_cognition.Stagnant_room ->
      Printf.sprintf "[meta-cognition] room stagnation elevated (%.0f%%)"
        (summary.stagnation_score *. 100.0)
  | Meta_cognition.Stable ->
      "[meta-cognition] room state updated"

let salience_line salience =
  Meta_cognition.salience_to_string salience
  |> String.map (function '_' -> ' ' | c -> c)

let body_of_snapshot snapshot (summary : Meta_cognition.summary_input)
    (interpretation : Meta_cognition.interpretation) =
  let focus = json_assoc_field "focus" snapshot in
  let dominant_belief =
    summary.Meta_cognition.dominant_belief
  in
  let top_tension = summary.Meta_cognition.top_tension in
  let top_desire = summary.Meta_cognition.top_desire in
  let evidence_refs = String.concat ", " interpretation.evidence_refs in
  let lines =
    [
      Some "project snapshot promoted a meta-cognition signal into shared attention.";
      json_string_field_opt "reason" focus;
      Some
        (Printf.sprintf "primary signal: %s"
           (salience_line interpretation.primary_salience));
      (match interpretation.secondary_saliences with
       | [] -> None
       | secondary ->
           Some
             (Printf.sprintf "secondary signals: %s"
                (secondary
                |> List.map salience_line
                |> String.concat ", ")));
      Some (Printf.sprintf "derived reason: %s" interpretation.reason);
      Some
        (Printf.sprintf "stagnation: %.0f%%" (summary.stagnation_score *. 100.0));
      Some
        (Printf.sprintf "contested beliefs: %d"
           summary.contested_belief_count);
      Option.map
        (fun claim ->
          let status =
            Option.bind dominant_belief (fun belief -> belief.status)
            |> Option.value ~default:"unknown"
          in
          Printf.sprintf "dominant belief: %s [%s]" claim status)
        (Option.bind dominant_belief (fun belief -> belief.claim));
      Option.map
        (fun topic ->
          let severity =
            Option.bind top_tension (fun tension -> tension.severity)
            |> Option.value ~default:"unknown"
          in
          Printf.sprintf "top tension: %s [%s]" topic severity)
        (Option.bind top_tension (fun tension -> tension.topic));
      Option.map
        (fun desired_state ->
          let actionability =
            Option.bind top_desire (fun desire -> desire.actionability)
            |> Option.value ~default:"unspecified"
          in
          Printf.sprintf "top desire: %s [%s]" desired_state actionability)
        (Option.bind top_desire (fun desire -> desire.desired_state));
      (if evidence_refs = "" then None
       else Some (Printf.sprintf "room evidence refs: %s" evidence_refs));
    ]
  in
  lines
  |> List.filter_map Fun.id
  |> List.map String.trim
  |> List.filter (fun line -> line <> "")
  |> String.concat "\n"

let meta_json_of_snapshot snapshot (summary : Meta_cognition.summary_input)
    (interpretation : Meta_cognition.interpretation) digest_key =
  let dominant_belief = summary.Meta_cognition.dominant_belief in
  let top_tension = summary.Meta_cognition.top_tension in
  let top_desire = summary.Meta_cognition.top_desire in
  `Assoc
    [
      ("source", `String digest_source);
      ("digest_key", `String digest_key);
      ( "primary_salience",
        `String
          (Meta_cognition.salience_to_string interpretation.primary_salience) );
      ( "secondary_saliences",
        `List
          (List.map
             (fun salience ->
               `String (Meta_cognition.salience_to_string salience))
             interpretation.secondary_saliences) );
      ( "focus_source",
        match focus_source snapshot with
        | Some value -> `String value
        | None -> `Null );
      ( "dominant_belief_id",
        match Option.bind dominant_belief (fun belief -> belief.id) with
        | Some value -> `String value
        | None -> `Null );
      ( "top_tension_id",
        match Option.bind top_tension (fun tension -> tension.id) with
        | Some value -> `String value
        | None -> `Null );
      ( "top_desire_id",
        match Option.bind top_desire (fun desire -> desire.id) with
        | Some value -> `String value
        | None -> `Null );
      ("contested_belief_count", `Int summary.contested_belief_count);
      ("stagnation_score", `Float summary.stagnation_score);
    ]

let latest_digest_json ?summary () =
  let parsed_summary =
    match summary with
    | Some json -> (
        match Meta_cognition.parse_summary json with
        | Ok parsed -> Some parsed
        | Error err ->
            Log.Dashboard.debug
              "meta-cognition latest digest summary parse skipped: %s" err;
            None)
    | None -> None
  in
  Meta_cognition.latest_digest_json ?summary:parsed_summary ()

let maybe_post_digest ~config:_ snapshot =
  if not (should_emit snapshot) then
    Skipped
  else
    match parse_snapshot_summary snapshot with
    | Error err ->
        Log.Dashboard.warn "meta-cognition digest skipped due to parse failure: %s" err;
        Skipped
    | Ok summary ->
        let interpretation = Meta_cognition.interpret summary in
        let digest_key = Meta_cognition.summary_signature summary in
        if already_posted digest_key then
          Deduped
        else
          let title = title_of_interpretation summary interpretation in
          let body = body_of_snapshot snapshot summary interpretation in
          let meta_json =
            Some
              (meta_json_of_snapshot snapshot summary interpretation digest_key)
          in
          match
            Board_dispatch.create_post ~author:digest_author ~title ~body
              ~content:body ~post_kind:Board.Automation_post ?meta_json
              ~visibility:Board.Internal ~ttl_hours:24 ~hearth:digest_hearth ()
          with
          | Ok post ->
              let post_id = Board.Post_id.to_string post.id in
              Log.Dashboard.info "meta-cognition digest posted: %s" post_id;
              Posted post_id
          | Error err ->
              let message = Board.show_board_error err in
              Log.Dashboard.warn "meta-cognition digest post failed: %s" message;
              Failed message
