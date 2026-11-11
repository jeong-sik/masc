(* Wire boundary for masc_ask: tool arguments in, a recorded question out.

   The tool surface spells free text as a boolean plus a hint because that is
   what a JSON schema can express. The domain spells it as one sum. Widening
   happens here so no value downstream can carry a bool and a hint that
   disagree. Every other rejection is the domain's: this module shapes
   arguments and hands them to Keeper_ask, which decides whether they make a
   question anyone could answer. *)

(* The shared context carries who is asking, where the store lives, and
   the raw arguments. The MCP server context also carries the session registry,
   the server state, and a switch none of them touch, and the agent-core lane
   has none of those to give -- so the handlers take the narrow record and each
   lane adapts its own context at the call site. Ask creation separately accepts
   frozen host provenance; raw client arguments cannot supply that identity. *)
type context = {
  config : Workspace.config;
  agent_name : string;
  arguments : Yojson.Safe.t;
}

let string_field key json =
  match Json_util.assoc_member_opt key json with
  | Some (`String s) -> Ok s
  | Some _ -> Error (key ^ " must be a string")
  | None -> Error (key ^ " is required")

let string_option_field key json =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> None
  | Some (`String s) -> Some s
  | Some _ -> None

let bool_field key json =
  match Json_util.assoc_member_opt key json with
  | Some (`Bool b) -> b
  | Some _ | None -> false

let list_field key json =
  match Json_util.assoc_member_opt key json with
  | None | Some `Null -> Ok []
  | Some (`List items) -> Ok items
  | Some _ -> Error (key ^ " must be an array")

let ( let* ) = Result.bind

(* [f] sees each item's zero-based position. *)
let mapi_results f items =
  let rec go index = function
    | [] -> Ok []
    | x :: rest ->
        let* y = f ~index x in
        let* ys = go (index + 1) rest in
        Ok (y :: ys)
  in
  go 0 items

(* A question's id and a choice's id are how an answer finds its way back to
   them, and they only have to be unique inside one ask. Nothing a Keeper
   calls later takes one: masc_ask_status and masc_ask_withdraw name the ask.
   The wake that delivers an answer turns each id back into its header and
   label, and masc_ask_status lists the ids beside the questions and choices
   they name in the same row. So the ids are numbered here by position rather
   than asked of the model. Every ask now has a q1, so a surface that edits
   an answer binds to the ask as well as the question (the TUI's
   free_text_slot). Asking cost more than it bought: a missing question_id
   was the most common first-call failure in the September ledger, and
   models that tried to make an id unique could loop inside the string until
   it never closed. *)
let position_id ~prefix index = Printf.sprintf "%s%d" prefix (index + 1)

let choice_of_json ~index json =
  let choice_id = position_id ~prefix:"c" index in
  let* label = string_field "label" json in
  let description = string_option_field "description" json in
  Result.map_error Keeper_ask.invalid_choice_to_string
    (Keeper_ask.choice ~choice_id ~label ?description ())

let mode_of_string = function
  | "single" -> Ok Keeper_ask.Single
  | "multi" -> Ok Keeper_ask.Multi
  | other -> Error (Printf.sprintf "mode must be single or multi, got %s" other)

let question_of_json ~index json =
  let question_id = position_id ~prefix:"q" index in
  let* header = string_field "header" json in
  let* prompt = string_field "prompt" json in
  let* mode_label = string_field "mode" json in
  let* mode = mode_of_string mode_label in
  let* choice_items = list_field "choices" json in
  let* choices = mapi_results choice_of_json choice_items in
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
      ("source_turn_ref", match a.source_turn_ref with
        | None -> `Null | Some reference -> Ids.Turn_ref.to_yojson reference);
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

let handle_ask ?source_turn_ref ~tool_name ~start_time (ctx : context) : Tool_result.result option =
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
      match mapi_results question_of_json question_items with
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
              ?source_turn_ref
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

(* The store keeps rows oldest first, and include_resolved returned all of
   them. In the 72 hours before 2026-11-11 08:40 KST, 83 such calls carried
   6.58 MB. 25 were over their lane's inline ceiling and reached the model as
   a blob preview: the oldest row, with the open asks at the end out of view
   (11 calls). The rest were up to 61 KB each.

   Open asks come first because they are the ones that wait for an answer.
   They keep the order they were asked in, which is the order the store lists
   them, so a read of the open asks alone lists the same rows in the same
   order. The resolved asks follow newest first. The ask id breaks a tie on
   asked_at so two reads of the same store list the same order. *)
let compare_rows (id_left, ((left : Keeper_ask.ask), resolution_left))
    (id_right, ((right : Keeper_ask.ask), resolution_right)) =
  let tie_break_on_ask_id = function
    | 0 -> String.compare id_left id_right
    | decided -> decided
  in
  match (is_open resolution_left, is_open resolution_right) with
  | true, false -> -1
  | false, true -> 1
  | true, true -> tie_break_on_ask_id (Float.compare left.asked_at right.asked_at)
  | false, false -> tie_break_on_ask_id (Float.compare right.asked_at left.asked_at)

let result_json ~keeper_name ~open_count ~matching ~returned ~asks ~omitted_ask_ids =
  `Assoc
    [
      ("keeper_name", `String keeper_name);
      ("open_count", `Int open_count);
      ("matching", `Int matching);
      ("returned", `Int returned);
      ("asks", `List asks);
      ("omitted_ask_ids", `List (List.map (fun ask_id -> `String ask_id) omitted_ask_ids));
    ]

(* Splits [sorted], the matching asks in list order, into the rows that go in
   the result and the ids of the asks left out, also in list order.

   The rows are the longest prefix whose result fits under
   Common.max_tool_result_wire_bytes, the lowest inline ceiling of any lane, so
   the result arrives inline everywhere. An ask left out keeps its id in the
   result, and a Keeper passes that id as ask_id to read the ask whole. The ids
   count against the ceiling too: a row is shown only while the rows shown and
   the ids of the asks left out still fit. When the ids alone are over the
   ceiling no row is shown, every id stays, and the result is over the ceiling.

   [envelope_bytes] is what the result takes around the rows and ids. Each row
   and id is counted with one comma, one more than the result holds for the
   last of each, so the size counted is never under the real size. *)
let split_within_inline_ceiling ~envelope_bytes sorted =
  let serialized_size json = String.length (Yojson.Safe.to_string json) + 1 in
  let entries =
    List.map
      (fun ((ask_id, _) as row) -> (ask_id, serialized_size (`String ask_id), row_json row))
      sorted
  in
  let budget = Common.max_tool_result_wire_bytes - envelope_bytes in
  let rec take ~used shown = function
    | [] -> (List.rev shown, [])
    | (_, id_size, row) :: rest as left_out ->
        let used = used - id_size + serialized_size row in
        if used > budget then (List.rev shown, List.map (fun (ask_id, _, _) -> ask_id) left_out)
        else take ~used (row :: shown) rest
  in
  take ~used:(List.fold_left (fun sum (_, id_size, _) -> sum + id_size) 0 entries) [] entries

let handle_ask_status ~tool_name ~start_time (ctx : context) : Tool_result.result option =
  let base_path = ctx.config.base_path in
  (* The same resolution the write side uses, and for a sharper reason: the
     store is keyed on the registry name, so reading under an unresolved
     spelling returns an empty list rather than an error. A Keeper would be
     told it never asked. *)
  let keeper_name = ctx.agent_name in
  let include_resolved = bool_field "include_resolved" ctx.arguments in
  let wanted_ask_id = string_option_field "ask_id" ctx.arguments in
  match Keeper_ask_store.rows_result ~base_path ~keeper_name with
  | Error error ->
      Some
        (Tool_result.error ~failure_class:Tool_result.Runtime_failure ~tool_name ~start_time
           (Keeper_ask_store.read_error_to_string error))
  | Ok snapshot ->
  let rows = match snapshot with
    | Keeper_ask_store.Missing_log -> []
    | Keeper_ask_store.Stored_rows rows -> rows in
  let open_count = List.fold_left
      (fun count (_, (_, resolution)) -> if is_open resolution then count + 1 else count)
      0 rows in
  let selected =
    List.filter
      (fun (ask_id, (_, resolution)) ->
        let id_matches =
          match wanted_ask_id with None -> true | Some wanted -> String.equal wanted ask_id
        in
        id_matches && (include_resolved || is_open resolution))
      rows
  in
  let matching = List.length selected in
  let sorted = List.sort compare_rows selected in
  (* An ask read by its id is returned whole, however long its context is. A
     result over the lane's ceiling then becomes a blob the Keeper reads in
     pages, as before. *)
  let asks, omitted_ask_ids =
    match wanted_ask_id with
    | Some _ -> (List.map row_json sorted, [])
    | None ->
        (* [returned] is at most [matching], so it has no more digits. *)
        let envelope_bytes =
          String.length
            (Yojson.Safe.to_string
               (result_json ~keeper_name ~open_count ~matching ~returned:matching ~asks:[]
                  ~omitted_ask_ids:[]))
        in
        split_within_inline_ceiling ~envelope_bytes sorted
  in
  Some
    (Tool_result.ok ~tool_name ~start_time
       (Yojson.Safe.to_string
          (result_json ~keeper_name ~open_count ~matching ~returned:(List.length asks) ~asks
             ~omitted_ask_ids)))

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
        | Error ((Keeper_ask_store.Withdraw_store_failed _
                  | Keeper_ask_store.Withdraw_recorded_unconfirmed _) as failure) ->
            Some (Tool_result.error ~failure_class:Tool_result.Runtime_failure ~tool_name
              ~start_time (Keeper_ask_store.withdraw_failure_to_string failure))
        | Error ((Keeper_ask_store.Withdraw_ask_not_found _
                  | Keeper_ask_store.Withdraw_already_answered _
                  | Keeper_ask_store.Withdraw_already_withdrawn _) as failure) ->
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
