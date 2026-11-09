open Board_types

type read =
  | Complete of { observation : comments_source_observation; comments : comment list;
                  diagnostics : comments_source_diagnostic list }
  | Partial of { observation : comments_source_observation; comments : comment list;
                 errors : comments_row_error list; diagnostics : comments_source_diagnostic list }
  | Unavailable of { failure : comments_source_failure;
                     diagnostics : comments_source_diagnostic list }

type 'a write_outcome =
  | Written of { value : 'a; diagnostics : comments_source_diagnostic list }
  | Not_written of { failure : comments_source_failure; diagnostics : comments_source_diagnostic list }
  | Unknown of { failure : comments_source_failure; diagnostics : comments_source_diagnostic list }

type append_receipt = comments_publication
type snapshot = {
  expected : (comments_source_observation, comments_source_failure) result;
  bytes : string;
}

let reserved_diagnostics = List.find_map (function
  | Comments_file_diagnostic error -> Board_posts_source.reserved_transaction error
  | Comments_workspace_diagnostic rejection ->
    Option.bind (Board_workspace_binding.raised rejection) Board_posts_source.reserved_exception
  | Comments_raised_diagnostic { exception_; backtrace; _ } ->
    Board_posts_source.reserved_exception (exception_, backtrace))

let stage_name = function
  | Read_comments -> "read comments" | Decode_comments -> "decode comments"
  | Encode_comments -> "encode comments" | Write_comments -> "write comments"
  | Project_comments -> "project comments" | Report_comments -> "report comments"

let diagnostic_to_string = function
  | Comments_file_diagnostic error -> Fs_compat.private_jsonl_transaction_error_to_string error
  | Comments_workspace_diagnostic rejection -> Board_workspace_binding.rejection_to_string rejection
  | Comments_raised_diagnostic { stage; exception_; _ } ->
    stage_name stage ^ ": " ^ Printexc.to_string exception_

let failure_to_board_error failure = Io_error (match failure with
  | Comments_not_observed -> "comments source has not been explicitly loaded"
  | Comments_rows_rejected errors ->
    List.map (function
      | Invalid_comments_json { line; detail } -> Printf.sprintf "line %d: invalid JSON: %s" line detail
      | Invalid_comments_row { line } -> Printf.sprintf "line %d: invalid persisted comment schema" line)
      errors |> String.concat "; "
  | Comments_transaction_failed error -> Fs_compat.private_jsonl_transaction_error_to_string error
  | Comments_missing -> "comments source is missing after this store observed it"
  | Comments_source_binding_mismatch -> "comments source belongs to another captured workspace"
  | Comments_snapshot_stale -> "captured comments snapshot is stale"
  | Comments_publication_pending -> "comments append has unfinished model publication"
  | Comments_reload_required -> "comments storage recovery requires a full model reload"
  | Comments_workspace_refused rejection -> Board_workspace_binding.rejection_to_string rejection
  | Comments_raised { exception_; _ } -> Printexc.to_string exception_)

let history = function
  | Comments_unobserved -> None
  | Comments_readable receipt | Comments_publishing receipt -> Some receipt.observation
  | Comments_refused { last_observed; _ } -> last_observed
  | Comments_unsettled { pending; _ } -> Some pending.expected

let refuse store failure diagnostics = match store.comments_source with
  | Comments_unsettled _ | Comments_publishing _ -> ()
  | Comments_unobserved | Comments_readable _ | Comments_refused _ ->
    store.comments_source <- Comments_refused {
      last_observed = history store.comments_source; failure; diagnostics }

let expected store = match store.comments_source with
  | Comments_readable { observation; _ } ->
    if String.equal observation.source_path (Board_paths.comments_path store)
    then Ok observation else Error Comments_source_binding_mismatch
  | Comments_unobserved -> Error Comments_not_observed
  | Comments_publishing _ -> Error Comments_publication_pending
  | Comments_refused { failure; _ } | Comments_unsettled { failure; _ } -> Error failure

let require_readable store = expected store |> Result.map (fun _ -> ())
  |> Result.map_error failure_to_board_error

let read_diagnostics = function
  | Complete { diagnostics; _ } | Partial { diagnostics; _ }
  | Unavailable { diagnostics; _ } -> diagnostics

let write_diagnostics = function
  | Written { diagnostics; _ } | Not_written { diagnostics; _ } | Unknown { diagnostics; _ } -> diagnostics

let finish_write outcome =
  let result = match outcome with
    | Written { value; _ } -> Ok value
    | Not_written { failure; _ } | Unknown { failure; _ } -> Error (failure_to_board_error failure) in
  Option.iter (fun (exception_, backtrace) ->
    Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result) exception_ backtrace)
    (reserved_diagnostics (write_diagnostics outcome));
  result

let finish_read outcome =
  let result = match outcome with
    | Complete _ -> Ok ()
    | Partial { errors; _ } -> Error (failure_to_board_error (Comments_rows_rejected errors))
    | Unavailable { failure; _ } -> Error (failure_to_board_error failure) in
  Option.iter (fun (exception_, backtrace) ->
    Board_posts_source.defer_reserved ~result exception_ backtrace)
    (reserved_diagnostics (read_diagnostics outcome));
  result

let observe_workspace store =
  try Board_paths.observe_workspace store with exception_ ->
    Error (Board_workspace_binding.Raised { exception_; backtrace = Printexc.get_raw_backtrace () })

let revalidate store (observation : comments_source_observation) =
  try Board_workspace_binding.revalidate store.workspace_binding observation.workspace_observation
  with exception_ ->
    Error (Board_workspace_binding.Raised { exception_; backtrace = Printexc.get_raw_backtrace () })

let finish_workspace store before =
  if Board_workspace_binding.workspace_directory_missing before then
    (match observe_workspace store with
     | Error _ as error -> error
     | Ok after when Board_workspace_binding.workspace_directory_missing after ->
       Error (Board_workspace_binding.Workspace_directory_changed (Board_paths.workspace_masc_dir store))
     | Ok after -> Ok after)
  else Result.map (fun () -> before)
    (Board_workspace_binding.revalidate store.workspace_binding before)

let read_file store path = match store.comments_source_io with
  | None -> Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
  | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing ~io path ~after:None

let rewrite_file store path ~expected bytes = match store.comments_source_io with
  | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result path ~expected bytes
  | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ~io ~before_sync_rewrite_parent:io.before_sync_parent path ~expected bytes

let missing_allowed store = match history store.comments_source with
  | None -> true
  | Some observation -> Fs_compat.Private_jsonl_cursor.is_missing observation.snapshot.cursor

let receipt_diagnostics error = match error with
  | None -> [] | Some error -> [Comments_file_diagnostic error]

let read store = match store.comments_source with
  | Comments_unsettled { failure; _ } -> Unavailable { failure; diagnostics = [] }
  | Comments_publishing _ -> Unavailable { failure = Comments_publication_pending; diagnostics = [] }
  | Comments_unobserved | Comments_readable _ | Comments_refused _ ->
    let diagnostics = ref [] and stage = ref Read_comments in
    let unavailable failure = refuse store failure !diagnostics;
      Unavailable { failure; diagnostics = !diagnostics } in
    try
      match observe_workspace store with
      | Error rejection -> diagnostics := [Comments_workspace_diagnostic rejection];
        unavailable (Comments_workspace_refused rejection)
      | Ok before ->
        let path = Board_paths.comments_path store in
        match Fs_compat.private_jsonl_snapshot_success_receipt (read_file store path) with
        | Error error -> diagnostics := [Comments_file_diagnostic error];
          unavailable (Comments_transaction_failed error)
        | Ok receipt ->
          diagnostics := receipt_diagnostics receipt.settlement_error;
          match reserved_diagnostics !diagnostics with
          | Some (exception_, backtrace) -> unavailable (Comments_raised { exception_; backtrace })
          | None ->
            match finish_workspace store before with
            | Error rejection -> diagnostics := !diagnostics @ [Comments_workspace_diagnostic rejection];
              unavailable (Comments_workspace_refused rejection)
            | Ok workspace_observation ->
              if Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor && not (missing_allowed store)
              then unavailable Comments_missing
              else (
                stage := Decode_comments;
                let comments = ref [] and errors = ref [] in
                String.split_on_char '\n' receipt.value.bytes |> List.iteri (fun index text ->
                  if String.trim text <> "" then
                    match Yojson.Safe.from_string text with
                    | json ->
                      let decoded = Board_content_json.comment_of_yojson json in
                      Board_content_diagnostics.emit decoded.diagnostics;
                      (match decoded.value with
                       | Some comment -> comments := comment :: !comments
                       | None -> errors := Invalid_comments_row { line = index + 1 } :: !errors)
                    | exception Yojson.Json_error detail ->
                      errors := Invalid_comments_json { line = index + 1; detail } :: !errors);
                let observation : comments_source_observation =
                  { source_path = path; snapshot = receipt.value; workspace_observation } in
                match List.rev !errors with
                | [] -> Complete { observation; comments = List.rev !comments; diagnostics = !diagnostics }
                | errors -> Partial { observation; comments = List.rev !comments; errors; diagnostics = !diagnostics })
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Comments_raised_diagnostic { stage = !stage; exception_; backtrace }];
      unavailable (Comments_raised { exception_; backtrace })

let publish_read store outcome = match store.comments_source with
  | Comments_unsettled _ | Comments_publishing _ -> ()
  | Comments_unobserved | Comments_readable _ | Comments_refused _ ->
    match outcome with
    | Complete { observation; diagnostics; _ } ->
      store.comments_source <- Comments_readable { observation; diagnostics }
    | Partial { observation; errors; diagnostics; _ } ->
      store.comments_source <- Comments_refused { last_observed = Some observation;
        failure = Comments_rows_rejected errors; diagnostics }
    | Unavailable { failure; diagnostics } -> refuse store failure diagnostics

let fail_read store outcome ~stage exception_ backtrace =
  let diagnostics = read_diagnostics outcome @ [Comments_raised_diagnostic { stage; exception_; backtrace }] in
  let failure = match outcome with
    | Unavailable { failure; _ } -> failure
    | Complete _ | Partial _ -> Comments_raised { exception_; backtrace } in
  refuse store failure diagnostics;
  Unavailable { failure; diagnostics }

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

let write store ~(before : comments_source_observation) ~kind ~bytes perform =
  let pending = { expected = before; kind; intended_bytes = bytes } in
  let unknown failure diagnostics =
    store.comments_source <- Comments_unsettled { pending; failure; diagnostics };
    Unknown { failure; diagnostics } in
  try
    match Fs_compat.private_jsonl_cursor_success_receipt (perform ()) with
    | Ok receipt ->
      let diagnostics = receipt_diagnostics receipt.settlement_error in
      let observation : comments_source_observation = { before with
        snapshot = { Fs_compat.bytes = bytes; cursor = receipt.value } } in
      let publication = { observation; diagnostics } in
      store.comments_source <- (match kind with
        | Comments_append -> Comments_publishing publication
        | Comments_rewrite -> Comments_readable publication);
      Written { value = publication; diagnostics }
    | Error error ->
      let diagnostics = [Comments_file_diagnostic error] in
      let failure = Comments_transaction_failed error in
      if Board_posts_source.definitely_not_written error then (
        if contradicts_observation error then refuse store failure diagnostics;
        not_written failure diagnostics)
      else unknown failure diagnostics
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let diagnostics = [Comments_raised_diagnostic { stage = Write_comments; exception_; backtrace }] in
    unknown (Comments_raised { exception_; backtrace }) diagnostics

let workspace_failure store rejection =
  let failure = Comments_workspace_refused rejection in
  let diagnostics = [Comments_workspace_diagnostic rejection] in
  refuse store failure diagnostics;
  not_written failure diagnostics

let append store (comment : comment) = match expected store with
  | Error failure -> not_written failure []
  | Ok before ->
    match revalidate store before with
    | Error rejection -> workspace_failure store rejection
    | Ok () ->
      let encoded = try Ok (Yojson.Safe.to_string (Board_content_json.comment_to_yojson comment) ^ "\n")
        with exception_ -> Error (exception_, Printexc.get_raw_backtrace ()) in
      match encoded with
      | Error (exception_, backtrace) ->
        not_written (Comments_raised { exception_; backtrace })
          [Comments_raised_diagnostic { stage = Encode_comments; exception_; backtrace }]
      | Ok suffix ->
        write store ~before ~kind:Comments_append ~bytes:(before.snapshot.bytes ^ suffix)
          (fun () -> match store.comments_source_io with
           | None -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_result
               before.source_path ~expected:before.snapshot suffix
           | Some io -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
               ~io before.source_path ~expected:before.snapshot suffix)

let publish_append store receipt = match store.comments_source with
  | Comments_publishing current when current == receipt ->
    store.comments_source <- Comments_readable receipt;
    Written { value = (); diagnostics = receipt.diagnostics }
  | Comments_publishing _ | Comments_unobserved | Comments_readable _
  | Comments_refused _ | Comments_unsettled _ -> not_written Comments_snapshot_stale []

let capture store =
  let expected = expected store in
  let bytes = match expected with
    | Error _ -> ""
    | Ok _ -> Board_snapshot_rows.render ~rows:store.comment_rows
        ~to_json:Board_content_json.comment_to_yojson store.comments in
  { expected; bytes }

let rewrite store snapshot =
  let result = match snapshot.expected, expected store with
    | Error failure, _ | _, Error failure -> not_written failure []
    | Ok before, Ok current ->
      if not (String.equal before.source_path current.source_path)
      then not_written Comments_source_binding_mismatch []
      else if not (Fs_compat.Private_jsonl_cursor.equal before.snapshot.cursor current.snapshot.cursor
                   && String.equal before.snapshot.bytes current.snapshot.bytes)
      then not_written Comments_snapshot_stale []
      else match revalidate store before with
        | Error rejection -> workspace_failure store rejection
        | Ok () -> write store ~before ~kind:Comments_rewrite ~bytes:snapshot.bytes
            (fun () -> rewrite_file store before.source_path ~expected:before.snapshot snapshot.bytes) in
  match result with
  | Written { diagnostics; _ } -> Written { value = (); diagnostics }
  | Not_written { failure; diagnostics } -> Not_written { failure; diagnostics }
  | Unknown { failure; diagnostics } -> Unknown { failure; diagnostics }

let settle store = match store.comments_source with
  | Comments_publishing _ -> not_written Comments_publication_pending []
  | Comments_unobserved | Comments_readable _ | Comments_refused _ -> Written { value = None; diagnostics = [] }
  | Comments_unsettled { pending; failure = prior_failure; _ } ->
    let diagnostics = ref [] in
    let inconclusive failure =
      store.comments_source <- Comments_unsettled { pending; failure = prior_failure; diagnostics = !diagnostics };
      Unknown { failure; diagnostics = !diagnostics } in
    let transaction_failed error =
      diagnostics := !diagnostics @ [Comments_file_diagnostic error];
      inconclusive (Comments_transaction_failed error) in
    try
      match revalidate store pending.expected with
      | Error rejection -> diagnostics := [Comments_workspace_diagnostic rejection];
        inconclusive (Comments_workspace_refused rejection)
      | Ok () ->
        let path = Board_paths.comments_path store in
        if not (String.equal path pending.expected.source_path)
        then inconclusive Comments_source_binding_mismatch
        else match Fs_compat.private_jsonl_snapshot_success_receipt (read_file store path) with
          | Error error -> transaction_failed error
          | Ok observed ->
            diagnostics := receipt_diagnostics observed.settlement_error;
            match reserved_diagnostics !diagnostics with
            | Some (exception_, backtrace) -> inconclusive (Comments_raised { exception_; backtrace })
            | None ->
              if Fs_compat.Private_jsonl_cursor.is_missing observed.value.cursor
                 && not (Fs_compat.Private_jsonl_cursor.is_missing pending.expected.snapshot.cursor)
              then inconclusive Comments_missing
              else match Fs_compat.private_jsonl_cursor_success_receipt
                  (rewrite_file store path ~expected:observed.value observed.value.bytes) with
                | Error error -> transaction_failed error
                | Ok proof ->
                  diagnostics := !diagnostics @ receipt_diagnostics proof.settlement_error;
                  let fence : comments_source_observation = { pending.expected with
                    snapshot = { Fs_compat.bytes = observed.value.bytes; cursor = proof.value } } in
                  (* An inode number can be reused. Do not call the original
                     expectation superseded if its exact snapshot reappears. *)
                  if Fs_compat.Private_jsonl_cursor.equal fence.snapshot.cursor pending.expected.snapshot.cursor
                     && String.equal fence.snapshot.bytes pending.expected.snapshot.bytes
                  then inconclusive Comments_snapshot_stale
                  else (
                    store.comments_source <- Comments_refused { last_observed = Some fence;
                      failure = Comments_reload_required; diagnostics = !diagnostics };
                    Written { value = Some { interrupted = pending; prior_failure; fence };
                      diagnostics = !diagnostics })
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Comments_raised_diagnostic { stage = Write_comments; exception_; backtrace }];
      inconclusive (Comments_raised { exception_; backtrace })
