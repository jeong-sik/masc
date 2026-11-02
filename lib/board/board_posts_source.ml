open Board_types

let live_guard_enforced = true

type reserved_settlement = {
  result : (unit, board_error) result;
  exception_ : exn;
  backtrace : Printexc.raw_backtrace;
}
exception Reserved_settlement of reserved_settlement

let rec reserved_exception (exception_, backtrace) = match exception_ with
  | Eio.Cancel.Cancelled _ | Eio.Time.Timeout | Out_of_memory | Stack_overflow | Sys.Break ->
    Some (exception_, backtrace)
  | Eio.Exn.Multiple failures ->
    (match List.find_map reserved_exception failures with
     | None -> None | Some _ -> Some (exception_, backtrace))
  (* exn is open; ordinary exceptions are retained as typed source failures. *)
  | _ -> None

let reserved_failure (failure : Fs_compat.private_jsonl_operation_failure) =
  reserved_exception (failure.exception_, failure.backtrace)

let rec reserved_transaction = function
  | Fs_compat.Private_jsonl_operation_failed failure -> reserved_failure failure
  | Rewrite_stage_failed { failure; cleanup_failures } ->
    (match reserved_failure failure with Some _ as found -> found
     | None -> List.find_map reserved_failure cleanup_failures)
  | Rewrite_published_durability_unknown { failure; _ } -> reserved_failure failure
  | Transaction_settlement_failed { primary; cleanup_failures } ->
    let first = match primary with
      | Transaction_succeeded _ -> None
      | Transaction_failed error -> reserved_transaction error in
    (match first with Some _ -> first | None -> List.find_map reserved_failure cleanup_failures)
  | Stable_lock_contended _ | Unexpected_stable_lock_permissions _
  | Invalid_stable_lock_state _ | Cursor_mismatch _ | Unexpected_transaction_file_kind _
  | Ambiguous_transaction_file_identity _ | Transaction_path_binding_changed _
  | Transaction_content_changed _ | Incomplete_transaction_tail _ | Invalid_transaction_suffix
  | Transaction_append_failed _ -> None

let reserved_diagnostics diagnostics =
  List.find_map (function
    | File_diagnostic { error; _ } -> reserved_transaction error
    | Workspace_diagnostic rejection ->
      Option.bind (Board_workspace_binding.raised rejection) reserved_exception
    | Raised_diagnostic { exception_; backtrace; _ } ->
      reserved_exception (exception_, backtrace)) diagnostics

let carry_reserved result = function
  | None -> ()
  | Some (exception_, backtrace) -> raise (Reserved_settlement { result; exception_; backtrace })

let propagate_reserved exception_ backtrace =
  match reserved_exception (exception_, backtrace) with
  | None -> ()
  | Some (exception_, backtrace) -> Printexc.raise_with_backtrace exception_ backtrace

let defer_reserved ~result exception_ backtrace =
  carry_reserved result (reserved_exception (exception_, backtrace))

let stage_name = function
  | Read_guard -> "read guard" | Validate_guard -> "validate guard"
  | Read_posts -> "read posts" | Decode_posts -> "decode posts"
  | Encode_posts -> "encode posts" | Write_posts -> "write posts"
  | Project_posts -> "project posts" | Report_source -> "report source"

let diagnostic_to_string = function
  | File_diagnostic { file; error } ->
    let file = match file with Guard_file -> "initialization guard" | Posts_file -> "posts" in
    file ^ ": " ^ Fs_compat.private_jsonl_transaction_error_to_string error
  | Workspace_diagnostic rejection -> Board_workspace_binding.rejection_to_string rejection
  | Raised_diagnostic { stage; exception_; _ } ->
    stage_name stage ^ ": " ^ Printexc.to_string exception_

let failure_to_board_error = function
  | Posts_not_observed -> Io_error "posts source has not been explicitly loaded"
  | Posts_rows_rejected errors ->
    let detail = List.map (function
      | Invalid_posts_json { line; detail } -> Printf.sprintf "line %d: invalid JSON: %s" line detail
      | Invalid_posts_row { line } -> Printf.sprintf "line %d: invalid persisted row schema" line) errors in
    Io_error (String.concat "; " detail)
  | Posts_transaction_failed error -> Io_error (Fs_compat.private_jsonl_transaction_error_to_string error)
  | Posts_missing -> Io_error "initialized posts source is missing"
  | Posts_guard_missing -> Io_error "posts initialization guard is missing"
  | Posts_guard_torn -> Io_error "posts initialization guard has an incomplete row"
  | Posts_guard_row_count_rejected count ->
    Io_error (Printf.sprintf "posts initialization guard requires exactly one row (observed %d)" count)
  | Posts_guard_row_rejected error ->
    Io_error (Yojson.Safe.to_string (Board_posts_guard_rows.validation_to_yojson
      (Board_posts_guard_rows.Guard_row_rejected error)))
  | Posts_guard_changed -> Io_error "posts initialization guard differs from accepted history"
  | Posts_source_binding_mismatch -> Io_error "posts source belongs to another captured workspace"
  | Posts_snapshot_stale -> Io_error "captured posts snapshot is stale"
  | Posts_workspace_binding_refused rejection ->
    Io_error (Board_workspace_binding.rejection_to_string rejection)
  | Posts_raised { exception_; _ } -> Io_error (Printexc.to_string exception_)

let history = function
  | Posts_unobserved -> No_initialization
  | Posts_guard_observed { initialization; _ } -> Guard_observed initialization
  | Posts_readable { observation; _ } -> Posts_observed observation
  | Posts_refused { last_observed; _ } | Posts_unsettled { last_observed; _ } -> last_observed

let guard_of_history = function
  | No_initialization -> None
  | Guard_observed guard -> Some guard
  | Posts_observed observation -> Some observation.initialization

let same_guard (left : posts_guard_observation) (right : posts_guard_observation) =
  String.equal left.guard_path right.guard_path
  && String.equal left.snapshot.bytes right.snapshot.bytes
  && String.equal (Board_posts_guard_json.generation left.value)
       (Board_posts_guard_json.generation right.value)
  && Board_workspace_binding.same_root left.workspace_observation right.workspace_observation

let refused store failure diagnostics = match store.posts_source with
  | Posts_unsettled _ -> ()
  | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ ->
    store.posts_source <- Posts_refused {
      last_observed = history store.posts_source; failure; diagnostics }

let unsettled store ~pending failure diagnostics =
  store.posts_source <- Posts_unsettled {
    last_observed = history store.posts_source; failure; pending; diagnostics }

let retain_trace store diagnostics = match store.posts_source with
  | Posts_unobserved | Posts_unsettled _ -> ()
  | Posts_guard_observed phase -> store.posts_source <- Posts_guard_observed { phase with diagnostics }
  | Posts_readable phase -> store.posts_source <- Posts_readable { phase with diagnostics }
  | Posts_refused phase -> store.posts_source <- Posts_refused { phase with diagnostics }

let accept_guard store initialization diagnostics =
  let update_history = function
    | No_initialization | Guard_observed _ -> Guard_observed initialization
    | Posts_observed observation -> Posts_observed { observation with initialization } in
  match store.posts_source with
  | Posts_unsettled _ -> ()
  | Posts_unobserved | Posts_guard_observed _ ->
    store.posts_source <- Posts_guard_observed { initialization; diagnostics }
  | Posts_readable phase ->
    store.posts_source <- Posts_readable {
      observation = { phase.observation with initialization }; diagnostics }
  | Posts_refused phase ->
    store.posts_source <- Posts_refused {
      last_observed = update_history phase.last_observed; failure = phase.failure; diagnostics }

let expected store = match store.posts_source with
  | Posts_readable { observation; _ } ->
    if String.equal observation.source_path (Board_paths.persist_path store)
    then Ok observation else Error Posts_source_binding_mismatch
  | Posts_unobserved | Posts_guard_observed _ -> Error Posts_not_observed
  | Posts_refused { failure; _ } | Posts_unsettled { failure; _ } -> Error failure

let require_readable store =
  expected store
  |> Result.map (fun _ -> ())
  |> Result.map_error failure_to_board_error

let observe_workspace store =
  try Board_paths.observe_workspace store with exception_ ->
    Error (Board_workspace_binding.Raised { exception_; backtrace = Printexc.get_raw_backtrace () })

let finish_workspace store before =
  try
    if Board_workspace_binding.workspace_directory_missing before then
      match observe_workspace store with
      | Error _ as error -> error
      | Ok after when Board_workspace_binding.workspace_directory_missing after ->
        Error (Board_workspace_binding.Workspace_directory_changed (Board_paths.workspace_masc_dir store))
      | Ok after -> Ok after
    else Result.map (fun () -> before)
      (Board_workspace_binding.revalidate store.workspace_binding before)
  with exception_ ->
    Error (Board_workspace_binding.Raised { exception_; backtrace = Printexc.get_raw_backtrace () })

type initialization_check = {
  checked : (posts_guard_observation, posts_source_failure) result;
  workspace : Board_workspace_binding.observation option;
  diagnostics : posts_source_diagnostic list;
}

let initialization_result (check : initialization_check) = Result.map (fun _ -> ()) check.checked
let initialization_diagnostics (check : initialization_check) = check.diagnostics
let finish_initialization ~result (check : initialization_check) =
  carry_reserved result (reserved_diagnostics check.diagnostics)

let initialization_exception store (check : initialization_check) exception_ backtrace =
  let diagnostics = check.diagnostics @ [Raised_diagnostic { stage = Report_source; exception_; backtrace }] in
  let failure = match check.checked with
    | Error failure -> failure | Ok _ -> Posts_raised { exception_; backtrace } in
  refused store failure diagnostics;
  { check with checked = Error failure; diagnostics }

(* The guard check proper. [refused] and [accept_guard] are no-ops on an
   unsettled store, so [settle] may run this for its own re-verification
   without disturbing the retained unknown write. *)
let check_initialization_inner store =
    let diagnostics = ref [] in
    let add diagnostic = diagnostics := !diagnostics @ [diagnostic] in
    let reject ?workspace failure =
      refused store failure !diagnostics;
      { checked = Error failure; workspace; diagnostics = !diagnostics } in
    match observe_workspace store with
    | Error rejection -> add (Workspace_diagnostic rejection);
      reject (Posts_workspace_binding_refused rejection)
    | Ok before ->
      let complete candidate =
        match reserved_diagnostics !diagnostics with
        | Some (exception_, backtrace) ->
          let failure = match candidate with Error failure -> failure
            | Ok _ -> Posts_raised { exception_; backtrace } in
          reject failure
        | None ->
          match finish_workspace store before with
          | Error rejection -> add (Workspace_diagnostic rejection);
            reject (Posts_workspace_binding_refused rejection)
          | Ok workspace ->
            match candidate with
            | Error failure -> reject ~workspace failure
            | Ok (snapshot, value) ->
              let initialization = {
                guard_path = Board_paths.posts_initialization_guard_file
                  ~workspace_masc_dir:(Board_paths.workspace_masc_dir store);
                snapshot; value; workspace_observation = workspace } in
              match guard_of_history (history store.posts_source) with
              | Some accepted when not (same_guard accepted initialization) ->
                reject ~workspace Posts_guard_changed
              | None | Some _ ->
                accept_guard store initialization !diagnostics;
                { checked = Ok initialization; workspace = Some workspace; diagnostics = !diagnostics }
      in
      let path = Board_paths.posts_initialization_guard_file
          ~workspace_masc_dir:(Board_paths.workspace_masc_dir store) in
      match Board_posts_guard_read.read ?io:store.posts_source_io.guard ~path () with
      | Failed error -> add (File_diagnostic { file = Guard_file; error });
        complete (Error (Posts_transaction_failed error))
      | Raised (exception_, backtrace) ->
        add (Raised_diagnostic { stage = Read_guard; exception_; backtrace });
        complete (Error (Posts_raised { exception_; backtrace }))
      | Read receipt ->
        Option.iter (fun error -> add (File_diagnostic { file = Guard_file; error })) receipt.settlement_error;
        let missing = Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor in
        match reserved_diagnostics !diagnostics with
        | Some (exception_, backtrace) ->
          (* Required post-read physical checks have not happened: retain only
             prior history and stop before any further workspace/posts IO. *)
          reject (if missing then Posts_guard_missing else Posts_raised { exception_; backtrace })
        | None ->
          let candidate =
            if missing then Error Posts_guard_missing
            else try
              match Board_posts_guard_read.validate receipt.value with
              | Valid_guard value -> Ok (receipt.value, value)
              | Torn_guard -> Error Posts_guard_torn
              | Guard_row_count_rejected count -> Error (Posts_guard_row_count_rejected count)
              | Guard_row_rejected error -> Error (Posts_guard_row_rejected error)
            with exception_ ->
              let backtrace = Printexc.get_raw_backtrace () in
              add (Raised_diagnostic { stage = Validate_guard; exception_; backtrace });
              Error (Posts_raised { exception_; backtrace }) in
          complete candidate

let check_initialization store = match store.posts_source with
  | Posts_unsettled { failure; _ } ->
    { checked = Error failure; workspace = None; diagnostics = [] }
  | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ ->
    check_initialization_inner store

let read_diagnostics = function
  | Posts_complete { diagnostics; _ } | Posts_partial { diagnostics; _ }
  | Posts_unadmitted { diagnostics; _ } | Posts_unavailable { diagnostics; _ } -> diagnostics

let write_diagnostics = function
  | Posts_written { diagnostics } | Posts_not_written { diagnostics; _ }
  | Posts_write_unknown { diagnostics; _ } -> diagnostics

let fail_read store outcome ~stage exception_ backtrace =
  let diagnostics = read_diagnostics outcome @ [Raised_diagnostic { stage; exception_; backtrace }] in
  let failure = match outcome with
    | Posts_unadmitted { failure; _ } | Posts_unavailable { failure; _ } -> failure
    | Posts_complete _ | Posts_partial _ -> Posts_raised { exception_; backtrace } in
  refused store failure diagnostics;
  Posts_unavailable { failure; diagnostics }, failure

let finish_read outcome =
  let result = match outcome with
    | Posts_complete _ -> Ok ()
    | Posts_partial { errors; _ } -> Error (failure_to_board_error (Posts_rows_rejected errors))
    | Posts_unadmitted { failure; _ } | Posts_unavailable { failure; _ } ->
      Error (failure_to_board_error failure) in
  carry_reserved result (reserved_diagnostics (read_diagnostics outcome))

let finish_write outcome =
  let result = match outcome with
    | Posts_written _ -> Ok ()
    | Posts_not_written { failure; _ } | Posts_write_unknown { failure; _ } ->
      Error (failure_to_board_error failure) in
  (* Reserved causes travel as [Reserved_settlement] so the enclosing persist
     lock releases cleanly; an unknown outcome stays settleable and never
     poisons the caller's persistence mutex. Only an explicit non-reserved
     exception crossing [use_rw] poisons it. *)
  carry_reserved result (reserved_diagnostics (write_diagnostics outcome));
  result

let read store = match store.posts_source with
  | Posts_unsettled { failure; _ } -> Posts_unavailable { failure; diagnostics = [] }
  | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ ->
    let check = check_initialization store in
    let failure current = match check.checked with Error prior -> prior | Ok _ -> current in
    let unavailable diagnostics current =
      let failure = failure current in
      refused store failure diagnostics; Posts_unavailable { failure; diagnostics } in
    match check.workspace, reserved_diagnostics check.diagnostics with
    | None, _ | Some _, Some _ ->
      let failure = match check.checked with Error failure -> failure
        | Ok _ -> Posts_not_observed in
      Posts_unavailable { failure; diagnostics = check.diagnostics }
    | Some before, None ->
      let diagnostics = ref check.diagnostics in
      let add diagnostic = diagnostics := !diagnostics @ [diagnostic] in
      let path = Board_paths.persist_path store in
      let stage = ref Read_posts in
      try
        let result = match store.posts_source_io.posts with
          | None -> Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
          | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing ~io path ~after:None in
        match Fs_compat.private_jsonl_snapshot_success_receipt result with
        | Error error -> add (File_diagnostic { file = Posts_file; error });
          unavailable !diagnostics (Posts_transaction_failed error)
        | Ok receipt ->
          Option.iter (fun error -> add (File_diagnostic { file = Posts_file; error })) receipt.settlement_error;
          let missing = Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor in
          match reserved_diagnostics !diagnostics with
          | Some (exception_, backtrace) -> unavailable !diagnostics
              (if missing then Posts_missing else Posts_raised { exception_; backtrace })
          | None ->
            match finish_workspace store before with
            | Error rejection -> add (Workspace_diagnostic rejection);
              unavailable !diagnostics (Posts_workspace_binding_refused rejection)
            | Ok workspace ->
              if missing then unavailable !diagnostics Posts_missing
              else
                let () = stage := Decode_posts in
                let posts = ref [] and errors = ref [] in
                String.split_on_char '\n' receipt.value.bytes |> List.iteri (fun index text ->
                  match Board_posts_rows.decode ~line:(index + 1) text with
                  | Blank -> ()
                  | Accepted { post; diagnostics } ->
                    Board_content_diagnostics.emit diagnostics; posts := post :: !posts
                  | Rejected { error; diagnostics } ->
                    Board_content_diagnostics.emit diagnostics; errors := error :: !errors);
                let posts = List.rev !posts and errors = List.rev !errors in
                match check.checked with
                | Error failure ->
                  let display = match errors with [] -> Complete_display posts
                    | errors -> Partial_display { posts; errors } in
                  Posts_unadmitted { source_path = path; snapshot = receipt.value;
                    display; failure; diagnostics = !diagnostics }
                | Ok initialization ->
                  let initialization = { initialization with workspace_observation = workspace } in
                  let observation = { source_path = path; snapshot = receipt.value; initialization } in
                  match errors with
                  | [] -> Posts_complete { observation; posts; diagnostics = !diagnostics }
                  | errors -> Posts_partial { observation; posts; errors; diagnostics = !diagnostics }
      with exception_ ->
        let backtrace = Printexc.get_raw_backtrace () in
        add (Raised_diagnostic { stage = !stage; exception_; backtrace });
        unavailable !diagnostics (Posts_raised { exception_; backtrace })

let publish_read store outcome = match store.posts_source with
  | Posts_unsettled _ -> ()
  | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ ->
    match outcome with
    | Posts_complete { observation; diagnostics; _ } ->
      store.posts_source <- Posts_readable { observation; diagnostics }
    | Posts_partial { observation; errors; diagnostics; _ } ->
      store.posts_source <- Posts_refused { last_observed = Posts_observed observation;
        failure = Posts_rows_rejected errors; diagnostics }
    | Posts_unadmitted { failure; diagnostics; _ } | Posts_unavailable { failure; diagnostics } ->
      refused store failure diagnostics

(* Only error branches with actual prepublication evidence are nonwrites. The
   final append fstat uses the same operation tag as its precondition fstat. *)
let rec definitely_not_written = function
  | Fs_compat.Stable_lock_contended _ | Unexpected_stable_lock_permissions _
  | Invalid_stable_lock_state _ | Cursor_mismatch _ | Unexpected_transaction_file_kind _
  | Ambiguous_transaction_file_identity _ | Transaction_path_binding_changed _
  | Transaction_content_changed _ | Incomplete_transaction_tail _ | Invalid_transaction_suffix
  | Rewrite_stage_failed _ -> true
  | Transaction_append_failed { rollback_failures; _ } -> rollback_failures = []
  | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> definitely_not_written error
  | Transaction_settlement_failed { primary = Transaction_succeeded (Cursor_precondition_succeeded _); _ } -> true
  | Transaction_settlement_failed { primary = Transaction_succeeded (Snapshot_succeeded _ | Cursor_succeeded _); _ }
  | Rewrite_published_durability_unknown _ -> false
  | Private_jsonl_operation_failed { operation; _ } ->
    (match operation with
     | Create_parent_directory | Canonicalize_parent_directory | Inspect_stable_lock
     | Open_stable_lock | Set_stable_lock_permissions | Sync_stable_lock_parent
     | Acquire_stable_lock | Read_stable_lock_state | Write_stable_lock_state
     | Sync_stable_lock | Open_transaction_data | Set_transaction_data_permissions
     | Inspect_transaction_path | Read_transaction_data | Create_rewrite_stage
     | Set_rewrite_stage_permissions | Write_rewrite_stage | Sync_rewrite_stage
     | Close_rewrite_stage | Rename_rewrite_stage | Remove_rewrite_stage -> true
     | Inspect_transaction_data | Close_transaction_data | Close_stable_lock
     | Sync_rewrite_parent | Inspect_rewritten_data | Truncate_transaction_data
     | Sync_transaction_data | Remove_transaction_data | Sync_removal_parent -> false)

(* A prewrite nonregular obstruction cannot authorize a write. Retain the old
   expectation so an applied deletion can retry after the original file is
   restored: Fs must still compare its exact identity and bytes. A real read
   failure remains a refusal through [publish_read]. *)
let rec contradicts_observation = function
  | Fs_compat.Cursor_mismatch _ | Transaction_content_changed _
  | Transaction_path_binding_changed _ | Incomplete_transaction_tail _
  | Ambiguous_transaction_file_identity _ -> true
  | Transaction_settlement_failed { primary = Transaction_failed error; _ } -> contradicts_observation error
  | Stable_lock_contended _ | Unexpected_stable_lock_permissions _ | Invalid_stable_lock_state _
  | Unexpected_transaction_file_kind _ | Invalid_transaction_suffix | Private_jsonl_operation_failed _
  | Rewrite_stage_failed _ | Rewrite_published_durability_unknown _
  | Transaction_settlement_failed { primary = Transaction_succeeded _; _ }
  | Transaction_append_failed _ -> false

let classify_write store ~pre_write ~kind ~initialization ~bytes ~diagnostics result =
  match Fs_compat.private_jsonl_cursor_success_receipt result with
  | Ok receipt ->
    let diagnostics = diagnostics @ (match receipt.settlement_error with None -> []
      | Some error -> [File_diagnostic { file = Posts_file; error }]) in
    let observation = { source_path = Board_paths.persist_path store;
      snapshot = { Fs_compat.bytes = bytes; cursor = receipt.value }; initialization } in
    store.posts_source <- Posts_readable { observation; diagnostics };
    Posts_written { diagnostics }
  | Error error ->
    let diagnostics = diagnostics @ [File_diagnostic { file = Posts_file; error }] in
    let failure = Posts_transaction_failed error in
    if definitely_not_written error then (
      if contradicts_observation error then refused store failure diagnostics
      else retain_trace store diagnostics;
      Posts_not_written { failure; diagnostics })
    else
      let pending : posts_unsettled_write =
        { expected = pre_write; kind; intended_bytes = bytes } in
      (unsettled store ~pending failure diagnostics; Posts_write_unknown { failure; diagnostics })

let write store ~pre_write ~kind ~initialization ~bytes ~diagnostics perform =
  try classify_write store ~pre_write ~kind ~initialization ~bytes ~diagnostics (perform ())
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let diagnostics = diagnostics @ [Raised_diagnostic { stage = Write_posts; exception_; backtrace }] in
    let failure = Posts_raised { exception_; backtrace } in
    let pending : posts_unsettled_write =
      { expected = pre_write; kind; intended_bytes = bytes } in
    unsettled store ~pending failure diagnostics; Posts_write_unknown { failure; diagnostics }

let not_written failure diagnostics = Posts_not_written { failure; diagnostics }

let append store post = match expected store with
  | Error failure -> not_written failure []
  | Ok observation ->
    let check = check_initialization store in
    match check.checked with
    | Error failure -> not_written failure check.diagnostics
    | Ok initialization ->
      let encoded = try Ok (Yojson.Safe.to_string (Board_content_json.post_to_yojson post) ^ "\n")
        with exception_ -> Error (exception_, Printexc.get_raw_backtrace ()) in
      match encoded with
      | Error (exception_, backtrace) ->
        let diagnostics = check.diagnostics @ [Raised_diagnostic { stage = Encode_posts; exception_; backtrace }] in
        retain_trace store diagnostics;
        not_written (Posts_raised { exception_; backtrace }) diagnostics
      | Ok suffix ->
        let bytes = observation.snapshot.bytes ^ suffix in
        let pre_write = { observation with initialization } in
        write store ~pre_write ~kind:Append_write ~initialization ~bytes ~diagnostics:check.diagnostics
          (fun () -> match store.posts_source_io.posts with
          | None -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_result
              observation.source_path ~expected:observation.snapshot suffix
          | Some io -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
              ~io observation.source_path ~expected:observation.snapshot suffix)

type snapshot = { expected : (posts_source_observation, posts_source_failure) result; bytes : string }

let capture ?replacement store =
  let expected = expected store in
  let bytes = match expected with
    | Error _ -> ""
    | Ok _ -> match replacement with
      | None -> Board_snapshot_rows.render ~rows:store.post_rows
          ~to_json:Board_content_json.post_to_yojson store.posts
      | Some (replacement : post) ->
        let buffer = Buffer.create 4096 in
        Hashtbl.iter (fun key (post : post) ->
          let post = if String.equal key (Post_id.to_string replacement.id) then replacement else post in
          Buffer.add_string buffer (Yojson.Safe.to_string (Board_content_json.post_to_yojson post));
          Buffer.add_char buffer '\n') store.posts;
        Buffer.contents buffer in
  { expected; bytes }

let rewrite store snapshot = match snapshot.expected, expected store with
  | Error failure, _ | _, Error failure -> not_written failure []
  | Ok captured, Ok current ->
    if not (String.equal captured.source_path current.source_path) then
      not_written Posts_source_binding_mismatch []
    else if not (Fs_compat.Private_jsonl_cursor.equal captured.snapshot.cursor current.snapshot.cursor
      && String.equal captured.snapshot.bytes current.snapshot.bytes
      && same_guard captured.initialization current.initialization) then
      not_written Posts_snapshot_stale []
    else
      let validation = try Board_workspace_binding.revalidate store.workspace_binding
          captured.initialization.workspace_observation with exception_ ->
        Error (Board_workspace_binding.Raised { exception_; backtrace = Printexc.get_raw_backtrace () }) in
      match validation with
      | Error rejection ->
        let failure = Posts_workspace_binding_refused rejection in
        let diagnostics = [Workspace_diagnostic rejection] in
        refused store failure diagnostics; not_written failure diagnostics
      | Ok () ->
        let check = check_initialization store in
        match check.checked with
        | Error failure -> not_written failure check.diagnostics
        | Ok initialization ->
          let pre_write : posts_source_observation =
            { source_path = captured.source_path; snapshot = captured.snapshot; initialization } in
          write store ~pre_write ~kind:Rewrite_write ~initialization ~bytes:snapshot.bytes
            ~diagnostics:check.diagnostics
            (fun () -> match store.posts_source_io.posts with
            | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
                captured.source_path ~expected:captured.snapshot snapshot.bytes
            | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
                ~io ~before_sync_rewrite_parent:io.before_sync_parent
                captured.source_path ~expected:captured.snapshot snapshot.bytes)

let settle_diagnostics = function
  | Posts_settled_written { diagnostics; _ } | Posts_settled_not_written { diagnostics; _ }
  | Posts_settle_superseded { diagnostics; _ } | Posts_settle_inconclusive { diagnostics; _ } ->
    diagnostics
  | Posts_settle_nothing_to_settle -> []

(* Byte-content evidence comparison for settlement. This compares observed
   file bytes against retained write evidence; it never dispatches on
   string tags. *)
let bytes_have_prefix ~prefix bytes =
  let prefix_length = String.length prefix in
  String.length bytes >= prefix_length
  && String.equal prefix (String.sub bytes 0 prefix_length)

type settle_direction =
  | Direction_landed
  | Direction_absent
  | Direction_diverged

(* Joint verdict over the retained write evidence and one fresh locked
   observation. There is no bytes-only shortcut: the pending kind,
   pre-write bytes and intended bytes all participate, and the caller
   re-verifies path, guard and cursor around this decision. A late
   completion landing after an [Direction_absent] verdict cannot silently
   duplicate: the restored pre-write cursor fences the retry, which then
   fails closed on cursor mismatch. *)
let settle_direction ~(pending : posts_unsettled_write) (observed : Fs_compat.private_jsonl_snapshot) =
  let original = pending.expected.snapshot.bytes in
  let intended = pending.intended_bytes in
  let current = observed.bytes in
  if String.equal current original then Direction_absent
  else
    let landed =
      String.equal current intended
      || (match pending.kind with
          | Append_write -> bytes_have_prefix ~prefix:intended current
          | Rewrite_write -> false)
    in
    if landed then Direction_landed else Direction_diverged

let settle_direction_for_testing ~pending observed = settle_direction ~pending observed

let settle_locked_read store path =
  match store.posts_source_io.posts with
  | None -> Fs_compat.read_private_jsonl_durable_locked_result path ~after:None
  | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing ~io path ~after:None

let settle_proof_rewrite store path ~expected bytes =
  match store.posts_source_io.posts with
  | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result path ~expected bytes
  | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ~io ~before_sync_rewrite_parent:io.before_sync_parent path ~expected bytes

type settle_proof =
  | Proof_written of posts_settle_outcome
  | Proof_reserved
  | Proof_failed of posts_source_diagnostic list

(* Prove durability of landed bytes with one durable rewrite of the exact
   observed content at the exact observed snapshot. The rewrite either
   returns a fresh durable cursor or fails closed (including on a
   concurrent third-party write); it never truncates or repairs tails. *)
let settle_prove store path ~failure ~initialization ~diagnostics observed =
  let prove_result = settle_proof_rewrite store path ~expected:observed observed.bytes in
  match Fs_compat.private_jsonl_cursor_success_receipt prove_result with
  | Ok receipt ->
    let diagnostics = diagnostics @ (match receipt.settlement_error with None -> []
      | Some error -> [File_diagnostic { file = Posts_file; error }]) in
    (match reserved_diagnostics diagnostics with
     | Some (exception_, backtrace) ->
       carry_reserved (Error (failure_to_board_error failure)) (Some (exception_, backtrace));
       Proof_reserved
     | None ->
       let observation = { source_path = path;
         snapshot = { Fs_compat.bytes = observed.bytes; cursor = receipt.value };
         initialization } in
       store.posts_source <- Posts_readable { observation; diagnostics };
       Proof_written (Posts_settled_written { observation; diagnostics }))
  | Error error ->
    let diagnostics = diagnostics @ [File_diagnostic { file = Posts_file; error }] in
    (match reserved_diagnostics diagnostics with
     | Some (exception_, backtrace) ->
       carry_reserved (Error (failure_to_board_error failure)) (Some (exception_, backtrace));
       Proof_reserved
     | None -> Proof_failed diagnostics)

let settle_inner store ~failure ~(pending : posts_unsettled_write) ~last_observed =
  let inconclusive diagnostics =
    store.posts_source <- Posts_unsettled { last_observed; failure; pending; diagnostics };
    Posts_settle_inconclusive { failure; diagnostics } in
  let check = check_initialization_inner store in
  match reserved_diagnostics check.diagnostics with
  | Some (exception_, backtrace) ->
    carry_reserved (Error (failure_to_board_error failure)) (Some (exception_, backtrace));
    inconclusive check.diagnostics
  | None ->
    (match check.checked with
     | Error guard_failure ->
       let diagnostics = check.diagnostics in
       store.posts_source <- Posts_refused { last_observed; failure = guard_failure; diagnostics };
       Posts_settle_superseded { failure = guard_failure; diagnostics }
     | Ok initialization ->
       let path = Board_paths.persist_path store in
       if not (String.equal path pending.expected.source_path) then (
         let failure = Posts_source_binding_mismatch in
         let diagnostics = check.diagnostics in
         store.posts_source <- Posts_refused { last_observed; failure; diagnostics };
         Posts_settle_superseded { failure; diagnostics })
       else
         let stage = ref Read_posts in
         (match settle_locked_read store path with
          | exception exception_ ->
            let backtrace = Printexc.get_raw_backtrace () in
            (match reserved_exception (exception_, backtrace) with
             | Some _ ->
               carry_reserved (Error (failure_to_board_error failure)) (Some (exception_, backtrace));
               inconclusive check.diagnostics
             | None ->
               let diagnostics = check.diagnostics
                 @ [Raised_diagnostic { stage = !stage; exception_; backtrace }] in
               inconclusive diagnostics)
          | result ->
            (match Fs_compat.private_jsonl_snapshot_success_receipt result with
             | Error error ->
               let diagnostics = check.diagnostics @ [File_diagnostic { file = Posts_file; error }] in
               (match reserved_diagnostics diagnostics with
                | Some (exception_, backtrace) ->
                  carry_reserved (Error (failure_to_board_error failure)) (Some (exception_, backtrace));
                  inconclusive diagnostics
                | None -> inconclusive diagnostics)
             | Ok receipt ->
               let diagnostics = check.diagnostics @ (match receipt.settlement_error with None -> []
                 | Some error -> [File_diagnostic { file = Posts_file; error }]) in
               (match reserved_diagnostics diagnostics with
                | Some (exception_, backtrace) ->
                  carry_reserved (Error (failure_to_board_error failure)) (Some (exception_, backtrace));
                  inconclusive diagnostics
                | None ->
                  let observed = receipt.value in
                  if Fs_compat.Private_jsonl_cursor.is_missing observed.cursor then (
                    let failure = Posts_missing in
                    store.posts_source <- Posts_refused { last_observed; failure; diagnostics };
                    Posts_settle_superseded { failure; diagnostics })
                  else
                    (match settle_direction ~pending observed with
                     | Direction_absent ->
                       let observation = pending.expected in
                       store.posts_source <- Posts_readable { observation; diagnostics };
                       Posts_settled_not_written { observation; diagnostics }
                     | Direction_diverged ->
                       let failure = Posts_snapshot_stale in
                       let fresh = { source_path = path; snapshot = observed; initialization } in
                       store.posts_source <- Posts_refused {
                         last_observed = Posts_observed fresh; failure; diagnostics };
                       Posts_settle_superseded { failure; diagnostics }
                     | Direction_landed ->
                       (match settle_prove store path ~failure ~initialization ~diagnostics observed with
                        | Proof_written outcome -> outcome
                        | Proof_reserved -> inconclusive diagnostics
                        | Proof_failed proof_diagnostics -> inconclusive proof_diagnostics))))))

let settle store = match store.posts_source with
  | Posts_unobserved | Posts_guard_observed _ | Posts_readable _ | Posts_refused _ ->
    Posts_settle_nothing_to_settle
  | Posts_unsettled { last_observed; failure; pending; _ } ->
    (try settle_inner store ~failure ~pending ~last_observed
     with exception_ ->
       let backtrace = Printexc.get_raw_backtrace () in
       (match reserved_exception (exception_, backtrace) with
        | Some _ ->
          carry_reserved (Error (failure_to_board_error failure)) (Some (exception_, backtrace));
          let diagnostics = [] in
          store.posts_source <- Posts_unsettled { last_observed; failure; pending; diagnostics };
          Posts_settle_inconclusive { failure; diagnostics }
        | None ->
          let diagnostics = [Raised_diagnostic { stage = Report_source; exception_; backtrace }] in
          store.posts_source <- Posts_unsettled { last_observed; failure; pending; diagnostics };
          Posts_settle_inconclusive { failure; diagnostics }))
