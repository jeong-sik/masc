open Board_types
open Result.Syntax

let path store = Board_paths.store_file_path store Board_paths.Deletion
let unavailable () = Io_error "Board deletion recovery is unavailable."

type write =
  | Recorded of deletion_receipt
  | Cleared of deletion_diagnostic list
  | Not_written of deletion_diagnostic list
  | Unknown of deletion_diagnostic list

let reserved diagnostics = List.find_map (function
  | Deletion_file_diagnostic error -> Board_posts_source.reserved_transaction error
  | Deletion_guard_diagnostic failure -> Board_posts_source.reserved_transaction failure.guard_error
  | Deletion_workspace_diagnostic rejection ->
    Option.bind (Board_workspace_binding.raised rejection) Board_posts_source.reserved_exception
  | Deletion_raised_diagnostic { exception_; backtrace } ->
    Board_posts_source.reserved_exception (exception_, backtrace)) diagnostics

let finish_diagnostics diagnostics result =
  Option.iter (fun (exception_, backtrace) ->
    Board_posts_source.defer_reserved ~result:(Result.map (fun _ -> ()) result) exception_ backtrace)
    (reserved diagnostics);
  result

let finish outcome result =
  let diagnostics = match outcome with
    | Recorded receipt -> receipt.decision_cleanup
    | Cleared diagnostics | Not_written diagnostics | Unknown diagnostics -> diagnostics in
  finish_diagnostics diagnostics result

let receipt_diagnostics = function
  | None -> [] | Some error -> [Deletion_file_diagnostic error]

let encode plan =
  Yojson.Safe.to_string (`Assoc [
    "version", `Int 1;
    "decision_id", `String (Deletion_id.to_string plan.decision_id);
    "post_id", `String (Post_id.to_string plan.deleted_post);
    "comment_ids", `List (List.map (fun id -> `String (Comment_id.to_string id)) plan.deleted_comments)
  ]) ^ "\n"

let decode bytes =
  let invalid () = Error (Deletion_invalid_decision "Invalid current Board deletion decision.") in
  let canonical parse render raw =
    match parse raw with
    | Ok value when String.equal raw (render value) -> Ok value
    | Ok _ | Error _ -> invalid () in
  let rec comments seen reversed = function
    | [] -> Ok (List.rev reversed)
    | `String raw :: remaining ->
      let* id = canonical Comment_id.of_string Comment_id.to_string raw in
      if Set_util.StringSet.mem raw seen then invalid ()
      else comments (Set_util.StringSet.add raw seen) (id :: reversed) remaining
    | (`Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `Assoc _ | `List _
      | `Tuple _ | `Variant _) :: _ -> invalid () in
  if String.equal bytes "" then Ok None
  else match String.split_on_char '\n' bytes with
    | [row; ""] ->
      (match Yojson.Safe.from_string row with
       | `Assoc fields when
           List.sort String.compare (List.map fst fields)
           = ["comment_ids"; "decision_id"; "post_id"; "version"] ->
         let field name = match List.assoc_opt name fields with
           | Some value -> Ok value | None -> invalid () in
         let* version = field "version" in
         let* decision = field "decision_id" in
         let* post = field "post_id" in
         let* ids = field "comment_ids" in
         (match version, decision, post, ids with
          | `Int 1, `String decision, `String post, `List ids ->
            let* decision_id = canonical Deletion_id.of_string Deletion_id.to_string decision in
            let* deleted_post = canonical Post_id.of_string Post_id.to_string post in
            let* deleted_comments = comments Set_util.StringSet.empty [] ids in
            Ok (Some { decision_id; deleted_post; deleted_comments })
          | _ -> invalid ())
       | _ -> invalid ()
       | exception Yojson.Json_error detail -> Error (Deletion_invalid_decision detail))
    | [] | [_] | _ :: _ :: _ -> invalid ()

let observe_workspace store =
  try Board_paths.observe_workspace store with exception_ ->
    Error (Board_workspace_binding.Raised { exception_; backtrace = Printexc.get_raw_backtrace () })

let finish_workspace store before =
  if Board_workspace_binding.workspace_directory_missing before then
    let* after = observe_workspace store in
    if Board_workspace_binding.workspace_directory_missing after then
      Error (Board_workspace_binding.Workspace_directory_changed (Board_paths.workspace_masc_dir store))
    else Ok after
  else Result.map (fun () -> before)
    (Board_workspace_binding.revalidate store.workspace_binding before)

let read_file store = match store.deletion_source_io with
  | None -> Fs_compat.read_private_jsonl_durable_locked_result (path store) ~after:None
  | Some io -> Fs_compat.read_private_jsonl_durable_locked_with_io_for_testing ~io (path store) ~after:None

let load store = match store.deletion_state with
  | Deletion_pending _ | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _ ->
    Error (unavailable ())
  | Deletion_unobserved | Deletion_readable _ ->
    let previous = match store.deletion_state with
      | Deletion_readable { observation; _ } -> Some observation
      | Deletion_unobserved -> None
      | Deletion_pending _ | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _ -> None in
    let diagnostics = ref [] and observed = ref previous in
    let refuse failure =
      store.deletion_state <- Deletion_refused { last_observed = !observed; failure; diagnostics = !diagnostics };
      finish_diagnostics !diagnostics (Error (unavailable ())) in
    let read () =
      match observe_workspace store with
      | Error rejection -> diagnostics := [Deletion_workspace_diagnostic rejection];
        refuse (Deletion_workspace_refused rejection)
      | Ok before ->
        match Fs_compat.private_jsonl_snapshot_success_receipt (read_file store) with
        | Error error -> diagnostics := [Deletion_file_diagnostic error];
          refuse (Deletion_transaction_failed error)
        | Ok receipt ->
          diagnostics := receipt_diagnostics receipt.settlement_error;
          match reserved !diagnostics with
          | Some (exception_, backtrace) -> refuse (Deletion_raised { exception_; backtrace })
          | None ->
            match finish_workspace store before with
            | Error rejection -> diagnostics := !diagnostics @ [Deletion_workspace_diagnostic rejection];
              refuse (Deletion_workspace_refused rejection)
            | Ok decision_workspace ->
              let observation = { decision_path = path store; decision_snapshot = receipt.value; decision_workspace } in
              observed := Some observation;
              let missing = Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor in
              let disappeared = match previous with
                | None -> false
                | Some old -> missing && not (Fs_compat.Private_jsonl_cursor.is_missing old.decision_snapshot.cursor) in
              if disappeared then refuse Deletion_marker_missing
              else match decode receipt.value.bytes with
                | Error failure -> refuse failure
                | Ok plan ->
                  store.deletion_state <- Deletion_readable { observation; plan; diagnostics = !diagnostics };
                  Ok plan in
    (* The shared carrier must leave this scope unchanged, after publication. *)
    try read () with
    | Board_posts_source.Reserved_settlement _ as deferred -> raise deferred
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Deletion_raised_diagnostic { exception_; backtrace }];
      refuse (Deletion_raised { exception_; backtrace })

let require_empty store = match store.deletion_state with
  | Deletion_readable { plan = Some _; _ } | Deletion_pending _
  | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _ -> Error (unavailable ())
  | Deletion_unobserved | Deletion_readable { plan = None; _ } ->
    let* plan = load store in
    match plan with None -> Ok () | Some _ -> Error (unavailable ())

let rewrite_with_io io before bytes = match io with
  | None -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_result
      before.decision_path ~expected:before.decision_snapshot bytes
  | Some io -> Fs_compat.rewrite_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ~io ~before_sync_rewrite_parent:io.Fs_compat.before_sync_parent
      before.decision_path ~expected:before.decision_snapshot bytes

let rewrite store before bytes = rewrite_with_io store.deletion_source_io before bytes

let purge store before = match store.deletion_source_io with
  | None -> Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_result
      before.decision_path ~expected:before.decision_snapshot
  | Some io -> Fs_compat.purge_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
      ~io before.decision_path ~expected:before.decision_snapshot

type file_result = (Fs_compat.Private_jsonl_cursor.t, Fs_compat.private_jsonl_transaction_error) result
type io_result =
  | Direct_io of file_result
  | Deletion_readset_io of
      file_result Fs_compat.private_jsonl_guard_result Fs_compat.private_jsonl_guard_result

let retain_guard_diagnostics store diagnostics = match store.deletion_state with
  | Deletion_readable readable ->
    store.deletion_state <- Deletion_readable {
      readable with diagnostics = readable.diagnostics @ diagnostics }
  | Deletion_unobserved | Deletion_pending _ | Deletion_unsettled _
  | Deletion_refused _ | Deletion_projection_failed _ -> ()

let perform store ~before ~attempt ~bytes operation =
  let fail ~unknown failure diagnostics =
    if unknown then (
      store.deletion_state <- Deletion_unsettled { before; attempt; intended_bytes = bytes; failure; diagnostics };
      Unknown diagnostics)
    else (
      let refused () = store.deletion_state <- Deletion_refused {
        last_observed = Some before; failure; diagnostics } in
      (match attempt with
       | Recording_decision _ -> refused ()
       | Retiring_decision receipt ->
         match store.deletion_state with
         | Deletion_pending work ->
           store.deletion_state <- Deletion_pending { work with decision_receipt = receipt;
             deletion_last_failure = Some failure; deletion_diagnostics = work.deletion_diagnostics @ diagnostics }
         | Deletion_unobserved | Deletion_readable _ | Deletion_unsettled _
         | Deletion_refused _ | Deletion_projection_failed _ -> refused ());
      Not_written diagnostics) in
  let classify result guard_diagnostics =
        match Fs_compat.private_jsonl_cursor_success_receipt result with
        | Error error -> fail ~unknown:(not (Board_posts_source.definitely_not_written error))
            (Deletion_transaction_failed error) (Deletion_file_diagnostic error :: guard_diagnostics)
        | Ok success ->
          let diagnostics = receipt_diagnostics success.settlement_error @ guard_diagnostics in
          let observation = { before with decision_snapshot = { Fs_compat.bytes = bytes; cursor = success.value } } in
          match attempt with
          | Recording_decision decision ->
            let receipt = { decision; decision_after = observation; decision_cleanup = diagnostics } in
            store.deletion_state <- Deletion_pending { decision_receipt = receipt;
              deletion_progress = Decision_recorded; deletion_last_failure = None; deletion_diagnostics = [] };
            Recorded receipt
          | Retiring_decision _ ->
            store.deletion_state <- Deletion_readable { observation; plan = None; diagnostics };
            Cleared diagnostics in
  let transact () =
    if not (String.equal before.decision_path (path store)) then
      fail ~unknown:false Deletion_binding_mismatch []
    else match Board_workspace_binding.revalidate store.workspace_binding before.decision_workspace with
      | Error rejection -> fail ~unknown:false (Deletion_workspace_refused rejection) [Deletion_workspace_diagnostic rejection]
      | Ok () ->
        match operation () with
        | Direct_io result -> classify result []
        | Deletion_readset_io (Fs_compat.Guard_refused failure) ->
          let diagnostics = [Deletion_guard_diagnostic failure] in
          retain_guard_diagnostics store diagnostics;
          Not_written diagnostics
        | Deletion_readset_io (Fs_compat.Guard_executed {
            value = Fs_compat.Guard_refused failure; cleanup_failures }) ->
          let diagnostics = List.map (fun failure -> Deletion_guard_diagnostic failure)
              (failure :: cleanup_failures) in
          retain_guard_diagnostics store diagnostics;
          Not_written diagnostics
        | Deletion_readset_io (Fs_compat.Guard_executed {
            value = Fs_compat.Guard_executed { value; cleanup_failures = comments_cleanup };
            cleanup_failures = parent_cleanup }) ->
          classify value (List.map (fun failure -> Deletion_guard_diagnostic failure)
            (comments_cleanup @ parent_cleanup)) in
  try transact () with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    fail ~unknown:true (Deletion_raised { exception_; backtrace }) [Deletion_raised_diagnostic { exception_; backtrace }]

let guard_with_io io path ~expected ~f = match io with
  | None -> Fs_compat.with_private_jsonl_snapshot_guard_result path ~expected ~f
  | Some io -> Fs_compat.with_private_jsonl_snapshot_guard_with_io_for_testing ~io path ~expected ~f

let record store ~(parent : posts_source_observation) ~(comments : comments_source_observation) plan = match store.deletion_state with
  | Deletion_readable { observation; plan = None; _ } ->
    let bytes = encode plan in
    let workspace =
      try
        let* () = Board_workspace_binding.revalidate store.workspace_binding parent.workspace_observation in
        Board_workspace_binding.revalidate store.workspace_binding comments.workspace_observation
      with exception_ -> Error (Board_workspace_binding.Raised {
        exception_; backtrace = Printexc.get_raw_backtrace () }) in
    (match workspace with
     | Error rejection ->
       let diagnostics = [Deletion_workspace_diagnostic rejection] in
       retain_guard_diagnostics store diagnostics;
       Not_written diagnostics
     | Ok () ->
       if not (String.equal parent.source_path (Board_paths.persist_path store)
               && String.equal comments.source_path (Board_paths.comments_path store)) then Not_written []
       else
         let deletion_io = store.deletion_source_io in
         let parent_io = store.posts_source_io.posts in
         let comments_io = store.comments_source_io in
         perform store ~before:observation ~attempt:(Recording_decision plan) ~bytes
         (fun () ->
           (* The worker touches only immutable IO/path/snapshot values and
              filesystem state. Source publication happens back in [classify]. *)
           let record () = rewrite_with_io deletion_io observation bytes in
           let guard_comments () = guard_with_io comments_io comments.source_path
               ~expected:comments.snapshot ~f:record in
           Deletion_readset_io (guard_with_io parent_io parent.source_path
             ~expected:parent.snapshot ~f:guard_comments)))
  | Deletion_unobserved | Deletion_readable { plan = Some _; _ }
  | Deletion_pending _ | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _ -> Not_written []

let fence_recovery store = match store.deletion_state with
  | Deletion_readable { observation; plan = Some plan; _ } ->
    let bytes = observation.decision_snapshot.bytes in
    perform store ~before:observation ~attempt:(Recording_decision plan) ~bytes
      (fun () -> Direct_io (rewrite store observation bytes))
  | Deletion_unobserved | Deletion_readable { plan = None; _ }
  | Deletion_pending _ | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _ -> Not_written []

let clear store receipt = match store.deletion_state with
  | Deletion_pending work when work.deletion_progress = Sources_written && work.decision_receipt == receipt ->
    perform store ~before:receipt.decision_after ~attempt:(Retiring_decision receipt) ~bytes:""
      (fun () -> Direct_io (purge store receipt.decision_after))
  | Deletion_unobserved | Deletion_readable _ | Deletion_pending _
  | Deletion_unsettled _ | Deletion_refused _ | Deletion_projection_failed _ -> Not_written []
