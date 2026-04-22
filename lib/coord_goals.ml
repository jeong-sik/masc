(** Coord_goals - Handlers for goal management tools *)

open Coord_types
open Tool_args

let goal_horizon_strings = [ "short"; "mid"; "long" ]
let goal_status_strings = [ "active"; "paused"; "done"; "dropped" ]
let goal_review_outcome_strings = [ "done"; "progress"; "blocked"; "dropped" ]

let make_enum_field_error ~field ~allowed ~received =
  {
    field;
    constraint_violated = One_of allowed;
    message =
      Printf.sprintf "%s must be one of: %s" field (String.concat ", " allowed);
    expected = Some (String.concat "|" allowed);
    received = Some received;
  }

let make_type_field_error ~field ~constraint_violated ~expected ~received =
  {
    field;
    constraint_violated;
    message = Printf.sprintf "%s must be a %s" field expected;
    expected = Some expected;
    received = Some received;
  }

let parse_optional_horizon args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_store.parse_horizon (Some raw) with
      | Some horizon -> Ok (Some horizon)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_horizon_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_goal_status args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_store.parse_goal_status (Some raw) with
      | Some status -> Ok (Some status)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_status_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_review_outcome args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `String raw -> (
      match Goal_store.parse_review_outcome raw with
      | Some outcome -> Ok (Some outcome)
      | None ->
          Error
            (make_enum_field_error ~field ~allowed:goal_review_outcome_strings
               ~received:raw))
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_string
           ~expected:"string"
           ~received:(Yojson.Safe.to_string json))

let parse_optional_priority args field =
  match Yojson.Safe.Util.member field args with
  | `Null -> Ok None
  | `Int n ->
      if n < 1 || n > 5 then
        Error
          {
            field;
            constraint_violated = Min_int 1;
            message = "priority must be between 1 and 5";
            expected = Some "1..5";
            received = Some (string_of_int n);
          }
      else Ok (Some n)
  | json ->
      Error
        (make_type_field_error ~field ~constraint_violated:Type_int
           ~expected:"integer"
           ~received:(Yojson.Safe.to_string json))

let handle_goal_list (ctx : context) args =
  match parse_optional_horizon args "horizon", parse_optional_goal_status args "status" with
  | Error err, _
  | _, Error err ->
      validation_error_result [ err ]
  | Ok horizon, Ok status ->
      let goals = Goal_store.list_goals ctx.config ?horizon ?status () in
      let rollup = Goal_store.compute_rollup goals in
      ok_result
        [
          ("generated_at", `String (Types.now_iso ()));
          ("count", `Int (List.length goals));
          ("goals", `List (List.map Goal_store.goal_to_yojson goals));
          ("rollup", Goal_store.rollup_to_yojson rollup);
        ]

let handle_goal_upsert (ctx : context) args =
  match
    parse_optional_horizon args "horizon",
    parse_optional_goal_status args "status",
    parse_optional_priority args "priority"
  with
  | Error err, _, _
  | _, Error err, _
  | _, _, Error err ->
      validation_error_result [ err ]
  | Ok horizon, Ok status, Ok priority ->
      let id = get_string_opt args "id" in
      let title = get_string_opt args "title" in
      let metric = get_string_opt args "metric" in
      let target_value = get_string_opt args "target_value" in
      let due_date = get_string_opt args "due_date" in
      let parent_goal_id = get_string_opt args "parent_goal_id" in
      match
        Goal_store.upsert_goal ctx.config ?id ?horizon ?title ?metric
          ?target_value ?due_date ?priority ?status ?parent_goal_id ()
      with
      | Error msg -> error_result_typed ~code:Validation_error msg
      | Ok (goal, action) ->
          let action_name =
            match action with
            | `created -> "created"
            | `updated -> "updated"
          in
          let task_marker = Printf.sprintf "[goal:%s]" goal.id in
          ok_result
            [
              ("action", `String action_name);
              ("goal_id", `String goal.id);
              ("goal", Goal_store.goal_to_yojson goal);
              ( "task_goal_id_example",
                `String
                  (Printf.sprintf
                     {|masc_add_task({title: "Implement %s", goal_id: "%s"})|}
                     goal.title goal.id) );
              ("task_title_marker", `String task_marker);
              ( "linked_task_title_example",
                `String
                  (Printf.sprintf "%s[child] %s" task_marker goal.title) );
            ]

let handle_goal_review (ctx : context) args =
  match validate_string_required args "goal_id", parse_optional_review_outcome args "outcome",
        parse_optional_horizon args "new_horizon" with
  | Error err, _, _
  | _, Error err, _
  | _, _, Error err ->
      validation_error_result [ err ]
  | Ok goal_id, Ok (Some outcome), Ok new_horizon ->
      let note = get_string_opt args "note" in
      begin
        match
          Goal_store.review_goal ctx.config ~goal_id ~outcome ?new_horizon ?note ()
        with
        | Error msg ->
            error_result_typed ~code:Not_found msg
        | Ok goal ->
            ok_result
              [
                ("goal_id", `String goal.id);
                ("goal", Goal_store.goal_to_yojson goal);
              ]
      end
  | Ok _, Ok None, _ ->
      validation_error_result
        [
          {
            field = "outcome";
            constraint_violated = Required;
            message = "outcome is required";
            expected = Some "string";
            received = None;
          };
        ]
