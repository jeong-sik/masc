open Board_types

type read =
  | Complete of { observation : sub_boards_source_observation; rows : sub_board list;
                  diagnostics : sub_boards_source_diagnostic list }
  | Partial of { observation : sub_boards_source_observation; rows : sub_board list;
                 errors : sub_boards_row_error list; diagnostics : sub_boards_source_diagnostic list }
  | Unavailable of { failure : sub_boards_source_failure;
                     diagnostics : sub_boards_source_diagnostic list }

type publication = sub_boards_publication
type write =
  | Written of { publication : publication; diagnostics : sub_boards_source_diagnostic list }
  | Not_written of { failure : sub_boards_source_failure; diagnostics : sub_boards_source_diagnostic list }
  | Unknown of { failure : sub_boards_source_failure; diagnostics : sub_boards_source_diagnostic list }

let unavailable_error () = Io_error "Board data is unavailable."

let reserved_diagnostics = List.find_map (function
  | Policy_file_diagnostic error -> Board_posts_source.reserved_transaction error
  | Policy_workspace_diagnostic rejection ->
    Option.bind (Board_workspace_binding.raised rejection) Board_posts_source.reserved_exception
  | Policy_raised_diagnostic { exception_; backtrace } ->
    Board_posts_source.reserved_exception (exception_, backtrace))

let finish result diagnostics =
  Option.iter (fun (exception_, backtrace) ->
    Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result) exception_ backtrace)
    (reserved_diagnostics diagnostics);
  result

let history = function
  | Policy_unobserved -> No_policy_observation
  | Policy_readable observation -> Policy_observed observation
  | Policy_publishing publication -> Policy_observed publication.policy_after
  | Policy_refused { policy_history; _ } -> policy_history
  | Policy_unsettled { policy_pending; _ } -> Policy_observed policy_pending.policy_before

let refuse store failure diagnostics = match store.sub_boards_source with
  | Policy_publishing _ | Policy_unsettled _ -> ()
  | Policy_unobserved | Policy_readable _ | Policy_refused _ ->
    store.sub_boards_source <- Policy_refused {
      policy_history = history store.sub_boards_source;
      policy_failure = failure; policy_diagnostics = diagnostics }

let refuse_present store failure diagnostics =
  let policy_history = match history store.sub_boards_source with
    | No_policy_observation | Policy_present_without_snapshot -> Policy_present_without_snapshot
    | Policy_observed observation as previous ->
      if Fs_compat.Private_jsonl_cursor.is_missing observation.policy_snapshot.cursor
      then Policy_present_without_snapshot else previous in
  match store.sub_boards_source with
  | Policy_publishing _ | Policy_unsettled _ -> ()
  | Policy_unobserved | Policy_readable _ | Policy_refused _ ->
    store.sub_boards_source <- Policy_refused {
      policy_history; policy_failure = failure; policy_diagnostics = diagnostics }

let expected store = match store.sub_boards_source with
  | Policy_readable observation ->
    if String.equal observation.policy_path (Board_paths.sub_boards_path store)
    then Ok observation else Error Policy_binding_mismatch
  | Policy_unobserved -> Error Policy_not_observed
  | Policy_publishing _ -> Error Policy_publication_pending
  | Policy_refused { policy_failure; _ } | Policy_unsettled { policy_failure; _ } ->
    Error policy_failure

let require_readable store = match expected store with
  | Ok _ -> Ok () | Error _ -> Error (unavailable_error ())

let missing_allowed store = match history store.sub_boards_source with
  | No_policy_observation -> true
  | Policy_present_without_snapshot -> false
  | Policy_observed observation -> Fs_compat.Private_jsonl_cursor.is_missing observation.policy_snapshot.cursor

let receipt_diagnostics = function
  | None -> [] | Some error -> [Policy_file_diagnostic error]

let read_file store path = match store.sub_boards_source_io with
  | None -> Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
  | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing ~io path ~after:None

let observe_workspace store =
  try Board_paths.observe_workspace store with exception_ ->
    Error (Board_workspace_binding.Raised { exception_; backtrace = Printexc.get_raw_backtrace () })

let finish_workspace store before =
  if Board_workspace_binding.workspace_directory_missing before then
    match observe_workspace store with
    | Error _ as error -> error
    | Ok after when Board_workspace_binding.workspace_directory_missing after ->
      Error (Board_workspace_binding.Workspace_directory_changed (Board_paths.workspace_masc_dir store))
    | Ok after -> Ok after
  else Result.map (fun () -> before)
    (Board_workspace_binding.revalidate store.workspace_binding before)

let read store = match store.sub_boards_source with
  | Policy_unsettled { policy_failure; _ } -> Unavailable { failure = policy_failure; diagnostics = [] }
  | Policy_publishing _ -> Unavailable { failure = Policy_publication_pending; diagnostics = [] }
  | Policy_unobserved | Policy_readable _ | Policy_refused _ ->
    let diagnostics = ref [] and saw_present = ref false in
    let unavailable failure =
      (if !saw_present then refuse_present else refuse) store failure !diagnostics;
      Unavailable { failure; diagnostics = !diagnostics } in
    try
      match observe_workspace store with
      | Error rejection -> diagnostics := [Policy_workspace_diagnostic rejection];
        unavailable (Policy_workspace_refused rejection)
      | Ok before ->
        let path = Board_paths.sub_boards_path store in
        match Fs_compat.private_jsonl_snapshot_success_receipt (read_file store path) with
        | Error error ->
          diagnostics := [Policy_file_diagnostic error];
          saw_present := Fs_compat.private_jsonl_transaction_error_is_incomplete_tail error;
          unavailable (Policy_transaction_failed error)
        | Ok receipt ->
          diagnostics := receipt_diagnostics receipt.settlement_error;
          saw_present := not (Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor);
          match reserved_diagnostics !diagnostics with
          | Some (exception_, backtrace) -> unavailable (Policy_raised { exception_; backtrace })
          | None ->
            match finish_workspace store before with
            | Error rejection -> diagnostics := !diagnostics @ [Policy_workspace_diagnostic rejection];
              unavailable (Policy_workspace_refused rejection)
            | Ok policy_workspace ->
              if Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor && not (missing_allowed store)
              then unavailable Policy_missing
              else (
                let rows = ref [] and errors = ref [] in
                String.split_on_char '\n' receipt.value.bytes |> List.iteri (fun index text ->
                  if String.trim text <> "" then
                    match Yojson.Safe.from_string text with
                    | json ->
                      (match Board_sub_board_json.sub_board_of_yojson json with
                       | Some row -> rows := row :: !rows
                       | None -> errors := Invalid_policy_row { line = index + 1 } :: !errors)
                    | exception Yojson.Json_error detail ->
                      errors := Invalid_policy_json { line = index + 1; detail } :: !errors);
                let observation = { policy_path = path; policy_snapshot = receipt.value; policy_workspace } in
                match List.rev !errors with
                | [] -> Complete { observation; rows = List.rev !rows; diagnostics = !diagnostics }
                | errors -> Partial { observation; rows = List.rev !rows; errors; diagnostics = !diagnostics })
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Policy_raised_diagnostic { exception_; backtrace }];
      unavailable (Policy_raised { exception_; backtrace })

let publish_read store outcome = match store.sub_boards_source with
  | Policy_publishing _ | Policy_unsettled _ -> ()
  | Policy_unobserved | Policy_readable _ | Policy_refused _ ->
    match outcome with
    | Complete { observation; _ } -> store.sub_boards_source <- Policy_readable observation
    | Partial { observation; errors; diagnostics; _ } ->
      store.sub_boards_source <- Policy_refused {
        policy_history = Policy_observed observation;
        policy_failure = Policy_rows_rejected errors; policy_diagnostics = diagnostics }
    | Unavailable { failure; diagnostics } -> refuse store failure diagnostics

let fail_read store outcome exception_ backtrace =
  let diagnostics, observation = match outcome with
    | Complete { observation; diagnostics; _ } | Partial { observation; diagnostics; _ } ->
      diagnostics, Some observation
    | Unavailable { diagnostics; _ } -> diagnostics, None in
  let failure = Policy_raised { exception_; backtrace } in
  let diagnostics = diagnostics @ [Policy_raised_diagnostic { exception_; backtrace }] in
  (match observation, store.sub_boards_source with
   | Some observation, (Policy_unobserved | Policy_readable _ | Policy_refused _) ->
     store.sub_boards_source <- Policy_refused { policy_history = Policy_observed observation;
       policy_failure = failure; policy_diagnostics = diagnostics }
   | Some _, (Policy_publishing _ | Policy_unsettled _)
   | None, (Policy_unobserved | Policy_readable _ | Policy_refused _ | Policy_publishing _ | Policy_unsettled _) ->
     refuse store failure diagnostics);
  Unavailable { failure; diagnostics }

let finish_read = function
  | Complete { diagnostics; _ } -> finish (Ok ()) diagnostics
  | Partial { diagnostics; _ } | Unavailable { diagnostics; _ } ->
    finish (Error (unavailable_error ())) diagnostics

let rec contradicts_observation = function
  | Fs_compat.Cursor_mismatch _ | Transaction_content_changed _ | Transaction_path_binding_changed _
  | Incomplete_transaction_tail _ | Ambiguous_transaction_file_identity _ -> true
  | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> contradicts_observation error
  | Stable_lock_contended _ | Unexpected_stable_lock_permissions _ | Invalid_stable_lock_state _
  | Unexpected_transaction_file_kind _ | Invalid_transaction_suffix | Private_jsonl_operation_failed _
  | Rewrite_stage_failed _ | Rewrite_published_durability_unknown _
  | Transaction_settlement_failed { primary = Transaction_succeeded _; _ }
  | Transaction_append_failed _ -> false

let not_written failure diagnostics = Not_written { failure; diagnostics }

let write store ~before ~kind ~bytes perform =
  let pending = { policy_before = before; policy_kind = kind; policy_intended_bytes = bytes } in
  let unknown failure diagnostics =
    store.sub_boards_source <- Policy_unsettled {
      policy_pending = pending; policy_failure = failure; policy_diagnostics = diagnostics };
    Unknown { failure; diagnostics } in
  try
    match Fs_compat.private_jsonl_cursor_success_receipt (perform ()) with
    | Ok receipt ->
      let diagnostics = receipt_diagnostics receipt.settlement_error in
      let publication = {
        policy_after = { before with policy_snapshot = { Fs_compat.bytes = bytes; cursor = receipt.value } };
        policy_cleanup = diagnostics } in
      store.sub_boards_source <- Policy_publishing publication;
      Written { publication; diagnostics }
    | Error error ->
      let diagnostics = [Policy_file_diagnostic error] in
      let failure = Policy_transaction_failed error in
      if Board_posts_source.definitely_not_written error then (
        if contradicts_observation error then refuse store failure diagnostics;
        not_written failure diagnostics)
      else unknown failure diagnostics
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    unknown (Policy_raised { exception_; backtrace }) [Policy_raised_diagnostic { exception_; backtrace }]

let before_write store f = match expected store with
  | Error failure -> not_written failure []
  | Ok before ->
    match Board_workspace_binding.revalidate store.workspace_binding before.policy_workspace with
    | Error rejection ->
      let failure = Policy_workspace_refused rejection in
      let diagnostics = [Policy_workspace_diagnostic rejection] in
      refuse store failure diagnostics;
      not_written failure diagnostics
    | Ok () -> f before
    | exception exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      let diagnostics = [Policy_raised_diagnostic { exception_; backtrace }] in
      refuse store (Policy_raised { exception_; backtrace }) diagnostics;
      not_written (Policy_raised { exception_; backtrace }) diagnostics

let append store row = before_write store (fun before ->
  let encoded = try Ok (Yojson.Safe.to_string (Board_sub_board_json.sub_board_to_yojson row) ^ "\n")
    with exception_ -> Error (exception_, Printexc.get_raw_backtrace ()) in
  match encoded with
  | Error (exception_, backtrace) -> not_written (Policy_raised { exception_; backtrace })
      [Policy_raised_diagnostic { exception_; backtrace }]
  | Ok suffix ->
    write store ~before ~kind:Policy_append ~bytes:(before.policy_snapshot.bytes ^ suffix)
      (fun () -> match store.sub_boards_source_io with
       | None -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_result
           before.policy_path ~expected:before.policy_snapshot suffix
       | Some io -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
           ~io before.policy_path ~expected:before.policy_snapshot suffix))

let rewrite store bytes = before_write store (fun before ->
  write store ~before ~kind:Policy_rewrite ~bytes (fun () -> match store.sub_boards_source_io with
    | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
        before.policy_path ~expected:before.policy_snapshot bytes
    | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
        ~io ~before_sync_rewrite_parent:io.before_sync_parent
        before.policy_path ~expected:before.policy_snapshot bytes))

let acknowledge_publication store receipt = match store.sub_boards_source with
  | Policy_publishing current when current == receipt ->
    store.sub_boards_source <- Policy_readable receipt.policy_after;
    Ok ()
  | Policy_unobserved | Policy_readable _ | Policy_publishing _ | Policy_refused _ | Policy_unsettled _ ->
    Error (unavailable_error ())

let fail_publication store receipt exception_ backtrace =
  let diagnostics = receipt.policy_cleanup @ [Policy_raised_diagnostic { exception_; backtrace }] in
  (match store.sub_boards_source with
   | Policy_publishing current when current == receipt ->
     store.sub_boards_source <- Policy_publishing { receipt with policy_cleanup = diagnostics }
   | Policy_unobserved | Policy_readable _ | Policy_publishing _ | Policy_refused _ | Policy_unsettled _ -> ());
  ignore (finish (Error (unavailable_error ())) diagnostics);
  Printexc.raise_with_backtrace exception_ backtrace

let finish_write outcome result =
  let diagnostics = match outcome with
    | Written { diagnostics; _ } | Not_written { diagnostics; _ } | Unknown { diagnostics; _ } -> diagnostics in
  finish result diagnostics
