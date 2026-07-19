(* See .mli. *)

module Board_signal = Keeper_world_observation_board_signal
module Candidate_map = Map.Make (String)
module Judgment_failure = Keeper_board_attention_failure

type retryable_failure_kind =
  | Runtime_configuration_unavailable
  | Prompt_contract_unavailable
  | Provider_unavailable
  | Response_contract_unavailable
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

type wake_decision =
  | Judgment_worker_requested of Keeper_board_attention_worker_wake.wake_result
  | Wake_not_required

type record_acceptance =
  { candidate : candidate
  ; persistence : persistence
  ; wake : wake_decision
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
             Some (serialize_candidates compacted), Ok result))
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

let same_judgment left right =
  left.verdict = right.verdict
  && String.equal left.runtime_id right.runtime_id
  && Float.equal left.judged_at right.judged_at
;;

let candidate_with_retryable_failure current failure =
  match current.status with
  | Pending pending ->
    (match pending.last_failure with
     | Some existing when same_failure existing failure -> current
     | Some _ | None ->
       { current with status = Pending { last_failure = Some failure } })
  | Judged judged ->
    (match judged.last_failure with
     | Some existing when same_failure existing failure -> current
     | Some _ | None ->
       { current with
         status = Judged { judged with last_failure = Some failure }
       })
  | Consumed _ -> current
;;

let record_retryable_failure ~base_path candidate failure =
  update_candidate
    ~base_path
    candidate.candidate_id
    candidate.keeper_name
    (fun current ->
       let updated = candidate_with_retryable_failure current failure in
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
      (match current.status with
       | Pending _ ->
         let updated =
           { current with
             status = Judged { judgment; last_failure = None }
           }
         in
         Ok (Some updated, updated)
       | Judged judged when same_judgment judged.judgment judgment ->
         Ok (None, current)
       | Consumed consumed when same_judgment consumed.judgment judgment ->
         Ok (None, current)
       | Judged _ | Consumed _ ->
         Error
           ("Board attention candidate judgment conflict: "
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
      (match current.status with
       | Judged judged when same_judgment judged.judgment judgment ->
         let updated =
           { current with
             status =
               Consumed
                 { judgment; delivery; consumed_at = Time_compat.now () }
           }
         in
         Ok (Some updated, updated)
       | Consumed consumed
         when same_judgment consumed.judgment judgment
              && consumed.delivery = delivery -> Ok (None, current)
       | Pending _ ->
         Error
           ("Pending Board attention candidate cannot be consumed: "
            ^ candidate.candidate_id)
       | Judged _ | Consumed _ ->
         Error
           ("Board attention candidate consumption conflict: "
            ^ candidate.candidate_id)))
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
      match persisted.status with
      | Pending _ | Judged _ ->
        request_worker persisted
      | Consumed _ -> Ok Wake_not_required
    in
    Ok
      { candidate = persisted
      ; persistence = Candidate_already_present
      ; wake
      }
;;

(* The configured output contract remains a one-item [verdicts] array so the
   prompt/schema SSOT does not fork. Partition membership itself is singleton:
   no candidate count, byte estimate, or token heuristic participates. *)

let prompt_name_batch = Keeper_prompt_names.board_attention_judgment_batch

let singleton_request_json candidate =
  match candidate.judgment_request with
  | `Assoc fields ->
    let contexts, item_fields =
      List.partition
        (fun (key, _) -> String.equal key "keeper_context")
        fields
    in
    (match contexts with
     | [ (_, keeper_context) ] ->
       Ok
         (`Assoc
            [ "keeper_context", keeper_context
            ; "items", `List [ `Assoc item_fields ]
            ])
     | [] -> Error "singleton judgment request lacks keeper_context"
     | _ -> Error "singleton judgment request contains multiple keeper_context fields")
  | _ -> Error "singleton judgment request must be an object"
;;

let build_singleton_prompt candidate =
  let* json = singleton_request_json candidate in
  Prompt_registry.render_prompt_template
    prompt_name_batch
    [ "batch_request_json", Yojson.Safe.to_string json ]
;;

let apply_batch_output_schema provider_config =
  Ok
    (Keeper_structured_output_schema.apply_schema_json_mode_or_prompt_tier
       ~log_label:"keeper Board attention batch judgment output contract"
       Keeper_structured_output_schema.board_attention_judgment_batch_output_schema
       provider_config)
;;

let judge_singleton ~sw ~net ~base_path candidate =
  let runtime_id_result =
    try Ok (Runtime.runtime_id_for_structured_judge ()) with
    | Eio.Cancel.Cancelled _ as exn -> raise exn
    | exn ->
      Error
        (Judgment_failure.runtime_configuration_change
           ~failed_at:(Time_compat.now ())
           ~detail:(Printexc.to_string exn))
  in
  match runtime_id_result with
  | Error _ as error -> error
  | Ok runtime_id ->
    (match build_singleton_prompt candidate with
     | Error detail ->
       Error
         (Judgment_failure.blocked
            ~blocked_at:(Time_compat.now ())
            ~kind:Judgment_failure.Prompt_contract_unavailable
            ~detail)
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
               ~provider_config_transform:apply_batch_output_schema
               ~sw
               ?net
               ()
           with
           | Ok result -> Ok result
           | Error error ->
             Error
               (Judgment_failure.of_sdk_error
                  ~observed_at:(Time_compat.now ())
                  error)
         with
         | Eio.Cancel.Cancelled _ as exn -> raise exn
         | exn ->
           Error
             (Judgment_failure.blocked
                ~blocked_at:(Time_compat.now ())
                ~kind:Judgment_failure.Unexpected_judgment_exception
                ~detail:(Printexc.to_string exn))
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
             Error
               (Judgment_failure.blocked
                  ~blocked_at:(Time_compat.now ())
                  ~kind:Judgment_failure.Response_contract_unavailable
                  ~detail)
           | Ok json ->
             (match Keeper_board_attention_judgment.batch_of_yojson json with
              | Error detail ->
                Error
                  (Judgment_failure.blocked
                     ~blocked_at:(Time_compat.now ())
                     ~kind:Judgment_failure.Response_contract_unavailable
                     ~detail)
              | Ok [ item ] when String.equal item.candidate_id candidate.candidate_id ->
                Ok
                  { verdict = item.verdict
                  ; runtime_id
                  ; judged_at = Time_compat.now ()
                  }
              | Ok [ item ] ->
                Error
                  (Judgment_failure.blocked
                     ~blocked_at:(Time_compat.now ())
                     ~kind:Judgment_failure.Response_contract_unavailable
                     ~detail:
                       (Printf.sprintf
                          "singleton verdict identity mismatch expected=%S actual=%S"
                          candidate.candidate_id
                          item.candidate_id))
              | Ok items ->
                Error
                  (Judgment_failure.blocked
                     ~blocked_at:(Time_compat.now ())
                     ~kind:Judgment_failure.Response_contract_unavailable
                     ~detail:
                       (Printf.sprintf
                          "singleton verdict count must be exactly one, got %d"
                          (List.length items)))))))
;;

let apply_judgment_and_deliver ~base_path ~keeper_name ~candidate_id ~judgment =
  let* candidates = load_candidates ~base_path ~keeper_name in
  let* candidate =
    match find_candidate candidates candidate_id with
    | Some candidate -> Ok candidate
    | None -> Error ("Board attention candidate not found: " ^ candidate_id)
  in
  let* judged_candidate =
    match candidate.status with
    | Pending _ -> record_judgment ~base_path candidate judgment
    | Judged judged when same_judgment judged.judgment judgment -> Ok candidate
    | Consumed consumed when same_judgment consumed.judgment judgment -> Ok candidate
    | Judged _ | Consumed _ ->
      Error ("Board attention candidate judgment conflicts with worker result: " ^ candidate_id)
  in
  match judged_candidate.status with
  | Consumed _ -> Ok judged_candidate
  | Pending _ ->
    Error ("Board attention candidate remained Pending after judgment commit: " ^ candidate_id)
  | Judged judged ->
    let* delivered = consume_judged ~base_path judged_candidate judged in
    (match delivered.status with
     | Consumed _ -> Ok delivered
     | Pending _ | Judged _ ->
       Error ("Board attention candidate delivery did not reach Consumed: " ^ candidate_id))
;;
