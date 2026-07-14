(* See .mli. *)

module Board_signal = Keeper_world_observation_board_signal
module Candidate_map = Map.Make (String)
module Active_set = Set.Make (String)

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
         ; "goal", `String meta.goal
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

let update_ledger ~base_path ~keeper_name decide =
  let path = candidate_path ~base_path ~keeper_name in
  match
    Fs_compat.update_private_file_durable_locked_result path (fun content ->
      match load_candidates_from_content content with
      | Error detail -> None, Error detail
      | Ok candidates ->
        (match decide candidates with
         | Error _ as error -> None, error
         | Ok (None, result) -> None, Ok result
         | Ok (Some candidate, result) -> Some (append_row candidate), Ok result))
  with
  | Error error -> Error (durable_error_to_string error)
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

let same_failure left right =
  left.kind = right.kind && String.equal left.detail right.detail
;;

let record_retryable_failure ~base_path candidate failure =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Pending pending ->
         (match pending.last_failure with
          | Some existing when same_failure existing failure -> None
          | Some _ | None ->
            Some { current with status = Pending { last_failure = Some failure } })
       | Judged judged ->
         (match judged.last_failure with
          | Some existing when same_failure existing failure -> None
          | Some _ | None ->
            Some
              { current with
                status = Judged { judged with last_failure = Some failure }
              })
       | Consumed _ -> None)
;;

let record_judgment ~base_path candidate judgment =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Pending _ ->
         Some
           { current with
             status = Judged { judgment; last_failure = None }
           }
       | Judged _ | Consumed _ -> None)
;;

let mark_consumed ~base_path candidate judgment delivery =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Judged _ ->
         Some
           { current with
             status =
               Consumed
                 { judgment; delivery; consumed_at = Time_compat.now () }
           }
       | Pending _ | Consumed _ -> None)
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
         Keeper_registry.wakeup
           ~intent:Keeper_registry.Reactive_signal
           ~base_path
           candidate.keeper_name
       in
       Ok consumed
     | Keeper_registry_event_queue.Identity_conflict detail
     | Keeper_registry_event_queue.Storage_error detail ->
       record_retryable_failure
         ~base_path
         candidate
         (failure ~kind:Durable_delivery_unavailable detail))
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

let run_judge candidate =
  let runtime_id_result =
    try Ok (Runtime.runtime_id_for_structured_judge ()) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (failure
           ~kind:Runtime_configuration_unavailable
           (Printexc.to_string exn))
  in
  match runtime_id_result with
  | Error _ as error -> error
  | Ok runtime_id ->
    (match build_prompt candidate with
     | Error detail -> Error (failure ~kind:Prompt_contract_unavailable detail)
     | Ok prompt ->
       let provider_result =
         try
           match
             Keeper_turn_driver_wrappers.run_named_with_masc_tools
               ~runtime_id
               ~keeper_name:candidate.keeper_name
               ~goal:prompt
               ~masc_tools:[]
               ~dispatch:reject_unregistered_tool
               ~provider_config_transform:apply_output_schema
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
           Error
             (failure ~kind:Provider_unavailable (Printexc.to_string exn))
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
             Error (failure ~kind:Response_contract_unavailable detail)
           | Ok json ->
             (match Keeper_board_attention_judgment.of_yojson json with
              | Error detail ->
                Error (failure ~kind:Response_contract_unavailable detail)
              | Ok verdict ->
                Ok { verdict; runtime_id; judged_at = Time_compat.now () }))))
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

let process ~base_path candidate =
  process_with_judge ~base_path ~judge:run_judge candidate
;;

let active_candidates = Atomic.make Active_set.empty

let active_key ~base_path candidate =
  String.concat "\031" [ base_path; candidate.keeper_name; candidate.candidate_id ]
;;

let rec claim_active key =
  let current = Atomic.get active_candidates in
  if Active_set.mem key current
  then false
  else if Atomic.compare_and_set active_candidates current (Active_set.add key current)
  then true
  else claim_active key
;;

let rec release_active key =
  let current = Atomic.get active_candidates in
  if not (Active_set.mem key current)
  then ()
  else if
    Atomic.compare_and_set active_candidates current (Active_set.remove key current)
  then ()
  else release_active key
;;

let observe_worker_failure ~base_path candidate kind detail =
  Log.Keeper.warn
    "Board attention worker deferred keeper=%s candidate=%s: %s"
    candidate.keeper_name
    candidate.candidate_id
    detail;
  match
    record_retryable_failure
      ~base_path
      candidate
      (failure ~kind detail)
  with
  | Ok _ -> ()
  | Error storage_detail ->
    Log.Keeper.error
      "Board attention worker failure could not be persisted keeper=%s candidate=%s: %s"
      candidate.keeper_name
      candidate.candidate_id
      storage_detail
;;

let start_async ~base_path candidate =
  match candidate.status with
  | Consumed _ -> false
  | Pending _ | Judged _ ->
    let key = active_key ~base_path candidate in
    if not (claim_active key)
    then false
    else (
      match Eio_context.get_root_switch_opt () with
      | None ->
        release_active key;
        observe_worker_failure
          ~base_path
          candidate
          Worker_unavailable
          "server root switch is not installed";
        false
      | Some sw ->
        (try
           Eio.Fiber.fork ~sw (fun () ->
             Fun.protect
               ~finally:(fun () -> release_active key)
               (fun () ->
                  try
                    match process ~base_path candidate with
                    | Ok _ -> ()
                    | Error detail ->
                      observe_worker_failure
                        ~base_path
                        candidate
                        Worker_unavailable
                        detail
                  with
                  | Eio.Cancel.Cancelled _ as exn -> raise exn
                  | exn ->
                    observe_worker_failure
                      ~base_path
                      candidate
                      Worker_unavailable
                      (Printexc.to_string exn)));
           true
         with
         | Eio.Cancel.Cancelled _ as exn ->
           release_active key;
           raise exn
         | exn ->
           release_active key;
           observe_worker_failure
             ~base_path
             candidate
             Worker_unavailable
             (Printexc.to_string exn);
           false))
;;

let record_and_start ~base_path candidate =
  match record ~base_path candidate with
  | Record_error detail -> Error detail
  | Recorded persisted | Duplicate persisted ->
    (* The durable candidate is the authority. Worker startup is best-effort
       scheduling only; [start_async] records every startup failure itself. *)
    let (_worker_started : bool) = start_async ~base_path persisted in
    Ok persisted
;;

let resume_pending ~base_path ~keeper_name =
  let* candidates = load_candidates ~base_path ~keeper_name in
  let started =
    List.fold_left
      (fun count candidate ->
         if start_async ~base_path candidate then count + 1 else count)
      0
      candidates
  in
  Ok started
;;
