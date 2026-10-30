(** Tool_local_runtime_systemone — typed client for Ollama's
    [/v1/systemone] structured-decision endpoint: up to 64 choice, noul
    (probability-of-true) or score questions about one shared state text,
    answered with probabilities. Served by the local Ollama or Ollama Cloud.

    The answers' [confidence] is the distribution's concentration
    (1 - H(p) / ln N), not a calibrated correctness probability. Callers use
    this to rank and screen; a justified verdict still reads the material.

    Wire facts measured against Ollama Cloud (2026-10-19, clef:cloud): the
    request is refused unless every question carries [instructions]; noul's
    true/false descriptions live under a [criteria] object, not beside it;
    [output_tokens] comes back zero — cloud decisions charge input only. *)

let ( let* ) = Result.bind

let max_questions = 64
let question_name_max_chars = 100
let choice_criteria_min = 2
let choice_criteria_max = 255
let score_scale_min = 2
let score_scale_max = 10
let timeout_sec_min = 1
let timeout_sec_max = 120
let default_timeout_sec = 60

type backend =
  | Local
  | Cloud

let backend_of_string = function
  | "local" -> Some Local
  | "cloud" -> Some Cloud
  | _ -> None

let backend_id = function
  | Local -> "local"
  | Cloud -> "cloud"

let local_url =
  Masc_network_defaults.ollama_default_url ^ Masc_network_defaults.ollama_systemone_path

(* Ollama Cloud serves the same path under https://ollama.com and bills the
   caller's usage credits per input token. *)
let cloud_url = "https://ollama.com" ^ Masc_network_defaults.ollama_systemone_path

let default_model = function
  | Local -> "nimble"
  | Cloud -> "clef:cloud"

(* The same env credential the [providers.ollama_cloud] declaration in
   runtime.toml reads. *)
let cloud_key_env = "OLLAMA_CLOUD_API_KEY"

type question =
  | Choice of
      { instructions : string
      ; criteria : (string * string option) list
      }
  | Noul of
      { instructions : string
      ; true_description : string option
      ; false_description : string option
      }
  | Score of
      { instructions : string
      ; scale : string list
      }

type request =
  { model : string
  ; state : string
  ; questions : (string * question) list
  }

type answer =
  | Choice_answer of
      { choice : string
      ; probabilities : (string * float) list
      ; confidence : float
      }
  | Noul_answer of float
  | Score_answer of
      { score : float
      ; legend : string list
      ; probabilities : float list
      ; confidence : float
      }

let valid_question_name name =
  name <> ""
  && String.length name <= question_name_max_chars
  && String.for_all
       (fun c ->
          (c >= 'A' && c <= 'Z')
          || (c >= 'a' && c <= 'z')
          || (c >= '0' && c <= '9')
          || c = '_' || c = '.' || c = '-')
       name
;;

let nonblank ~field value =
  if String.length (String.trim value) = 0 then Error (field ^ " must not be blank")
  else Ok value
;;

let validate_question_name name =
  if valid_question_name name then Ok ()
  else
    Error
      (Printf.sprintf
         "question name %S must be 1-%d chars of ASCII letters, digits, _, . or -"
         name question_name_max_chars)
;;

let validate_question (name, question) =
  let instructions = nonblank ~field:(name ^ ".instructions") in
  match question with
  | Choice { instructions = text; criteria } ->
      let* text = instructions text in
      let count = List.length criteria in
      if count < choice_criteria_min || count > choice_criteria_max then
        Error
          (Printf.sprintf "%s: choice needs %d-%d criteria, got %d" name
             choice_criteria_min choice_criteria_max count)
      else if List.exists (fun (option, _) -> option = "") criteria then
        Error (name ^ ": choice criteria keys must not be blank")
      else Ok (Choice { instructions = text; criteria })
  | Noul { instructions = text; true_description; false_description } ->
      let* text = instructions text in
      Ok (Noul { instructions = text; true_description; false_description })
  | Score { instructions = text; scale } ->
      let* text = instructions text in
      let count = List.length scale in
      if count < score_scale_min || count > score_scale_max then
        Error
          (Printf.sprintf "%s: score needs %d-%d rubric entries, got %d" name
             score_scale_min score_scale_max count)
      else if List.exists (fun entry -> entry = "") scale then
        Error (name ^ ": score rubric entries must not be blank")
      else Ok (Score { instructions = text; scale })
;;

let validate_request (request : request) : (unit, string) result =
  let* state = nonblank ~field:"state" request.state in
  let count = List.length request.questions in
  if count = 0 || count > max_questions then
    Error (Printf.sprintf "questions must number 1-%d, got %d" max_questions count)
  else
    let names = List.map fst request.questions in
    let* () =
      List.fold_left
        (fun acc name ->
          let* () = acc in
          let* () = validate_question_name name in
          if List.length (List.filter (String.equal name) names) > 1 then
            Error (Printf.sprintf "question name %S appears more than once" name)
          else Ok ())
        (Ok ()) names
    in
    let* () =
      List.fold_left
        (fun acc entry ->
          let* () = acc in
          let* question = validate_question entry in
          ignore question;
          Ok ())
        (Ok ()) request.questions
    in
    ignore state;
    Ok ()
;;

(* ── Encode ─────────────────────────────────────────────── *)

let option_to_yojson = function
  | Some text -> `String text
  | None -> `Null

let question_to_yojson question =
  match question with
  | Choice { instructions; criteria } ->
      `Assoc
        [ ("type", `String "choice")
        ; ("instructions", `String instructions)
        ; ( "criteria"
          , `Assoc
              (List.map
                 (fun (option, description) -> (option, option_to_yojson description))
                 criteria) )
        ]
  | Noul { instructions; true_description; false_description } ->
      `Assoc
        [ ("type", `String "noul")
        ; ("instructions", `String instructions)
        ; ( "criteria"
          , `Assoc
              [ ("true", option_to_yojson true_description)
              ; ("false", option_to_yojson false_description)
              ] )
        ]
  | Score { instructions; scale } ->
      `Assoc
        [ ("type", `String "score")
        ; ("instructions", `String instructions)
        ; ("criteria", `List (List.map (fun entry -> `String entry) scale))
        ]
;;

let request_to_yojson (request : request) : Yojson.Safe.t =
  `Assoc
    [ ("model", `String request.model)
    ; ("state", `String request.state)
    ; ( "questions"
      , `Assoc
          (List.map (fun (name, question) -> (name, question_to_yojson question))
             request.questions) )
    ]
;;

(* ── Decode ─────────────────────────────────────────────── *)

let string_member ~context = function
  | `String value -> Ok value
  | _ -> Error (context ^ " must be a string")
;;

let number_member ~context = function
  | `Float value when Float.is_finite value -> Ok value
  | `Float _ -> Error (context ^ " must be finite")
  | `Int value -> Ok (Float.of_int value)
  | _ -> Error (context ^ " must be a number")
;;

let bounded_number ~context ~maximum json =
  let* value = number_member ~context json in
  if value < 0. || value > maximum then
    Error (Printf.sprintf "%s must be between 0 and %g" context maximum)
  else Ok value
;;

let probability_member ~context = bounded_number ~context ~maximum:1.

let string_option_member ~context = function
  | `String value -> Ok (Some value)
  | `Null -> Ok None
  | _ -> Error (context ^ " must be a string or null")
;;

let optional_description ~context key pairs =
  match List.assoc_opt key pairs with
  | None -> Ok None
  | Some json -> string_option_member ~context:(context ^ "." ^ key) json
;;

let decode_instructions ~context = function
  | `String value -> Ok value
  | _ -> Error (context ^ " must be a string")
;;

let decode_choice name body =
  let instructions =
    match List.assoc_opt "instructions" body with
    | Some json -> decode_instructions ~context:(name ^ ".instructions") json
    | None -> Error (name ^ " is missing instructions")
  in
  let criteria =
    match List.assoc_opt "criteria" body with
    | Some (`Assoc pairs) -> Ok pairs
    | _ -> Error (name ^ " criteria must be an object of option to description")
  in
  let* instructions = instructions in
  let* criteria = criteria in
  let* criteria =
    List.fold_left
      (fun acc (option, json) ->
        let* acc = acc in
        let* _ = nonblank ~field:(name ^ " criteria key") option in
        if List.mem_assoc option acc then
          Error (Printf.sprintf "%s criteria key %S appears more than once" name option)
        else
          let* description =
            string_option_member ~context:(name ^ ".criteria." ^ option) json
          in
          Ok ((option, description) :: acc))
      (Ok []) criteria
  in
  Ok (Choice { instructions; criteria = List.rev criteria })
;;

let decode_noul name body =
  let instructions =
    match List.assoc_opt "instructions" body with
    | Some json -> decode_instructions ~context:(name ^ ".instructions") json
    | None -> Error (name ^ " is missing instructions")
  in
  let criteria =
    match List.assoc_opt "criteria" body with
    | None | Some `Null -> Ok []
    | Some (`Assoc pairs) -> Ok pairs
    | Some _ -> Error (name ^ " criteria must be an object or null")
  in
  let* instructions = instructions in
  let* criteria = criteria in
  let* _ =
    List.fold_left
      (fun acc (key, _) ->
        let* seen = acc in
        if key <> "true" && key <> "false" then
          Error (name ^ " criteria permits only true and false descriptions")
        else if List.mem key seen then
          Error (Printf.sprintf "%s criteria key %S appears more than once" name key)
        else Ok (key :: seen))
      (Ok []) criteria
  in
  let* true_description = optional_description ~context:(name ^ ".criteria") "true" criteria in
  let* false_description = optional_description ~context:(name ^ ".criteria") "false" criteria in
  Ok (Noul { instructions; true_description; false_description })
;;

let decode_score name body =
  let instructions =
    match List.assoc_opt "instructions" body with
    | Some json -> decode_instructions ~context:(name ^ ".instructions") json
    | None -> Error (name ^ " is missing instructions")
  in
  let scale =
    match List.assoc_opt "criteria" body with
    | Some (`List entries) ->
        List.fold_left
          (fun acc entry ->
            let* acc = acc in
            let* value = string_member ~context:(name ^ ".criteria entry") entry in
            Ok (acc @ [ value ]))
          (Ok []) entries
    | _ -> Error (name ^ " criteria must be an array of rubric strings, lowest first")
  in
  let* instructions = instructions in
  let* scale = scale in
  Ok (Score { instructions; scale })
;;

let decode_question name = function
  | `Assoc body -> (
      match List.assoc_opt "type" body with
      | Some (`String "choice") -> decode_choice name body
      | Some (`String "noul") -> decode_noul name body
      | Some (`String "score") -> decode_score name body
      | Some (`String other) ->
          Error (Printf.sprintf "%s has unknown question type %S" name other)
      | _ -> Error (name ^ " is missing a type of choice, noul or score"))
  | _ -> Error (name ^ " must be a question object")
;;

let decode_questions = function
  | `Assoc pairs ->
      List.fold_left
        (fun acc (name, json) ->
          let* acc = acc in
          let* () = validate_question_name name in
          if List.mem_assoc name acc then
            Error (Printf.sprintf "question name %S appears more than once" name)
          else
            let* question = decode_question name json in
            Ok ((name, question) :: acc))
        (Ok []) pairs
  | _ -> Error "questions must be an object of question name to question"
;;

(* ── Answers ────────────────────────────────────────────── *)

(* Bind object fields to the original request, including duplicate and missing
   keys. Object order is not significant; the returned list follows the request. *)
let requested_members ~context ~keys = function
  | `Assoc pairs ->
      let* _ =
        List.fold_left
          (fun acc (key, _) ->
            let* seen = acc in
            if not (List.mem key keys) then
              Error (Printf.sprintf "%s has unasked key %S" context key)
            else if List.mem key seen then
              Error (Printf.sprintf "%s key %S appears more than once" context key)
            else Ok (key :: seen))
          (Ok []) pairs
      in
      List.fold_right
        (fun key acc ->
          let* acc = acc in
          match List.assoc_opt key pairs with
          | None -> Error (Printf.sprintf "%s is missing key %S" context key)
          | Some value -> Ok ((key, value) :: acc))
        keys (Ok [])
  | _ -> Error (context ^ " must be an object")
;;

let decode_probabilities ~context ~keys json =
  let* pairs = requested_members ~context ~keys json in
  List.fold_right
    (fun (key, value) acc ->
      let* acc = acc in
      let* probability = probability_member ~context:(context ^ "." ^ key) value in
      Ok ((key, probability) :: acc))
    pairs (Ok [])
;;

let decode_answer (name, question) = function
  | `Assoc body -> (
      let kind = List.assoc_opt "type" body in
      match question, kind with
      | Choice { criteria; _ }, Some (`String "choice") ->
          let keys = List.map fst criteria in
          let choice =
            match List.assoc_opt "choice" body with
            | Some json -> string_member ~context:(name ^ ".choice") json
            | None -> Error (name ^ " answer is missing choice")
          in
          let probabilities =
            match List.assoc_opt "probabilities" body with
            | Some json -> decode_probabilities ~context:(name ^ ".probabilities") ~keys json
            | None -> Error (name ^ " answer is missing probabilities")
          in
          let confidence =
            match List.assoc_opt "confidence" body with
            | Some json -> probability_member ~context:(name ^ ".confidence") json
            | None -> Error (name ^ " answer is missing confidence")
          in
          let* choice = choice in
          let* probabilities = probabilities in
          let* confidence = confidence in
          if List.mem choice keys then
            Ok (Choice_answer { choice; probabilities; confidence })
          else Error (Printf.sprintf "%s chose unasked option %S" name choice)
      | Noul _, Some (`String "noul") ->
          let noul =
            match List.assoc_opt "noul" body with
            | Some json -> probability_member ~context:(name ^ ".noul") json
            | None -> Error (name ^ " answer is missing noul")
          in
          let* noul = noul in
          Ok (Noul_answer noul)
      | Score { scale; _ }, Some (`String "score") ->
          let keys = List.mapi (fun index _ -> string_of_int index) scale in
          let score =
            match List.assoc_opt "score" body with
            | Some json ->
                bounded_number ~context:(name ^ ".score")
                  ~maximum:(Float.of_int (List.length scale - 1)) json
            | None -> Error (name ^ " answer is missing score")
          in
          let legend =
            match List.assoc_opt "legend" body with
            | Some json ->
                let* entries = requested_members ~context:(name ^ ".legend") ~keys json in
                List.fold_right
                  (fun (_, entry) acc ->
                    let* acc = acc in
                    let* value = string_member ~context:(name ^ ".legend entry") entry in
                    Ok (value :: acc))
                  entries (Ok [])
            | None -> Error (name ^ " answer is missing legend")
          in
          let probabilities =
            match List.assoc_opt "probabilities" body with
            | Some json ->
                let* pairs = decode_probabilities ~context:(name ^ ".probabilities") ~keys json in
                Ok (List.map snd pairs)
            | None -> Error (name ^ " answer is missing probabilities")
          in
          let confidence =
            match List.assoc_opt "confidence" body with
            | Some json -> probability_member ~context:(name ^ ".confidence") json
            | None -> Error (name ^ " answer is missing confidence")
          in
          let* score = score in
          let* legend = legend in
          let* probabilities = probabilities in
          let* confidence = confidence in
          if legend = scale then
            Ok (Score_answer { score; legend; probabilities; confidence })
          else Error (name ^ " answer legend does not match the requested criteria")
      | Choice _, _ | Noul _, _ | Score _, _ ->
          let describe_question = function
            | Choice _ -> "choice"
            | Noul _ -> "noul"
            | Score _ -> "score"
          in
          let got =
            match kind with
            | Some (`String value) -> value
            | _ -> "unknown"
          in
          Error
            (Printf.sprintf "%s was asked as %s but answered as %s" name
               (describe_question question) got))
  | _ -> Error (name ^ " answer must be an object")
;;

let answer_to_yojson (answer : answer) : Yojson.Safe.t =
  match answer with
  | Choice_answer { choice; probabilities; confidence } ->
      `Assoc
        [ ("choice", `String choice)
        ; ("probabilities", `Assoc (List.map (fun (o, p) -> (o, `Float p)) probabilities))
        ; ("confidence", `Float confidence)
        ]
  | Noul_answer probability ->
      `Assoc [ ("noul", `Float probability) ]
  | Score_answer { score; legend; probabilities; confidence } ->
      `Assoc
        [ ("score", `Float score)
        ; ("legend", `List (List.map (fun entry -> `String entry) legend))
        ; ("probabilities", `List (List.map (fun p -> `Float p) probabilities))
        ; ("confidence", `Float confidence)
        ]
;;

(* ── Tool arguments ─────────────────────────────────────── *)

type args =
  { backend : backend
  ; model : string option
  ; state : string
  ; questions : (string * question) list
  ; timeout_sec : int
  }

let args_of_yojson (json : Yojson.Safe.t) : (args, string) result =
  match json with
  | `Assoc _ ->
      let state =
        match Json_util.get_string_nonempty json "state" with
        | Some value -> Ok value
        | None -> Error "state is required and must not be blank"
      in
      let questions =
        match Json_util.assoc_member_opt "questions" json with
        | Some member -> decode_questions member
        | None -> Error "questions is required"
      in
      let backend =
        match Json_util.get_string json "backend" with
        | None -> Ok Local
        | Some raw -> (
            match backend_of_string raw with
            | Some backend -> Ok backend
            | None -> Error "backend must be local or cloud")
      in
      let model =
        match Json_util.get_string json "model" with
        | Some "" -> Error "model must not be blank"
        | other -> Ok other
      in
      let timeout_sec =
        match Json_util.get_int json "timeout_sec" with
        | None -> Ok default_timeout_sec
        | Some value ->
            if value < timeout_sec_min || value > timeout_sec_max then
              Error
                (Printf.sprintf "timeout_sec must be %d-%d, got %d" timeout_sec_min
                   timeout_sec_max value)
            else Ok value
      in
      let* state = state in
      let* questions = questions in
      let* backend = backend in
      let* model = model in
      let* timeout_sec = timeout_sec in
      Ok { backend; model; state; questions; timeout_sec }
  | _ -> Error "arguments must be an object"
;;

(* ── The call ───────────────────────────────────────────── *)

let excerpt_max_bytes = 200

let excerpt text =
  let length = String.length text in
  if length <= excerpt_max_bytes then text
  else String_util.utf8_prefix ~max_bytes:excerpt_max_bytes text ^ "..."
;;

let decide ~timeout_sec (request : request) (backend : backend) :
    (Yojson.Safe.t, string) result =
  let* () = validate_request request in
  let url = match backend with Local -> local_url | Cloud -> cloud_url in
  let headers =
    match backend with
    | Local -> Ok []
    | Cloud -> (
        match Sys.getenv_opt cloud_key_env with
        | Some key when key <> "" -> Ok [ ("Authorization", "Bearer " ^ String.trim key) ]
        | _ -> Error ("cloud backend needs " ^ cloud_key_env ^ " in the environment"))
  in
  let* headers = headers in
  let body = Yojson.Safe.to_string (request_to_yojson request) in
  match
    Tool_local_runtime_http.http_post_json_text_with_status_with_headers ~timeout_sec
      ~headers ~url ~body_json:body ()
  with
  | Error transport -> Error transport
  | Ok (Some 200, payload) -> (
      match Yojson.Safe.from_string payload with
      | exception _ -> Error "systemone returned a body that is not JSON"
      | `Assoc body -> (
          let model =
            match List.assoc_opt "model" body with
            | Some (`String value) -> value
            | _ -> request.model
          in
          let usage =
            match List.assoc_opt "usage" body with
            | Some (`Assoc pairs) ->
                `Assoc
                  (List.filter_map
                     (fun (key, value) ->
                        match value with
                        | `Int _ | `Float _ -> Some (key, value)
                        | _ -> None)
                     pairs)
            | _ -> `Null
          in
          match List.assoc_opt "answers" body with
          | Some (`Assoc answers) ->
              let* decoded =
                List.fold_left
                  (fun acc (name, answer_json) ->
                    let* acc = acc in
                    let* () =
                      if List.mem_assoc name acc then
                        Error (Printf.sprintf "answer for question %S appears more than once" name)
                      else Ok ()
                    in
                    let question =
                      List.assoc_opt name request.questions
                    in
                    match question with
                    | None ->
                        (* The endpoint answers only what was asked; an extra
                           name means the reply and the request parted ways. *)
                        Error (Printf.sprintf "answer for unasked question %S" name)
                    | Some question ->
                        let* answer = decode_answer (name, question) answer_json in
                        Ok (acc @ [ (name, answer) ]))
                  (Ok []) answers
              in
              let missing =
                List.filter_map
                  (fun (name, _) ->
                    if List.mem_assoc name decoded then None else Some name)
                  request.questions
              in
              (match missing with
               | [] ->
                   Ok
                     (`Assoc
                        [ ("backend", `String (backend_id backend))
                        ; ("model", `String model)
                        ; ( "answers"
                          , `Assoc (List.map (fun (n, a) -> (n, answer_to_yojson a)) decoded) )
                        ; ("usage", usage)
                        ])
               | missing ->
                   Error
                     (Printf.sprintf "no answer for question(s) %s"
                        (String.concat ", " (List.map (fun n -> "\"" ^ n ^ "\"") missing))))
          | _ -> Error "systemone response is missing answers")
      | _ -> Error "systemone response must be an object")
  | Ok (status, payload) ->
      let status =
        match status with
        | Some code -> string_of_int code
        | None -> "unknown (curl wrote no status)"
      in
      Error
        (Printf.sprintf "systemone (%s) returned http %s: %s" (backend_id backend) status
           (excerpt payload))
;;
