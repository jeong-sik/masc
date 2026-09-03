(* Wire boundary for masc_ask: tool arguments in, a recorded question out.

   The tool surface spells free text as a boolean plus a hint because that is
   what a JSON schema can express. The domain spells it as one sum. Widening
   happens here so no value downstream can carry a bool and a hint that
   disagree. Every other rejection is the domain's: this module shapes
   arguments and hands them to Keeper_ask, which decides whether they make a
   question anyone could answer. *)

(* The handlers read three things: who is asking, where the store lives, and
   the raw arguments. The MCP server context also carries the session registry,
   the server state, and a switch none of them touch, and the agent-core lane
   has none of those to give -- so the handlers take the narrow record and each
   lane adapts its own context at the call site. *)
type context = {
  config : Workspace.config;
  agent_name : string;
  arguments : Yojson.Safe.t;
}

let field key = function
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let string_field key json =
  match field key json with
  | Some (`String s) -> Ok s
  | Some _ -> Error (key ^ " must be a string")
  | None -> Error (key ^ " is required")

let string_option_field key json =
  match field key json with
  | None | Some `Null -> None
  | Some (`String s) -> Some s
  | Some _ -> None

let bool_field key json =
  match field key json with Some (`Bool b) -> b | Some _ | None -> false

let list_field key json =
  match field key json with
  | None | Some `Null -> Ok []
  | Some (`List items) -> Ok items
  | Some _ -> Error (key ^ " must be an array")

let ( let* ) = Result.bind

let rec map_results f = function
  | [] -> Ok []
  | x :: rest ->
      let* y = f x in
      let* ys = map_results f rest in
      Ok (y :: ys)

let choice_of_json json =
  let* choice_id = string_field "choice_id" json in
  let* label = string_field "label" json in
  let description = string_option_field "description" json in
  Result.map_error Keeper_ask.invalid_choice_to_string
    (Keeper_ask.choice ~choice_id ~label ?description ())

let mode_of_string = function
  | "single" -> Ok Keeper_ask.Single
  | "multi" -> Ok Keeper_ask.Multi
  | other -> Error (Printf.sprintf "mode must be single or multi, got %s" other)

let question_of_json json =
  let* question_id = string_field "question_id" json in
  let* header = string_field "header" json in
  let* prompt = string_field "prompt" json in
  let* mode_label = string_field "mode" json in
  let* mode = mode_of_string mode_label in
  let* choice_items = list_field "choices" json in
  let* choices = map_results choice_of_json choice_items in
  let free_text =
    if bool_field "free_text" json then
      Keeper_ask.Free_text_allowed { hint = string_option_field "free_text_hint" json }
    else Keeper_ask.Choices_only
  in
  Result.map_error Keeper_ask.invalid_question_to_string
    (Keeper_ask.question ~question_id ~header ~prompt ~choices ~mode ~free_text)

let ask_json (a : Keeper_ask.ask) =
  `Assoc
    [
      ("ask_id", `String a.ask_id);
      ("keeper_name", `String a.keeper_name);
      ( "questions",
        `List
          (List.map
             (fun (q : Keeper_ask.question) ->
               `Assoc
                 [
                   ("question_id", `String q.question_id);
                   ("header", `String q.header);
                 ])
             a.questions) );
    ]

let handle_ask ~tool_name ~start_time (ctx : context) : Tool_result.result option =
  (* RFC-0393: a Keeper reaches its tools under its keeper_name — there is no
     alias or nickname spelling to unwrap. A name the registry does not know
     fails the registry check, which is the honest answer for a caller that
     is not a Keeper. *)
  let keeper_name = ctx.agent_name in
  let reject detail =
    (* A refused question is worth a line. The Keeper sees the rejection in
       its own result; an operator wondering why nothing is waiting on them
       has only the log. *)
    Log.Keeper.info "keeper_ask: keeper=%s refused=%s" keeper_name detail;
    Some
      (Tool_result.error ~failure_class:Tool_result.Workflow_rejection ~tool_name ~start_time
         detail)
  in
  let base_path = ctx.config.base_path in
  (* A question belongs to the Keeper that asked it, and every surface that
     renders one resolves the Keeper first. A caller that is not a registered
     Keeper could still write to the log, but nothing could ever read the row
     back -- it would be a question with no owner, costing an operator's
     attention for an answer that reaches nobody. Refuse at the write. *)
  if not (Keeper_registry.is_registered ~base_path keeper_name) then
    reject
      (Printf.sprintf
         "unknown keeper %s: a question from a caller the registry does not hold could not be read back"
         keeper_name)
  else
  match list_field "questions" ctx.arguments with
  | Error detail -> reject detail
  | Ok [] -> reject "at least one question is required"
  | Ok question_items -> (
      match map_results question_of_json question_items with
      | Error detail -> reject detail
      | Ok questions -> (
          let context = string_option_field "context" ctx.arguments in
          let task_id = string_option_field "task_id" ctx.arguments in
          let goal_id = string_option_field "goal_id" ctx.arguments in
          let continuation =
            match Keeper_continuation_channel.keeper ~keeper_name with
            | Ok channel -> channel
            | Error detail ->
                (* A keeper name the channel refuses is not a route we can
                   invent one for; record why rather than pick a surface. *)
                Keeper_continuation_channel.unrouted detail
          in
          let ask_id = Random_id.prefixed ~prefix:"ask" ~bytes:8 in
          let asked_at = Time_compat.now () in
          match
            Keeper_ask.ask ~ask_id ~keeper_name ~questions ?context ?task_id ?goal_id
              ~continuation ~asked_at ()
          with
          | Error e -> reject (Keeper_ask.invalid_ask_to_string e)
          | Ok a -> (
              match Keeper_ask_store.record_ask ~base_path a with
              | Error detail ->
                  Some
                    (Tool_result.error ~failure_class:Tool_result.Runtime_failure ~tool_name
                       ~start_time detail)
              | Ok () ->
                  (* The reply says how many of this Keeper's questions are now
                     open. A Keeper that cannot see its own queue growing asks
                     again instead of waiting, and a human reading a list of
                     five answers the top one. *)
                  let open_count =
                    Keeper_ask_store.open_ask_count ~base_path ~keeper_name
                  in
                  (* Recording a question spends an operator's attention
                     later, so the act is logged where it happens rather than
                     inferred from the store's file changing. *)
                  Log.Keeper.info
                    "keeper_ask: keeper=%s ask_id=%s questions=%d open=%d" keeper_name
                    a.ask_id (List.length a.questions) open_count;
                  let body =
                    match ask_json a with
                    | `Assoc fields ->
                        `Assoc (fields @ [ ("open_count", `Int open_count) ])
                    | other -> other
                  in
                  Some
                    (Tool_result.ok ~tool_name ~start_time
                       (Yojson.Safe.to_string body)))))

(* masc_ask_status: what the Keeper asked and what came back.

   An answer does not interrupt the asking Keeper, so a question it never
   reads is worse than one it never asked -- the operator spent attention on a
   decision that went nowhere. This is the read side that closes that loop. *)

let response_json = function
  | Keeper_ask.Chose { choice_ids } ->
      `Assoc
        [
          ("kind", `String "chose");
          ("choice_ids", `List (List.map (fun id -> `String id) choice_ids));
        ]
  | Keeper_ask.Wrote text -> `Assoc [ ("kind", `String "wrote"); ("text", `String text) ]
  | Keeper_ask.Skipped -> `Assoc [ ("kind", `String "skipped") ]

let answer_json (answer : Keeper_ask.answer) =
  `Assoc
    [
      ("question_id", `String answer.question_id);
      ("response", response_json answer.response);
    ]

let responder_json (responder : Keeper_ask.responder) =
  `Assoc
    [
      ("surface", Surface_ref.to_json responder.surface);
      ( "actor_id",
        match responder.actor_id with None -> `Null | Some id -> `String id );
      ( "display_name",
        match responder.display_name with None -> `Null | Some name -> `String name );
    ]

let resolution_json = function
  | Keeper_ask.Open -> `Assoc [ ("state", `String "open") ]
  | Keeper_ask.Answered_by { answers; responder; answered_at } ->
      `Assoc
        [
          ("state", `String "answered");
          ("answered_at", `Float answered_at);
          ("responder", responder_json responder);
          ("answers", `List (List.map answer_json answers));
        ]
  | Keeper_ask.Withdrawn_because { reason; withdrawn_at } ->
      `Assoc
        [
          ("state", `String "withdrawn");
          ("reason", `String reason);
          ("withdrawn_at", `Float withdrawn_at);
        ]

let question_summary_json (q : Keeper_ask.question) =
  `Assoc
    [
      ("question_id", `String q.question_id);
      ("header", `String q.header);
      ("prompt", `String q.prompt);
      ( "choices",
        `List
          (List.map
             (fun (c : Keeper_ask.choice) ->
               `Assoc [ ("choice_id", `String c.choice_id); ("label", `String c.label) ])
             q.choices) );
    ]

let row_json (ask_id, ((a : Keeper_ask.ask), resolution)) =
  `Assoc
    [
      ("ask_id", `String ask_id);
      ("asked_at", `Float a.asked_at);
      ("context", match a.context with None -> `Null | Some c -> `String c);
      ("questions", `List (List.map question_summary_json a.questions));
      ("resolution", resolution_json resolution);
    ]

let is_open = function
  | Keeper_ask.Open -> true
  | Keeper_ask.Answered_by _ | Keeper_ask.Withdrawn_because _ -> false

let handle_ask_status ~tool_name ~start_time (ctx : context) : Tool_result.result option =
  let base_path = ctx.config.base_path in
  (* The same resolution the write side uses, and for a sharper reason: the
     store is keyed on the registry name, so reading under an unresolved
     spelling returns an empty list rather than an error. A Keeper would be
     told it never asked. *)
  let keeper_name = ctx.agent_name in
  let include_resolved = bool_field "include_resolved" ctx.arguments in
  let wanted_ask_id = string_option_field "ask_id" ctx.arguments in
  let rows = Keeper_ask_store.rows ~base_path ~keeper_name in
  let selected =
    List.filter
      (fun (ask_id, (_, resolution)) ->
        let id_matches =
          match wanted_ask_id with None -> true | Some wanted -> String.equal wanted ask_id
        in
        id_matches && (include_resolved || is_open resolution))
      rows
  in
  Some
    (Tool_result.ok ~tool_name ~start_time
       (Yojson.Safe.to_string
          (`Assoc
            [
              ("keeper_name", `String keeper_name);
              ("open_count", `Int (Keeper_ask_store.open_ask_count ~base_path ~keeper_name));
              ("returned", `Int (List.length selected));
              ("asks", `List (List.map row_json selected));
            ])))

(* masc_ask_withdraw: taking back a question that stopped mattering.

   [Keeper_ask_store.withdraw] has been here since the store was written, and
   nothing outside its own tests ever called it. The tool description says a
   question stays open "until a human answers it or the asking Keeper
   withdraws it" — this is the half that made the second clause true.

   A question left standing costs an operator the attention of reading it and
   deciding, for a choice that no longer changes anything. *)

let handle_ask_withdraw ~tool_name ~start_time (ctx : context) : Tool_result.result option =
  let base_path = ctx.config.base_path in
  let keeper_name = ctx.agent_name in
  let reject detail =
    Log.Keeper.info "keeper_ask_withdraw: keeper=%s refused=%s" keeper_name detail;
    Some
      (Tool_result.error ~failure_class:Tool_result.Workflow_rejection ~tool_name ~start_time
         detail)
  in
  match (string_field "ask_id" ctx.arguments, string_field "reason" ctx.arguments) with
  | Error detail, _ | _, Error detail -> reject detail
  | Ok ask_id, Ok reason -> (
      (* Blank is not a reason. An operator who watched the question appear and
         then vanish has nothing else to read. *)
      if String.trim reason = "" then reject "reason must say why it no longer needs answering"
      else
        match
          Keeper_ask_store.withdraw ~base_path ~keeper_name ~ask_id ~reason
            ~now:(Time_compat.now ())
        with
        | Error failure ->
            reject (Keeper_ask_store.withdraw_failure_to_string failure)
        | Ok () ->
            Log.Keeper.info "keeper_ask_withdraw: keeper=%s ask_id=%s" keeper_name ask_id;
            Some
              (Tool_result.ok ~tool_name ~start_time
                 (Yojson.Safe.to_string
                    (`Assoc
                      [
                        ("withdrawn", `Bool true);
                        ("ask_id", `String ask_id);
                        ( "open_remaining",
                          `Int (Keeper_ask_store.open_ask_count ~base_path ~keeper_name)
                        );
                      ]))))
