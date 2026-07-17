(* See .mli. *)

module Board_signal = Keeper_world_observation_board_signal
module Candidate_map = Map.Make (String)

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_delivery_unavailable
  | Worker_unavailable

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

type retry_gate =
  { not_before : float
  ; attempts : int
  }

type deferred_resume =
  | Resume_judge
  | Resume_delivery of judgment

type deferred_state =
  { resume : deferred_resume
  ; failure : retryable_failure
  ; retry : retry_gate
  }

type permanent_class =
  | Auth
  | Authorization
  | Payment_required
  | Invalid_request
  | Not_found
  | Context_overflow

type terminal_reason =
  | Judge_rejected of
      { class_ : permanent_class
      ; detail : string
      }
  | Retry_budget_exhausted of
      { last : retryable_failure
      ; attempts : int
      }
  | Expired_backlog of
      { age_s : float
      ; max_age_s : float
      }

type terminal_state =
  { reason : terminal_reason
  ; failed_at : float
  }

type status =
  | Pending of pending_state
  | Judged of judged_state
  | Deferred of deferred_state
  | Consumed of consumed_state
  | Terminal_failed of terminal_state

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

type retry_policy =
  { retry_base_sec : float
  ; retry_max_sec : float
  ; max_attempts : int
  ; max_pending_age_sec : float
  }

type judge_error =
  | Judge_retryable of
      { failure : retryable_failure
      ; retry_after : float option
      }
  | Judge_permanent of
      { class_ : permanent_class
      ; detail : string
      }

exception Candidate_unavailable of string

let prompt_name = Keeper_prompt_names.board_attention_judgment

let retryable_failure_kind_to_string = function
  | Runtime_configuration_unavailable -> "runtime_configuration_unavailable"
  | Prompt_contract_unavailable -> "prompt_contract_unavailable"
  | Provider_unavailable -> "provider_unavailable"
  | Response_contract_unavailable -> "response_contract_unavailable"
  | Durable_delivery_unavailable -> "durable_delivery_unavailable"
  | Worker_unavailable -> "worker_unavailable"
;;

let retryable_failure_kind_of_string = function
  | "runtime_configuration_unavailable" -> Some Runtime_configuration_unavailable
  | "prompt_contract_unavailable" -> Some Prompt_contract_unavailable
  | "provider_unavailable" -> Some Provider_unavailable
  | "response_contract_unavailable" -> Some Response_contract_unavailable
  | "durable_delivery_unavailable" -> Some Durable_delivery_unavailable
  | "worker_unavailable" -> Some Worker_unavailable
  | _ -> None
;;

let permanent_class_to_string = function
  | Auth -> "auth"
  | Authorization -> "authorization"
  | Payment_required -> "payment_required"
  | Invalid_request -> "invalid_request"
  | Not_found -> "not_found"
  | Context_overflow -> "context_overflow"
;;

let permanent_class_of_string = function
  | "auth" -> Some Auth
  | "authorization" -> Some Authorization
  | "payment_required" -> Some Payment_required
  | "invalid_request" -> Some Invalid_request
  | "not_found" -> Some Not_found
  | "context_overflow" -> Some Context_overflow
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

let deferred_resume_to_yojson = function
  | Resume_judge -> `Assoc [ "kind", `String "judge" ]
  | Resume_delivery judgment ->
    `Assoc [ "kind", `String "delivery"; "judgment", judgment_to_yojson judgment ]
;;

let terminal_reason_to_yojson = function
  | Judge_rejected { class_; detail } ->
    `Assoc
      [ "kind", `String "judge_rejected"
      ; "class", `String (permanent_class_to_string class_)
      ; "detail", `String detail
      ]
  | Retry_budget_exhausted { last; attempts } ->
    `Assoc
      [ "kind", `String "retry_budget_exhausted"
      ; "last", retryable_failure_to_yojson last
      ; "attempts", `Int attempts
      ]
  | Expired_backlog { age_s; max_age_s } ->
    `Assoc
      [ "kind", `String "expired_backlog"
      ; "age_s", `Float age_s
      ; "max_age_s", `Float max_age_s
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
  | Deferred deferred ->
    `Assoc
      [ "kind", `String "deferred"
      ; "resume", deferred_resume_to_yojson deferred.resume
      ; "failure", retryable_failure_to_yojson deferred.failure
      ; "not_before", `Float deferred.retry.not_before
      ; "attempts", `Int deferred.retry.attempts
      ]
  | Consumed consumed ->
    `Assoc
      [ "kind", `String "consumed"
      ; "judgment", judgment_to_yojson consumed.judgment
      ; "delivery", `String (delivery_to_string consumed.delivery)
      ; "consumed_at", `Float consumed.consumed_at
      ]
  | Terminal_failed terminal ->
    `Assoc
      [ "kind", `String "terminal_failed"
      ; "reason", terminal_reason_to_yojson terminal.reason
      ; "failed_at", `Float terminal.failed_at
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

let int_json ~context = function
  | `Int value -> Ok value
  | _ -> Error (context ^ " must be an integer")
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

let deferred_resume_of_yojson json =
  let context = "candidate.status.resume" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "judge" ->
    let* () = exact_fields ~context [ "kind" ] fields in
    Ok Resume_judge
  | "delivery" ->
    let* () = exact_fields ~context [ "kind"; "judgment" ] fields in
    let* judgment_json = field ~context "judgment" fields in
    let* judgment = judgment_of_yojson judgment_json in
    Ok (Resume_delivery judgment)
  | value -> Error (Printf.sprintf "unknown Board attention resume kind %S" value)
;;

let terminal_reason_of_yojson json =
  let context = "candidate.status.reason" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "judge_rejected" ->
    let* () = exact_fields ~context [ "kind"; "class"; "detail" ] fields in
    let* class_json = field ~context "class" fields in
    let* class_raw = string_json ~context:(context ^ ".class") class_json in
    let* class_ =
      match permanent_class_of_string class_raw with
      | Some class_ -> Ok class_
      | None -> Error (Printf.sprintf "unknown Board attention permanent class %S" class_raw)
    in
    let* detail_json = field ~context "detail" fields in
    let* detail = string_json ~context:(context ^ ".detail") detail_json in
    Ok (Judge_rejected { class_; detail })
  | "retry_budget_exhausted" ->
    let* () = exact_fields ~context [ "kind"; "last"; "attempts" ] fields in
    let* last_json = field ~context "last" fields in
    let* last = retryable_failure_of_yojson last_json in
    let* attempts_json = field ~context "attempts" fields in
    let* attempts = int_json ~context:(context ^ ".attempts") attempts_json in
    Ok (Retry_budget_exhausted { last; attempts })
  | "expired_backlog" ->
    let* () = exact_fields ~context [ "kind"; "age_s"; "max_age_s" ] fields in
    let* age_s_json = field ~context "age_s" fields in
    let* age_s = float_json ~context:(context ^ ".age_s") age_s_json in
    let* max_age_s_json = field ~context "max_age_s" fields in
    let* max_age_s = float_json ~context:(context ^ ".max_age_s") max_age_s_json in
    Ok (Expired_backlog { age_s; max_age_s })
  | value -> Error (Printf.sprintf "unknown Board attention terminal reason %S" value)
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
  | "deferred" ->
    let* () =
      exact_fields
        ~context
        [ "kind"; "resume"; "failure"; "not_before"; "attempts" ]
        fields
    in
    let* resume_json = field ~context "resume" fields in
    let* resume = deferred_resume_of_yojson resume_json in
    let* failure_json = field ~context "failure" fields in
    let* failure = retryable_failure_of_yojson failure_json in
    let* not_before_json = field ~context "not_before" fields in
    let* not_before = float_json ~context:(context ^ ".not_before") not_before_json in
    let* attempts_json = field ~context "attempts" fields in
    let* attempts = int_json ~context:(context ^ ".attempts") attempts_json in
    Ok (Deferred { resume; failure; retry = { not_before; attempts } })
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
  | "terminal_failed" ->
    let* () = exact_fields ~context [ "kind"; "reason"; "failed_at" ] fields in
    let* reason_json = field ~context "reason" fields in
    let* reason = terminal_reason_of_yojson reason_json in
    let* failed_at_json = field ~context "failed_at" fields in
    let* failed_at = float_json ~context:(context ^ ".failed_at") failed_at_json in
    Ok (Terminal_failed { reason; failed_at })
  | value -> Error (Printf.sprintf "unknown Board attention candidate status %S" value)
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
  let expected_id = candidate_id_of_signal ~keeper_name signal in
  let* () =
    if String.equal candidate_id expected_id
    then Ok ()
    else Error "candidate_id does not match the exact Keeper and Board signal identity"
  in
  let* judgment_request = field ~context "judgment_request" fields in
  let* (_ : (string * Yojson.Safe.t) list) =
    assoc ~context:(context ^ ".judgment_request") judgment_request
  in
  let* recorded_at_json = field ~context "recorded_at" fields in
  let* recorded_at = float_json ~context:(context ^ ".recorded_at") recorded_at_json in
  let* status_json = field ~context "status" fields in
  let* status = status_of_yojson status_json in
  Ok { candidate_id; keeper_name; signal; judgment_request; recorded_at; status }
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

let latest_candidates rows =
  let _, latest =
    List.fold_left
      (fun (index, map) candidate ->
         let first_index =
           match Candidate_map.find_opt candidate.candidate_id map with
           | Some (first_index, _) -> first_index
           | None -> index
         in
         index + 1, Candidate_map.add candidate.candidate_id (first_index, candidate) map)
      (0, Candidate_map.empty)
      rows
  in
  Candidate_map.bindings latest
  |> List.map snd
  |> List.sort (fun (left, _) (right, _) -> Int.compare left right)
  |> List.map snd
;;

let load_candidates_from_content content =
  let* rows = parse_rows content in
  Ok (latest_candidates rows)
;;

let durable_error_to_string error =
  Fs_compat.durable_append_error_to_string error
;;

let read_locked path parse =
  match
    Fs_compat.update_private_file_durable_locked_result path (fun content ->
      None, parse content)
  with
  | Error error -> Error (durable_error_to_string error)
  | Ok result -> result
;;

let load_candidates ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  read_locked path load_candidates_from_content
;;

let append_row candidate = Yojson.Safe.to_string (candidate_to_json candidate) ^ "\n"

let serialize_candidates candidates =
  String.concat "" (List.map append_row candidates)
;;

let update_ledger ~base_path ~keeper_name decide =
  let path = candidate_path ~base_path ~keeper_name in
  (* Compact on write: a committed change rewrites the ledger as the deduped
     latest-per-id set (via [latest_candidates]) instead of appending one row.
     The reader already discards all but the latest row per candidate_id, so the
     older rows are dead weight; appending them grew the file without bound and
     made every update O(n^2) because the durable transaction re-parses the whole
     ledger before writing. Rewriting keeps the file bounded to the number of
     distinct candidates. *)
  match
    Fs_compat.rewrite_private_file_durable_locked_result path (fun content ->
      match load_candidates_from_content content with
      | Error detail -> None, Error detail
      | Ok candidates ->
        (match decide candidates with
         | Error _ as error -> None, error
         | Ok (None, result) -> None, Ok result
         | Ok (Some candidate, result) ->
           let compacted = latest_candidates (candidates @ [ candidate ]) in
           Some (serialize_candidates compacted), Ok result))
  with
  | Error error -> Error error
  | Ok result -> result
;;

let find_candidate candidates candidate_id =
  List.find_opt
    (fun candidate -> String.equal candidate.candidate_id candidate_id)
    candidates
;;

let record ~base_path candidate =
  match
    update_ledger
      ~base_path
      ~keeper_name:candidate.keeper_name
      (fun candidates ->
         match find_candidate candidates candidate.candidate_id with
         | None -> Ok (Some candidate, Recorded candidate)
         | Some existing when existing.signal = candidate.signal ->
           Ok (None, Duplicate existing)
         | Some _ ->
           Error
             "candidate identity conflict: the same candidate_id has a different Board signal")
  with
  | Ok result -> result
  | Error detail -> Record_error detail
;;

let update_candidate ~base_path candidate_id keeper_name transition =
  update_ledger ~base_path ~keeper_name (fun candidates ->
    match find_candidate candidates candidate_id with
    | None -> Error (Printf.sprintf "Board attention candidate not found: %s" candidate_id)
    | Some current ->
      (match transition current with
       | None -> Ok (None, current)
       | Some updated -> Ok (Some updated, updated)))
;;

let record_judgment ~base_path candidate judgment =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Pending _ | Deferred { resume = Resume_judge; _ } ->
         Some
           { current with
             status = Judged { judgment; last_failure = None }
           }
       | Deferred { resume = Resume_delivery _; _ }
       | Judged _ | Consumed _ | Terminal_failed _ -> None)
;;

let mark_consumed ~base_path candidate judgment delivery =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Judged _ | Deferred { resume = Resume_delivery _; _ } ->
         Some
           { current with
             status =
               Consumed
                 { judgment; delivery; consumed_at = Time_compat.now () }
           }
       | Pending _ | Deferred { resume = Resume_judge; _ }
       | Consumed _ | Terminal_failed _ -> None)
;;

let record_deferred ~base_path candidate deferred =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Consumed _ | Terminal_failed _ -> None
       | Pending _ | Judged _ | Deferred _ ->
         Some { current with status = Deferred deferred })
;;

let record_terminal ~base_path candidate terminal =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Consumed _ | Terminal_failed _ -> None
       | Pending _ | Judged _ | Deferred _ ->
         Some { current with status = Terminal_failed terminal })
;;

let failure ~kind detail = { kind; detail; failed_at = Time_compat.now () }
let judge_retryable ~kind ?retry_after detail = Judge_retryable { failure = failure ~kind detail; retry_after }

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

(* Deterministic jitter derived from [candidate_id], not [Random]: a replayed
   ledger (audit, test) always derives the identical [not_before], and no
   process-global RNG state is shared across domains. Bounded to a fraction of
   the computed backoff so many candidates deferred at the same instant do not
   all become due at exactly the same tick (thundering-herd on the judge
   endpoint). *)
let jitter_fraction = 0.1

let jitter_seconds ~candidate_id ~bound =
  if bound <= 0.0
  then 0.0
  else (
    let raw = Digestif.SHA256.(to_raw_string (digest_string candidate_id)) in
    let sample =
      String.fold_left
        (fun acc c -> (acc * 256 + Char.code c) land max_int)
        0
        (String.sub raw 0 7)
    in
    bound *. (float_of_int sample /. float_of_int max_int))
;;

let next_not_before ~now ~attempts ~retry_after ~policy ~candidate_id =
  match retry_after with
  | Some hint ->
    (* Provider-supplied retry-after wins over our own schedule. *)
    now +. Float.max 0.0 hint
  | None ->
    let backoff = policy.retry_base_sec *. (2. ** float_of_int attempts) in
    let capped = Float.min backoff policy.retry_max_sec in
    let jitter = jitter_seconds ~candidate_id ~bound:(capped *. jitter_fraction) in
    now +. capped +. jitter
;;

let warn_terminal candidate ~reason detail =
  Log.Keeper.warn
    "Board attention candidate terminalized keeper=%s candidate=%s reason=%s: %s"
    candidate.keeper_name
    candidate.candidate_id
    reason
    detail
;;

(* Shared by judge-attempt and delivery-attempt failures: both defer with the
   same capped-exponential/jitter schedule and terminalize on the same budget.
   [retry_after] is [Some _] only for judge failures with a provider hint
   (delivery failures are local storage errors with no such hint). *)
let retry_or_terminalize ~base_path ~now ~policy candidate ~resume ~current_attempts ~retry_after failure =
  let new_attempts = current_attempts + 1 in
  if new_attempts < policy.max_attempts
  then (
    let not_before =
      next_not_before
        ~now
        ~attempts:current_attempts
        ~retry_after
        ~policy
        ~candidate_id:candidate.candidate_id
    in
    record_deferred
      ~base_path
      candidate
      { resume; failure; retry = { not_before; attempts = new_attempts } })
  else (
    warn_terminal candidate ~reason:"retry_budget_exhausted" failure.detail;
    record_terminal
      ~base_path
      candidate
      { reason = Retry_budget_exhausted { last = failure; attempts = new_attempts }
      ; failed_at = now
      })
;;

let apply_judge_outcome ~base_path ~now ~policy candidate ~current_attempts = function
  | Judge_permanent { class_; detail } ->
    warn_terminal candidate ~reason:"judge_rejected" detail;
    record_terminal
      ~base_path
      candidate
      { reason = Judge_rejected { class_; detail }; failed_at = now }
  | Judge_retryable { failure; retry_after } ->
    retry_or_terminalize
      ~base_path
      ~now
      ~policy
      candidate
      ~resume:Resume_judge
      ~current_attempts
      ~retry_after
      failure
;;

let apply_delivery_outcome ~base_path ~now ~policy candidate ~current_attempts judgment
  : Keeper_registry_event_queue.enqueue_if_missing_durable_result -> (candidate, string) result
  = function
  | Keeper_registry_event_queue.Enqueued | Keeper_registry_event_queue.Already_present ->
    let* consumed = mark_consumed ~base_path candidate judgment Enqueued_to_keeper_lane in
    let (_ : Keeper_registry.wakeup_outcome) =
      Keeper_registry.wakeup
        ~intent:Keeper_registry.Reactive_signal
        ~base_path
        candidate.keeper_name
    in
    Ok consumed
  | Keeper_registry_event_queue.Identity_conflict detail
  | Keeper_registry_event_queue.Storage_error detail ->
    retry_or_terminalize
      ~base_path
      ~now
      ~policy
      candidate
      ~resume:(Resume_delivery judgment)
      ~current_attempts
      ~retry_after:None
      (failure ~kind:Durable_delivery_unavailable detail)
;;

let delivery_current_attempts candidate =
  match candidate.status with
  | Deferred { resume = Resume_delivery _; retry; _ } -> retry.attempts
  | Pending _ | Judged _ | Deferred { resume = Resume_judge; _ }
  | Consumed _ | Terminal_failed _ -> 0
;;

let attempt_delivery ~base_path ~now ~policy candidate judgment =
  match judgment.verdict.decision with
  | Keeper_board_attention_judgment.Not_relevant ->
    mark_consumed ~base_path candidate judgment Not_relevant
  | Keeper_board_attention_judgment.Relevant ->
    let stimulus = board_attention_stimulus candidate in
    let current_attempts = delivery_current_attempts candidate in
    let outcome =
      Keeper_registry_event_queue.enqueue_if_missing_durable_result
        ~base_path
        ~event_id:candidate.candidate_id
        candidate.keeper_name
        stimulus
    in
    apply_delivery_outcome ~base_path ~now ~policy candidate ~current_attempts judgment outcome
;;

let age_seconds candidate ~now = now -. candidate.recorded_at

let expire ~base_path ~now ~policy candidate =
  let age_s = age_seconds candidate ~now in
  warn_terminal candidate ~reason:"expired_backlog" (Printf.sprintf "age_s=%.1f" age_s);
  record_terminal
    ~base_path
    candidate
    { reason = Expired_backlog { age_s; max_age_s = policy.max_pending_age_sec }
    ; failed_at = now
    }
;;

let terminalize_expired ~base_path ~now ~policy candidate =
  match candidate.status with
  | Pending _ | Deferred _ ->
    if age_seconds candidate ~now > policy.max_pending_age_sec
    then expire ~base_path ~now ~policy candidate
    else Ok candidate
  | Judged _ | Consumed _ | Terminal_failed _ -> Ok candidate
;;

let is_eligible_for_dispatch ~now candidate =
  match candidate.status with
  | Pending _ | Judged _ -> true
  | Deferred { retry; _ } -> now >= retry.not_before
  | Consumed _ | Terminal_failed _ -> false
;;

let rec process_with_judge ~base_path ~now ~policy ~judge candidate =
  let now_value = now () in
  match candidate.status with
  | Consumed _ | Terminal_failed _ -> Ok candidate
  | Judged judged -> attempt_delivery ~base_path ~now:now_value ~policy candidate judged.judgment
  | Pending _ ->
    if age_seconds candidate ~now:now_value > policy.max_pending_age_sec
    then expire ~base_path ~now:now_value ~policy candidate
    else (
      match judge candidate with
      | Error outcome ->
        apply_judge_outcome ~base_path ~now:now_value ~policy candidate ~current_attempts:0 outcome
      | Ok judgment ->
        let* current = record_judgment ~base_path candidate judgment in
        process_with_judge ~base_path ~now ~policy ~judge current)
  | Deferred deferred ->
    if age_seconds candidate ~now:now_value > policy.max_pending_age_sec
    then expire ~base_path ~now:now_value ~policy candidate
    else if now_value < deferred.retry.not_before
    then Ok candidate
    else (
      match deferred.resume with
      | Resume_judge ->
        (match judge candidate with
         | Error outcome ->
           apply_judge_outcome
             ~base_path
             ~now:now_value
             ~policy
             candidate
             ~current_attempts:deferred.retry.attempts
             outcome
         | Ok judgment ->
           let* current = record_judgment ~base_path candidate judgment in
           process_with_judge ~base_path ~now ~policy ~judge current)
      | Resume_delivery judgment ->
        attempt_delivery ~base_path ~now:now_value ~policy candidate judgment)
;;

let classify_judge_sdk_error (error : Agent_sdk.Error.sdk_error) : judge_error =
  let detail = Agent_sdk.Error.to_string error in
  match Agent_sdk.Error_domain.of_sdk_error error with
  (* Provider gave an explicit backoff window; honor it over our own schedule. *)
  | `Rate_limited retry_after -> judge_retryable ~kind:Provider_unavailable ?retry_after detail
  (* Transient provider/transport failures with no explicit retry hint. *)
  | `Overloaded
  | `Server_error _
  | `Network_error _
  | `Provider_timeout _
  | `Streaming_timeout _ -> judge_retryable ~kind:Provider_unavailable detail
  (* Credential, authorization, billing, and request-shape rejections repeat
     identically without operator intervention: never worth retrying. *)
  | `Auth_error _ -> Judge_permanent { class_ = Auth; detail }
  | `Authorization_error _ -> Judge_permanent { class_ = Authorization; detail }
  | `Payment_required _ -> Judge_permanent { class_ = Payment_required; detail }
  | `Invalid_request _ -> Judge_permanent { class_ = Invalid_request; detail }
  | `Not_found _ -> Judge_permanent { class_ = Not_found; detail }
  | `Context_overflow _ -> Judge_permanent { class_ = Context_overflow; detail }
  (* Non-provider SDK domains surface while attempting the same provider call
     (tool dispatch, guardrails, config resolution, MCP transport, (de)serialization,
     local IO, orchestration, or an unclassified internal fault). They are
     environment/operator-fixable, not a judge verdict on the candidate, so
     they get the same attempt budget as a provider hiccup instead of a
     permanent rejection. *)
  | `Tool_exec_failed _
  | `Tool_timeout _
  | `Guardrail_violation _
  | `Tripwire_violation _
  | `Input_required _
  | `Hook_execution_failed _
  | `Unrecognized_stop_reason _
  | `Missing_env_var _
  | `Unsupported_provider _
  | `Invalid_config _
  | `Sensitive_value_in_config _
  | `Mcp_server_start_failed _
  | `Mcp_init_failed _
  | `Mcp_tool_list_failed _
  | `Mcp_tool_call_failed _
  | `Mcp_http_failed _
  | `Serialization _
  | `Io _
  | `Orchestration _
  | `Internal _ -> judge_retryable ~kind:Provider_unavailable detail
;;

let build_prompt candidate =
  Prompt_registry.render_prompt_template
    prompt_name
    [ "judgment_request_json", Yojson.Safe.to_string candidate.judgment_request ]
;;

let apply_output_schema provider_config =
  Ok
    (Keeper_structured_output_schema.apply_schema_or_prompt_tier
       ~log_label:"keeper Board attention judgment output contract"
       Keeper_structured_output_schema.board_attention_judgment_output_schema
       provider_config)
;;

let reject_unregistered_tool ~name ~args:_ =
  Tool_result.error
    ~tool_name:name
    ~start_time:(Time_compat.now ())
    "Board attention judgment is a tool-free boundary"
;;

let run_judge ~base_path candidate =
  let runtime_id_result =
    try Ok (Runtime.runtime_id_for_structured_judge ()) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (judge_retryable
           ~kind:Runtime_configuration_unavailable
           (Printexc.to_string exn))
  in
  match runtime_id_result with
  | Error _ as error -> error
  | Ok runtime_id ->
    (match build_prompt candidate with
     | Error detail -> Error (judge_retryable ~kind:Prompt_contract_unavailable detail)
     | Ok prompt ->
       let provider_result =
         try
           match
             Keeper_turn_driver_wrappers.run_named_with_masc_tools
               ~runtime_id
               ~keeper_name:candidate.keeper_name
               ~goal:prompt
               ~base_path
               ~masc_tools:[]
               ~dispatch:reject_unregistered_tool
               ~provider_config_transform:apply_output_schema
               ()
           with
           | Ok result -> Ok result
           | Error error -> Error (classify_judge_sdk_error error)
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Error (judge_retryable ~kind:Provider_unavailable (Printexc.to_string exn))
       in
       (match provider_result with
        | Error _ as error -> error
        | Ok result ->
          (match
             Agent_sdk_response.structured_json_of_response
               ~schema_name:Keeper_board_attention_judgment.schema_name
               result.response
           with
           | Error detail ->
             Error (judge_retryable ~kind:Response_contract_unavailable detail)
           | Ok json ->
             (match Keeper_board_attention_judgment.of_yojson json with
              | Error detail ->
                Error (judge_retryable ~kind:Response_contract_unavailable detail)
              | Ok verdict ->
                Ok { verdict; runtime_id; judged_at = Time_compat.now () }))))
;;
