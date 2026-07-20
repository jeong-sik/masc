(* See .mli. *)

module Board_signal = Keeper_world_observation_board_signal
module Candidate_map = Map.Make (String)
module Id_set = Set.Make (String)
module Sequence_map = Map.Make (Int)

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_candidate_storage_unavailable
  | Partition_membership_conflict
  | Durable_delivery_unavailable

type retryable_failure =
  { kind : retryable_failure_kind
  ; detail : string
  ; failed_at : float
  }

type judgment =
  { verdict : Keeper_board_attention_judgment.t
  ; runtime_id : string
  ; judged_at : float
  }

type delivery =
  | Enqueued_to_keeper_lane
  | Not_relevant

type pending_state = { last_failure : retryable_failure option }

type judged_state =
  { judgment : judgment
  ; last_failure : retryable_failure option
  }

type consumed_state =
  { judgment : judgment
  ; delivery : delivery
  ; consumed_at : float
  }

type status =
  | Pending of pending_state
  | Judged of judged_state
  | Consumed of consumed_state

type candidate =
  { candidate_id : string
  ; keeper_name : string
  ; signal : Board_dispatch.board_signal
  ; judgment_request : Yojson.Safe.t
  ; recorded_at : float
  ; status : status
  }

type record_result =
  | Recorded of candidate
  | Duplicate of candidate
  | Record_error of string

type persistence =
  | Candidate_recorded
  | Candidate_already_present

type drain_report =
  { attempted : int
  ; consumed : int
  ; remaining : int
  }

type compaction_report =
  { rewritten : bool
  ; removed_rows : int
  }

type ledger_measurement =
  { rows : int
  ; bytes : int
  }

type ledger_operation =
  | Append of ledger_measurement
  | Rewrite of ledger_measurement

exception Candidate_unavailable of string

let retryable_failure_kind_to_string = function
  | Runtime_configuration_unavailable -> "runtime_configuration_unavailable"
  | Prompt_contract_unavailable -> "prompt_contract_unavailable"
  | Provider_unavailable -> "provider_unavailable"
  | Response_contract_unavailable -> "response_contract_unavailable"
  | Durable_candidate_storage_unavailable -> "durable_candidate_storage_unavailable"
  | Partition_membership_conflict -> "partition_membership_conflict"
  | Durable_delivery_unavailable -> "durable_delivery_unavailable"
;;

let retryable_failure_kind_of_string = function
  | "runtime_configuration_unavailable" -> Some Runtime_configuration_unavailable
  | "prompt_contract_unavailable" -> Some Prompt_contract_unavailable
  | "provider_unavailable" -> Some Provider_unavailable
  | "response_contract_unavailable" -> Some Response_contract_unavailable
  | "durable_candidate_storage_unavailable" ->
    Some Durable_candidate_storage_unavailable
  | "partition_membership_conflict" -> Some Partition_membership_conflict
  | "durable_delivery_unavailable" -> Some Durable_delivery_unavailable
  | _ -> None
;;

let delivery_to_string = function
  | Enqueued_to_keeper_lane -> "enqueued_to_keeper_lane"
  | Not_relevant -> "not_relevant"
;;

let delivery_of_string = function
  | "enqueued_to_keeper_lane" -> Some Enqueued_to_keeper_lane
  | "not_relevant" -> Some Not_relevant
  | _ -> None
;;

let candidate_dir base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    "board_attention_candidates"
;;

let candidate_path ~base_path ~keeper_name =
  Filename.concat
    (candidate_dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let option_json f = function
  | Some value -> f value
  | None -> `Null
;;

let queue_reaction_to_yojson (reaction : Board_dispatch.board_reaction_change) =
  `Assoc
    [ ( "target_type"
      , `String (Board.reaction_target_type_to_string reaction.target_type) )
    ; "target_id", `String reaction.target_id
    ; "user_id", `String reaction.user_id
    ; "emoji", `String reaction.emoji
    ; "reacted", `Bool reaction.reacted
    ]
;;

let signal_kind_to_string = function
  | Board_dispatch.Board_post_created -> "post_created"
  | Board_dispatch.Board_comment_added -> "comment_added"
  | Board_dispatch.Board_reaction_changed _ -> "reaction_changed"
;;

let signal_to_yojson (signal : Board_dispatch.board_signal) =
  `Assoc
    [ "kind", `String (signal_kind_to_string signal.kind)
    ; "post_id", `String signal.post_id
    ; "author", `String signal.author
    ; "title", `String signal.title
    ; "content", `String signal.content
    ; "hearth", option_json (fun value -> `String value) signal.hearth
    ; "updated_at", option_json (fun value -> `Float value) signal.updated_at
    ; ( "reaction"
      , match signal.kind with
        | Board_dispatch.Board_reaction_changed reaction ->
          queue_reaction_to_yojson reaction
        | Board_dispatch.Board_post_created | Board_dispatch.Board_comment_added ->
          `Null )
    ]
;;

let json_string_list values =
  `List (List.map (fun value -> `String value) values)
;;

let canonical_mention_targets (meta : Keeper_meta_contract.keeper_meta) =
  let targets =
    if meta.mention_targets = [] then [ meta.name ] else meta.mention_targets
  in
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | target :: rest ->
      (match Keeper_identity.Keeper_id.of_string target with
       | Some id -> loop (Keeper_identity.Keeper_id.to_string id :: acc) rest
       | None -> Error "keeper mention target must not be empty")
  in
  loop [] targets
;;

let keeper_context_to_yojson (meta : Keeper_meta_contract.keeper_meta) =
  match canonical_mention_targets meta with
  | Error _ as error -> error
  | Ok mention_targets ->
    Ok
      (`Assoc
         [ "lane_keeper_name", `String meta.name
         ; "agent_name", `String meta.agent_name
         ; "keeper_record_id", option_json Ids.Keeper_id.to_yojson meta.id
         ; ( "keeper_runtime_uid"
           , option_json Keeper_id.uid_to_yojson meta.keeper_id )
         ; "persona", option_json (fun value -> `String value) meta.persona
         ; "instructions", `String meta.instructions
         ; "active_goal_ids", json_string_list meta.active_goal_ids
         ; ( "current_task_id"
           , option_json
               (fun task_id -> `String (Keeper_id.Task_id.to_string task_id))
               meta.current_task_id )
         ; "mention_keeper_ids", json_string_list mention_targets
         ])
;;

let candidate_id_of_signal ~keeper_name signal =
  let identity =
    `Assoc
      [ "keeper_name", `String keeper_name
      ; "signal", signal_to_yojson signal
      ]
    |> Yojson.Safe.to_string
  in
  Digestif.SHA256.(digest_string identity |> to_hex)
;;

let of_board_evidence
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~recorded_at
      ~(signal : Board_dispatch.board_signal)
      ~(post : Board.post)
      ~(comments : Board.comment list)
  =
  match keeper_context_to_yojson meta with
  | Error _ as error -> error
  | Ok keeper_context ->
    let candidate_id = candidate_id_of_signal ~keeper_name:meta.name signal in
    let judgment_request =
      `Assoc
        [ "candidate_id", `String candidate_id
        ; "signal", signal_to_yojson signal
        ; "post", Board.post_to_yojson post
        ; "comments", `List (List.map Board.comment_to_yojson comments)
        ; "keeper_context", keeper_context
        ]
    in
    Ok
      { candidate_id
      ; keeper_name = meta.name
      ; signal
      ; judgment_request
      ; recorded_at
      ; status = Pending { last_failure = None }
      }
;;

let of_board_signal
      ~(meta : Keeper_meta_contract.keeper_meta)
      ~recorded_at
      (signal : Board_dispatch.board_signal)
  =
  match Board_dispatch.get_post ~post_id:signal.post_id with
  | Error error ->
    Board_signal.Unavailable
      { operation = Board_signal.Get_post; post_id = signal.post_id; error }
  | Ok post ->
    (match Board_dispatch.get_comments ~post_id:signal.post_id with
     | Error error ->
       Board_signal.Unavailable
         { operation = Board_signal.Get_comments; post_id = signal.post_id; error }
     | Ok comments ->
       (match of_board_evidence ~meta ~recorded_at ~signal ~post ~comments with
        | Ok candidate -> Board_signal.Available candidate
        | Error detail -> raise (Candidate_unavailable detail)))
;;

let retryable_failure_to_yojson failure =
  `Assoc
    [ "kind", `String (retryable_failure_kind_to_string failure.kind)
    ; "detail", `String failure.detail
    ; "failed_at", `Float failure.failed_at
    ]
;;

let judgment_to_yojson judgment =
  `Assoc
    [ "verdict", Keeper_board_attention_judgment.to_yojson judgment.verdict
    ; "runtime_id", `String judgment.runtime_id
    ; "judged_at", `Float judgment.judged_at
    ]
;;

let status_to_yojson = function
  | Pending pending ->
    `Assoc
      [ "kind", `String "pending"
      ; ( "last_failure"
        , option_json retryable_failure_to_yojson pending.last_failure )
      ]
  | Judged judged ->
    `Assoc
      [ "kind", `String "judged"
      ; "judgment", judgment_to_yojson judged.judgment
      ; ( "last_failure"
        , option_json retryable_failure_to_yojson judged.last_failure )
      ]
  | Consumed consumed ->
    `Assoc
      [ "kind", `String "consumed"
      ; "judgment", judgment_to_yojson consumed.judgment
      ; "delivery", `String (delivery_to_string consumed.delivery)
      ; "consumed_at", `Float consumed.consumed_at
      ]
;;

let candidate_to_json candidate =
  `Assoc
    [ "candidate_id", `String candidate.candidate_id
    ; "keeper_name", `String candidate.keeper_name
    ; "signal", signal_to_yojson candidate.signal
    ; "judgment_request", candidate.judgment_request
    ; "recorded_at", `Float candidate.recorded_at
    ; "status", status_to_yojson candidate.status
    ]
;;

let ( let* ) = Result.bind

let exact_fields ~context expected fields =
  let actual = List.map fst fields in
  if List.length actual = List.length expected
     && List.for_all (fun key -> List.mem key actual) expected
  then Ok ()
  else
    Error
      (Printf.sprintf
         "%s fields must be exactly [%s], got [%s]"
         context
         (String.concat "," expected)
         (String.concat "," actual))
;;

let assoc ~context = function
  | `Assoc fields -> Ok fields
  | _ -> Error (context ^ " must be an object")
;;

let field ~context key fields =
  match List.assoc_opt key fields with
  | Some value -> Ok value
  | None -> Error (Printf.sprintf "%s missing field %s" context key)
;;

let string_json ~context = function
  | `String value -> Ok value
  | _ -> Error (context ^ " must be a string")
;;

let bool_json ~context = function
  | `Bool value -> Ok value
  | _ -> Error (context ^ " must be a boolean")
;;

let float_json ~context = function
  | `Float value -> Ok value
  | `Int value -> Ok (float_of_int value)
  | _ -> Error (context ^ " must be a number")
;;

let optional_json parser = function
  | `Null -> Ok None
  | value ->
    let* parsed = parser value in
    Ok (Some parsed)
;;

let parse_reaction json =
  let context = "candidate.signal.reaction" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "target_type"; "target_id"; "user_id"; "emoji"; "reacted" ]
      fields
  in
  let* target_type_json = field ~context "target_type" fields in
  let* target_type_raw = string_json ~context:(context ^ ".target_type") target_type_json in
  let* target_type =
    match Board.reaction_target_type_of_string_opt target_type_raw with
    | Some target_type -> Ok target_type
    | None -> Error (Printf.sprintf "unknown reaction target type %S" target_type_raw)
  in
  let* target_id_json = field ~context "target_id" fields in
  let* target_id = string_json ~context:(context ^ ".target_id") target_id_json in
  let* user_id_json = field ~context "user_id" fields in
  let* user_id = string_json ~context:(context ^ ".user_id") user_id_json in
  let* emoji_json = field ~context "emoji" fields in
  let* emoji = string_json ~context:(context ^ ".emoji") emoji_json in
  let* reacted_json = field ~context "reacted" fields in
  let* reacted = bool_json ~context:(context ^ ".reacted") reacted_json in
  Ok
    { Board_dispatch.target_type = target_type
    ; target_id
    ; user_id
    ; emoji
    ; reacted
    }
;;

let signal_of_yojson json =
  let context = "candidate.signal" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "kind"
      ; "post_id"
      ; "author"
      ; "title"
      ; "content"
      ; "hearth"
      ; "updated_at"
      ; "reaction"
      ]
      fields
  in
  let* kind_json = field ~context "kind" fields in
  let* kind_raw = string_json ~context:(context ^ ".kind") kind_json in
  let* reaction_json = field ~context "reaction" fields in
  let* kind =
    match kind_raw, reaction_json with
    | "post_created", `Null -> Ok Board_dispatch.Board_post_created
    | "comment_added", `Null -> Ok Board_dispatch.Board_comment_added
    | "reaction_changed", (`Assoc _ as json) ->
      let* reaction = parse_reaction json in
      Ok (Board_dispatch.Board_reaction_changed reaction)
    | "post_created", _ | "comment_added", _ ->
      Error "non-reaction Board signal must carry reaction=null"
    | "reaction_changed", _ -> Error "reaction_changed signal requires reaction object"
    | value, _ -> Error (Printf.sprintf "unknown Board signal kind %S" value)
  in
  let* post_id_json = field ~context "post_id" fields in
  let* post_id = string_json ~context:(context ^ ".post_id") post_id_json in
  let* author_json = field ~context "author" fields in
  let* author = string_json ~context:(context ^ ".author") author_json in
  let* title_json = field ~context "title" fields in
  let* title = string_json ~context:(context ^ ".title") title_json in
  let* content_json = field ~context "content" fields in
  let* content = string_json ~context:(context ^ ".content") content_json in
  let* hearth_json = field ~context "hearth" fields in
  let* hearth =
    optional_json (string_json ~context:(context ^ ".hearth")) hearth_json
  in
  let* updated_at_json = field ~context "updated_at" fields in
  let* updated_at =
    optional_json (float_json ~context:(context ^ ".updated_at")) updated_at_json
  in
  Ok
    { Board_dispatch.kind = kind
    ; post_id
    ; author
    ; title
    ; content
    ; hearth
    ; updated_at
    }
;;

let retryable_failure_of_yojson json =
  let context = "candidate.status.last_failure" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "kind"; "detail"; "failed_at" ] fields in
  let* kind_json = field ~context "kind" fields in
  let* kind_raw = string_json ~context:(context ^ ".kind") kind_json in
  let* kind =
    match retryable_failure_kind_of_string kind_raw with
    | Some kind -> Ok kind
    | None -> Error (Printf.sprintf "unknown retryable failure kind %S" kind_raw)
  in
  let* detail_json = field ~context "detail" fields in
  let* detail = string_json ~context:(context ^ ".detail") detail_json in
  let* failed_at_json = field ~context "failed_at" fields in
  let* failed_at = float_json ~context:(context ^ ".failed_at") failed_at_json in
  Ok { kind; detail; failed_at }
;;

let judgment_of_yojson json =
  let context = "candidate.status.judgment" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "verdict"; "runtime_id"; "judged_at" ] fields in
  let* verdict_json = field ~context "verdict" fields in
  let* verdict = Keeper_board_attention_judgment.of_yojson verdict_json in
  let* runtime_id_json = field ~context "runtime_id" fields in
  let* runtime_id = string_json ~context:(context ^ ".runtime_id") runtime_id_json in
  let* judged_at_json = field ~context "judged_at" fields in
  let* judged_at = float_json ~context:(context ^ ".judged_at") judged_at_json in
  Ok { verdict; runtime_id; judged_at }
;;

let status_of_yojson json =
  let context = "candidate.status" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "pending" ->
    let* () = exact_fields ~context [ "kind"; "last_failure" ] fields in
    let* failure_json = field ~context "last_failure" fields in
    let* last_failure =
      optional_json retryable_failure_of_yojson failure_json
    in
    Ok (Pending { last_failure })
  | "judged" ->
    let* () = exact_fields ~context [ "kind"; "judgment"; "last_failure" ] fields in
    let* judgment_json = field ~context "judgment" fields in
    let* judgment = judgment_of_yojson judgment_json in
    let* failure_json = field ~context "last_failure" fields in
    let* last_failure =
      optional_json retryable_failure_of_yojson failure_json
    in
    Ok (Judged { judgment; last_failure })
  | "consumed" ->
    let* () =
      exact_fields
        ~context
        [ "kind"; "judgment"; "delivery"; "consumed_at" ]
        fields
    in
    let* judgment_json = field ~context "judgment" fields in
    let* judgment = judgment_of_yojson judgment_json in
    let* delivery_json = field ~context "delivery" fields in
    let* delivery_raw = string_json ~context:(context ^ ".delivery") delivery_json in
    let* delivery =
      match delivery_of_string delivery_raw with
      | Some delivery -> Ok delivery
      | None -> Error (Printf.sprintf "unknown Board attention delivery %S" delivery_raw)
    in
    let* consumed_at_json = field ~context "consumed_at" fields in
    let* consumed_at = float_json ~context:(context ^ ".consumed_at") consumed_at_json in
    Ok (Consumed { judgment; delivery; consumed_at })
  | value -> Error (Printf.sprintf "unknown Board attention candidate status %S" value)
;;

let delivery_matches_judgment delivery judgment =
  match judgment.verdict.decision, delivery with
  | Keeper_board_attention_judgment.Relevant, Enqueued_to_keeper_lane
  | Keeper_board_attention_judgment.Not_relevant, Not_relevant -> true
  | Keeper_board_attention_judgment.Relevant, Not_relevant
  | Keeper_board_attention_judgment.Not_relevant, Enqueued_to_keeper_lane -> false
;;

let validate_status_payload candidate =
  match candidate.status with
  | Pending { last_failure = None } -> Ok ()
  | Pending { last_failure = Some failure } ->
    (match failure.kind with
     | Runtime_configuration_unavailable
     | Prompt_contract_unavailable
     | Provider_unavailable
     | Response_contract_unavailable -> Ok ()
     | Durable_candidate_storage_unavailable
     | Partition_membership_conflict
     | Durable_delivery_unavailable ->
       Error
         (Printf.sprintf
            "candidate %s Pending status contains non-judge failure kind %s"
            candidate.candidate_id
            (retryable_failure_kind_to_string failure.kind)))
  | Judged { last_failure = None; _ } -> Ok ()
  | Judged { last_failure = Some failure; _ } ->
    (match failure.kind with
     | Durable_delivery_unavailable -> Ok ()
     | Runtime_configuration_unavailable
     | Prompt_contract_unavailable
     | Provider_unavailable
     | Response_contract_unavailable
     | Durable_candidate_storage_unavailable
     | Partition_membership_conflict ->
       Error
         (Printf.sprintf
            "candidate %s Judged status contains non-delivery failure kind %s"
            candidate.candidate_id
            (retryable_failure_kind_to_string failure.kind)))
  | Consumed { judgment; delivery; _ } ->
    if delivery_matches_judgment delivery judgment
    then Ok ()
    else
      Error
        (Printf.sprintf
           "candidate %s Consumed delivery disagrees with its judgment"
           candidate.candidate_id)
;;

let validate_candidate_invariants candidate =
  let expected_id = candidate_id_of_signal ~keeper_name:candidate.keeper_name candidate.signal in
  let* () =
    if String.equal candidate.candidate_id expected_id
    then Ok ()
    else Error "candidate_id does not match the exact Keeper and Board signal identity"
  in
  let request_context = "board attention candidate.judgment_request" in
  let* request_fields = assoc ~context:request_context candidate.judgment_request in
  let* request_candidate_id_json =
    field ~context:request_context "candidate_id" request_fields
  in
  let* request_candidate_id =
    string_json
      ~context:(request_context ^ ".candidate_id")
      request_candidate_id_json
  in
  let* request_signal_json = field ~context:request_context "signal" request_fields in
  let* request_signal = signal_of_yojson request_signal_json in
  let* keeper_context_json =
    field ~context:request_context "keeper_context" request_fields
  in
  let keeper_context = request_context ^ ".keeper_context" in
  let* keeper_context_fields = assoc ~context:keeper_context keeper_context_json in
  let* lane_keeper_name_json =
    field ~context:keeper_context "lane_keeper_name" keeper_context_fields
  in
  let* lane_keeper_name =
    string_json
      ~context:(keeper_context ^ ".lane_keeper_name")
      lane_keeper_name_json
  in
  let* () =
    if not (String.equal request_candidate_id candidate.candidate_id)
    then Error "judgment_request.candidate_id differs from the outer candidate identity"
    else if request_signal <> candidate.signal
    then Error "judgment_request.signal differs from the outer candidate signal"
    else if not (String.equal lane_keeper_name candidate.keeper_name)
    then Error "judgment_request Keeper identity differs from the outer Keeper identity"
    else Ok ()
  in
  validate_status_payload candidate
;;

let candidate_of_json json =
  let context = "board attention candidate" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "candidate_id"
      ; "keeper_name"
      ; "signal"
      ; "judgment_request"
      ; "recorded_at"
      ; "status"
      ]
      fields
  in
  let* candidate_id_json = field ~context "candidate_id" fields in
  let* candidate_id = string_json ~context:(context ^ ".candidate_id") candidate_id_json in
  let* keeper_name_json = field ~context "keeper_name" fields in
  let* keeper_name = string_json ~context:(context ^ ".keeper_name") keeper_name_json in
  let* signal_json = field ~context "signal" fields in
  let* signal = signal_of_yojson signal_json in
  let* judgment_request = field ~context "judgment_request" fields in
  let* recorded_at_json = field ~context "recorded_at" fields in
  let* recorded_at = float_json ~context:(context ^ ".recorded_at") recorded_at_json in
  let* status_json = field ~context "status" fields in
  let* status = status_of_yojson status_json in
  let candidate =
    { candidate_id; keeper_name; signal; judgment_request; recorded_at; status }
  in
  let* () = validate_candidate_invariants candidate in
  Ok candidate
;;

let parse_rows content =
  let lines = String.split_on_char '\n' content in
  let rec loop line_number acc = function
    | [] -> Ok (List.rev acc)
    | line :: rest ->
      let line = String.trim line in
      if String.equal line ""
      then loop (line_number + 1) acc rest
      else
        (match Yojson.Safe.from_string line with
         | json ->
           (match candidate_of_json json with
            | Ok candidate -> loop (line_number + 1) (candidate :: acc) rest
            | Error detail ->
              Error (Printf.sprintf "candidate ledger line %d: %s" line_number detail))
         | exception Yojson.Json_error detail ->
           Error
             (Printf.sprintf
                "candidate ledger line %d: invalid JSON: %s"
                line_number
                detail))
  in
  loop 1 [] lines
;;

type view =
  { cursor : Fs_compat.Private_jsonl_cursor.t
  ; by_id : candidate Candidate_map.t
  ; by_sequence : string Sequence_map.t
  ; next_sequence : int
  ; keeper_names : Id_set.t
  }

let empty_view cursor =
  { cursor
  ; by_id = Candidate_map.empty
  ; by_sequence = Sequence_map.empty
  ; next_sequence = 0
  ; keeper_names = Id_set.empty
  }
;;

let same_candidate_identity left right =
  String.equal left.candidate_id right.candidate_id
  && String.equal left.keeper_name right.keeper_name
  && left.signal = right.signal
  && left.judgment_request = right.judgment_request
  && Float.equal left.recorded_at right.recorded_at
;;

let same_failure left right =
  left.kind = right.kind && String.equal left.detail right.detail
;;

let legal_status_transition previous next =
  match previous, next with
  | Pending { last_failure = None }, Pending { last_failure = Some _ } -> true
  | ( Pending { last_failure = Some previous }
    , Pending { last_failure = Some next } ) ->
    not (same_failure previous next)
  | Pending _, Judged { last_failure = None; _ } -> true
  | ( Judged { judgment = previous; last_failure = None }
    , Judged { judgment = next; last_failure = Some _ } ) ->
    previous = next
  | ( Judged { judgment = previous_judgment; last_failure = Some previous }
    , Judged { judgment = next_judgment; last_failure = Some next } ) ->
    previous_judgment = next_judgment && not (same_failure previous next)
  | Judged previous, Consumed next -> previous.judgment = next.judgment
  | ( Pending { last_failure = None }
    , Pending { last_failure = None } )
  | ( Pending { last_failure = Some _ }
    , Pending { last_failure = None } )
  | ( Pending _
    , Judged { last_failure = Some _; _ } )
  | ( Judged { last_failure = None; _ }
    , Judged { last_failure = None; _ } )
  | ( Judged { last_failure = Some _; _ }
    , Judged { last_failure = None; _ } )
  | ( Pending _, Consumed _ )
  | ( Judged _, Pending _ )
  | ( Consumed _, (Pending _ | Judged _ | Consumed _) ) -> false
;;

let apply_row view candidate =
  let* () = validate_candidate_invariants candidate in
  match Candidate_map.find_opt candidate.candidate_id view.by_id with
  | None ->
    Ok
      { view with
        by_id = Candidate_map.add candidate.candidate_id candidate view.by_id
      ; by_sequence =
          Sequence_map.add
            view.next_sequence
            candidate.candidate_id
            view.by_sequence
      ; next_sequence = view.next_sequence + 1
      ; keeper_names = Id_set.add candidate.keeper_name view.keeper_names
      }
  | Some previous ->
    if not (same_candidate_identity previous candidate)
    then Error ("candidate changed immutable identity: " ^ candidate.candidate_id)
    else if previous = candidate
    then Ok view
    else if legal_status_transition previous.status candidate.status
    then
      Ok
        { view with
          by_id = Candidate_map.add candidate.candidate_id candidate view.by_id
        }
    else
      Error
        (Printf.sprintf
           "candidate %s has an illegal durable status transition"
           candidate.candidate_id)
;;

let apply_rows view rows =
  List.fold_left
    (fun result candidate ->
       let* view = result in
       apply_row view candidate)
    (Ok view)
    rows
;;

let view_candidates view =
  Sequence_map.bindings view.by_sequence
  |> List.fold_left
       (fun result (_, candidate_id) ->
          let* candidates = result in
          match Candidate_map.find_opt candidate_id view.by_id with
          | Some candidate -> Ok (candidate :: candidates)
          | None -> Error ("candidate index lost identity " ^ candidate_id))
       (Ok [])
  |> Result.map List.rev
;;

type cache_entry =
  { cached : view option Atomic.t
  ; mutation_mutex : Stdlib.Mutex.t
  }

let cache_registry : (string, cache_entry) Hashtbl.t = Hashtbl.create 16
let cache_registry_mutex = Stdlib.Mutex.create ()
let ledger_operation_observer : (ledger_operation -> unit) Atomic.t =
  Atomic.make (fun _ -> ())

let observe_ledger_operation operation =
  (Atomic.get ledger_operation_observer) operation
;;

let cache_entry path =
  Stdlib.Mutex.protect cache_registry_mutex (fun () ->
    match Hashtbl.find_opt cache_registry path with
    | Some entry -> entry
    | None ->
      let entry =
        { cached = Atomic.make None; mutation_mutex = Stdlib.Mutex.create () }
      in
      Hashtbl.add cache_registry path entry;
      entry)
;;

let run_blocking label operation =
  match Eio.Fiber.is_cancelled () with
  | true | false -> Eio_unix.run_in_systhread ~label operation
  | exception Effect.Unhandled _ -> operation ()
;;

let store_error error = Fs_compat.private_jsonl_transaction_error_to_string error

let observe_settlement_warning ~ledger_path error =
  Log.Keeper.error
    "board_attention_candidate: descriptor settlement incomplete ledger=%s detail=%s"
    ledger_path
    (store_error error)
;;

let snapshot_result ~ledger_path result =
  match Fs_compat.private_jsonl_snapshot_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error } ->
    Option.iter (observe_settlement_warning ~ledger_path) settlement_error;
    Ok value
;;

let cursor_result ~ledger_path result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Error error -> Error (store_error error)
  | Ok { value; settlement_error } ->
    Option.iter (observe_settlement_warning ~ledger_path) settlement_error;
    Ok value
;;

let invalidate_cached entry observed =
  (* See cache race contract: a failed CAS means a newer cursor owns the slot. *)
  ignore (Atomic.compare_and_set entry.cached observed None : bool)
;;

let publish_cached entry observed view =
  (* See cache race contract: publication is optional; [view] stays exact. *)
  ignore (Atomic.compare_and_set entry.cached observed (Some view) : bool)
;;

let read_view_blocking path =
  let entry = cache_entry path in
  let observed = Atomic.get entry.cached in
  let after = Option.map (fun view -> view.cursor) observed in
  match
    Fs_compat.read_private_jsonl_durable_locked_result path ~after
    |> snapshot_result ~ledger_path:path
  with
  | Error error ->
    invalidate_cached entry observed;
    Error error
  | Ok snapshot ->
    let* rows = parse_rows snapshot.bytes in
    let base =
      match observed with
      | Some view -> view
      | None -> empty_view snapshot.cursor
    in
    let* view = apply_rows base rows in
    let view = { view with cursor = snapshot.cursor } in
    publish_cached entry observed view;
    Ok view
;;

let read_view path =
  run_blocking "board-attention-candidate-read" (fun () ->
    let entry = cache_entry path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () -> read_view_blocking path))
;;

let validate_keeper_identity ~keeper_name view =
  match Id_set.elements view.keeper_names with
  | [] -> Ok ()
  | [ observed ] when String.equal observed keeper_name -> Ok ()
  | observed ->
    Error
      (Printf.sprintf
         "Board attention candidate ledger identity mismatch expected=%s observed=[%s]"
         keeper_name
         (String.concat "," observed))
;;

let load_candidates_path path =
  let* view = read_view path in
  view_candidates view
;;

let load_candidates ~base_path ~keeper_name =
  let* view = read_view (candidate_path ~base_path ~keeper_name) in
  let* () = validate_keeper_identity ~keeper_name view in
  view_candidates view
;;

let append_row candidate = Yojson.Safe.to_string (candidate_to_json candidate) ^ "\n"

let serialize_candidates candidates =
  String.concat "" (List.map append_row candidates)
;;

let compact_for_process_start ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  run_blocking "board-attention-candidate-process-start-compaction" (fun () ->
    let entry = cache_entry path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      match
        Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
        |> snapshot_result ~ledger_path:path
      with
      | Error error -> Error error
      | Ok snapshot ->
        let* rows = parse_rows snapshot.bytes in
        let* view = apply_rows (empty_view snapshot.cursor) rows in
        let* () = validate_keeper_identity ~keeper_name view in
        let* candidates = view_candidates view in
        let canonical = serialize_candidates candidates in
        let removed = List.length rows - List.length candidates in
        if String.equal canonical snapshot.bytes
        then (
          Atomic.set entry.cached (Some view);
          Ok { rewritten = false; removed_rows = 0 })
        else
          (match
             Fs_compat.rewrite_private_jsonl_durable_locked_at_cursor_result
               path
               ~expected:snapshot.cursor
               canonical
             |> cursor_result ~ledger_path:path
           with
           | Error error -> Error error
           | Ok cursor ->
             Atomic.set entry.cached (Some { view with cursor });
             observe_ledger_operation
               (Rewrite
                  { rows = List.length candidates
                  ; bytes = String.length canonical
                  });
             Ok { rewritten = true; removed_rows = removed })))
;;

type ledger_read_error =
  { ledger_path : string
  ; detail : string
  }

type discovery =
  { keeper_names : string list
  ; read_errors : ledger_read_error list
  }

let discover_keeper_names ~base_path =
  let directory = candidate_dir base_path in
  try
    if not (Sys.file_exists directory)
    then { keeper_names = []; read_errors = [] }
    else if not (Sys.is_directory directory)
    then
      { keeper_names = []
      ; read_errors =
          [ { ledger_path = directory
            ; detail = "Board attention candidate ledger root is not a directory"
            }
          ]
      }
    else
      let paths =
        Sys.readdir directory
        |> Array.to_list
        |> List.filter (fun name -> Filename.check_suffix name ".jsonl")
        |> List.sort String.compare
        |> List.map (Filename.concat directory)
      in
      List.fold_left
        (fun discovery path ->
           match load_candidates_path path with
           | Error detail ->
             { discovery with
               read_errors = { ledger_path = path; detail } :: discovery.read_errors
             }
           | Ok candidates ->
             let ledger_segment =
               path
               |> Filename.basename
               |> fun name -> Filename.chop_suffix name ".jsonl"
             in
             let ledger_names =
               candidates
               |> List.map (fun candidate -> candidate.keeper_name)
               |> List.sort_uniq String.compare
             in
             (match ledger_names with
              | [] -> discovery
              | [ keeper_name ] ->
                let expected_segment =
                  Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name
                in
                if String.equal ledger_segment expected_segment
                then
                  { discovery with keeper_names = keeper_name :: discovery.keeper_names }
                else
                  { discovery with
                    read_errors =
                      { ledger_path = path
                      ; detail =
                          Printf.sprintf
                            "Board attention candidate ledger path identity mismatch keeper=%s expected_segment=%s"
                            keeper_name
                            expected_segment
                      }
                      :: discovery.read_errors
                  }
              | _ ->
                { discovery with
                  read_errors =
                    { ledger_path = path
                    ; detail =
                        Printf.sprintf
                          "Board attention candidate ledger identity collision keepers=[%s]"
                          (String.concat "," ledger_names)
                    }
                    :: discovery.read_errors
                }))
        { keeper_names = []; read_errors = [] }
        paths
      |> fun discovery ->
      { keeper_names = List.sort_uniq String.compare discovery.keeper_names
      ; read_errors = List.rev discovery.read_errors
      }
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | (Sys_error _ | Unix.Unix_error _) as exn ->
    { keeper_names = []
    ; read_errors =
        [ { ledger_path = directory
          ; detail = "Board attention candidate discovery failed: " ^ Printexc.to_string exn
          }
        ]
    }
;;

let update_ledger_many ~base_path ~keeper_name decide =
  let path = candidate_path ~base_path ~keeper_name in
  run_blocking "board-attention-candidate-update" (fun () ->
    let entry = cache_entry path in
    Stdlib.Mutex.protect entry.mutation_mutex (fun () ->
      let* view = read_view_blocking path in
      let* () = validate_keeper_identity ~keeper_name view in
      let* rows, result = decide view in
      match rows with
      | [] -> Ok result
      | _ :: _ ->
        let* updated = apply_rows view rows in
        let bytes = serialize_candidates rows in
        (match
           Fs_compat.append_private_jsonl_durable_locked_at_cursor_result
             path
             ~expected:view.cursor
             bytes
           |> cursor_result ~ledger_path:path
         with
         | Error error -> Error error
         | Ok cursor ->
           Atomic.set entry.cached (Some { updated with cursor });
           observe_ledger_operation
             (Append { rows = List.length rows; bytes = String.length bytes });
           Ok result)))
;;

let update_ledger ~base_path ~keeper_name decide =
  update_ledger_many ~base_path ~keeper_name (fun view ->
    match decide view with
    | Error _ as error -> error
    | Ok (None, result) -> Ok ([], result)
    | Ok (Some candidate, result) -> Ok ([ candidate ], result))
;;

let record ~base_path candidate =
  match validate_candidate_invariants candidate with
  | Error detail -> Record_error detail
  | Ok () ->
    (match
       update_ledger
         ~base_path
         ~keeper_name:candidate.keeper_name
         (fun view ->
            match Candidate_map.find_opt candidate.candidate_id view.by_id with
            | None ->
              (match candidate.status with
               | Pending { last_failure = None } ->
                 Ok (Some candidate, Recorded candidate)
               | Pending { last_failure = Some _ } | Judged _ | Consumed _ ->
                 Error
                   ("new candidate must start Pending without failure evidence: "
                    ^ candidate.candidate_id))
            | Some existing when existing.signal = candidate.signal ->
              Ok (None, Duplicate existing)
            | Some _ ->
              Error
                "candidate identity conflict: the same candidate_id has a different Board signal")
     with
     | Ok result -> result
     | Error detail -> Record_error detail)
;;

let update_candidate_result ~base_path candidate_id keeper_name transition =
  update_ledger ~base_path ~keeper_name (fun view ->
    match Candidate_map.find_opt candidate_id view.by_id with
    | None -> Error (Printf.sprintf "Board attention candidate not found: %s" candidate_id)
    | Some current ->
      (match transition current with
       | Error _ as error -> error
       | Ok None -> Ok (None, current)
       | Ok (Some updated) -> Ok (Some updated, updated)))
;;

let update_candidate_ids_result ~base_path ~keeper_name candidate_ids transition =
  let requested =
    List.fold_left
      (fun result candidate_id ->
         let* ids = result in
         if Id_set.mem candidate_id ids
         then Error ("duplicate candidate in atomic batch: " ^ candidate_id)
         else Ok (Id_set.add candidate_id ids))
      (Ok Id_set.empty)
      candidate_ids
  in
  let* (_requested : Id_set.t) = requested in
  update_ledger_many ~base_path ~keeper_name (fun view ->
    let* updated_rows, selected_in_request_order =
      List.fold_left
        (fun result candidate_id ->
           let* updated_rows, selected = result in
           match Candidate_map.find_opt candidate_id view.by_id with
             | None ->
               Error
                 (Printf.sprintf
                    "Board attention candidate not found for atomic batch: %s"
                    candidate_id)
             | Some current ->
               let* next = transition current in
               Ok
                 ( (if next = current then updated_rows else next :: updated_rows)
                 , next :: selected ))
        (Ok ([], []))
        candidate_ids
    in
    let rows = List.rev updated_rows in
    Ok (rows, List.rev selected_in_request_order))
;;

let update_candidate_batch_result ~base_path ~keeper_name candidates transition =
  let* candidate_ids =
    List.fold_left
      (fun result candidate ->
         let* candidate_ids = result in
         if String.equal candidate.keeper_name keeper_name
         then Ok (candidate.candidate_id :: candidate_ids)
         else
           Error
             (Printf.sprintf
                "atomic batch Keeper identity mismatch expected=%s observed=%s candidate=%s"
                keeper_name
                candidate.keeper_name
                candidate.candidate_id))
      (Ok [])
      candidates
    |> Result.map List.rev
  in
  update_candidate_ids_result
    ~base_path
    ~keeper_name
    candidate_ids
    transition
;;

let update_candidate_batch ~base_path ~keeper_name candidates transition =
  update_candidate_batch_result
    ~base_path
    ~keeper_name
    candidates
    (fun current -> Ok (transition current))
;;

let candidate_with_retryable_failure current failure =
  match current.status with
  | Pending pending ->
    (match pending.last_failure with
     | Some existing when same_failure existing failure -> Ok current
     | Some _ | None ->
       Ok { current with status = Pending { last_failure = Some failure } })
  | Judged judged ->
    (match judged.last_failure with
     | Some existing when same_failure existing failure -> Ok current
     | Some _ | None ->
       Ok
         { current with
           status = Judged { judged with last_failure = Some failure }
         })
  | Consumed _ ->
    Error
      (Printf.sprintf
         "retryable failure cannot be recorded after candidate consumption: %s"
         current.candidate_id)
;;

let record_retryable_failure ~base_path candidate failure =
  update_candidate_result
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       let* updated = candidate_with_retryable_failure current failure in
       Ok (if updated = current then None else Some updated))
;;

let record_judgment ~base_path candidate judgment =
  update_candidate_result
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Pending _ ->
         Ok
           (Some
              { current with
                status = Judged { judgment; last_failure = None }
              })
       | Judged persisted when persisted.judgment = judgment -> Ok None
       | Consumed persisted when persisted.judgment = judgment -> Ok None
       | Judged _ | Consumed _ ->
         Error
           ("judgment conflicts with persisted candidate " ^ current.candidate_id))
;;

let mark_consumed ~base_path candidate judgment delivery =
  update_candidate_result
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Judged persisted when persisted.judgment = judgment ->
         Ok
           (Some
              { current with
                status =
                  Consumed
                    { judgment; delivery; consumed_at = Time_compat.now () }
              })
       | Consumed persisted
         when persisted.judgment = judgment && persisted.delivery = delivery ->
         Ok None
       | Pending _ ->
         Error ("candidate is not durably Judged: " ^ current.candidate_id)
       | Judged _ | Consumed _ ->
         Error
           ("consumption conflicts with persisted candidate " ^ current.candidate_id))
;;

let failure ~kind detail = { kind; detail; failed_at = Time_compat.now () }

let board_attention_stimulus candidate =
  { Keeper_event_queue.post_id = candidate.signal.post_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = candidate.recorded_at
  ; payload =
      Keeper_event_queue.Board_attention
        { candidate_id = candidate.candidate_id
        ; signal = Board_signal.board_stimulus_of_board_signal candidate.signal
        }
  }
;;

let observe_wakeup ~site candidate = function
  | Keeper_registry.Signaled ->
    Log.Keeper.info
      "Board attention owner lane signaled keeper=%s candidate=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      site
  | Keeper_registry.Deferred_unregistered ->
    Log.Keeper.info
      "Board attention candidate durable; owner lane unregistered keeper=%s \
       candidate=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      site
  | Keeper_registry.Deferred_not_running phase ->
    Log.Keeper.info
      "Board attention candidate durable; owner lane not running keeper=%s \
       candidate=%s phase=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      (Keeper_state_machine.phase_to_string phase)
      site
  | Keeper_registry.Deferred_lifecycle denial ->
    Log.Keeper.info
      "Board attention candidate durable; owner lane lifecycle-deferred \
       keeper=%s candidate=%s reason=%s site=%s"
      candidate.keeper_name
      candidate.candidate_id
      (Keeper_lifecycle_admission.autonomous_denial_to_wire denial)
      site
;;

let request_owner_wake ~site ~base_path candidate =
  let outcome =
    Keeper_registry.wakeup_running
      ~intent:Keeper_registry.Reactive_signal
      ~base_path
      candidate.keeper_name
  in
  observe_wakeup ~site candidate outcome;
  outcome
;;

let consume_judged ~base_path candidate (judged : judged_state) =
  match judged.judgment.verdict.decision with
  | Keeper_board_attention_judgment.Not_relevant ->
    mark_consumed ~base_path candidate judged.judgment Not_relevant
  | Keeper_board_attention_judgment.Relevant ->
    let stimulus = board_attention_stimulus candidate in
    (match
       Keeper_registry_event_queue.enqueue_if_missing_durable_result
         ~base_path
         ~event_id:candidate.candidate_id
         candidate.keeper_name
         stimulus
     with
     | Keeper_registry_event_queue.Enqueued
     | Keeper_registry_event_queue.Already_present ->
       let* consumed =
         mark_consumed
           ~base_path
           candidate
           judged.judgment
           Enqueued_to_keeper_lane
       in
       let (_ : Keeper_registry.wakeup_outcome) =
         request_owner_wake ~site:"durable_delivery" ~base_path consumed
       in
       Ok consumed
     | Keeper_registry_event_queue.Identity_conflict detail
     | Keeper_registry_event_queue.Storage_error detail ->
       record_retryable_failure
         ~base_path
         candidate
         (failure ~kind:Durable_delivery_unavailable detail))
;;

let reject_unregistered_tool ~name ~args:_ =
  Tool_result.error
    ~tool_name:name
    ~start_time:(Time_compat.now ())
    "Board attention judgment is a tool-free boundary"
;;

let rec process_with_judge ~base_path ~judge candidate =
  match candidate.status with
  | Consumed _ -> Ok candidate
  | Judged judged -> consume_judged ~base_path candidate judged
  | Pending _ ->
    (match judge candidate with
     | Error failure -> record_retryable_failure ~base_path candidate failure
     | Ok judgment ->
       let* current = record_judgment ~base_path candidate judgment in
       process_with_judge ~base_path ~judge current)
;;

(* ── Batch judgment ───────────────────────────────────── *)

let prompt_name_batch = Keeper_prompt_names.board_attention_judgment_batch

let rec canonical_json = function
  | `Assoc fields ->
    `Assoc
      (fields
       |> List.map (fun (key, value) -> key, canonical_json value)
       |> List.sort (fun (left, _) (right, _) -> String.compare left right))
  | `List values -> `List (List.map canonical_json values)
  | (`Bool _ | `Float _ | `Int _ | `Intlit _ | `Null | `String _) as scalar ->
    scalar
;;

let keeper_context_key candidate =
  match candidate.judgment_request with
  | `Assoc fields ->
    (match List.assoc_opt "keeper_context" fields with
     | Some context -> Ok (Yojson.Safe.to_string (canonical_json context))
     | None -> Error "judgment request lacks keeper_context")
  | _ -> Error "judgment request is not an object"
;;

let select_context_cohort candidates =
  match candidates with
  | [] -> [], []
  | first :: rest ->
    (match keeper_context_key first with
     | Error _ -> [ first ], rest
     | Ok first_key ->
       let rec loop selected deferred = function
         | [] -> List.rev selected, List.rev deferred
         | candidate :: tail ->
           (match keeper_context_key candidate with
            | Ok key when String.equal first_key key ->
              loop (candidate :: selected) deferred tail
            | Ok _ | Error _ -> loop selected (candidate :: deferred) tail)
       in
       loop [ first ] [] rest)
;;

let batch_request_json candidates =
  let keeper_context_of candidate =
    match candidate.judgment_request with
    | `Assoc fields -> List.assoc_opt "keeper_context" fields
    | _ -> None
  in
  let item_of candidate =
    match candidate.judgment_request with
    | `Assoc fields ->
      `Assoc
        (List.filter
           (fun (key, _) -> not (String.equal key "keeper_context"))
           fields)
    | other -> other
  in
  match candidates with
  | [] -> None
  | first :: _ ->
    (match keeper_context_of first with
     | None -> None
     | Some keeper_context ->
       Some
         (`Assoc
            [ "keeper_context", keeper_context
            ; "items", `List (List.map item_of candidates)
            ]))
;;

let build_batch_prompt candidates =
  match batch_request_json candidates with
  | None -> Error "batch request lacks the shared keeper context"
  | Some json ->
    Prompt_registry.render_prompt_template
      prompt_name_batch
      [ "batch_request_json", Yojson.Safe.to_string json ]
;;

let apply_batch_output_schema provider_config =
  Ok
    (Keeper_structured_output_schema.apply_schema_or_prompt_tier
       ~log_label:"keeper Board attention batch judgment output contract"
       Keeper_structured_output_schema.board_attention_judgment_batch_output_schema
       provider_config)
;;

let run_judge_batch ~base_path candidates =
  match candidates with
  | [] -> Ok Candidate_map.empty
  | first :: _ ->
    let runtime_id_result =
      try Ok (Runtime.runtime_id_for_structured_judge ()) with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Error
          (failure
             ~kind:Runtime_configuration_unavailable
             (Printexc.to_string exn))
    in
    (match runtime_id_result with
     | Error _ as error -> error
     | Ok runtime_id ->
       (match build_batch_prompt candidates with
        | Error detail -> Error (failure ~kind:Prompt_contract_unavailable detail)
        | Ok prompt ->
          let provider_result =
            try
              match
                Keeper_turn_driver_wrappers.run_named_with_masc_tools
                  ~runtime_id
                  ~keeper_name:first.keeper_name
                  ~goal:prompt
                  ~base_path
                  ~masc_tools:[]
                  ~dispatch:reject_unregistered_tool
                  ~provider_config_transform:apply_batch_output_schema
                  ()
              with
              | Ok result -> Ok result
              | Error error ->
                Error
                  (failure
                     ~kind:Provider_unavailable
                     (Agent_sdk.Error.to_string error))
            with
            | Eio.Cancel.Cancelled _ as exn -> raise exn
            | exn ->
              Error (failure ~kind:Provider_unavailable (Printexc.to_string exn))
          in
          (match provider_result with
           | Error _ as error -> error
           | Ok result ->
             (match
                Agent_sdk_response.structured_json_of_response
                  ~schema_name:Keeper_board_attention_judgment.batch_schema_name
                  result.response
              with
              | Error detail ->
                Error (failure ~kind:Response_contract_unavailable detail)
              | Ok json ->
                (match Keeper_board_attention_judgment.batch_of_yojson json with
                 | Error detail ->
                   Error (failure ~kind:Response_contract_unavailable detail)
                 | Ok items ->
                   let ids =
                     List.fold_left
                       (fun set candidate -> Id_set.add candidate.candidate_id set)
                       Id_set.empty
                       candidates
                   in
                   (match
                      List.find_opt
                        (fun (item : Keeper_board_attention_judgment.batch_item) ->
                           not (Id_set.mem item.candidate_id ids))
                        items
                    with
                    | Some item ->
                      Error
                        (failure
                           ~kind:Response_contract_unavailable
                           (Printf.sprintf
                              "batch verdict references unknown candidate_id %S"
                              item.candidate_id))
                    | None ->
                      let judged_at = Time_compat.now () in
                      List.fold_left
                        (fun result (item : Keeper_board_attention_judgment.batch_item) ->
                           match result with
                           | Error _ -> result
                           | Ok map ->
                             if Candidate_map.mem item.candidate_id map
                             then
                               Error
                                 (failure
                                    ~kind:Response_contract_unavailable
                                    (Printf.sprintf
                                       "batch verdict duplicates candidate_id %S"
                                       item.candidate_id))
                             else
                               Ok
                                 (Candidate_map.add
                                    item.candidate_id
                                    { verdict = item.verdict
                                    ; runtime_id
                                    ; judged_at
                                    }
                                    map))
                        (Ok Candidate_map.empty)
                        items))))))
;;

(* ── Owner-lane batch drain ───────────────────────────── *)

let record_batch_failures ~base_path candidates failure =
  match candidates with
  | [] -> Ok ()
  | first :: _ ->
    (match
       update_candidate_batch_result
         ~base_path
         ~keeper_name:first.keeper_name
         candidates
         (fun current ->
            match current.status with
            | Consumed _ -> Ok current
            | Pending _ | Judged _ ->
              candidate_with_retryable_failure current failure)
     with
     | Ok _ -> Ok ()
     | Error detail ->
       Error
         (Printf.sprintf
            "Board attention batch failure evidence could not be persisted keeper=%s: %s"
            first.keeper_name
            detail))
;;

let record_batch_judgments ~base_path candidates judgments =
  match candidates with
  | [] -> Ok []
  | first :: _ ->
    update_candidate_batch
      ~base_path
      ~keeper_name:first.keeper_name
      candidates
      (fun current ->
         match current.status with
         | Pending _ ->
           (match Candidate_map.find_opt current.candidate_id judgments with
            | Some judgment ->
              { current with
                status = Judged { judgment; last_failure = None }
              }
            | None -> current)
         | Judged _ | Consumed _ -> current)
;;

let delivery_of_judgment judgment =
  match judgment.verdict.decision with
  | Keeper_board_attention_judgment.Not_relevant -> Not_relevant
  | Keeper_board_attention_judgment.Relevant -> Enqueued_to_keeper_lane
;;

let enqueue_batch_deliveries ~base_path candidates =
  List.fold_left
    (fun result candidate ->
       let* () = result in
       match candidate.status with
       | Judged judged ->
         (match judged.judgment.verdict.decision with
          | Keeper_board_attention_judgment.Not_relevant -> Ok ()
          | Keeper_board_attention_judgment.Relevant ->
            let stimulus = board_attention_stimulus candidate in
            (match
               Keeper_registry_event_queue.enqueue_if_missing_durable_result
                 ~base_path
                 ~event_id:candidate.candidate_id
                 candidate.keeper_name
                 stimulus
             with
             | Keeper_registry_event_queue.Enqueued
             | Keeper_registry_event_queue.Already_present -> Ok ()
             | Keeper_registry_event_queue.Identity_conflict detail
             | Keeper_registry_event_queue.Storage_error detail -> Error detail))
       | Pending _ ->
         Error
           (Printf.sprintf
              "candidate %s was not durably judged before batch delivery"
              candidate.candidate_id)
       | Consumed _ -> Ok ())
    (Ok ())
    candidates
;;

(* The candidate ledger and Keeper event queue are separate durable files, so
   pretending they share one atomic transaction would create an unprovable
   exactly-once boundary. The caller first commits every verdict as [Judged].
   This function then performs idempotent event enqueues and commits every
   [Consumed] row together. A crash between those steps replays from [Judged];
   event identity makes the enqueue replay safe. *)
let consume_judged_batch ~base_path candidates =
  match candidates with
  | [] -> Ok (0, 0)
  | first :: _ ->
    (match enqueue_batch_deliveries ~base_path candidates with
     | Error detail ->
       let delivery_failure = failure ~kind:Durable_delivery_unavailable detail in
       let* () = record_batch_failures ~base_path candidates delivery_failure in
       Ok (0, List.length candidates)
     | Ok () ->
       let consumed_at = Time_compat.now () in
       let* current =
         update_candidate_batch
           ~base_path
           ~keeper_name:first.keeper_name
           candidates
           (fun candidate ->
              match candidate.status with
              | Judged judged ->
                { candidate with
                  status =
                    Consumed
                      { judgment = judged.judgment
                      ; delivery = delivery_of_judgment judged.judgment
                      ; consumed_at
                      }
                }
              | Pending _ | Consumed _ -> candidate)
       in
       let consumed, remaining, wake_candidate =
         List.fold_left
           (fun (consumed, remaining, wake_candidate) candidate ->
              match candidate.status with
              | Consumed { delivery = Enqueued_to_keeper_lane; _ } ->
                ( consumed + 1
                , remaining
                , (match wake_candidate with
                   | Some _ -> wake_candidate
                   | None -> Some candidate) )
              | Consumed { delivery = Not_relevant; _ } ->
                consumed + 1, remaining, wake_candidate
              | Pending _ | Judged _ -> consumed, remaining + 1, wake_candidate)
           (0, 0, None)
           current
       in
       (match wake_candidate with
        | None -> ()
        | Some candidate ->
          let (_ : Keeper_registry.wakeup_outcome) =
            request_owner_wake ~site:"durable_batch_delivery" ~base_path candidate
          in
          ());
       Ok (consumed, remaining))
;;

let validate_batch_coverage batch judgments =
  let requested =
    List.fold_left
      (fun ids candidate -> Id_set.add candidate.candidate_id ids)
      Id_set.empty
      batch
  in
  let returned =
    Candidate_map.fold
      (fun candidate_id _ ids -> Id_set.add candidate_id ids)
      judgments
      Id_set.empty
  in
  if Id_set.equal requested returned
  then Ok ()
  else
    let missing = Id_set.diff requested returned |> Id_set.elements in
    let unknown = Id_set.diff returned requested |> Id_set.elements in
    Error
      (failure
         ~kind:Response_contract_unavailable
         (Printf.sprintf
            "batch verdict identity mismatch missing=[%s] unknown=[%s]"
            (String.concat "," missing)
            (String.concat "," unknown)))
;;

let judge_batch_exact ~base_path batch =
  let* judgments = run_judge_batch ~base_path batch in
  let* () = validate_batch_coverage batch judgments in
  Ok judgments
;;

let apply_completed_judgments ~base_path ~keeper_name completed =
  match completed with
  | [] -> Ok { attempted = 0; consumed = 0; remaining = 0 }
  | _ :: _ ->
    let* expected =
      List.fold_left
        (fun result (candidate_id, judgment) ->
           let* expected = result in
           if Candidate_map.mem candidate_id expected
           then Error ("duplicate completed candidate judgment: " ^ candidate_id)
           else Ok (Candidate_map.add candidate_id judgment expected))
        (Ok Candidate_map.empty)
        completed
    in
    let candidate_ids = List.map fst completed in
    let* judged =
      update_candidate_ids_result
        ~base_path
        ~keeper_name
        candidate_ids
        (fun candidate ->
           match Candidate_map.find_opt candidate.candidate_id expected with
           | None -> Error ("completed judgment lookup failed: " ^ candidate.candidate_id)
           | Some expected_judgment ->
             (match candidate.status with
              | Pending _ ->
                Ok
                  { candidate with
                    status =
                      Judged
                        { judgment = expected_judgment
                        ; last_failure = None
                        }
                  }
              | Judged { judgment; _ } when judgment = expected_judgment ->
                Ok candidate
              | Consumed { judgment; _ } when judgment = expected_judgment ->
                Ok candidate
              | Judged _ | Consumed _ ->
                Error
                  (Printf.sprintf
                     "partition judgment conflicts with persisted candidate %s"
                     candidate.candidate_id)))
    in
    let* consumed, remaining = consume_judged_batch ~base_path judged in
    Ok { attempted = List.length completed; consumed; remaining }
;;

let resume_judged_on_owner_lane ~base_path ~keeper_name =
  let* candidates = load_candidates ~base_path ~keeper_name in
  let judged =
    List.filter
      (fun candidate ->
         match candidate.status with
         | Judged _ -> true
         | Pending _ | Consumed _ -> false)
      candidates
  in
  let* consumed, remaining = consume_judged_batch ~base_path judged in
  Ok { attempted = List.length judged; consumed; remaining }
;;

let drain_pending_with_judge_batch ~base_path ~keeper_name ~judge_batch =
  let* candidates = load_candidates ~base_path ~keeper_name in
  let judged_ready, pending =
    List.fold_left
      (fun (judged_ready, pending) candidate ->
         match candidate.status with
         | Pending _ -> judged_ready, candidate :: pending
         | Judged judged -> (candidate, judged) :: judged_ready, pending
         | Consumed _ -> judged_ready, pending)
      ([], [])
      candidates
  in
  (* Already-judged verdicts deliver without new model calls. *)
  let judged_candidates = List.map fst judged_ready in
  let* judged_consumed, judged_remaining =
    consume_judged_batch ~base_path judged_candidates
  in
  (* The test adapter performs one provider call for the entire first exact
     persisted Keeper context. No candidate-count or size estimate truncates
     the cohort. Other contexts remain durable for a later call. *)
  let batch, deferred = select_context_cohort (List.rev pending) in
  let* batch_report =
    match batch with
    | [] -> Ok { attempted = 0; consumed = 0; remaining = 0 }
    | _ ->
      (match judge_batch batch with
       | Error failure ->
         let* () = record_batch_failures ~base_path batch failure in
         Ok
           { attempted = List.length batch
           ; consumed = 0
           ; remaining = List.length batch + List.length deferred
           }
       | Ok judgments ->
         (match validate_batch_coverage batch judgments with
          | Error failure ->
            let* () = record_batch_failures ~base_path batch failure in
            Ok
              { attempted = List.length batch
              ; consumed = 0
              ; remaining = List.length batch + List.length deferred
              }
          | Ok () ->
            let* judged = record_batch_judgments ~base_path batch judgments in
            let* consumed, remaining = consume_judged_batch ~base_path judged in
            Ok
              { attempted = List.length batch
              ; consumed
              ; remaining = remaining + List.length deferred
              }))
  in
  Ok
    { attempted = batch_report.attempted + judged_consumed + judged_remaining
    ; consumed = batch_report.consumed + judged_consumed
    ; remaining = batch_report.remaining + judged_remaining
    }
;;

module For_testing = struct
  let set_ledger_operation_observer observer =
    Atomic.set ledger_operation_observer observer
  ;;

  let reset_ledger_operation_observer () =
    Atomic.set ledger_operation_observer (fun _ -> ())
  ;;

  let drain_pending_with_judge_batch = drain_pending_with_judge_batch

  let drain_pending_with_judge ~base_path ~keeper_name ~judge =
    let judge_batch candidates =
      let rec fold map = function
        | [] -> Ok map
        | candidate :: rest ->
          (match judge candidate with
           | Ok judgment ->
             fold (Candidate_map.add candidate.candidate_id judgment map) rest
           | Error failure -> Error failure)
      in
      fold Candidate_map.empty candidates
    in
    drain_pending_with_judge_batch ~base_path ~keeper_name ~judge_batch
  ;;
end
;;
