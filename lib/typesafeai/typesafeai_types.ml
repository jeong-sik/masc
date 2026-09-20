type model =
  | Jev_latest
  | Jev_preview
  | Custom of string

let model_to_string = function
  | Jev_latest -> "jev-latest"
  | Jev_preview -> "jev-preview"
  | Custom s -> s
;;

let model_of_string = function
  | "jev-latest" -> Jev_latest
  | "jev-preview" -> Jev_preview
  | s -> Custom s
;;

type choice_question =
  { instructions : string
  ; criteria : (string * string option) list
  }

type score_question =
  { instructions : string
  ; criteria : string list
  }

type noul_question =
  { instructions : string
  ; criteria : (string * string) option
  }

type question =
  | Choice of choice_question
  | Score of score_question
  | Noul of noul_question

type choice_answer =
  { choice : string
  ; probabilities : (string * float) list
  ; confidence : float
  }

type score_answer =
  { score : float
  ; probabilities : (int * float) list
  ; confidence : float
  }

type noul_answer =
  { noul : float
  }

type answer =
  | Choice_answer of choice_answer
  | Score_answer of score_answer
  | Noul_answer of noul_answer

type usage =
  { input_tokens : int
  ; output_tokens : int
  }

type eval_response =
  { model : string
  ; answers : (string * answer) list
  ; usage : usage option
  }

let ( let* ) = Result.bind

let question_to_yojson = function
  | Choice { instructions; criteria } ->
    let criteria_assoc =
      List.map
        (fun (opt, desc) ->
          let v =
            match desc with
            | None -> `Null
            | Some d -> `String d
          in
          opt, v)
        criteria
    in
    `Assoc
      [ "type", `String "choice"
      ; "instructions", `String instructions
      ; "criteria", `Assoc criteria_assoc
      ]
  | Score { instructions; criteria } ->
    let criteria_list = List.map (fun level -> `String level) criteria in
    `Assoc
      [ "type", `String "score"
      ; "instructions", `String instructions
      ; "criteria", `List criteria_list
      ]
  | Noul { instructions; criteria } ->
    let fields =
      [ "type", `String "noul"
      ; "instructions", `String instructions
      ]
    in
    let fields =
      match criteria with
      | None -> fields
      | Some (t_meaning, f_meaning) ->
        fields @ [ "criteria", `Assoc [ "true", `String t_meaning; "false", `String f_meaning ] ]
    in
    `Assoc fields
;;

let request_to_yojson ~model ~state ~questions =
  let questions_assoc =
    List.map (fun (id, q) -> id, question_to_yojson q) questions
  in
  `Assoc
    [ "model", `String model
    ; "state", state
    ; "questions", `Assoc questions_assoc
    ]
;;

let parse_probabilities probabilities =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | (key, `Float value) :: rest -> loop ((key, value) :: acc) rest
    | (key, `Int value) :: rest -> loop ((key, float_of_int value) :: acc) rest
    | (key, _) :: _ ->
      Error (Printf.sprintf "typesafeai: probability for %S must be a number" key)
  in
  match probabilities with
  | [] -> Error "typesafeai: 'probabilities' map is empty"
  | _ :: _ -> loop [] probabilities
;;

let answer_to_yojson = function
  | Noul_answer { noul } ->
    `Assoc [ "type", `String "noul"; "noul", `Float noul ]
  | Choice_answer { choice; probabilities; confidence } ->
    `Assoc
      [ "type", `String "choice"; "choice", `String choice
      ; "probabilities", `Assoc (List.map (fun (id, p) -> id, `Float p) probabilities)
      ; "confidence", `Float confidence ]
  | Score_answer { score; probabilities; confidence } ->
    `Assoc
      [ "type", `String "score"; "score", `Float score
      ; "probabilities", `Assoc
          (List.map (fun (level, p) -> string_of_int level, `Float p) probabilities)
      ; "confidence", `Float confidence ]
;;

let answer_of_yojson json =
  match json with
  | `Assoc fields ->
    (match List.assoc_opt "type" fields with
     | Some (`String "noul") ->
       (match List.assoc_opt "noul" fields with
        | Some (`Float n) -> Ok (Noul_answer { noul = n })
        | Some (`Int i) -> Ok (Noul_answer { noul = float_of_int i })
        | _ -> Error "typesafeai: noul answer missing numeric 'noul' field")
     | Some (`String "choice") ->
       let* choice =
         match List.assoc_opt "choice" fields with
         | Some (`String s) -> Ok s
         | _ -> Error "typesafeai: choice answer missing 'choice' field"
       in
       let* confidence =
         match List.assoc_opt "confidence" fields with
         | Some (`Float f) -> Ok f
         | Some (`Int i) -> Ok (float_of_int i)
         | _ -> Error "typesafeai: choice answer missing numeric 'confidence' field"
       in
       let* probabilities =
         match List.assoc_opt "probabilities" fields with
         | Some (`Assoc probs) -> parse_probabilities probs
         | _ -> Error "typesafeai: choice answer missing 'probabilities' map"
       in
       Ok (Choice_answer { choice; probabilities; confidence })
     | Some (`String "score") ->
       let* score =
         match List.assoc_opt "score" fields with
         | Some (`Float f) -> Ok f
         | Some (`Int i) -> Ok (float_of_int i)
         | _ -> Error "typesafeai: score answer missing numeric 'score' field"
       in
       let* confidence =
         match List.assoc_opt "confidence" fields with
         | Some (`Float f) -> Ok f
         | Some (`Int i) -> Ok (float_of_int i)
         | _ -> Error "typesafeai: score answer missing numeric 'confidence' field"
       in
       let* probabilities =
         match List.assoc_opt "probabilities" fields with
         | Some (`Assoc probs) ->
           let* probabilities = parse_probabilities probs in
           let rec parse_levels acc = function
             | [] -> Ok (List.rev acc)
             | (key, probability) :: rest ->
               (match int_of_string_opt key with
                | Some level when level >= 0 ->
                  parse_levels ((level, probability) :: acc) rest
                | _ ->
                  Error
                    (Printf.sprintf
                       "typesafeai: score level %S must be a non-negative integer" key))
           in
           parse_levels [] probabilities
         | _ -> Error "typesafeai: score answer missing 'probabilities' map"
       in
       Ok (Score_answer { score; probabilities; confidence })
     | Some (`String other) ->
       Error (Printf.sprintf "typesafeai: unknown answer type %S" other)
     | _ -> Error "typesafeai: answer missing 'type' field")
  | _ -> Error "typesafeai: answer must be a JSON object"
;;

let usage_of_yojson = function
  | `Assoc fields ->
    let input_tokens =
      match List.assoc_opt "input_tokens" fields with
      | Some (`Int i) -> i
      | _ -> 0
    in
    let output_tokens =
      match List.assoc_opt "output_tokens" fields with
      | Some (`Int i) -> i
      | _ -> 0
    in
    Some { input_tokens; output_tokens }
  | _ -> None
;;

let eval_response_of_yojson json =
  match json with
  | `Assoc fields ->
    let* model =
      match List.assoc_opt "model" fields with
      | Some (`String m) -> Ok m
      | _ -> Error "typesafeai: response missing 'model' string"
    in
    let* answers =
      match List.assoc_opt "answers" fields with
      | Some (`Assoc ans_list) ->
        let rec parse_answers acc = function
          | [] -> Ok (List.rev acc)
          | (id, ans_json) :: rest ->
            let* ans = answer_of_yojson ans_json in
            parse_answers ((id, ans) :: acc) rest
        in
        parse_answers [] ans_list
      | _ -> Error "typesafeai: response missing 'answers' map"
    in
    let usage =
      match List.assoc_opt "usage" fields with
      | Some u -> usage_of_yojson u
      | None -> None
    in
    Ok { model; answers; usage }
  | _ -> Error "typesafeai: response must be a JSON object"
;;

type 'option choice_set =
  { options : 'option list
  ; label : 'option -> string
  ; describe : 'option -> string option
  }

let choice_set ~options ~label ~describe =
  let labels = List.map label options in
  match options with
  | [] -> Error "typesafeai: a choice question needs at least one option"
  | _ :: _ ->
    if List.length (List.sort_uniq String.compare labels) = List.length labels
    then Ok { options; label; describe }
    else
      Error
        (Printf.sprintf
           "typesafeai: choice options share a label: %s"
           (String.concat ", " labels))
;;

let choice_of_set ~instructions set =
  Choice
    { instructions
    ; criteria = List.map (fun option -> set.label option, set.describe option) set.options
    }
;;

type 'option decoded_choice =
  { choice : 'option
  ; probabilities : ('option * float) list
  ; confidence : float
  }

let option_of_label set label =
  match List.find_opt (fun option -> String.equal (set.label option) label) set.options with
  | Some option -> Ok option
  | None -> Error (Printf.sprintf "typesafeai: %S is not one of the question's options" label)
;;

let decode_choice set = function
  | Choice_answer { choice; probabilities; confidence } ->
    let* choice = option_of_label set choice in
    let rec decode_probabilities acc = function
      | [] -> Ok (List.rev acc)
      | (label, probability) :: rest ->
        let* option = option_of_label set label in
        decode_probabilities ((option, probability) :: acc) rest
    in
    let* probabilities = decode_probabilities [] probabilities in
    Ok ({ choice; probabilities; confidence } : _ decoded_choice)
  | Score_answer _ -> Error "typesafeai: expected a choice answer, got a score answer"
  | Noul_answer _ -> Error "typesafeai: expected a choice answer, got a noul answer"
;;
