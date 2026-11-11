open Board_types

type row = reaction

let source_path store = Board_paths.store_file_path store Board_paths.Reactions

type read =
  | Complete of { observation : reactions_source_observation; rows : row list;
                  diagnostics : reactions_source_diagnostic list }
  | Partial of { observation : reactions_source_observation; rows : row list;
                 errors : reactions_row_error list; diagnostics : reactions_source_diagnostic list }
  | Unavailable of { failure : reactions_source_failure;
                     diagnostics : reactions_source_diagnostic list }

type publication = reactions_publication
type write =
  | Written of { publication : publication; diagnostics : reactions_source_diagnostic list }
  | Not_written of { failure : reactions_source_failure; diagnostics : reactions_source_diagnostic list }
  | Unknown of { failure : reactions_source_failure; diagnostics : reactions_source_diagnostic list }

let unavailable_error () = Io_error "Board data is unavailable."

let reserved_diagnostics = List.find_map (function
  | Reaction_file_diagnostic error -> Board_posts_source.reserved_transaction error
  | Reaction_guard_diagnostic failure -> Board_posts_source.reserved_transaction failure.guard_error
  | Reaction_workspace_diagnostic rejection ->
    Option.bind (Board_workspace_binding.raised rejection) Board_posts_source.reserved_exception
  | Reaction_raised_diagnostic { exception_; backtrace } ->
    Board_posts_source.reserved_exception (exception_, backtrace)
  | Reaction_projection_diagnostic _ -> None)

let finish result diagnostics =
  Option.iter (fun (exception_, backtrace) ->
    Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result) exception_ backtrace)
    (reserved_diagnostics diagnostics);
  result

let history = function
  | Reactions_unobserved -> No_reactions_observation
  | Reactions_readable observation -> Reactions_observed observation
  | Reactions_publishing publication -> Reactions_observed publication.reaction_after
  | Reactions_refused { reaction_history; _ } -> reaction_history
  | Reactions_unsettled { reaction_pending; _ } -> Reactions_observed reaction_pending.reaction_before

let refuse store failure diagnostics = match store.reactions_source with
  | Reactions_publishing _ | Reactions_unsettled _ -> ()
  | Reactions_unobserved | Reactions_readable _ | Reactions_refused _ ->
    store.reactions_source <- Reactions_refused {
      reaction_history = history store.reactions_source;
      reaction_failure = failure; reaction_diagnostics = diagnostics }

let refuse_present store failure diagnostics =
  let reaction_history = match history store.reactions_source with
    | No_reactions_observation | Reactions_present_without_snapshot -> Reactions_present_without_snapshot
    | Reactions_observed observation as previous ->
      if Fs_compat.Private_jsonl_cursor.is_missing observation.reaction_snapshot.cursor
      then Reactions_present_without_snapshot else previous in
  match store.reactions_source with
  | Reactions_publishing _ | Reactions_unsettled _ -> ()
  | Reactions_unobserved | Reactions_readable _ | Reactions_refused _ ->
    store.reactions_source <- Reactions_refused {
      reaction_history; reaction_failure = failure; reaction_diagnostics = diagnostics }

let expected store = match store.reactions_source with
  | Reactions_readable observation ->
    if String.equal observation.reaction_path (source_path store)
    then Ok observation else Error Reactions_binding_mismatch
  | Reactions_unobserved -> Error Reactions_not_observed
  | Reactions_publishing _ -> Error Reactions_publication_pending
  | Reactions_refused { reaction_failure; _ } | Reactions_unsettled { reaction_failure; _ } ->
    Error reaction_failure

let require_readable store = match expected store with
  | Ok _ -> Ok () | Error _ -> Error (unavailable_error ())

let missing_allowed store = match history store.reactions_source with
  | No_reactions_observation -> true
  | Reactions_present_without_snapshot -> false
  | Reactions_observed observation -> Fs_compat.Private_jsonl_cursor.is_missing observation.reaction_snapshot.cursor

let receipt_diagnostics = function
  | None -> [] | Some error -> [Reaction_file_diagnostic error]

let read_file store path = match store.reactions_source_io with
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

let read store = match store.reactions_source with
  | Reactions_unsettled { reaction_failure; _ } -> Unavailable { failure = reaction_failure; diagnostics = [] }
  | Reactions_publishing _ -> Unavailable { failure = Reactions_publication_pending; diagnostics = [] }
  | Reactions_unobserved | Reactions_readable _ | Reactions_refused _ ->
    let diagnostics = ref [] and saw_present = ref false in
    let unavailable failure =
      (if !saw_present then refuse_present else refuse) store failure !diagnostics;
      Unavailable { failure; diagnostics = !diagnostics } in
    try
      match observe_workspace store with
      | Error rejection -> diagnostics := [Reaction_workspace_diagnostic rejection];
        unavailable (Reactions_workspace_refused rejection)
      | Ok before ->
        let path = source_path store in
        match Fs_compat.private_jsonl_snapshot_success_receipt (read_file store path) with
        | Error error ->
          diagnostics := [Reaction_file_diagnostic error];
          saw_present := Fs_compat.private_jsonl_transaction_error_is_incomplete_tail error;
          unavailable (Reactions_transaction_failed error)
        | Ok receipt ->
          diagnostics := receipt_diagnostics receipt.settlement_error;
          saw_present := not (Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor);
          match reserved_diagnostics !diagnostics with
          | Some (exception_, backtrace) -> unavailable (Reactions_raised { exception_; backtrace })
          | None ->
            match finish_workspace store before with
            | Error rejection -> diagnostics := !diagnostics @ [Reaction_workspace_diagnostic rejection];
              unavailable (Reactions_workspace_refused rejection)
            | Ok reaction_workspace ->
              if Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor && not (missing_allowed store)
              then unavailable Reactions_missing
              else (
                let rows = ref [] and errors = ref [] in
                String.split_on_char '\n' receipt.value.bytes |> List.iteri (fun index text ->
                  if String.trim text <> "" then
                    match Yojson.Safe.from_string text with
                    | json ->
                      (match Board_core_json.reaction_of_yojson json with
                       | Some row -> rows := row :: !rows
                       | None -> errors := Invalid_reaction_row { line = index + 1 } :: !errors)
                    | exception Yojson.Json_error detail ->
                      errors := Invalid_reaction_json { line = index + 1; detail } :: !errors);
                let observation = { reaction_path = path; reaction_snapshot = receipt.value; reaction_workspace } in
                match List.rev !errors with
                | [] -> Complete { observation; rows = List.rev !rows; diagnostics = !diagnostics }
                | errors -> Partial { observation; rows = List.rev !rows; errors; diagnostics = !diagnostics })
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Reaction_raised_diagnostic { exception_; backtrace }];
      unavailable (Reactions_raised { exception_; backtrace })

let publish_read store outcome = match store.reactions_source with
  | Reactions_publishing _ | Reactions_unsettled _ -> ()
  | Reactions_unobserved | Reactions_readable _ | Reactions_refused _ ->
    match outcome with
    | Complete { observation; _ } -> store.reactions_source <- Reactions_readable observation
    | Partial { observation; errors; diagnostics; _ } ->
      store.reactions_source <- Reactions_refused {
        reaction_history = Reactions_observed observation;
        reaction_failure = Reactions_rows_rejected errors; reaction_diagnostics = diagnostics }
    | Unavailable { failure; diagnostics } -> refuse store failure diagnostics

let fail_read store outcome exception_ backtrace =
  let diagnostics, observation = match outcome with
    | Complete { observation; diagnostics; _ } | Partial { observation; diagnostics; _ } ->
      diagnostics, Some observation
    | Unavailable { diagnostics; _ } -> diagnostics, None in
  let failure = Reactions_raised { exception_; backtrace } in
  let diagnostics = diagnostics @ [Reaction_raised_diagnostic { exception_; backtrace }] in
  (match observation, store.reactions_source with
   | Some observation, (Reactions_unobserved | Reactions_readable _ | Reactions_refused _) ->
     store.reactions_source <- Reactions_refused { reaction_history = Reactions_observed observation;
       reaction_failure = failure; reaction_diagnostics = diagnostics }
   | Some _, (Reactions_publishing _ | Reactions_unsettled _)
   | None, (Reactions_unobserved | Reactions_readable _ | Reactions_refused _ | Reactions_publishing _ | Reactions_unsettled _) ->
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

let guard_diagnostics failures = List.map (fun failure -> Reaction_guard_diagnostic failure) failures

let write store ~before ~bytes perform =
  let pending = { reaction_before = before; reaction_intended_bytes = bytes } in
  let unknown failure diagnostics =
    store.reactions_source <- Reactions_unsettled {
      reaction_pending = pending; reaction_failure = failure; reaction_diagnostics = diagnostics };
    Unknown { failure; diagnostics } in
  let classify result parent_diagnostics =
    match Fs_compat.private_jsonl_cursor_success_receipt result with
    | Ok receipt ->
      let diagnostics = receipt_diagnostics receipt.settlement_error @ parent_diagnostics in
      let publication = {
        reaction_after = { before with reaction_snapshot = { Fs_compat.bytes = bytes; cursor = receipt.value } };
        reaction_cleanup = diagnostics } in
      store.reactions_source <- Reactions_publishing publication;
      Written { publication; diagnostics }
    | Error error ->
      let diagnostics = Reaction_file_diagnostic error :: parent_diagnostics in
      let failure = Reactions_transaction_failed error in
      if Board_posts_source.definitely_not_written error then (
        if contradicts_observation error then refuse store failure diagnostics;
        not_written failure diagnostics)
      else unknown failure diagnostics in
  try match perform () with
    | Direct_io result -> classify result []
    | Admitted_io (admission, Board_target_admission.Refused refusal) ->
      let diagnostics = guard_diagnostics (refusal.failure :: refusal.cleanup_failures) in
      Board_target_admission.observe_refusal store admission refusal;
      not_written (Reactions_transaction_failed refusal.failure.guard_error) diagnostics
    | Admitted_io (_, Board_target_admission.Executed { value; cleanup_failures }) ->
      classify value (guard_diagnostics cleanup_failures)
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    unknown (Reactions_raised { exception_; backtrace }) [Reaction_raised_diagnostic { exception_; backtrace }]

let before_write store f = match expected store with
  | Error failure -> not_written failure []
  | Ok before ->
    match Board_workspace_binding.revalidate store.workspace_binding before.reaction_workspace with
    | Error rejection ->
      let failure = Reactions_workspace_refused rejection in
      let diagnostics = [Reaction_workspace_diagnostic rejection] in
      refuse store failure diagnostics;
      not_written failure diagnostics
    | Ok () -> f before
    | exception exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      let diagnostics = [Reaction_raised_diagnostic { exception_; backtrace }] in
      refuse store (Reactions_raised { exception_; backtrace }) diagnostics;
      not_written (Reactions_raised { exception_; backtrace }) diagnostics

let rewrite store bytes = before_write store (fun before ->
  let io = store.reactions_source_io in
  write store ~before ~bytes (fun () -> Direct_io (match io with
    | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
        before.reaction_path ~expected:before.reaction_snapshot bytes
    | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
        ~io ~before_sync_rewrite_parent:io.before_sync_parent
        before.reaction_path ~expected:before.reaction_snapshot bytes)))

let rewrite_admitted store ~admission bytes = before_write store (fun before ->
  match Board_target_admission.revalidate store admission with
  | Error rejection ->
    let failure = Reactions_workspace_refused rejection in
    let diagnostics = [Reaction_workspace_diagnostic rejection] in
    refuse store failure diagnostics;
    not_written failure diagnostics
  | Ok () ->
    let io = store.reactions_source_io in
    let posts_io = store.posts_source_io.posts and comments_io = store.comments_source_io in
    write store ~before ~bytes (fun () -> Admitted_io (admission,
      Board_target_admission.guard admission ~posts_io ~comments_io ~f:(fun () -> match io with
        | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
            before.reaction_path ~expected:before.reaction_snapshot bytes
        | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
            ~io ~before_sync_rewrite_parent:io.before_sync_parent
            before.reaction_path ~expected:before.reaction_snapshot bytes))))

let acknowledge_publication store receipt = match store.reactions_source with
  | Reactions_publishing current when current == receipt ->
    store.reactions_source <- Reactions_readable receipt.reaction_after;
    Ok ()
  | Reactions_unobserved | Reactions_readable _ | Reactions_publishing _ | Reactions_refused _ | Reactions_unsettled _ ->
    Error (unavailable_error ())

let reject_publication store receipt failure = match store.reactions_source with
  | Reactions_publishing current when current == receipt ->
    store.reactions_source <- Reactions_publishing {
      receipt with reaction_cleanup = receipt.reaction_cleanup @ [Reaction_projection_diagnostic failure] }
  | Reactions_unobserved | Reactions_readable _ | Reactions_publishing _ | Reactions_refused _ | Reactions_unsettled _ -> ()

let fail_publication store receipt exception_ backtrace =
  let diagnostics = receipt.reaction_cleanup @ [Reaction_raised_diagnostic { exception_; backtrace }] in
  (match store.reactions_source with
   | Reactions_publishing current when current == receipt ->
     store.reactions_source <- Reactions_publishing { receipt with reaction_cleanup = diagnostics }
   | Reactions_unobserved | Reactions_readable _ | Reactions_publishing _ | Reactions_refused _ | Reactions_unsettled _ -> ());
  ignore (finish (Error (unavailable_error ())) diagnostics);
  Printexc.raise_with_backtrace exception_ backtrace

let finish_write outcome result =
  let diagnostics = match outcome with
    | Written { diagnostics; _ } | Not_written { diagnostics; _ } | Unknown { diagnostics; _ } -> diagnostics in
  finish result diagnostics
