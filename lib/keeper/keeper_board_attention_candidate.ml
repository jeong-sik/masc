(* See .mli. *)

module Board_signal = Keeper_world_observation_board_signal
module Candidate_map = Map.Make (String)
type delivery_failure_kind =
  | Durable_delivery_unavailable

type delivery_failure =
  { kind : delivery_failure_kind
  ; detail : string
  ; failed_at : float
  }

type judgment =
  { verdict : Keeper_board_attention_judgment.t
  ; slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  ; judged_at : float
  }

type delivery =
  | Enqueued_to_keeper_lane
  | Not_relevant

type pending_state = { last_delivery_failure : delivery_failure option }

type judged_state =
  { judgment : judgment
  ; last_delivery_failure : delivery_failure option
  }

type consumed_state =
  { judgment : judgment
  ; delivery : delivery
  ; consumed_at : float
  }

type resumable_status =
  | Resumable_pending of pending_state
  | Resumable_judged of judged_state
  | Resumable_consumed of consumed_state

type quarantine_failure_category =
  | Candidate_membership_conflict
  | Durable_partition_invariant
  | Exact_setup_unavailable
  | Exact_flow_replayed
  | Exact_execution_terminal
  | Domain_output_invalid
  | Execution_provenance_mismatch
  | Unexpected_worker_failure
  | Exact_execution_quarantined

type attempt_provenance =
  { slot_id : string
  ; call_id : string
  ; plan_fingerprint : string
  ; request_body_sha256 : string
  }

type quarantine =
  { quarantine_id : string
  ; partition_id : string
  ; failure_category : quarantine_failure_category
  ; attempt_provenance : attempt_provenance option
  ; quarantined_at : float
  ; prior_status : resumable_status
  }

type quarantine_phase =
  | Quarantined
  | Requeue_requested of { requested_at : float }
  | Requeued of { requeued_at : float }

type quarantine_state =
  { quarantine : quarantine
  ; phase : quarantine_phase
  }

type status =
  | Pending of pending_state
  | Judged of judged_state
  | Consumed of consumed_state
  | Quarantine of quarantine_state

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

type wake_decision =
  | Judgment_worker_requested of Keeper_board_attention_worker_wake.wake_result
  | Wake_not_required

type record_acceptance =
  { candidate : candidate
  ; persistence : persistence
  ; wake : wake_decision
  }

exception Candidate_unavailable of string

let schema_version = 2

let quarantine_failure_category_to_string = function
  | Candidate_membership_conflict -> "candidate_membership_conflict"
  | Durable_partition_invariant -> "durable_partition_invariant"
  | Exact_setup_unavailable -> "exact_setup_unavailable"
  | Exact_flow_replayed -> "exact_flow_replayed"
  | Exact_execution_terminal -> "exact_execution_terminal"
  | Domain_output_invalid -> "domain_output_invalid"
  | Execution_provenance_mismatch -> "execution_provenance_mismatch"
  | Unexpected_worker_failure -> "unexpected_worker_failure"
  | Exact_execution_quarantined -> "exact_execution_quarantined"
;;

let quarantine_failure_category_of_string = function
  | "candidate_membership_conflict" -> Some Candidate_membership_conflict
  | "durable_partition_invariant" -> Some Durable_partition_invariant
  | "exact_setup_unavailable" -> Some Exact_setup_unavailable
  | "exact_flow_replayed" -> Some Exact_flow_replayed
  | "exact_execution_terminal" -> Some Exact_execution_terminal
  | "domain_output_invalid" -> Some Domain_output_invalid
  | "execution_provenance_mismatch" -> Some Execution_provenance_mismatch
  | "unexpected_worker_failure" -> Some Unexpected_worker_failure
  | "exact_execution_quarantined" -> Some Exact_execution_quarantined
  | _ -> None
;;

let resumable_status = function
  | Pending pending -> Some (Resumable_pending pending)
  | Judged judged -> Some (Resumable_judged judged)
  | Consumed consumed -> Some (Resumable_consumed consumed)
  | Quarantine { quarantine; phase = Requeued _ } -> Some quarantine.prior_status
  | Quarantine { phase = (Quarantined | Requeue_requested _); _ } -> None
;;

let quarantine_state = function
  | Quarantine state -> Some state
  | Pending _ | Judged _ | Consumed _ -> None
;;

let status_of_resumable = function
  | Resumable_pending pending -> Pending pending
  | Resumable_judged judged -> Judged judged
  | Resumable_consumed consumed -> Consumed consumed
;;

let delivery_failure_kind_to_string = function
  | Durable_delivery_unavailable -> "durable_delivery_unavailable"
;;

let delivery_failure_kind_of_string = function
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
      ; status = Pending { last_delivery_failure = None }
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

let delivery_failure_to_yojson failure =
  `Assoc
    [ "kind", `String (delivery_failure_kind_to_string failure.kind)
    ; "detail", `String failure.detail
    ; "failed_at", `Float failure.failed_at
    ]
;;

let judgment_to_yojson judgment =
  `Assoc
    [ "verdict", Keeper_board_attention_judgment.to_yojson judgment.verdict
    ; "slot_id", `String judgment.slot_id
    ; "call_id", `String judgment.call_id
    ; "plan_fingerprint", `String judgment.plan_fingerprint
    ; "request_body_sha256", `String judgment.request_body_sha256
    ; "judged_at", `Float judgment.judged_at
    ]
;;

let resumable_status_to_yojson = function
  | Resumable_pending pending ->
    `Assoc
      [ "kind", `String "pending"
      ; ( "last_delivery_failure"
        , option_json
            delivery_failure_to_yojson
            pending.last_delivery_failure )
      ]
  | Resumable_judged judged ->
    `Assoc
      [ "kind", `String "judged"
      ; "judgment", judgment_to_yojson judged.judgment
      ; ( "last_delivery_failure"
        , option_json
            delivery_failure_to_yojson
            judged.last_delivery_failure )
      ]
  | Resumable_consumed consumed ->
    `Assoc
      [ "kind", `String "consumed"
      ; "judgment", judgment_to_yojson consumed.judgment
      ; "delivery", `String (delivery_to_string consumed.delivery)
      ; "consumed_at", `Float consumed.consumed_at
      ]
;;

let attempt_provenance_to_yojson provenance =
  `Assoc
    [ "slot_id", `String provenance.slot_id
    ; "call_id", `String provenance.call_id
    ; "plan_fingerprint", `String provenance.plan_fingerprint
    ; "request_body_sha256", `String provenance.request_body_sha256
    ]
;;

let quarantine_to_yojson quarantine =
  `Assoc
    [ "quarantine_id", `String quarantine.quarantine_id
    ; "partition_id", `String quarantine.partition_id
    ; ( "failure_category"
      , `String
          (quarantine_failure_category_to_string quarantine.failure_category) )
    ; ( "attempt_provenance"
      , option_json attempt_provenance_to_yojson quarantine.attempt_provenance )
    ; "quarantined_at", `Float quarantine.quarantined_at
    ; "prior_status", resumable_status_to_yojson quarantine.prior_status
    ]
;;

let status_to_yojson = function
  | Pending pending -> resumable_status_to_yojson (Resumable_pending pending)
  | Judged judged -> resumable_status_to_yojson (Resumable_judged judged)
  | Consumed consumed -> resumable_status_to_yojson (Resumable_consumed consumed)
  | Quarantine { quarantine; phase = Quarantined } ->
    `Assoc
      [ "kind", `String "quarantined"
      ; "quarantine", quarantine_to_yojson quarantine
      ]
  | Quarantine { quarantine; phase = Requeue_requested { requested_at } } ->
    `Assoc
      [ "kind", `String "requeue_requested"
      ; "quarantine", quarantine_to_yojson quarantine
      ; "requested_at", `Float requested_at
      ]
  | Quarantine { quarantine; phase = Requeued { requeued_at } } ->
    `Assoc
      [ "kind", `String "requeued"
      ; "quarantine", quarantine_to_yojson quarantine
      ; "requeued_at", `Float requeued_at
      ]
;;

let candidate_to_json candidate =
  `Assoc
    [ "schema_version", `Int schema_version
    ; "candidate_id", `String candidate.candidate_id
    ; "keeper_name", `String candidate.keeper_name
    ; "signal", signal_to_yojson candidate.signal
    ; "judgment_request", candidate.judgment_request
    ; "recorded_at", `Float candidate.recorded_at
    ; "status", status_to_yojson candidate.status
    ]
;;

let ( let* ) = Result.bind

module Context_key = struct
  type t = Yojson.Safe.t

  let rec canonicalize ~context = function
    | `Assoc fields ->
      let* canonical_fields =
        List.fold_left
          (fun result (key, value) ->
             let* fields = result in
             let* value = canonicalize ~context:(context ^ "." ^ key) value in
             Ok ((key, value) :: fields))
          (Ok [])
          fields
        |> Result.map List.rev
      in
      let sorted =
        List.sort
          (fun (left, _) (right, _) -> String.compare left right)
          canonical_fields
      in
      let rec reject_duplicate_keys previous = function
        | [] -> Ok ()
        | (key, _) :: rest ->
          (match previous with
           | Some prior when String.equal prior key ->
             Error (Printf.sprintf "%s contains duplicate object key %S" context key)
           | Some _ | None -> reject_duplicate_keys (Some key) rest)
      in
      let* () = reject_duplicate_keys None sorted in
      Ok (`Assoc sorted)
    | `List values ->
      List.fold_left
        (fun result value ->
           let* values = result in
           let* value = canonicalize ~context value in
           Ok (value :: values))
        (Ok [])
        values
      |> Result.map (fun values -> `List (List.rev values))
    | `Float value when not (Float.is_finite value) ->
      Error (context ^ " contains a non-finite number")
    | `Float value ->
      Ok (`Float (if Float.equal value 0.0 then 0.0 else value))
    | (`Bool _ | `Int _ | `Intlit _ | `Null | `String _) as scalar -> Ok scalar
  ;;

  let of_yojson = function
    | `Assoc _ as context -> canonicalize ~context:"keeper_context" context
    | _ -> Error "keeper_context must be an object"
  ;;

  let of_candidate candidate =
    match candidate.judgment_request with
    | `Assoc fields ->
      let contexts =
        List.filter_map
          (fun (key, value) ->
             if String.equal key "keeper_context" then Some value else None)
          fields
      in
      (match contexts with
       | [ context ] -> of_yojson context
       | [] -> Error "judgment request lacks keeper_context"
       | _ -> Error "judgment request contains multiple keeper_context fields")
    | _ -> Error "judgment request must be an object"
  ;;

  let to_yojson context = context
  let to_canonical_string context = Yojson.Safe.to_string context
  let equal = ( = )
end

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

let finite_time ~context value =
  if Float.is_finite value then Ok () else Error (context ^ " must be finite")
;;

let finite_float_json ~context json =
  let* value = float_json ~context json in
  let* () = finite_time ~context value in
  Ok value
;;

let nonblank_string ~context value =
  if String.equal (String.trim value) ""
  then Error (context ^ " must not be empty")
  else Ok ()
;;

let rec validate_finite_json ~context = function
  | `Float value -> finite_time ~context value
  | `Assoc fields ->
    List.fold_left
      (fun result (key, value) ->
         let* () = result in
         validate_finite_json ~context:(context ^ "." ^ key) value)
      (Ok ())
      fields
  | `List values ->
    let rec loop index = function
      | [] -> Ok ()
      | value :: rest ->
        let* () =
          validate_finite_json
            ~context:(Printf.sprintf "%s[%d]" context index)
            value
        in
        loop (index + 1) rest
    in
    loop 0 values
  | `Bool _ | `Int _ | `Intlit _ | `Null | `String _ -> Ok ()
;;

let validate_judgment ~context (judgment : judgment) =
  let* () =
    nonblank_string
      ~context:(context ^ ".verdict.rationale")
      judgment.verdict.rationale
  in
  let* () = nonblank_string ~context:(context ^ ".slot_id") judgment.slot_id in
  let* () = nonblank_string ~context:(context ^ ".call_id") judgment.call_id in
  let* () =
    nonblank_string
      ~context:(context ^ ".plan_fingerprint")
      judgment.plan_fingerprint
  in
  let* () =
    nonblank_string
      ~context:(context ^ ".request_body_sha256")
      judgment.request_body_sha256
  in
  finite_time ~context:(context ^ ".judged_at") judgment.judged_at
;;

let validate_optional_delivery_failure = function
  | None -> Ok ()
  | Some failure ->
    finite_time
      ~context:"candidate.status.last_delivery_failure.failed_at"
      failure.failed_at
;;

let validate_resumable_state = function
  | Resumable_pending pending ->
    validate_optional_delivery_failure pending.last_delivery_failure
  | Resumable_judged judged ->
    let* () =
      validate_judgment ~context:"candidate.status.judgment" judged.judgment
    in
    validate_optional_delivery_failure judged.last_delivery_failure
  | Resumable_consumed consumed ->
    let* () =
      validate_judgment ~context:"candidate.status.judgment" consumed.judgment
    in
    finite_time ~context:"candidate.status.consumed_at" consumed.consumed_at
;;

let nonblank_quarantine_field context value =
  if String.equal (String.trim value) ""
  then Error (context ^ " must not be blank")
  else Ok ()
;;

let validate_attempt_provenance provenance =
  let* () = nonblank_quarantine_field "candidate quarantine slot_id" provenance.slot_id in
  let* () = nonblank_quarantine_field "candidate quarantine call_id" provenance.call_id in
  let* () =
    nonblank_quarantine_field
      "candidate quarantine plan_fingerprint"
      provenance.plan_fingerprint
  in
  nonblank_quarantine_field
    "candidate quarantine request_body_sha256"
    provenance.request_body_sha256
;;

let validate_quarantine quarantine =
  let* () =
    nonblank_quarantine_field
      "candidate quarantine quarantine_id"
      quarantine.quarantine_id
  in
  let* () =
    nonblank_quarantine_field
      "candidate quarantine partition_id"
      quarantine.partition_id
  in
  let* () =
    match quarantine.attempt_provenance with
    | None -> Ok ()
    | Some provenance -> validate_attempt_provenance provenance
  in
  let* () =
    finite_time
      ~context:"candidate.status.quarantine.quarantined_at"
      quarantine.quarantined_at
  in
  validate_resumable_state quarantine.prior_status
;;

let validate_candidate_state (candidate : candidate) =
  let* () = finite_time ~context:"candidate.recorded_at" candidate.recorded_at in
  match candidate.status with
  | Pending pending -> validate_resumable_state (Resumable_pending pending)
  | Judged judged -> validate_resumable_state (Resumable_judged judged)
  | Consumed consumed -> validate_resumable_state (Resumable_consumed consumed)
  | Quarantine { quarantine; phase } ->
    let* () = validate_quarantine quarantine in
    (match phase with
     | Quarantined -> Ok ()
     | Requeue_requested { requested_at } ->
       finite_time
         ~context:"candidate.status.quarantine.requested_at"
         requested_at
     | Requeued { requeued_at } ->
       finite_time ~context:"candidate.status.quarantine.requeued_at" requeued_at)
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
    optional_json
      (finite_float_json ~context:(context ^ ".updated_at"))
      updated_at_json
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

let delivery_failure_of_yojson json =
  let context = "candidate.status.last_delivery_failure" in
  let* fields = assoc ~context json in
  let* () = exact_fields ~context [ "kind"; "detail"; "failed_at" ] fields in
  let* kind_json = field ~context "kind" fields in
  let* kind_raw = string_json ~context:(context ^ ".kind") kind_json in
  let* kind =
    match delivery_failure_kind_of_string kind_raw with
    | Some kind -> Ok kind
    | None -> Error (Printf.sprintf "unknown delivery failure kind %S" kind_raw)
  in
  let* detail_json = field ~context "detail" fields in
  let* detail = string_json ~context:(context ^ ".detail") detail_json in
  let* failed_at_json = field ~context "failed_at" fields in
  let* failed_at =
    finite_float_json ~context:(context ^ ".failed_at") failed_at_json
  in
  Ok { kind; detail; failed_at }
;;

let judgment_of_yojson json =
  let context = "candidate.status.judgment" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "verdict"
      ; "slot_id"
      ; "call_id"
      ; "plan_fingerprint"
      ; "request_body_sha256"
      ; "judged_at"
      ]
      fields
  in
  let* verdict_json = field ~context "verdict" fields in
  let* verdict = Keeper_board_attention_judgment.of_yojson verdict_json in
  let* slot_id_json = field ~context "slot_id" fields in
  let* slot_id = string_json ~context:(context ^ ".slot_id") slot_id_json in
  let* call_id_json = field ~context "call_id" fields in
  let* call_id = string_json ~context:(context ^ ".call_id") call_id_json in
  let* plan_fingerprint_json = field ~context "plan_fingerprint" fields in
  let* plan_fingerprint =
    string_json
      ~context:(context ^ ".plan_fingerprint")
      plan_fingerprint_json
  in
  let* request_body_sha256_json = field ~context "request_body_sha256" fields in
  let* request_body_sha256 =
    string_json
      ~context:(context ^ ".request_body_sha256")
      request_body_sha256_json
  in
  let* judged_at_json = field ~context "judged_at" fields in
  let* judged_at = float_json ~context:(context ^ ".judged_at") judged_at_json in
  let judgment =
    { verdict
    ; slot_id
    ; call_id
    ; plan_fingerprint
    ; request_body_sha256
    ; judged_at
    }
  in
  let* () =
    validate_judgment ~context judgment
  in
  Ok judgment
;;

let resumable_status_of_yojson json =
  let context = "candidate.status" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "pending" ->
    let* () =
      exact_fields ~context [ "kind"; "last_delivery_failure" ] fields
    in
    let* failure_json = field ~context "last_delivery_failure" fields in
    let* last_delivery_failure =
      optional_json delivery_failure_of_yojson failure_json
    in
    Ok (Resumable_pending { last_delivery_failure })
  | "judged" ->
    let* () =
      exact_fields
        ~context
        [ "kind"; "judgment"; "last_delivery_failure" ]
        fields
    in
    let* judgment_json = field ~context "judgment" fields in
    let* judgment = judgment_of_yojson judgment_json in
    let* failure_json = field ~context "last_delivery_failure" fields in
    let* last_delivery_failure =
      optional_json delivery_failure_of_yojson failure_json
    in
    Ok (Resumable_judged { judgment; last_delivery_failure })
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
    let* consumed_at =
      finite_float_json ~context:(context ^ ".consumed_at") consumed_at_json
    in
    Ok (Resumable_consumed { judgment; delivery; consumed_at })
  | value ->
    Error (Printf.sprintf "unknown resumable Board attention status %S" value)
;;

let attempt_provenance_of_yojson json =
  let context = "candidate quarantine attempt provenance" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "slot_id"; "call_id"; "plan_fingerprint"; "request_body_sha256" ]
      fields
  in
  let* slot_id_json = field ~context "slot_id" fields in
  let* slot_id = string_json ~context:(context ^ ".slot_id") slot_id_json in
  let* call_id_json = field ~context "call_id" fields in
  let* call_id = string_json ~context:(context ^ ".call_id") call_id_json in
  let* plan_json = field ~context "plan_fingerprint" fields in
  let* plan_fingerprint =
    string_json ~context:(context ^ ".plan_fingerprint") plan_json
  in
  let* request_json = field ~context "request_body_sha256" fields in
  let* request_body_sha256 =
    string_json ~context:(context ^ ".request_body_sha256") request_json
  in
  Ok { slot_id; call_id; plan_fingerprint; request_body_sha256 }
;;

let quarantine_of_yojson json =
  let context = "candidate quarantine" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "quarantine_id"
      ; "partition_id"
      ; "failure_category"
      ; "attempt_provenance"
      ; "quarantined_at"
      ; "prior_status"
      ]
      fields
  in
  let* quarantine_id_json = field ~context "quarantine_id" fields in
  let* quarantine_id =
    string_json ~context:(context ^ ".quarantine_id") quarantine_id_json
  in
  let* partition_id_json = field ~context "partition_id" fields in
  let* partition_id =
    string_json ~context:(context ^ ".partition_id") partition_id_json
  in
  let* category_json = field ~context "failure_category" fields in
  let* category_raw =
    string_json ~context:(context ^ ".failure_category") category_json
  in
  let* failure_category =
    match quarantine_failure_category_of_string category_raw with
    | Some category -> Ok category
    | None -> Error ("unknown candidate quarantine failure category: " ^ category_raw)
  in
  let* provenance_json = field ~context "attempt_provenance" fields in
  let* attempt_provenance =
    optional_json attempt_provenance_of_yojson provenance_json
  in
  let* quarantined_at_json = field ~context "quarantined_at" fields in
  let* quarantined_at =
    finite_float_json
      ~context:(context ^ ".quarantined_at")
      quarantined_at_json
  in
  let* prior_json = field ~context "prior_status" fields in
  let* prior_status = resumable_status_of_yojson prior_json in
  Ok
    { quarantine_id
    ; partition_id
    ; failure_category
    ; attempt_provenance
    ; quarantined_at
    ; prior_status
    }
;;

let status_of_yojson json =
  let context = "candidate.status" in
  let* fields = assoc ~context json in
  let* kind_json = field ~context "kind" fields in
  let* kind = string_json ~context:(context ^ ".kind") kind_json in
  match kind with
  | "pending" | "judged" | "consumed" ->
    let* resumable = resumable_status_of_yojson json in
    Ok (status_of_resumable resumable)
  | "quarantined" ->
    let* () = exact_fields ~context [ "kind"; "quarantine" ] fields in
    let* quarantine_json = field ~context "quarantine" fields in
    let* quarantine = quarantine_of_yojson quarantine_json in
    Ok (Quarantine { quarantine; phase = Quarantined })
  | "requeue_requested" ->
    let* () =
      exact_fields ~context [ "kind"; "quarantine"; "requested_at" ] fields
    in
    let* quarantine_json = field ~context "quarantine" fields in
    let* quarantine = quarantine_of_yojson quarantine_json in
    let* requested_json = field ~context "requested_at" fields in
    let* requested_at =
      finite_float_json ~context:(context ^ ".requested_at") requested_json
    in
    Ok (Quarantine { quarantine; phase = Requeue_requested { requested_at } })
  | "requeued" ->
    let* () =
      exact_fields ~context [ "kind"; "quarantine"; "requeued_at" ] fields
    in
    let* quarantine_json = field ~context "quarantine" fields in
    let* quarantine = quarantine_of_yojson quarantine_json in
    let* requeued_json = field ~context "requeued_at" fields in
    let* requeued_at =
      finite_float_json ~context:(context ^ ".requeued_at") requeued_json
    in
    Ok (Quarantine { quarantine; phase = Requeued { requeued_at } })
  | value -> Error (Printf.sprintf "unknown Board attention candidate status %S" value)
;;

let string_list_of_yojson ~context = function
  | `List values ->
    List.fold_left
      (fun result value ->
         let* () = result in
         let* (_ : string) = string_json ~context value in
         Ok ())
      (Ok ())
      values
  | _ -> Error (context ^ " must be an array of strings")
;;

let optional_string_of_yojson ~context = function
  | `Null -> Ok ()
  | value ->
    let* (_ : string) = string_json ~context value in
    Ok ()
;;

let validate_keeper_context ~keeper_name json =
  let context = "candidate.judgment_request.keeper_context" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "lane_keeper_name"
      ; "agent_name"
      ; "keeper_record_id"
      ; "keeper_runtime_uid"
      ; "persona"
      ; "instructions"
      ; "active_goal_ids"
      ; "current_task_id"
      ; "mention_keeper_ids"
      ]
      fields
  in
  let* lane_keeper_name_json = field ~context "lane_keeper_name" fields in
  let* lane_keeper_name =
    string_json
      ~context:(context ^ ".lane_keeper_name")
      lane_keeper_name_json
  in
  let* () =
    if String.equal lane_keeper_name keeper_name
    then Ok ()
    else Error (context ^ ".lane_keeper_name does not match candidate keeper_name")
  in
  let* agent_name_json = field ~context "agent_name" fields in
  let* (_ : string) =
    string_json ~context:(context ^ ".agent_name") agent_name_json
  in
  let* instructions_json = field ~context "instructions" fields in
  let* (_ : string) =
    string_json ~context:(context ^ ".instructions") instructions_json
  in
  let* keeper_record_id = field ~context "keeper_record_id" fields in
  let* () =
    optional_string_of_yojson
      ~context:(context ^ ".keeper_record_id")
      keeper_record_id
  in
  let* keeper_runtime_uid = field ~context "keeper_runtime_uid" fields in
  let* () =
    optional_string_of_yojson
      ~context:(context ^ ".keeper_runtime_uid")
      keeper_runtime_uid
  in
  let* persona = field ~context "persona" fields in
  let* () =
    optional_string_of_yojson ~context:(context ^ ".persona") persona
  in
  let* active_goal_ids = field ~context "active_goal_ids" fields in
  let* () =
    string_list_of_yojson
      ~context:(context ^ ".active_goal_ids")
      active_goal_ids
  in
  let* current_task_id = field ~context "current_task_id" fields in
  let* () =
    optional_string_of_yojson
      ~context:(context ^ ".current_task_id")
      current_task_id
  in
  let* mention_keeper_ids = field ~context "mention_keeper_ids" fields in
  let* () =
    string_list_of_yojson
      ~context:(context ^ ".mention_keeper_ids")
      mention_keeper_ids
  in
  let* canonical = Context_key.of_yojson json in
  Ok (Context_key.to_yojson canonical)
;;

let canonical_judgment_request candidate =
  let context = "candidate.judgment_request" in
  let* () = validate_finite_json ~context candidate.judgment_request in
  let* fields = assoc ~context candidate.judgment_request in
  let* () =
    exact_fields
      ~context
      [ "candidate_id"; "signal"; "post"; "comments"; "keeper_context" ]
      fields
  in
  let* candidate_id_json = field ~context "candidate_id" fields in
  let* candidate_id =
    string_json ~context:(context ^ ".candidate_id") candidate_id_json
  in
  let* () =
    if String.equal candidate_id candidate.candidate_id
    then Ok ()
    else Error (context ^ ".candidate_id does not match durable candidate identity")
  in
  let* signal_json = field ~context "signal" fields in
  let* request_signal = signal_of_yojson signal_json in
  let* () =
    if request_signal = candidate.signal
    then Ok ()
    else Error (context ^ ".signal does not match durable candidate signal")
  in
  let* post = field ~context "post" fields in
  let* canonical_post =
    match Board.post_of_yojson post with
    | None -> Error (context ^ ".post does not match the current Board post schema")
    | Some decoded ->
      let post_id = Board.Post_id.to_string decoded.id in
      if String.equal post_id candidate.signal.post_id
      then Ok (Board.post_to_yojson decoded)
      else Error (context ^ ".post.id does not match durable signal.post_id")
  in
  let* comments = field ~context "comments" fields in
  let* canonical_comments =
    match comments with
    | `List values ->
      List.fold_left
        (fun result value ->
           let* canonical = result in
           match Board.comment_of_yojson value with
           | None ->
             Error
               (context
                ^ ".comments[] does not match the current Board comment schema")
           | Some decoded ->
             let post_id = Board.Post_id.to_string decoded.post_id in
             if String.equal post_id candidate.signal.post_id
             then Ok (Board.comment_to_yojson decoded :: canonical)
             else
               Error
                 (context
                  ^ ".comments[].post_id does not match durable signal.post_id"))
        (Ok [])
        values
      |> Result.map List.rev
    | _ -> Error (context ^ ".comments must be an array of objects")
  in
  let* keeper_context = field ~context "keeper_context" fields in
  let* canonical_keeper_context =
    validate_keeper_context ~keeper_name:candidate.keeper_name keeper_context
  in
  Ok
    (`Assoc
       [ "candidate_id", `String candidate.candidate_id
       ; "signal", signal_to_yojson candidate.signal
       ; "post", canonical_post
       ; "comments", `List canonical_comments
       ; "keeper_context", canonical_keeper_context
       ])
;;

let require_current_canonical_judgment_request candidate =
  let* canonical = canonical_judgment_request candidate in
  if Yojson.Safe.equal candidate.judgment_request canonical
  then Ok canonical
  else
    Error
      "candidate.judgment_request does not match the current canonical Board schema"
;;

let singleton_judgment_request candidate =
  let context = "canonical candidate.judgment_request" in
  let* canonical = require_current_canonical_judgment_request candidate in
  let* fields = assoc ~context canonical in
  let* keeper_context = field ~context "keeper_context" fields in
  let item_fields =
    List.filter
      (fun (key, _) -> not (String.equal key "keeper_context"))
      fields
  in
  Ok
    (`Assoc
       [ "keeper_context", keeper_context
       ; "items", `List [ `Assoc item_fields ]
       ])
;;

let validate_candidate_for_persistence candidate =
  let* () =
    validate_finite_json
      ~context:"candidate.signal"
      (signal_to_yojson candidate.signal)
  in
  let* (_ : Yojson.Safe.t) = singleton_judgment_request candidate in
  validate_candidate_state candidate
;;

let candidate_of_json json =
  let context = "board attention candidate" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "schema_version"
      ; "candidate_id"
      ; "keeper_name"
      ; "signal"
      ; "judgment_request"
      ; "recorded_at"
      ; "status"
      ]
      fields
  in
  let* version_json = field ~context "schema_version" fields in
  let* () =
    match version_json with
    | `Int version when Int.equal version schema_version -> Ok ()
    | `Int version ->
      Error
        (Printf.sprintf
           "unsupported Board attention candidate schema version %d"
           version)
    | _ -> Error (context ^ ".schema_version must be an integer")
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
  let* recorded_at_json = field ~context "recorded_at" fields in
  let* recorded_at =
    finite_float_json ~context:(context ^ ".recorded_at") recorded_at_json
  in
  let* status_json = field ~context "status" fields in
  let* status = status_of_yojson status_json in
  let candidate =
    { candidate_id; keeper_name; signal; judgment_request; recorded_at; status }
  in
  let* () = validate_candidate_for_persistence candidate in
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
  | Private_file_failed error -> Error (durable_error_to_string error)
  | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
    Error
      (Printf.sprintf
         "%s; descriptor settlement failed: %s"
         (durable_error_to_string error)
         (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure))
  | Private_file_succeeded result -> result
  | Private_file_succeeded_with_cleanup_failure
      { value = result; cleanup_failure } ->
    Log.Keeper.error
      "board attention candidate read succeeded with descriptor settlement failure path=%s: %s"
      path
      (Fs_compat.private_jsonl_operation_failure_to_string cleanup_failure);
    result
;;

(* Read-side stat memo. Owner-lane drains call [load_candidates] far more often
   than the ledger changes, and every call otherwise re-reads and re-parses the
   whole file — with multi-MB ledgers this was a dominant CPU source (issue
   #25003: concurrent whole-file Yojson parses in systhreads starving the
   domain's main event loop). Every producer replaces the ledger through an
   atomic temp+rename ([update_ledger] via
   [Fs_compat.rewrite_private_file_durable_locked_result]), so any content
   change allocates a new inode; (dev, ino, mtime, size) equality therefore
   implies unchanged content. One entry per keeper ledger path, so the table
   stays as small as the fleet. *)
type ledger_stat_key =
  { stat_dev : int
  ; stat_ino : int
  ; stat_mtime : float
  ; stat_size : int
  }

let ledger_stat_key_opt path =
  match Unix.stat path with
  | stats ->
    Some
      { stat_dev = stats.st_dev
      ; stat_ino = stats.st_ino
      ; stat_mtime = stats.st_mtime
      ; stat_size = stats.st_size
      }
  | exception Unix.Unix_error _ -> None
;;

let candidate_read_memo : (string, ledger_stat_key * candidate list) Hashtbl.t =
  Hashtbl.create 16
;;

(* Stdlib mutex on purpose: touched from systhread read paths and module-level
   state; the critical sections are Hashtbl lookups with no yield. *)
let candidate_read_memo_mutex = Stdlib.Mutex.create ()

let load_candidates ~base_path ~keeper_name =
  let path = candidate_path ~base_path ~keeper_name in
  let before = ledger_stat_key_opt path in
  let cached =
    match before with
    | None -> None
    | Some key ->
      Stdlib.Mutex.protect candidate_read_memo_mutex (fun () ->
        match Hashtbl.find_opt candidate_read_memo path with
        | Some (cached_key, candidates) when cached_key = key -> Some candidates
        | Some _ | None -> None)
  in
  match cached with
  | Some candidates -> Ok candidates
  | None ->
    let* candidates = read_locked path load_candidates_from_content in
    (* Double-stat: memoize only when the file identity is unchanged across
       the read; a concurrent rewrite lands as a new inode and skips the
       store, so the next call re-reads. *)
    (match before, ledger_stat_key_opt path with
     | Some key_before, Some key_after when key_before = key_after ->
       Stdlib.Mutex.protect candidate_read_memo_mutex (fun () ->
         Hashtbl.replace candidate_read_memo path (key_before, candidates))
     | Some _, (Some _ | None) | None, (Some _ | None) -> ());
    Ok candidates
;;

let append_row candidate = Yojson.Safe.to_string (candidate_to_json candidate) ^ "\n"

let serialize_candidates candidates =
  String.concat "" (List.map append_row candidates)
;;

let update_ledger_many ~base_path ~keeper_name decide =
  let path = candidate_path ~base_path ~keeper_name in
  (* Compact on write: a committed change rewrites the ledger as the deduped
     latest-per-id set (via [latest_candidates]) instead of appending one row.
     The reader already discards all but the latest row per candidate_id, so the
     older rows are dead weight; appending them grew the file without bound and
     made every update O(n^2) because the durable transaction re-parses the whole
     ledger before writing. Rewriting keeps the file bounded to the number of
     distinct candidates. *)
  try
    match
      Fs_compat.rewrite_private_file_durable_locked_result path (fun content ->
        match load_candidates_from_content content with
        | Error detail -> None, Error detail
        | Ok candidates ->
          (match decide candidates with
           | Error _ as error -> None, error
           | Ok (None, result) -> None, Ok result
           | Ok (Some updated, result) ->
             let compacted = latest_candidates (candidates @ updated) in
             let validation =
               List.fold_left
                 (fun validation candidate ->
                    let* () = validation in
                    validate_candidate_for_persistence candidate)
                 (Ok ())
                 compacted
             in
             (match validation with
              | Error detail -> None, Error detail
              | Ok () -> Some (serialize_candidates compacted), Ok result)))
    with
    | Error error -> Error error
    | Ok result -> result
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "Board attention ledger update failed keeper=%s path=%s: %s"
         keeper_name
         path
         (Printexc.to_string exn))
;;

let update_ledger ~base_path ~keeper_name decide =
  update_ledger_many ~base_path ~keeper_name (fun candidates ->
    match decide candidates with
    | Error _ as error -> error
    | Ok (None, result) -> Ok (None, result)
    | Ok (Some candidate, result) -> Ok (Some [ candidate ], result))
;;

let find_candidate candidates candidate_id =
  List.find_opt
    (fun candidate -> String.equal candidate.candidate_id candidate_id)
    candidates
;;

let record ~base_path candidate =
  match validate_candidate_for_persistence candidate with
  | Error detail -> Record_error ("invalid Board attention candidate: " ^ detail)
  | Ok () ->
    (match
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
     | Error detail -> Record_error detail)
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

let same_delivery_failure left right =
  left.kind = right.kind && String.equal left.detail right.detail
;;

let same_judgment left right =
  left.verdict = right.verdict
  && String.equal left.slot_id right.slot_id
  && String.equal left.call_id right.call_id
  && String.equal left.plan_fingerprint right.plan_fingerprint
  && String.equal left.request_body_sha256 right.request_body_sha256
  && Float.equal left.judged_at right.judged_at
;;

let replace_resumable_status status resumable =
  match status with
  | Pending _ | Judged _ | Consumed _ -> status_of_resumable resumable
  | Quarantine ({ quarantine; phase = Requeued _ } as state) ->
    Quarantine
      { state with
        quarantine = { quarantine with prior_status = resumable }
      }
  | Quarantine ({ phase = (Quarantined | Requeue_requested _); _ } as state) ->
    Quarantine state
;;

let resumable_with_delivery_failure resumable failure =
  match resumable with
  | Resumable_pending pending ->
    (match pending.last_delivery_failure with
     | Some existing when same_delivery_failure existing failure -> resumable
     | Some _ | None ->
       Resumable_pending { last_delivery_failure = Some failure })
  | Resumable_judged judged ->
    (match judged.last_delivery_failure with
     | Some existing when same_delivery_failure existing failure -> resumable
     | Some _ | None ->
       Resumable_judged { judged with last_delivery_failure = Some failure })
  | Resumable_consumed _ -> resumable
;;

let candidate_with_delivery_failure current failure =
  match resumable_status current.status with
  | None -> current
  | Some resumable ->
    let updated = resumable_with_delivery_failure resumable failure in
    if updated = resumable
    then current
    else { current with status = replace_resumable_status current.status updated }
;;

let record_delivery_failure ~base_path candidate failure =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       let updated = candidate_with_delivery_failure current failure in
       if updated = current then None else Some updated)
;;

let record_judgment ~base_path candidate judgment =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error
        (Printf.sprintf
           "Board attention candidate not found: %s"
           candidate.candidate_id)
    | Some current ->
      (match resumable_status current.status with
       | Some (Resumable_pending _) ->
         let updated =
           { current with
             status =
               status_of_resumable
                 (Resumable_judged
                    { judgment; last_delivery_failure = None })
           }
         in
         Ok (Some updated, updated)
       | Some (Resumable_judged judged)
         when same_judgment judged.judgment judgment ->
         Ok (None, current)
       | Some (Resumable_consumed consumed)
         when same_judgment consumed.judgment judgment ->
         Ok (None, current)
       | Some (Resumable_judged _ | Resumable_consumed _) ->
         Error
           ("Board attention candidate judgment conflict: "
            ^ candidate.candidate_id)
       | None ->
         Error
           ("Quarantined Board attention candidate cannot be judged: "
            ^ candidate.candidate_id)))
;;

let mark_consumed ~base_path candidate judgment delivery =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error
        (Printf.sprintf
           "Board attention candidate not found: %s"
           candidate.candidate_id)
    | Some current ->
      (match resumable_status current.status with
       | Some (Resumable_judged judged)
         when same_judgment judged.judgment judgment ->
         let updated =
           { current with
             status =
               status_of_resumable
                 (Resumable_consumed
                    { judgment; delivery; consumed_at = Time_compat.now () })
           }
         in
         Ok (Some updated, updated)
       | Some (Resumable_consumed consumed)
         when same_judgment consumed.judgment judgment
              && consumed.delivery = delivery -> Ok (None, current)
       | Some (Resumable_pending _) ->
         Error
           ("Pending Board attention candidate cannot be consumed: "
            ^ candidate.candidate_id)
       | Some (Resumable_judged _ | Resumable_consumed _) ->
         Error
           ("Board attention candidate consumption conflict: "
            ^ candidate.candidate_id)
       | None ->
         Error
           ("Quarantined Board attention candidate cannot be consumed: "
            ^ candidate.candidate_id)))
;;

let quarantine_id
      ~candidate_id
      ~partition_id
      ~failure_category
      ~attempt_provenance
      ~quarantined_at
  =
  let provenance =
    match attempt_provenance with
    | None -> [ "" ]
    | Some provenance ->
      [ provenance.slot_id
      ; provenance.call_id
      ; provenance.plan_fingerprint
      ; provenance.request_body_sha256
      ]
  in
  String.concat
    "\000"
    ([ candidate_id
     ; partition_id
     ; quarantine_failure_category_to_string failure_category
     ; Printf.sprintf "%.17g" quarantined_at
     ]
     @ provenance)
  |> Digestif.SHA256.digest_string
  |> Digestif.SHA256.to_hex
  |> ( ^ ) "ba-quarantine-"
;;

let normalize_requeued_consumed ~base_path ~keeper_name ~candidate_id =
  update_ledger ~base_path ~keeper_name (fun candidates ->
    match find_candidate candidates candidate_id with
    | None -> Error ("Board attention candidate not found: " ^ candidate_id)
    | Some current ->
      (match current.status with
       | Consumed _ -> Ok (None, current)
       | Quarantine
           { quarantine = { prior_status = Resumable_consumed consumed; _ }
           ; phase = Requeued _
           } ->
         let updated = { current with status = Consumed consumed } in
         Ok (Some updated, updated)
       | Pending _ | Judged _ | Quarantine _ ->
         Error
           ("Board attention candidate is not requeued-consumed: "
            ^ candidate_id)))
;;

let same_quarantine_identity left right =
  String.equal left.quarantine_id right.quarantine_id
  && String.equal left.partition_id right.partition_id
;;

let quarantine
      ~base_path
      ~(candidate : candidate)
      ~partition_id
      ~failure_category
      ~attempt_provenance
      ~quarantined_at
  =
  let quarantine_id =
    quarantine_id
      ~candidate_id:candidate.candidate_id
      ~partition_id
      ~failure_category
      ~attempt_provenance
      ~quarantined_at
  in
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error ("Board attention candidate not found: " ^ candidate.candidate_id)
    | Some current ->
      let prior_status =
        match resumable_status current.status with
        | Some status -> status
        | None ->
          (match current.status with
           | Quarantine state -> state.quarantine.prior_status
           | Pending _ | Judged _ | Consumed _ -> assert false)
      in
      let requested =
        { quarantine_id
        ; partition_id
        ; failure_category
        ; attempt_provenance
        ; quarantined_at
        ; prior_status
        }
      in
      (match current.status with
       | Quarantine state
         when same_quarantine_identity state.quarantine requested ->
         Ok (None, current)
       | Quarantine { phase = (Quarantined | Requeue_requested _); _ } ->
         Error
           ("candidate is already quarantined by another generation: "
            ^ current.candidate_id)
       | Pending _ | Judged _ | Consumed _ | Quarantine { phase = Requeued _; _ } ->
         let updated =
           { current with
             status = Quarantine { quarantine = requested; phase = Quarantined }
           }
         in
         Ok (Some updated, updated)))
;;

let request_quarantine_requeue
      ~base_path
      ~(candidate : candidate)
      ~partition_id
      ~expected_quarantine_id
      ~requested_at
  =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error ("Board attention candidate not found: " ^ candidate.candidate_id)
    | Some current ->
      (match current.status with
       | Quarantine ({ quarantine; phase = Quarantined } as state)
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         let updated =
           { current with
             status =
               Quarantine
                 { state with phase = Requeue_requested { requested_at } }
           }
         in
         Ok (Some updated, updated)
       | Quarantine
           { quarantine
           ; phase = (Requeue_requested _ | Requeued _)
           }
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         Ok (None, current)
       | Pending _ | Judged _ | Consumed _ | Quarantine _ ->
         Error
           ("candidate quarantine generation does not match operator request: "
            ^ current.candidate_id)))
;;

let finish_quarantine_requeue
      ~base_path
      ~(candidate : candidate)
      ~partition_id
      ~expected_quarantine_id
      ~requeued_at
  =
  update_ledger ~base_path ~keeper_name:candidate.keeper_name (fun candidates ->
    match find_candidate candidates candidate.candidate_id with
    | None ->
      Error ("Board attention candidate not found: " ^ candidate.candidate_id)
    | Some current ->
      (match current.status with
       | Quarantine ({ quarantine; phase = Requeue_requested _ } as state)
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         let updated =
           { current with
             status = Quarantine { state with phase = Requeued { requeued_at } }
           }
         in
         Ok (Some updated, updated)
       | Quarantine { quarantine; phase = Requeued _ }
         when String.equal quarantine.partition_id partition_id
              && String.equal quarantine.quarantine_id expected_quarantine_id ->
         Ok (None, current)
       | Pending _ | Judged _ | Consumed _ | Quarantine _ ->
         Error
           ("candidate is not in the requested requeue generation: "
            ^ current.candidate_id)))
;;

let delivery_failure ~kind detail =
  { kind; detail; failed_at = Time_compat.now () }
;;

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
       record_delivery_failure
         ~base_path
         candidate
         (delivery_failure ~kind:Durable_delivery_unavailable detail))
;;

let record_and_wake ~base_path candidate =
  let request_worker persisted =
    let* wake =
      Keeper_board_attention_worker_wake.request
        ~base_path
        ~keeper_name:persisted.keeper_name
    in
    Ok (Judgment_worker_requested wake)
  in
  match record ~base_path candidate with
  | Record_error detail -> Error detail
  | Recorded persisted ->
    let* wake = request_worker persisted in
    Ok { candidate = persisted; persistence = Candidate_recorded; wake }
  | Duplicate persisted ->
    let* wake =
      match resumable_status persisted.status with
      | Some (Resumable_pending _ | Resumable_judged _) ->
        request_worker persisted
      | Some (Resumable_consumed _) | None -> Ok Wake_not_required
    in
    Ok
      { candidate = persisted
      ; persistence = Candidate_already_present
      ; wake
      }
;;

let apply_judgment_and_deliver ~base_path ~keeper_name ~candidate_id ~judgment =
  let* candidates = load_candidates ~base_path ~keeper_name in
  let* candidate =
    match find_candidate candidates candidate_id with
    | Some candidate -> Ok candidate
    | None -> Error ("Board attention candidate not found: " ^ candidate_id)
  in
  let* judged_candidate =
    match resumable_status candidate.status with
    | Some (Resumable_pending _) ->
      record_judgment ~base_path candidate judgment
    | Some (Resumable_judged judged)
      when same_judgment judged.judgment judgment ->
      Ok candidate
    | Some (Resumable_consumed consumed)
      when same_judgment consumed.judgment judgment ->
      Ok candidate
    | Some (Resumable_judged _ | Resumable_consumed _) ->
      Error ("Board attention candidate judgment conflicts with worker result: " ^ candidate_id)
    | None ->
      Error
        ("Quarantined or requeue-requested Board attention candidate cannot be settled: "
         ^ candidate_id)
  in
  match resumable_status judged_candidate.status with
  | Some (Resumable_consumed _) ->
    normalize_requeued_consumed ~base_path ~keeper_name ~candidate_id
  | Some (Resumable_pending _) ->
    Error ("Board attention candidate remained Pending after judgment commit: " ^ candidate_id)
  | Some (Resumable_judged judged) ->
    let* delivered = consume_judged ~base_path judged_candidate judged in
    (match resumable_status delivered.status with
     | Some (Resumable_consumed _) ->
       normalize_requeued_consumed ~base_path ~keeper_name ~candidate_id
     | Some (Resumable_pending _ | Resumable_judged _) ->
       Error
         ("Board attention candidate delivery did not reach Consumed: "
          ^ candidate_id)
     | None ->
       Error
         ("Board attention candidate became quarantined during delivery: "
          ^ candidate_id))
  | None ->
    Error
      ("Quarantined or requeue-requested Board attention candidate cannot be settled: "
       ^ candidate_id)
;;
