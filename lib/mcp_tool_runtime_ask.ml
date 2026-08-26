(* Wire boundary for masc_ask: tool arguments in, a recorded question out.

   The tool surface spells free text as a boolean plus a hint because that is
   what a JSON schema can express. The domain spells it as one sum. Widening
   happens here so no value downstream can carry a bool and a hint that
   disagree. Every other rejection is the domain's: this module shapes
   arguments and hands them to Keeper_ask, which decides whether they make a
   question anyone could answer. *)

open Mcp_tool_runtime_types

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
      ("question_count", `Int (List.length a.questions));
      ( "questions",
        `List
          (List.map
             (fun (q : Keeper_ask.question) ->
               `Assoc
                 [
                   ("question_id", `String q.question_id);
                   ("header", `String q.header);
                   ("choice_count", `Int (List.length q.choices));
                 ])
             a.questions) );
    ]

(* Which Keeper is calling.

   A Keeper reaches its own tools under whatever name its runtime was spawned
   with -- the [keeper-<name>-agent] alias, a bare [keeper-<name>], or a
   generated nickname -- while the registry holds one name. RFC-0232 put every
   spelling behind [canonical_keeper_name]; matching one of them here by hand
   is how a live Keeper ends up refused by a guard written for unregistered
   callers. A name it does not recognise passes through and fails the registry
   check, which is the honest answer for a caller that is not a Keeper.

   Named rather than inlined so the tests call the resolution the tools use
   instead of a lookalike beside it. *)
let asking_keeper_name agent_name =
  Option.value (Keeper_identity.canonical_keeper_name agent_name) ~default:agent_name

let handle_ask ~tool_name ~start_time (ctx : context) : Tool_result.result option =
  let keeper_name = asking_keeper_name ctx.agent_name in
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
                  (* Recording a question spends an operator's attention
                     later, so the act is logged where it happens rather than
                     inferred from the store's file changing. *)
                  Log.Keeper.info "keeper_ask: keeper=%s ask_id=%s questions=%d"
                    keeper_name a.ask_id (List.length a.questions);
                  Some
                    (Tool_result.ok ~tool_name ~start_time
                       (Yojson.Safe.to_string (ask_json a))))))
