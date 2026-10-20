let ( let* ) = Result.bind

type ask =
  { ask_id : string
  ; declaration_id : string
  ; title : string
  ; questions : Keeper_ask.question list
  ; context : string option
  ; asked_at : float
  }

let blank value = String.trim value = ""

let ask ~ask_id ~declaration_id ~title ~questions ?context ~asked_at () =
  let ids = List.map (fun (question : Keeper_ask.question) -> question.question_id) questions in
  if blank ask_id then Error "an installation question requires a non-blank request id"
  else if blank declaration_id then Error "an installation question requires its declaration id"
  else if blank title then Error "an installation question requires the package title"
  else if questions = [] then Error "an installation question requires at least one question"
  else if List.length (List.sort_uniq String.compare ids) <> List.length ids
  then Error "an installation question names a question id twice"
  else Ok { ask_id; declaration_id; title; questions; context; asked_at }

let questions_of_json = function
  | `List (_ :: _ as values) ->
    List.fold_right
      (fun value acc ->
         let* acc = acc in
         let* question = Keeper_ask.question_of_json value in
         Ok (question :: acc))
      values (Ok [])
  | _ -> Error "questions requires a non-empty array"

type event = ask Keeper_ask.lifecycle_event
type row = string * (ask * Keeper_ask.resolution)

let field key fields = List.assoc_opt key fields

let exact keys fields =
  match List.find_opt (fun (key, _) -> not (List.mem key keys)) fields with
  | Some (key, _) -> Error ("an installation question event has no key " ^ key)
  | None -> Ok ()

let text key fields =
  match field key fields with Some (`String value) -> Ok value | _ -> Error (key ^ " requires a string")

let number key fields =
  match field key fields with
  | Some (`Float value) -> Ok value
  | Some (`Int value) -> Ok (float_of_int value)
  | _ -> Error (key ^ " requires a number")

let list key decode fields =
  match field key fields with
  | Some (`List values) ->
    List.fold_right (fun value acc -> let* acc = acc in let* item = decode value in Ok (item :: acc)) values (Ok [])
  | _ -> Error (key ^ " requires an array")

let event_to_json : event -> Yojson.Safe.t = function
  | Keeper_ask.Asked a ->
    `Assoc
      [ "kind", `String "asked"; "ask_id", `String a.ask_id; "declaration_id", `String a.declaration_id
      ; "title", `String a.title; "questions", `List (List.map Keeper_ask.question_to_json a.questions)
      ; "context", (match a.context with None -> `Null | Some context -> `String context)
      ; "asked_at", `Float a.asked_at ]
  | Keeper_ask.Answered { ask_id; answers; responder; answered_at } ->
    `Assoc
      [ "kind", `String "answered"; "ask_id", `String ask_id
      ; "answers", `List (List.map Keeper_ask.answer_to_json answers)
      ; "responder", Keeper_ask.responder_to_json responder; "answered_at", `Float answered_at ]
  | Keeper_ask.Withdrawn { ask_id; reason; withdrawn_at } ->
    `Assoc
      [ "kind", `String "withdrawn"; "ask_id", `String ask_id; "reason", `String reason
      ; "withdrawn_at", `Float withdrawn_at ]

let event_of_json : Yojson.Safe.t -> (event, string) result = function
  | `Assoc fields ->
    let* kind = text "kind" fields in
    (match kind with
     | "asked" ->
       let* () = exact [ "kind"; "ask_id"; "declaration_id"; "title"; "questions"; "context"; "asked_at" ] fields in
       let* ask_id = text "ask_id" fields in
       let* declaration_id = text "declaration_id" fields in
       let* title = text "title" fields in
       let* questions = list "questions" Keeper_ask.question_of_json fields in
       let* context =
         match field "context" fields with
         | Some `Null -> Ok None
         | Some (`String context) -> Ok (Some context)
         | _ -> Error "context requires a string or null"
       in
       let* asked_at = number "asked_at" fields in
       let* a = ask ~ask_id ~declaration_id ~title ~questions ?context ~asked_at () in
       Ok (Keeper_ask.Asked a)
     | "answered" ->
       let* () = exact [ "kind"; "ask_id"; "answers"; "responder"; "answered_at" ] fields in
       let* ask_id = text "ask_id" fields in
       let* answers = list "answers" Keeper_ask.answer_of_json fields in
       let* responder =
         match field "responder" fields with
         | Some json -> Keeper_ask.responder_of_json json
         | None -> Error "responder requires an object"
       in
       let* answered_at = number "answered_at" fields in
       Ok (Keeper_ask.Answered { ask_id; answers; responder; answered_at })
     | "withdrawn" ->
       let* () = exact [ "kind"; "ask_id"; "reason"; "withdrawn_at" ] fields in
       let* ask_id = text "ask_id" fields in
       let* reason = text "reason" fields in
       let* withdrawn_at = number "withdrawn_at" fields in
       Ok (Keeper_ask.Withdrawn { ask_id; reason; withdrawn_at })
     | other -> Error ("an installation question event has no kind " ^ other))
  | _ -> Error "an installation question event must be an object"

let directory store = Filename.concat (Lane_addon_store.root store) "asks"
let log_path store ~declaration_id =
  Filename.concat (directory store) (Lane_addon_store.digest declaration_id ^ ".jsonl")

(* As the Keeper question log: only newline-complete lines count, and only the
   last of them may be cut short by a crash. *)
let decode content =
  let complete = match List.rev (String.split_on_char '\n' content) with [] -> [] | _tail :: lines -> List.rev lines in
  let lines = List.filter (fun line -> not (blank line)) complete in
  let count = List.length lines in
  let rec go index acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
      let decoded =
        match Yojson.Safe.from_string line with
        | exception Yojson.Json_error detail -> Error detail
        | json -> event_of_json json
      in
      (match decoded with
       | Ok event -> go (index + 1) (event :: acc) rest
       | Error _ when index = count -> Ok (List.rev acc)
       | Error detail -> Error (Printf.sprintf "installation question log line %d: %s" index detail))
  in
  go 1 [] lines

let load_path store path =
  match
    Fs_compat.load_owned_regular_file_with_snapshot ~owner_uid:(Unix.getuid ())
      ~ownership_root:(Lane_addon_store.root store) path
  with
  | Error error -> Error (Fs_compat.owned_regular_file_read_error_to_string error)
  | Ok None -> Ok []
  | Ok (Some { content; _ }) -> decode content

let events store ~declaration_id =
  let* events = load_path store (log_path store ~declaration_id) in
  (* A log holds one declaration's questions; another's would be misfiled. *)
  match
    List.find_opt
      (function
        | Keeper_ask.Asked (a : ask) -> not (String.equal a.declaration_id declaration_id)
        | Keeper_ask.Answered _ | Keeper_ask.Withdrawn _ -> false)
      events
  with
  | Some _ -> Error "an installation question log holds another declaration's question"
  | None -> Ok events

let rows store ~declaration_id =
  let* events = events store ~declaration_id in
  Ok (Keeper_ask.fold_lifecycle ~ask_id:(fun (a : ask) -> a.ask_id) events)

let declarations store =
  let dir = directory store in
  if not (Sys.file_exists dir) then Ok []
  else
    let* ids =
      Array.to_list (Sys.readdir dir)
      |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
      |> List.fold_left
           (fun acc name ->
              let* acc = acc in
              let* events = load_path store (Filename.concat dir name) in
              match
                List.find_map
                  (function
                    | Keeper_ask.Asked (a : ask) -> Some a.declaration_id
                    | Keeper_ask.Answered _ | Keeper_ask.Withdrawn _ -> None)
                  events
              with
              | Some id -> Ok (id :: acc)
              | None -> Ok acc)
           (Ok [])
    in
    Ok (List.sort_uniq String.compare ids)

let append store ~declaration_id event =
  let path = log_path store ~declaration_id in
  try
    Fs_compat.mkdir_p (directory store);
    match Fs_compat.append_private_jsonl_durable_locked_result path (Yojson.Safe.to_string (event_to_json event) ^ "\n") with
    | Fs_compat.Private_file_succeeded () -> Ok ()
    | Fs_compat.Private_file_succeeded_with_cleanup_failure { value = (); cleanup_failure } ->
      Log.Misc.warn "installation question append committed; descriptor cleanup failed: %s"
        (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
      Ok ()
    | Fs_compat.Private_file_failed error -> Error (Fs_compat.private_jsonl_append_error_to_string error)
    | Fs_compat.Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
      Error
        (Fs_compat.private_jsonl_append_error_to_string error ^ "; "
         ^ Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure)
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Unix.Unix_error _ | Sys_error _ | Failure _) as exn -> Error (Printexc.to_string exn)

let find rows ask_id = List.find_map (fun (id, row) -> if String.equal id ask_id then Some row else None) rows

type record_outcome = Recorded | Already_recorded | Id_reused

let record store (a : ask) =
  let* current = rows store ~declaration_id:a.declaration_id in
  match find current a.ask_id with
  | Some (recorded, _) ->
    Ok
      (if recorded.questions = a.questions && recorded.context = a.context && String.equal recorded.title a.title
       then Already_recorded else Id_reused)
  | None ->
    let* () = append store ~declaration_id:a.declaration_id (Keeper_ask.Asked a) in
    Ok Recorded

type answer_failure =
  | Ask_not_found
  | Already_answered of { answered_at : float }
  | Already_withdrawn of { withdrawn_at : float }
  | Rejected of Keeper_ask.invalid_answer list
  | Store_failed of string

let answer_failure_to_string = function
  | Ask_not_found -> "no such installation question"
  | Already_answered { answered_at } -> Printf.sprintf "already answered at %.3f" answered_at
  | Already_withdrawn { withdrawn_at } -> Printf.sprintf "withdrawn by the package at %.3f" withdrawn_at
  | Rejected errors -> String.concat "; " (List.map Keeper_ask.invalid_answer_to_string errors)
  | Store_failed detail -> detail

let answer store ~declaration_id ~ask_id ~submissions ~responder ~now =
  let* before = rows store ~declaration_id |> Result.map_error (fun detail -> Store_failed detail) in
  match find before ask_id with
  | None -> Error Ask_not_found
  | Some (_, Keeper_ask.Answered_by { answered_at; _ }) -> Error (Already_answered { answered_at })
  | Some (_, Keeper_ask.Withdrawn_because { withdrawn_at; _ }) -> Error (Already_withdrawn { withdrawn_at })
  | Some (asked, Keeper_ask.Open) ->
    let* answers =
      Keeper_ask.parse_question_answers ~questions:asked.questions ~submissions
      |> Result.map_error (fun errors -> Rejected errors)
    in
    let* () =
      append store ~declaration_id (Keeper_ask.Answered { ask_id; answers; responder; answered_at = now })
      |> Result.map_error (fun detail -> Store_failed detail)
    in
    (* Another surface may have answered between the read and the append; the
       log's first terminal event is the answer. *)
    let* after = rows store ~declaration_id |> Result.map_error (fun detail -> Store_failed detail) in
    (match find after ask_id with
     | Some (_, Keeper_ask.Answered_by canonical) when canonical.answered_at = now && canonical.answers = answers ->
       Ok answers
     | Some (_, Keeper_ask.Answered_by { answered_at; _ }) -> Error (Already_answered { answered_at })
     | Some (_, Keeper_ask.Withdrawn_because { withdrawn_at; _ }) -> Error (Already_withdrawn { withdrawn_at })
     | Some (_, Keeper_ask.Open) | None -> Error (Store_failed "the committed answer has no answered row"))

type withdraw_outcome = Withdrawn | Was_answered | Was_withdrawn | Not_asked

let withdraw store ~declaration_id ~ask_id ~reason ~now =
  let* current = rows store ~declaration_id in
  match find current ask_id with
  | None -> Ok Not_asked
  | Some (_, Keeper_ask.Answered_by _) -> Ok Was_answered
  | Some (_, Keeper_ask.Withdrawn_because _) -> Ok Was_withdrawn
  | Some (_, Keeper_ask.Open) ->
    let* () = append store ~declaration_id (Keeper_ask.Withdrawn { ask_id; reason; withdrawn_at = now }) in
    Ok Withdrawn
