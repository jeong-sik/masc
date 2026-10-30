module Client = Typesafeai_client
module Types = Typesafeai_types

type decision = Applicable | Not_applicable | Insufficient_context

let label = function
  | Applicable -> "applicable"
  | Not_applicable -> "not_applicable"
  | Insufficient_context -> "insufficient_context"
;;

let choices ~describe =
  Types.choice_set
    ~options:[ Applicable; Not_applicable; Insufficient_context ]
    ~label
    ~describe
;;

type outcome =
  | Failed of Client.failure
  | Invalid_answer of Client.evaluated * string
  | Judged of Client.evaluated * decision Types.decoded_choice

type t =
  | Skipped of Typesafeai_config.unavailable_reason
  | Context_unavailable
  | Question_unavailable of string
  | Evaluated of
      { reference : Skill_reference.t
      ; body_sha256 : string
      ; requested_models : string list
      ; outcome : outcome
      }

let assess ?clock ~keeper_id ~context ~reference ~body () =
  match Typesafeai_config.skill_applicability_destinations ~keeper_id with
  | Error reason -> Skipped reason
  | Ok ((first, rest) as armed) ->
    let question () =
      let open Result.Syntax in
      let* applicable = Prompt_registry.render_prompt_template Prompt_names.skill_applicability_applicable [] in
      let* not_applicable = Prompt_registry.render_prompt_template Prompt_names.skill_applicability_not_applicable [] in
      let* insufficient_context = Prompt_registry.render_prompt_template Prompt_names.skill_applicability_insufficient_context [] in
      let* choices = choices ~describe:(function
        | Applicable -> Some applicable
        | Not_applicable -> Some not_applicable
        | Insufficient_context -> Some insufficient_context) in
      let* instructions =
        Prompt_registry.render_prompt_template Prompt_names.skill_applicability []
      in
      Ok (choices, Types.choice_of_set choices ~instructions)
    in
    (match context with
     | None -> Context_unavailable
     | Some context ->
     match question () with
     | Error reason -> Question_unavailable reason
     | Ok (choices, question) ->
       let requested_models =
         List.map (fun (destination : Client.destination) -> destination.model) (first :: rest)
       in
       let body_sha256 = Agent_core_sha256.(digest_string body |> to_hex) in
       let state = `Assoc
         [ "keeper", `String keeper_id
         ; "turn_context", context
         ; "skill", `Assoc
             [ "reference", Skill_reference.to_yojson reference
             ; "body", `String body
             ; "sha256", `String body_sha256
             ]
         ] in
       let questions = [ "applicability", question ] in
       let observe fields =
         Log.Keeper.info ~keeper_name:keeper_id "skill_applicability %s"
           (Yojson.Safe.to_string (`Assoc
              ([ "reference", Skill_reference.to_yojson reference
               ; "body_sha256", `String body_sha256
               ; "requested_models", `List (List.map (fun model -> `String model) requested_models)
               ] @ fields)))
       in
       observe [ "status", `String "started" ];
       let outcome =
         match Client.evaluate ?clock ~destinations:armed ~state ~questions () with
         | Error failure -> Failed failure
         | Ok evaluated ->
           let decoded =
             match evaluated.response.answers with
             | [ id, answer ] when String.equal id "applicability" ->
               Types.decode_choice choices answer
             | _ ->
               Error "Skill applicability requires exactly one applicability answer"
           in
           (match decoded with
            | Ok judgment -> Judged (evaluated, judgment)
            | Error reason -> Invalid_answer (evaluated, reason))
       in
       (match outcome with
        | Failed _ -> observe [ "status", `String "failed" ]
        | Invalid_answer (evaluated, _) -> observe
            [ "status", `String "invalid_answer"; "model", `String evaluated.response.model
            ; "request_body_sha256", `String evaluated.request_body_sha256 ]
        | Judged (evaluated, judgment) -> observe
            [ "status", `String "judged"; "model", `String evaluated.response.model
            ; "request_body_sha256", `String evaluated.request_body_sha256
            ; "decision", `String (label judgment.choice)
            ; "reported_probability_sum", `Float judgment.reported_probability_sum
            ; "reported_probabilities", `Assoc (List.map
                (fun (choice, probability) -> label choice, `Float probability)
                judgment.reported_probabilities) ]);
       Evaluated { reference; body_sha256; requested_models; outcome })
;;

let evaluated_fields (evaluated : Client.evaluated) =
  [ "destination_uri", `String evaluated.destination.destination_uri
  ; "requested_model", `String evaluated.destination.model
  ; "passed_over", `List (List.map Client.attempt_to_yojson evaluated.passed_over)
  ; "model", `String evaluated.response.model
  ; "request_body_sha256", `String evaluated.request_body_sha256
  ]
;;

let to_yojson = function
  | Skipped reason -> `Assoc
      [ "status", `String "skipped"
      ; "reason", `String (Typesafeai_config.unavailable_reason_to_string reason) ]
  | Context_unavailable -> `Assoc
      [ "status", `String "unavailable"; "reason", `String "turn_context_unavailable" ]
  | Question_unavailable reason -> `Assoc
      [ "status", `String "unavailable"; "reason", `String reason ]
  | Evaluated { reference; body_sha256; requested_models; outcome } ->
    let fields = match outcome with
      | Failed failure ->
        [ "status", `String "failed"; "failure", Client.failure_to_yojson failure ]
      | Invalid_answer (evaluated, reason) ->
        [ "status", `String "invalid_answer"; "reason", `String reason
        ; "returned_answers", `Assoc (List.map
            (fun (id, answer) -> id, Types.answer_to_yojson answer) evaluated.response.answers)
        ] @ evaluated_fields evaluated
      | Judged (evaluated, judgment) ->
        [ "status", `String "judged"
        ; "decision", `String (label judgment.choice)
        ; "confidence", `Float judgment.confidence
        ; "reported_probability_sum", `Float judgment.reported_probability_sum
        ; "reported_probabilities", `Assoc (List.map
            (fun (choice, probability) -> label choice, `Float probability) judgment.reported_probabilities)
        ] @ evaluated_fields evaluated
    in
    `Assoc ([ "reference", Skill_reference.to_yojson reference
            ; "body_sha256", `String body_sha256
            ; "requested_models", `List (List.map (fun model -> `String model) requested_models)
            ] @ fields)
;;

let model_advice = function
  | Skipped _ | Context_unavailable | Question_unavailable _ -> Ok None
  | Evaluated { outcome; _ } ->
    let key, variables = match outcome with
      | Failed failure ->
        Prompt_names.skill_applicability_unavailable, ["reason", Client.failure_to_string failure]
      | Invalid_answer (_, reason) ->
        Prompt_names.skill_applicability_unavailable, ["reason", reason]
      | Judged (_, judgment) ->
        Prompt_names.skill_applicability_advice, ["decision", label judgment.choice]
    in
    Prompt_registry.render_prompt_template key variables |> Result.map (fun text -> Some (String.trim text))
;;
