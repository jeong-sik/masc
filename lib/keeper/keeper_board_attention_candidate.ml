(* See .mli. *)

module Board_signal = Keeper_world_observation_board_signal
module Candidate_map = Map.Make (String)
module Id_set = Set.Make (String)

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
  | Durable_delivery_unavailable
  | Lifecycle_policy_migrated

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
  | Lifecycle_policy_migrated -> "lifecycle_policy_migrated"
;;

let retryable_failure_kind_of_string = function
  | "runtime_configuration_unavailable" -> Some Runtime_configuration_unavailable
  | "prompt_contract_unavailable" -> Some Prompt_contract_unavailable
  | "provider_unavailable" -> Some Provider_unavailable
  | "response_contract_unavailable" -> Some Response_contract_unavailable
  | "durable_delivery_unavailable" -> Some Durable_delivery_unavailable
  | "lifecycle_policy_migrated" -> Some Lifecycle_policy_migrated
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
  | "expired" ->
    let* () = exact_fields ~context [ "kind"; "expired_at" ] fields in
    let* expired_at_json = field ~context "expired_at" fields in
    let* expired_at = float_json ~context:(context ^ ".expired_at") expired_at_json in
    Ok
      (Pending
         { last_failure =
             Some
               { kind = Lifecycle_policy_migrated
               ; detail =
                   "legacy wall-clock expiry recovered to Pending; no customer work was discarded"
               ; failed_at = expired_at
               }
         })
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
let batch_max_candidates = 8

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

let select_context_batch candidates =
  match candidates with
  | [] -> [], []
  | first :: rest ->
    (match keeper_context_key first with
     | Error _ -> [ first ], rest
     | Ok first_key ->
       let rec loop selected deferred selected_count = function
         | [] -> List.rev selected, List.rev deferred
         | candidate :: tail ->
           if selected_count < batch_max_candidates
           then
             (match keeper_context_key candidate with
              | Ok key when String.equal first_key key ->
                loop
                  (candidate :: selected)
                  deferred
                  (selected_count + 1)
                  tail
              | Ok _ | Error _ ->
                loop selected (candidate :: deferred) selected_count tail)
           else
             loop selected (candidate :: deferred) selected_count tail
       in
       loop [ first ] [] 1 rest)
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

let apply_judgment ~base_path candidate judgment =
  process_with_judge ~base_path ~judge:(fun _ -> Ok judgment) candidate
;;

let record_batch_failure ~base_path candidate failure =
  match record_retryable_failure ~base_path candidate failure with
  | Ok _ -> Ok ()
  | Error detail ->
    Error
      (Printf.sprintf
         "Board attention batch failure evidence could not be persisted keeper=%s \
          candidate=%s: %s"
         candidate.keeper_name
         candidate.candidate_id
         detail)
;;

let record_batch_failures ~base_path candidates failure =
  List.fold_left
    (fun result candidate ->
       let* () = result in
       record_batch_failure ~base_path candidate failure)
    (Ok ())
    candidates
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
    List.fold_left
      (fun result (candidate, judged) ->
         match result with
         | Error _ -> result
         | Ok (consumed, remaining) ->
           (match consume_judged ~base_path candidate judged with
            | Ok current ->
              (match current.status with
               | Consumed _ -> Ok (consumed + 1, remaining)
               | Pending _ | Judged _ -> Ok (consumed, remaining + 1))
            | Error detail -> Error detail))
      (Ok (0, 0))
      judged_ready
  in
  (* A single owner admission performs at most one provider call, and that
     call contains one exact persisted Keeper context. Other contexts and
     capacity overflow remain durable for a later admission. *)
  let batch, deferred = select_context_batch (List.rev pending) in
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
            let* consumed, remaining =
              List.fold_left
                (fun result candidate ->
                   let* consumed, remaining = result in
                   match Candidate_map.find_opt candidate.candidate_id judgments with
                   | None ->
                     Error "validated batch verdict disappeared before application"
                   | Some judgment ->
                     let* current = apply_judgment ~base_path candidate judgment in
                     (match current.status with
                      | Consumed _ -> Ok (consumed + 1, remaining)
                      | Pending _ | Judged _ -> Ok (consumed, remaining + 1)))
                (Ok (0, 0))
                batch
            in
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

let drain_pending_on_owner_lane ~base_path ~keeper_name =
  drain_pending_with_judge_batch
    ~base_path
    ~keeper_name
    ~judge_batch:(run_judge_batch ~base_path)
;;

module For_testing = struct
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
