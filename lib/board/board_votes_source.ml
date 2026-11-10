open Board_types

type row = Board_vote_key.t * vote_direction * float

let source_path store = Board_paths.store_file_path store Board_paths.Votes

type read =
  | Complete of { observation : votes_source_observation; rows : row list;
                  diagnostics : votes_source_diagnostic list }
  | Partial of { observation : votes_source_observation; rows : row list;
                 errors : votes_row_error list; diagnostics : votes_source_diagnostic list }
  | Unavailable of { failure : votes_source_failure;
                     diagnostics : votes_source_diagnostic list }

type publication = votes_publication
type write =
  | Written of { publication : publication; diagnostics : votes_source_diagnostic list }
  | Not_written of { failure : votes_source_failure; diagnostics : votes_source_diagnostic list }
  | Unknown of { failure : votes_source_failure; diagnostics : votes_source_diagnostic list }

let unavailable_error () = Io_error "Board data is unavailable."

let reserved_diagnostics = List.find_map (function
  | Vote_file_diagnostic error -> Board_posts_source.reserved_transaction error
  | Vote_guard_diagnostic failure -> Board_posts_source.reserved_transaction failure.guard_error
  | Vote_workspace_diagnostic rejection ->
    Option.bind (Board_workspace_binding.raised rejection) Board_posts_source.reserved_exception
  | Vote_raised_diagnostic { exception_; backtrace } ->
    Board_posts_source.reserved_exception (exception_, backtrace)
  | Vote_projection_diagnostic _ -> None)

let finish result diagnostics =
  Option.iter (fun (exception_, backtrace) ->
    Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result) exception_ backtrace)
    (reserved_diagnostics diagnostics);
  result

let history = function
  | Votes_unobserved -> No_votes_observation
  | Votes_readable observation -> Votes_observed observation
  | Votes_publishing publication -> Votes_observed publication.vote_after
  | Votes_refused { vote_history; _ } -> vote_history
  | Votes_unsettled { vote_pending; _ } -> Votes_observed vote_pending.vote_before

let refuse store failure diagnostics = match store.votes_source with
  | Votes_publishing _ | Votes_unsettled _ -> ()
  | Votes_unobserved | Votes_readable _ | Votes_refused _ ->
    store.votes_source <- Votes_refused {
      vote_history = history store.votes_source;
      vote_failure = failure; vote_diagnostics = diagnostics }

let refuse_present store failure diagnostics =
  let vote_history = match history store.votes_source with
    | No_votes_observation | Votes_present_without_snapshot -> Votes_present_without_snapshot
    | Votes_observed observation as previous ->
      if Fs_compat.Private_jsonl_cursor.is_missing observation.vote_snapshot.cursor
      then Votes_present_without_snapshot else previous in
  match store.votes_source with
  | Votes_publishing _ | Votes_unsettled _ -> ()
  | Votes_unobserved | Votes_readable _ | Votes_refused _ ->
    store.votes_source <- Votes_refused {
      vote_history; vote_failure = failure; vote_diagnostics = diagnostics }

let expected store = match store.votes_source with
  | Votes_readable observation ->
    if String.equal observation.vote_path (source_path store)
    then Ok observation else Error Votes_binding_mismatch
  | Votes_unobserved -> Error Votes_not_observed
  | Votes_publishing _ -> Error Votes_publication_pending
  | Votes_refused { vote_failure; _ } | Votes_unsettled { vote_failure; _ } ->
    Error vote_failure

let require_readable store = match expected store with
  | Ok _ -> Ok () | Error _ -> Error (unavailable_error ())

let missing_allowed store = match history store.votes_source with
  | No_votes_observation -> true
  | Votes_present_without_snapshot -> false
  | Votes_observed observation -> Fs_compat.Private_jsonl_cursor.is_missing observation.vote_snapshot.cursor

let receipt_diagnostics = function
  | None -> [] | Some error -> [Vote_file_diagnostic error]

let read_file store path = match store.votes_source_io with
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

let read store = match store.votes_source with
  | Votes_unsettled { vote_failure; _ } -> Unavailable { failure = vote_failure; diagnostics = [] }
  | Votes_publishing _ -> Unavailable { failure = Votes_publication_pending; diagnostics = [] }
  | Votes_unobserved | Votes_readable _ | Votes_refused _ ->
    let diagnostics = ref [] and saw_present = ref false in
    let unavailable failure =
      (if !saw_present then refuse_present else refuse) store failure !diagnostics;
      Unavailable { failure; diagnostics = !diagnostics } in
    try
      match observe_workspace store with
      | Error rejection -> diagnostics := [Vote_workspace_diagnostic rejection];
        unavailable (Votes_workspace_refused rejection)
      | Ok before ->
        let path = source_path store in
        match Fs_compat.private_jsonl_snapshot_success_receipt (read_file store path) with
        | Error error ->
          diagnostics := [Vote_file_diagnostic error];
          saw_present := Fs_compat.private_jsonl_transaction_error_is_incomplete_tail error;
          unavailable (Votes_transaction_failed error)
        | Ok receipt ->
          diagnostics := receipt_diagnostics receipt.settlement_error;
          saw_present := not (Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor);
          match reserved_diagnostics !diagnostics with
          | Some (exception_, backtrace) -> unavailable (Votes_raised { exception_; backtrace })
          | None ->
            match finish_workspace store before with
            | Error rejection -> diagnostics := !diagnostics @ [Vote_workspace_diagnostic rejection];
              unavailable (Votes_workspace_refused rejection)
            | Ok vote_workspace ->
              if Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor && not (missing_allowed store)
              then unavailable Votes_missing
              else (
                let rows = ref [] and errors = ref [] in
                String.split_on_char '\n' receipt.value.bytes |> List.iteri (fun index text ->
                  if String.trim text <> "" then
                    match Yojson.Safe.from_string text with
                    | json ->
                      (match Board_vote_row.of_yojson json with
                       | Some row -> rows := row :: !rows
                       | None -> errors := Invalid_vote_row { line = index + 1 } :: !errors)
                    | exception Yojson.Json_error detail ->
                      errors := Invalid_vote_json { line = index + 1; detail } :: !errors);
                let observation = { vote_path = path; vote_snapshot = receipt.value; vote_workspace } in
                match List.rev !errors with
                | [] -> Complete { observation; rows = List.rev !rows; diagnostics = !diagnostics }
                | errors -> Partial { observation; rows = List.rev !rows; errors; diagnostics = !diagnostics })
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Vote_raised_diagnostic { exception_; backtrace }];
      unavailable (Votes_raised { exception_; backtrace })

let publish_read store outcome = match store.votes_source with
  | Votes_publishing _ | Votes_unsettled _ -> ()
  | Votes_unobserved | Votes_readable _ | Votes_refused _ ->
    match outcome with
    | Complete { observation; _ } -> store.votes_source <- Votes_readable observation
    | Partial { observation; errors; diagnostics; _ } ->
      store.votes_source <- Votes_refused {
        vote_history = Votes_observed observation;
        vote_failure = Votes_rows_rejected errors; vote_diagnostics = diagnostics }
    | Unavailable { failure; diagnostics } -> refuse store failure diagnostics

let fail_read store outcome exception_ backtrace =
  let diagnostics, observation = match outcome with
    | Complete { observation; diagnostics; _ } | Partial { observation; diagnostics; _ } ->
      diagnostics, Some observation
    | Unavailable { diagnostics; _ } -> diagnostics, None in
  let failure = Votes_raised { exception_; backtrace } in
  let diagnostics = diagnostics @ [Vote_raised_diagnostic { exception_; backtrace }] in
  (match observation, store.votes_source with
   | Some observation, (Votes_unobserved | Votes_readable _ | Votes_refused _) ->
     store.votes_source <- Votes_refused { vote_history = Votes_observed observation;
       vote_failure = failure; vote_diagnostics = diagnostics }
   | Some _, (Votes_publishing _ | Votes_unsettled _)
   | None, (Votes_unobserved | Votes_readable _ | Votes_refused _ | Votes_publishing _ | Votes_unsettled _) ->
     refuse store failure diagnostics);
  Unavailable { failure; diagnostics }

let finish_read = function
  | Complete { rows; diagnostics; _ } -> finish (Ok (List.length rows)) diagnostics
  | Partial { diagnostics; _ } | Unavailable { diagnostics; _ } ->
    finish (Error (unavailable_error ())) diagnostics

let rec contradicts_observation = function
  | Fs_compat.Cursor_mismatch _ | Transaction_content_changed _ | Transaction_path_binding_changed _
  | Incomplete_transaction_tail _ | Ambiguous_transaction_file_identity _
  | Unexpected_transaction_file_kind _ -> true
  | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> contradicts_observation error
  | Stable_lock_contended _ | Unexpected_stable_lock_permissions _ | Invalid_stable_lock_state _
  | Invalid_transaction_suffix | Private_jsonl_operation_failed _
  | Rewrite_stage_failed _ | Rewrite_published_durability_unknown _
  | Transaction_settlement_failed { primary = Transaction_succeeded _; _ }
  | Transaction_append_failed _ -> false

let not_written failure diagnostics = Not_written { failure; diagnostics }

type file_result = (Fs_compat.Private_jsonl_cursor.t, Fs_compat.private_jsonl_transaction_error) result
type write_io =
  | Direct_io of file_result
  | Admitted_io of Board_target_admission.t * file_result Board_target_admission.guarded

let guard_diagnostics failures = List.map (fun failure -> Vote_guard_diagnostic failure) failures

let write store ~before ~kind ~bytes perform =
  let pending = { vote_before = before; vote_kind = kind; vote_intended_bytes = bytes } in
  let unknown failure diagnostics =
    store.votes_source <- Votes_unsettled {
      vote_pending = pending; vote_failure = failure; vote_diagnostics = diagnostics };
    Unknown { failure; diagnostics } in
  let classify result parent_diagnostics =
    match Fs_compat.private_jsonl_cursor_success_receipt result with
    | Ok receipt ->
      let diagnostics = receipt_diagnostics receipt.settlement_error @ parent_diagnostics in
      let publication = {
        vote_after = { before with vote_snapshot = { Fs_compat.bytes = bytes; cursor = receipt.value } };
        vote_cleanup = diagnostics } in
      store.votes_source <- Votes_publishing publication;
      Written { publication; diagnostics }
    | Error error ->
      let diagnostics = Vote_file_diagnostic error :: parent_diagnostics in
      let failure = Votes_transaction_failed error in
      if Board_posts_source.definitely_not_written error then (
        if contradicts_observation error then refuse store failure diagnostics;
        not_written failure diagnostics)
      else unknown failure diagnostics in
  try match perform () with
    | Direct_io result -> classify result []
    | Admitted_io (admission, Board_target_admission.Refused refusal) ->
      let diagnostics = guard_diagnostics (refusal.failure :: refusal.cleanup_failures) in
      Board_target_admission.observe_refusal store admission refusal;
      not_written (Votes_transaction_failed refusal.failure.guard_error) diagnostics
    | Admitted_io (_, Board_target_admission.Executed { value; cleanup_failures }) ->
      classify value (guard_diagnostics cleanup_failures)
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    unknown (Votes_raised { exception_; backtrace }) [Vote_raised_diagnostic { exception_; backtrace }]

let before_write store f = match expected store with
  | Error failure -> not_written failure []
  | Ok before ->
    match Board_workspace_binding.revalidate store.workspace_binding before.vote_workspace with
    | Error rejection ->
      let failure = Votes_workspace_refused rejection in
      let diagnostics = [Vote_workspace_diagnostic rejection] in
      refuse store failure diagnostics;
      not_written failure diagnostics
    | Ok () -> f before
    | exception exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      let diagnostics = [Vote_raised_diagnostic { exception_; backtrace }] in
      refuse store (Votes_raised { exception_; backtrace }) diagnostics;
      not_written (Votes_raised { exception_; backtrace }) diagnostics

let workspace_failure store rejection =
  let failure = Votes_workspace_refused rejection in
  let diagnostics = [Vote_workspace_diagnostic rejection] in
  refuse store failure diagnostics;
  not_written failure diagnostics

let append store ~admission row = before_write store (fun before ->
  match Board_target_admission.revalidate store admission with
  | Error rejection -> workspace_failure store rejection
  | Ok () ->
    let encoded = try Ok (Yojson.Safe.to_string (Board_vote_row.to_yojson row) ^ "\n")
      with exception_ -> Error (exception_, Printexc.get_raw_backtrace ()) in
    match encoded with
    | Error (exception_, backtrace) -> not_written (Votes_raised { exception_; backtrace })
        [Vote_raised_diagnostic { exception_; backtrace }]
    | Ok suffix ->
      let io = store.votes_source_io in
      let posts_io = store.posts_source_io.posts and comments_io = store.comments_source_io in
      write store ~before ~kind:Vote_append ~bytes:(before.vote_snapshot.bytes ^ suffix)
        (fun () -> Admitted_io (admission, Board_target_admission.guard admission ~posts_io ~comments_io
          ~f:(fun () -> match io with
            | None -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_result
                before.vote_path ~expected:before.vote_snapshot suffix
            | Some io -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
                ~io before.vote_path ~expected:before.vote_snapshot suffix))))

let rewrite store bytes = before_write store (fun before ->
  let io = store.votes_source_io in
  write store ~before ~kind:Vote_rewrite ~bytes (fun () -> Direct_io (match io with
    | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
        before.vote_path ~expected:before.vote_snapshot bytes
    | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
        ~io ~before_sync_rewrite_parent:io.before_sync_parent
        before.vote_path ~expected:before.vote_snapshot bytes)))

type admission_check = {
  check_result : (unit, board_error) result;
  check_diagnostics : votes_source_diagnostic list;
}

let check_admission store ~admission =
  let failed diagnostics = { check_result = Error (unavailable_error ()); check_diagnostics = diagnostics } in
  match expected store with
  | Error _ -> failed []
  | Ok before ->
    let workspace = try
      let open Result.Syntax in
      let* () = Board_workspace_binding.revalidate store.workspace_binding before.vote_workspace in
      Board_target_admission.revalidate store admission
      with exception_ -> Error (Board_workspace_binding.Raised {
        exception_; backtrace = Printexc.get_raw_backtrace () }) in
    match workspace with
    | Error rejection -> failed [Vote_workspace_diagnostic rejection]
    | Ok () ->
      let io = store.votes_source_io in
      let posts_io = store.posts_source_io.posts and comments_io = store.comments_source_io in
      try match Board_target_admission.guard admission ~posts_io ~comments_io ~f:(fun () ->
          match io with
          | None -> Fs_compat.with_private_jsonl_snapshot_guard_result
              before.vote_path ~expected:before.vote_snapshot ~f:(fun () -> ())
          | Some io -> Fs_compat.with_private_jsonl_snapshot_guard_with_io_for_testing ~io
              before.vote_path ~expected:before.vote_snapshot ~f:(fun () -> ())) with
      | Board_target_admission.Refused refusal ->
        let diagnostics = guard_diagnostics (refusal.failure :: refusal.cleanup_failures) in
        Board_target_admission.observe_refusal store admission refusal;
        failed diagnostics
      | Board_target_admission.Executed { value = Fs_compat.Guard_refused failure; cleanup_failures } ->
        let diagnostics = guard_diagnostics (failure :: cleanup_failures) in
        if contradicts_observation failure.guard_error then
          refuse store (Votes_transaction_failed failure.guard_error) diagnostics;
        failed diagnostics
      | Board_target_admission.Executed {
          value = Fs_compat.Guard_executed { value = (); cleanup_failures = vote_cleanup };
          cleanup_failures = parent_cleanup } ->
        { check_result = Ok (); check_diagnostics = guard_diagnostics (vote_cleanup @ parent_cleanup) }
      with exception_ ->
        failed [Vote_raised_diagnostic { exception_; backtrace = Printexc.get_raw_backtrace () }]

let finish_check checked result =
  let result = Result.bind checked.check_result (fun () -> result) in
  finish result checked.check_diagnostics

let acknowledge_publication store receipt = match store.votes_source with
  | Votes_publishing current when current == receipt ->
    store.votes_source <- Votes_readable receipt.vote_after;
    Ok ()
  | Votes_unobserved | Votes_readable _ | Votes_publishing _ | Votes_refused _ | Votes_unsettled _ ->
    Error (unavailable_error ())

let reject_publication store receipt failure = match store.votes_source with
  | Votes_publishing current when current == receipt ->
    store.votes_source <- Votes_publishing {
      receipt with vote_cleanup = receipt.vote_cleanup @ [Vote_projection_diagnostic failure] }
  | Votes_unobserved | Votes_readable _ | Votes_publishing _ | Votes_refused _ | Votes_unsettled _ -> ()

let fail_publication store receipt exception_ backtrace =
  let diagnostics = receipt.vote_cleanup @ [Vote_raised_diagnostic { exception_; backtrace }] in
  (match store.votes_source with
   | Votes_publishing current when current == receipt ->
     store.votes_source <- Votes_publishing { receipt with vote_cleanup = diagnostics }
   | Votes_unobserved | Votes_readable _ | Votes_publishing _ | Votes_refused _ | Votes_unsettled _ -> ());
  ignore (finish (Error (unavailable_error ())) diagnostics);
  Printexc.raise_with_backtrace exception_ backtrace

let finish_write outcome result =
  let diagnostics = match outcome with
    | Written { diagnostics; _ } | Not_written { diagnostics; _ } | Unknown { diagnostics; _ } -> diagnostics in
  finish result diagnostics
