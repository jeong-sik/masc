(* See .mli. *)

module Board_signal = Keeper_world_observation_board_signal
module Candidate_map = Map.Make (String)
module Id_set = Set.Make (String)

let ( let* ) = Result.bind

module Attempt_count = struct
  type t = string

  let one = "1"
  let to_string value = value

  let of_string value =
    let length = String.length value in
    if length = 0
    then Error "Board attention attempt_count must not be empty"
    else if Char.equal value.[0] '0'
    then Error "Board attention attempt_count must be a canonical positive integer"
    else
      let rec validate index =
        if index = length
        then Ok value
        else
          let digit = value.[index] in
          if digit >= '0' && digit <= '9'
          then validate (index + 1)
          else Error "Board attention attempt_count must contain decimal digits only"
      in
      validate 0
  ;;

  let succ value =
    let digits = Bytes.of_string value in
    let rec increment index =
      if index < 0
      then "1" ^ Bytes.to_string digits
      else
        match Bytes.get digits index with
        | '9' ->
          Bytes.set digits index '0';
          increment (index - 1)
        | digit ->
          Bytes.set digits index (Char.chr (Char.code digit + 1));
          Bytes.to_string digits
    in
    increment (Bytes.length digits - 1)
  ;;
end

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_delivery_unavailable

type retryable_failure =
  { kind : retryable_failure_kind
  ; detail : string
  ; attempt_count : Attempt_count.t
  ; first_failed_at : float
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
  ; delivery_signal : Keeper_event_queue.board_stimulus
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
  | Wake_requested of Keeper_registry.wakeup_outcome
  | Wake_not_required

type record_acceptance =
  { candidate : candidate
  ; persistence : persistence
  ; wake : wake_decision
  }

type drain_report =
  { attempted : int
  ; consumed : int
  ; remaining : int
  }

exception Candidate_unavailable of string

let retryable_failure_kind_to_string = function
  | Runtime_configuration_unavailable -> "runtime_configuration_unavailable"
  | Prompt_contract_unavailable -> "prompt_contract_unavailable"
  | Provider_unavailable -> "provider_unavailable"
  | Response_contract_unavailable -> "response_contract_unavailable"
  | Durable_delivery_unavailable -> "durable_delivery_unavailable"
;;

let retryable_failure_kind_of_string = function
  | "runtime_configuration_unavailable" -> Some Runtime_configuration_unavailable
  | "prompt_contract_unavailable" -> Some Prompt_contract_unavailable
  | "provider_unavailable" -> Some Provider_unavailable
  | "response_contract_unavailable" -> Some Response_contract_unavailable
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

let current_schema = "masc.board_attention_candidates.v2"
let current_candidate_directory = "board_attention_candidates_v2"
let retired_candidate_directory = "board_attention_candidates"

let candidate_dir base_path =
  Filename.concat
    (Common.masc_dir_from_base_path ~base_path)
    current_candidate_directory
;;

let retired_candidate_path ~base_path ~keeper_name =
  Filename.concat
    (Filename.concat
       (Common.masc_dir_from_base_path ~base_path)
       retired_candidate_directory)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let candidate_path ~base_path ~keeper_name =
  Filename.concat
    (candidate_dir base_path)
    (Workspace_utils_backend_setup.sanitize_namespace_segment keeper_name ^ ".jsonl")
;;

let canonical_owner_base_path base_path =
  Config_dir_resolver.canonical_base_path base_path
  |> Result.map_error Config_dir_resolver.canonical_base_path_error_to_string
;;

let retired_epoch_residue ~base_path ~keeper_name =
  let path = retired_candidate_path ~base_path ~keeper_name in
  try
    match Unix.lstat path with
    | _ -> Ok (Some path)
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (error, operation, argument) ->
      Error
        (Printf.sprintf
           "failed to inspect retired Board attention candidate epoch path=%S operation=%s argument=%S: %s"
           path
           operation
           argument
           (Unix.error_message error))
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | exn ->
    Error
      (Printf.sprintf
         "failed to inspect retired Board attention candidate epoch path=%S: %s"
         path
         (Printexc.to_string exn))
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
  let* delivery_signal =
    Board_signal.board_stimulus_of_board_evidence
      ~meta
      ~signal
      ~post
      ~comments
    |> Result.map_error Board_signal.materialization_error_to_string
  in
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
      ; delivery_signal
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
    ; "attempt_count", `String (Attempt_count.to_string failure.attempt_count)
    ; "first_failed_at", `Float failure.first_failed_at
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
    ; "delivery_signal", Keeper_event_queue.board_stimulus_to_yojson candidate.delivery_signal
    ; "judgment_request", candidate.judgment_request
    ; "recorded_at", `Float candidate.recorded_at
    ; "status", status_to_yojson candidate.status
    ]
;;

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

let float_json ~context json =
  let* value =
    match json with
    | `Float value -> Ok value
    | `Int value -> Ok (float_of_int value)
    | _ -> Error (context ^ " must be a number")
  in
  if Float.is_finite value
  then Ok value
  else Error (context ^ " must be finite")
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
  let* () =
    exact_fields
      ~context
      [ "kind"; "detail"; "attempt_count"; "first_failed_at"; "failed_at" ]
      fields
  in
  let* kind_json = field ~context "kind" fields in
  let* kind_raw = string_json ~context:(context ^ ".kind") kind_json in
  let* kind =
    match retryable_failure_kind_of_string kind_raw with
    | Some kind -> Ok kind
    | None -> Error (Printf.sprintf "unknown retryable failure kind %S" kind_raw)
  in
  let* detail_json = field ~context "detail" fields in
  let* detail = string_json ~context:(context ^ ".detail") detail_json in
  let* attempt_count_json = field ~context "attempt_count" fields in
  let* attempt_count_raw =
    string_json ~context:(context ^ ".attempt_count") attempt_count_json
  in
  let* attempt_count = Attempt_count.of_string attempt_count_raw in
  let* first_failed_at_json = field ~context "first_failed_at" fields in
  let* first_failed_at =
    float_json ~context:(context ^ ".first_failed_at") first_failed_at_json
  in
  let* failed_at_json = field ~context "failed_at" fields in
  let* failed_at = float_json ~context:(context ^ ".failed_at") failed_at_json in
  Ok { kind; detail; attempt_count; first_failed_at; failed_at }
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
      ; "delivery_signal"
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
  let* delivery_signal_json = field ~context "delivery_signal" fields in
  let* delivery_signal = Keeper_event_queue.board_stimulus_of_yojson delivery_signal_json in
  let* judgment_request = field ~context "judgment_request" fields in
  let* (_ : (string * Yojson.Safe.t) list) =
    assoc ~context:(context ^ ".judgment_request") judgment_request
  in
  let* recorded_at_json = field ~context "recorded_at" fields in
  let* recorded_at = float_json ~context:(context ^ ".recorded_at") recorded_at_json in
  let* status_json = field ~context "status" fields in
  let* status = status_of_yojson status_json in
  Ok
    { candidate_id
    ; keeper_name
    ; signal
    ; delivery_signal
    ; judgment_request
    ; recorded_at
    ; status
    }
;;

let stored_row_to_json ~owner_base_path candidate =
  `Assoc
    [ "schema", `String current_schema
    ; "owner_base_path", `String owner_base_path
    ; "keeper_name", `String candidate.keeper_name
    ; "candidate", candidate_to_json candidate
    ]
;;

let stored_row_of_json ~expected_owner_base_path ~expected_keeper_name json =
  let context = "Board attention candidate v2 row" in
  let* fields = assoc ~context json in
  let* () =
    exact_fields
      ~context
      [ "schema"; "owner_base_path"; "keeper_name"; "candidate" ]
      fields
  in
  let* schema_json = field ~context "schema" fields in
  let* schema = string_json ~context:(context ^ ".schema") schema_json in
  let* () =
    if String.equal schema current_schema
    then Ok ()
    else Error (Printf.sprintf "unsupported Board attention candidate schema %S" schema)
  in
  let* owner_json = field ~context "owner_base_path" fields in
  let* owner_base_path =
    string_json ~context:(context ^ ".owner_base_path") owner_json
  in
  let* () =
    if String.equal owner_base_path expected_owner_base_path
    then Ok ()
    else
      Error
        (Printf.sprintf
           "Board attention candidate base-path owner mismatch expected=%S actual=%S"
           expected_owner_base_path
           owner_base_path)
  in
  let* keeper_json = field ~context "keeper_name" fields in
  let* keeper_name = string_json ~context:(context ^ ".keeper_name") keeper_json in
  let* () =
    if String.equal keeper_name expected_keeper_name
    then Ok ()
    else
      Error
        (Printf.sprintf
           "Board attention candidate Keeper owner mismatch expected=%S actual=%S"
           expected_keeper_name
           keeper_name)
  in
  let* candidate_json = field ~context "candidate" fields in
  let* candidate = candidate_of_json candidate_json in
  if String.equal candidate.keeper_name expected_keeper_name
  then Ok candidate
  else
    Error
      (Printf.sprintf
         "Board attention candidate embedded Keeper mismatch expected=%S actual=%S"
         expected_keeper_name
         candidate.keeper_name)
;;

let parse_rows ~expected_owner_base_path ~expected_keeper_name content =
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
           (match
              stored_row_of_json
                ~expected_owner_base_path
                ~expected_keeper_name
                json
            with
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

let load_candidates_from_content ~expected_owner_base_path ~expected_keeper_name content =
  let* rows =
    parse_rows ~expected_owner_base_path ~expected_keeper_name content
  in
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
  let* owner_base_path = canonical_owner_base_path base_path in
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
    let* candidates =
      read_locked
        path
        (load_candidates_from_content
           ~expected_owner_base_path:owner_base_path
           ~expected_keeper_name:keeper_name)
    in
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

let append_row ~owner_base_path candidate =
  Yojson.Safe.to_string (stored_row_to_json ~owner_base_path candidate) ^ "\n"
;;

let serialize_candidates ~owner_base_path candidates =
  String.concat "" (List.map (append_row ~owner_base_path) candidates)
;;

let rewrite_ledger ~base_path ~keeper_name decide =
  let* owner_base_path = canonical_owner_base_path base_path in
  let path = candidate_path ~base_path ~keeper_name in
  match
    Fs_compat.rewrite_private_file_durable_locked_result path (fun content ->
      match
        load_candidates_from_content
          ~expected_owner_base_path:owner_base_path
          ~expected_keeper_name:keeper_name
          content
      with
      | Error detail -> None, Error detail
      | Ok candidates ->
        (match decide candidates with
         | Error _ as error -> None, error
         | Ok (None, result) -> None, Ok result
         | Ok (Some rewritten, result) ->
           Some (serialize_candidates ~owner_base_path rewritten), Ok result))
  with
  | Error error -> Error error
  | Ok result -> result
;;

let update_ledger ~base_path ~keeper_name decide =
  (* Compact on write: a committed change rewrites the ledger as the deduped
     latest-per-id set (via [latest_candidates]) instead of appending one row.
     The reader already discards all but the latest row per candidate_id, so the
     older rows are dead weight; appending them grew the file without bound and
     made every update O(n^2) because the durable transaction re-parses the whole
     ledger before writing. Rewriting keeps the file bounded to the number of
     distinct candidates. *)
  rewrite_ledger ~base_path ~keeper_name (fun candidates ->
    match decide candidates with
    | Error _ as error -> error
    | Ok (None, result) -> Ok (None, result)
    | Ok (Some candidate, result) ->
      Ok (Some (latest_candidates (candidates @ [ candidate ])), result))
;;

let find_candidate candidates candidate_id =
  List.find_opt
    (fun candidate -> String.equal candidate.candidate_id candidate_id)
    candidates
;;

let record ~base_path candidate =
  match candidate.status with
  | Judged _ | Consumed _ | Pending { last_failure = Some _ } ->
    Record_error
      "Board attention admission requires Pending status without retry evidence"
  | Pending { last_failure = None } ->
    (match candidate_of_json (candidate_to_json candidate) with
     | Error detail -> Record_error ("invalid Board attention candidate: " ^ detail)
     | Ok candidate ->
    (match
       update_ledger
         ~base_path
         ~keeper_name:candidate.keeper_name
         (fun candidates ->
            match find_candidate candidates candidate.candidate_id with
            | None -> Ok (Some candidate, Recorded candidate)
            | Some existing
              when existing.signal = candidate.signal
                   && existing.delivery_signal = candidate.delivery_signal ->
              Ok (None, Duplicate existing)
            | Some _ ->
              Error
                "candidate identity conflict: the same candidate_id has different Board occurrence or delivery evidence")
     with
     | Ok result -> result
     | Error detail -> Record_error detail))
;;

let update_candidate ~base_path candidate_id keeper_name transition =
  update_ledger ~base_path ~keeper_name (fun candidates ->
    match find_candidate candidates candidate_id with
    | None -> Error (Printf.sprintf "Board attention candidate not found: %s" candidate_id)
    | Some current ->
      let* transition = transition current in
      (match transition with
       | None -> Ok (None, current)
       | Some updated -> Ok (Some updated, updated)))
;;

let validate_failure_occurrence failure =
  if not (String.equal (Attempt_count.to_string failure.attempt_count) "1")
  then
    Error
      "Board attention retry occurrence must enter the durable boundary with attempt_count=1"
  else if not (Float.is_finite failure.first_failed_at && Float.is_finite failure.failed_at)
  then Error "Board attention retry occurrence timestamps must be finite"
  else if Float.compare failure.first_failed_at failure.failed_at <> 0
  then
    Error
      "Board attention retry occurrence must enter the durable boundary with identical first_failed_at and failed_at"
  else Ok failure
;;

let next_failure previous failure =
  let* failure = validate_failure_occurrence failure in
  match previous with
  | None -> Ok failure
  | Some previous ->
    Ok
      { failure with
        attempt_count = Attempt_count.succ previous.attempt_count
      ; first_failed_at = previous.first_failed_at
      }
;;

let with_retryable_failure failure current =
  match current.status with
  | Pending pending ->
    let* next_failure = next_failure pending.last_failure failure in
    Ok
      (Some
         { current with
           status = Pending { last_failure = Some next_failure }
         })
  | Judged judged ->
    let* next_failure = next_failure judged.last_failure failure in
    Ok
      (Some
         { current with
           status = Judged { judged with last_failure = Some next_failure }
         })
  | Consumed _ -> Ok None
;;

let record_retryable_failure ~base_path candidate failure =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (with_retryable_failure failure)
;;

let record_judgment ~base_path candidate judgment =
  update_candidate
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
       | Judged _ | Consumed _ -> Ok None)
;;

let mark_consumed ~base_path candidate judgment delivery =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       match current.status with
       | Judged _ ->
         Ok
           (Some
              { current with
                status =
                  Consumed
                    { judgment; delivery; consumed_at = Time_compat.now () }
              })
       | Pending _ | Consumed _ -> Ok None)
;;

let failure ~kind detail =
  let failed_at = Time_compat.now () in
  { kind
  ; detail
  ; attempt_count = Attempt_count.one
  ; first_failed_at = failed_at
  ; failed_at
  }
;;

let board_attention_stimulus candidate =
  { Keeper_event_queue.post_id = candidate.signal.post_id
  ; urgency = Keeper_event_queue.Normal
  ; arrived_at = candidate.recorded_at
  ; payload =
      Keeper_event_queue.Board_attention
        { candidate_id = candidate.candidate_id
        ; signal = candidate.delivery_signal
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

let record_and_wake ~base_path candidate =
  match record ~base_path candidate with
  | Record_error detail -> Error detail
  | Recorded persisted ->
    let wake =
      Wake_requested (request_owner_wake ~site:"recorded" ~base_path persisted)
    in
    Ok { candidate = persisted; persistence = Candidate_recorded; wake }
  | Duplicate persisted ->
    let wake =
      match persisted.status with
      | Pending _ | Judged _ ->
        Wake_requested (request_owner_wake ~site:"duplicate" ~base_path persisted)
      | Consumed _ -> Wake_not_required
    in
    Ok
      { candidate = persisted
      ; persistence = Candidate_already_present
      ; wake
      }
;;

(* ── Batch judgment ───────────────────────────────────── *)

let prompt_name_batch = Keeper_prompt_names.board_attention_judgment_batch

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

let quoted_ids ids =
  String.concat "," (List.map (Printf.sprintf "%S") ids)
;;

let validate_batch_judgments candidates judgments =
  let requested =
    List.fold_left
      (fun ids candidate -> Id_set.add candidate.candidate_id ids)
      Id_set.empty
      candidates
  in
  if Id_set.cardinal requested <> List.length candidates
  then
    Error
      (failure
         ~kind:Response_contract_unavailable
         "Board attention owner-lane batch contains duplicate candidate identities")
  else
    let unknown =
      Candidate_map.bindings judgments
      |> List.filter_map (fun (candidate_id, _) ->
        if Id_set.mem candidate_id requested then None else Some candidate_id)
    in
    let missing =
      List.filter_map
        (fun candidate ->
           if Candidate_map.mem candidate.candidate_id judgments
           then None
           else Some candidate.candidate_id)
        candidates
    in
    match unknown with
    | candidate_id :: other_candidate_ids ->
      let candidate_ids = candidate_id :: other_candidate_ids in
      let detail =
        match missing with
        | [] ->
          Printf.sprintf
            "batch verdict references unknown candidate_ids [%s]"
            (quoted_ids candidate_ids)
        | _ :: _ ->
          Printf.sprintf
            "batch verdict references unknown candidate_ids [%s] and omits requested candidate_ids [%s]"
            (quoted_ids candidate_ids)
            (quoted_ids missing)
      in
      Error (failure ~kind:Response_contract_unavailable detail)
    | [] ->
      (match missing with
       | _ :: _ ->
         Error
           (failure
              ~kind:Response_contract_unavailable
              (Printf.sprintf
                 "batch verdict omits requested candidate_ids [%s]"
                 (quoted_ids missing)))
       | [] -> Ok judgments)
;;

let record_batch_failure ~base_path candidates failure =
  match candidates with
  | [] -> Ok ()
  | first :: _ ->
    (match
       List.find_opt
         (fun candidate -> not (String.equal candidate.keeper_name first.keeper_name))
         candidates
     with
     | Some candidate ->
       Error
         (Printf.sprintf
            "Board attention failure batch crosses Keeper lanes: %S and %S"
            first.keeper_name
            candidate.keeper_name)
     | None ->
       let requested =
         List.fold_left
           (fun ids candidate -> Id_set.add candidate.candidate_id ids)
           Id_set.empty
           candidates
       in
       rewrite_ledger ~base_path ~keeper_name:first.keeper_name (fun current ->
         let* rewritten, found, changed =
           List.fold_right
             (fun candidate result ->
                let* rows, found, changed = result in
                if Id_set.mem candidate.candidate_id requested
                then
                  let found = Id_set.add candidate.candidate_id found in
                  let* updated = with_retryable_failure failure candidate in
                  (match updated with
                   | None -> Ok (candidate :: rows, found, changed)
                   | Some updated -> Ok (updated :: rows, found, true))
                else Ok (candidate :: rows, found, changed))
             current
             (Ok ([], Id_set.empty, false))
         in
         let missing = Id_set.diff requested found |> Id_set.elements in
         match missing with
         | _ :: _ ->
           Error
             (Printf.sprintf
                "Board attention candidates disappeared before failure evidence commit: [%s]"
                (quoted_ids missing))
         | [] ->
           Ok ((if changed then Some rewritten else None), ())))
;;

let record_batch_judgments ~base_path ~keeper_name candidates judgments =
  let requested =
    List.fold_left
      (fun ids candidate -> Id_set.add candidate.candidate_id ids)
      Id_set.empty
      candidates
  in
  rewrite_ledger ~base_path ~keeper_name (fun current ->
    let rec rewrite found judged reversed = function
      | [] ->
        let missing = Id_set.diff requested found |> Id_set.elements in
        (match missing with
         | _ :: _ ->
           Error
             (Printf.sprintf
                "Board attention candidates disappeared before judgment commit: [%s]"
                (quoted_ids missing))
         | [] -> Ok (Some (List.rev reversed), List.rev judged))
      | candidate :: rest ->
        if not (Id_set.mem candidate.candidate_id requested)
        then rewrite found judged (candidate :: reversed) rest
        else
          let found = Id_set.add candidate.candidate_id found in
          (match Candidate_map.find_opt candidate.candidate_id judgments with
           | None ->
             Error
               (Printf.sprintf
                  "validated Board attention verdict disappeared before commit candidate_id=%S"
                  candidate.candidate_id)
           | Some judgment ->
             (match candidate.status with
              | Pending _ ->
                let updated =
                  { candidate with
                    status = Judged { judgment; last_failure = None }
                  }
                in
                rewrite found (updated :: judged) (updated :: reversed) rest
              | Judged _ | Consumed _ ->
                Error
                  (Printf.sprintf
                     "Board attention candidate changed state before judgment commit candidate_id=%S"
                     candidate.candidate_id)))
    in
    rewrite Id_set.empty [] [] current)
;;

type delivery_attempt_outcome =
  | Delivery_committed of delivery
  | Delivery_failed of retryable_failure

type delivery_attempt =
  { da_candidate : candidate
  ; da_judgment : judgment
  ; da_outcome : delivery_attempt_outcome
  }

let attempt_judged_delivery ~base_path candidate judgment =
  match judgment.verdict.decision with
  | Keeper_board_attention_judgment.Not_relevant ->
    { da_candidate = candidate
    ; da_judgment = judgment
    ; da_outcome = Delivery_committed Not_relevant
    }
  | Keeper_board_attention_judgment.Relevant ->
    let stimulus = board_attention_stimulus candidate in
    let da_outcome =
      match
        Keeper_registry_event_queue.enqueue_if_missing_durable_result
          ~base_path
          ~event_id:candidate.candidate_id
          candidate.keeper_name
          stimulus
      with
      | Keeper_registry_event_queue.Enqueued
      | Keeper_registry_event_queue.Already_present ->
        Delivery_committed Enqueued_to_keeper_lane
      | Keeper_registry_event_queue.Identity_conflict detail
      | Keeper_registry_event_queue.Storage_error detail ->
        Delivery_failed (failure ~kind:Durable_delivery_unavailable detail)
    in
    { da_candidate = candidate; da_judgment = judgment; da_outcome }
;;

let commit_delivery_attempts ~base_path ~keeper_name attempts =
  let attempt_index_result =
    List.fold_left
      (fun result attempt ->
         let* index = result in
         let candidate_id = attempt.da_candidate.candidate_id in
         if Candidate_map.mem candidate_id index
         then
           Error
             (Printf.sprintf
                "Board attention delivery batch duplicates candidate_id=%S"
                candidate_id)
         else Ok (Candidate_map.add candidate_id attempt index))
      (Ok Candidate_map.empty)
      attempts
  in
  let* attempt_index = attempt_index_result in
  let requested =
    Candidate_map.fold (fun candidate_id _ ids -> Id_set.add candidate_id ids)
      attempt_index
      Id_set.empty
  in
  let consumed_at = Time_compat.now () in
  rewrite_ledger ~base_path ~keeper_name (fun current ->
    let rec rewrite found consumed wake reversed = function
      | [] ->
        let missing = Id_set.diff requested found |> Id_set.elements in
        (match missing with
         | _ :: _ ->
           Error
             (Printf.sprintf
                "Board attention candidates disappeared before delivery commit: [%s]"
                (quoted_ids missing))
         | [] ->
           Ok
             ( Some (List.rev reversed)
             , (consumed, List.length attempts - consumed, List.rev wake) ))
      | candidate :: rest ->
        (match Candidate_map.find_opt candidate.candidate_id attempt_index with
         | None -> rewrite found consumed wake (candidate :: reversed) rest
         | Some attempt ->
           let found = Id_set.add candidate.candidate_id found in
           (match candidate.status with
            | Judged judged when judged.judgment = attempt.da_judgment ->
              (match attempt.da_outcome with
               | Delivery_committed delivery ->
                 let updated =
                   { candidate with
                     status =
                       Consumed
                         { judgment = attempt.da_judgment
                         ; delivery
                         ; consumed_at
                         }
                   }
                 in
                 let wake =
                   match delivery with
                   | Not_relevant -> wake
                   | Enqueued_to_keeper_lane -> updated :: wake
                 in
                 rewrite found (consumed + 1) wake (updated :: reversed) rest
               | Delivery_failed failure ->
                 (match with_retryable_failure failure candidate with
                  | Error detail -> Error detail
                  | Ok None ->
                    Error
                      (Printf.sprintf
                         "Board attention judged candidate rejected retry evidence candidate_id=%S"
                         candidate.candidate_id)
                  | Ok (Some updated) ->
                    rewrite found consumed wake (updated :: reversed) rest))
            | Pending _ | Consumed _ | Judged _ ->
              Error
                (Printf.sprintf
                   "Board attention candidate changed state before delivery commit candidate_id=%S"
                   candidate.candidate_id)))
    in
    rewrite Id_set.empty 0 [] [] current)
  |> Result.map (fun (consumed, remaining, wake) ->
    List.iter
      (fun candidate ->
         let (_ : Keeper_registry.wakeup_outcome) =
           request_owner_wake ~site:"durable_delivery_batch" ~base_path candidate
         in
         ())
      wake;
    consumed, remaining)
;;

let consume_judged_batch ~base_path ~keeper_name judged =
  let attempts =
    List.map
      (fun (candidate, (state : judged_state)) ->
         attempt_judged_delivery ~base_path candidate state.judgment)
      judged
  in
  commit_delivery_attempts ~base_path ~keeper_name attempts
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
  let* judged_consumed, judged_remaining =
    match judged_ready with
    | [] -> Ok (0, 0)
    | _ :: _ ->
      consume_judged_batch
        ~base_path
        ~keeper_name
        (List.rev judged_ready)
  in
  let pending = List.rev pending in
  let pending_count = List.length pending in
  match pending with
  | [] ->
    Ok
      { attempted = judged_consumed + judged_remaining
      ; consumed = judged_consumed
      ; remaining = judged_remaining
      }
  | _ :: _ ->
    (match judge_batch pending with
     | Error failure ->
       let* () = record_batch_failure ~base_path pending failure in
       Ok
         { attempted = pending_count + judged_consumed + judged_remaining
         ; consumed = judged_consumed
         ; remaining = pending_count + judged_remaining
         }
     | Ok judgments ->
       (match validate_batch_judgments pending judgments with
        | Error failure ->
          let* () = record_batch_failure ~base_path pending failure in
          Ok
            { attempted = pending_count + judged_consumed + judged_remaining
            ; consumed = judged_consumed
            ; remaining = pending_count + judged_remaining
            }
        | Ok exact_judgments ->
          let* newly_judged =
            record_batch_judgments
              ~base_path
              ~keeper_name
              pending
              exact_judgments
          in
          let* newly_judged =
            let rec collect reversed = function
              | [] -> Ok (List.rev reversed)
              | candidate :: rest ->
                (match candidate.status with
                 | Judged judged -> collect ((candidate, judged) :: reversed) rest
                 | Pending _ | Consumed _ ->
                   Error
                     (Printf.sprintf
                        "judgment commit returned non-Judged candidate_id=%S"
                        candidate.candidate_id))
            in
            collect [] newly_judged
          in
          let* consumed, remaining =
            consume_judged_batch ~base_path ~keeper_name newly_judged
          in
          Ok
            { attempted = pending_count + judged_consumed + judged_remaining
            ; consumed = consumed + judged_consumed
            ; remaining = remaining + judged_remaining
            }))
;;

let drain_pending_on_owner_lane ~base_path ~keeper_name =
  drain_pending_with_judge_batch
    ~base_path
    ~keeper_name
    ~judge_batch:(run_judge_batch ~base_path)
;;

module For_testing = struct
  let next_retryable_failure ~previous failure = next_failure previous failure
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
