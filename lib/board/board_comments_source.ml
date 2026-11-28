open Board_types

module String_map = Set_util.StringMap

type comments_index = {
  by_id : comment String_map.t;
  slices : Board_posts_rows.slice String_map.t;
  covered_bytes : int;
}

let comments_cache : comments_index Board_posts_rows.Snapshot_bytes_cache.t =
  Board_posts_rows.Snapshot_bytes_cache.create 8

let register_comments_snapshot ~bytes ~by_id ~slices ~covered_bytes =
  Board_posts_rows.Snapshot_bytes_cache.replace comments_cache bytes
    { by_id; slices; covered_bytes }

let register_comments_append ~before_bytes ~after_bytes ~offset ~length (comment : comment) =
  match Board_posts_rows.Snapshot_bytes_cache.find_opt comments_cache before_bytes with
  | None -> ()
  | Some prev ->
    let id = Comment_id.to_string comment.id in
    let prev_len =
      match String_map.find_opt id prev.slices with
      | Some (s : Board_posts_rows.slice) -> s.length
      | None -> 0
    in
    let by_id = String_map.add id comment prev.by_id in
    let canonical =
      Board_posts_rows.is_canonical_slice after_bytes ~start:offset
        ~stop:(offset + length - 1) ~has_newline:true
    in
    let slices =
      if canonical then String_map.add id { Board_posts_rows.offset; length } prev.slices
      else String_map.remove id prev.slices
    in
    let covered_bytes =
      if canonical then prev.covered_bytes - prev_len + length
      else prev.covered_bytes - prev_len
    in
    Board_posts_rows.Snapshot_bytes_cache.replace comments_cache after_bytes
      { by_id; slices; covered_bytes }

let parse_comments_index bytes =
  let by_id = ref String_map.empty in
  let slices = ref String_map.empty in
  let covered = ref 0 in
  let rejected = ref false in
  let exception Bad_row in
  (try
     Board_posts_rows.iter_lines_with_offsets bytes
       (fun ~line_number:_ ~start ~stop ~has_newline ->
          if Board_posts_rows.slice_has_content bytes ~start ~stop then
            let text = String.sub bytes start (stop - start) in
            match Yojson.Safe.from_string text with
            | json ->
              (match (Board_content_json.comment_of_yojson json).value with
               | None ->
                 rejected := true;
                 raise_notrace Bad_row
               | Some comment ->
                 let id = Comment_id.to_string comment.id in
                 by_id := String_map.add id comment !by_id;
                 let prev_len =
                   match String_map.find_opt id !slices with
                   | Some (s : Board_posts_rows.slice) -> s.length
                   | None -> 0
                 in
                 if Board_posts_rows.is_canonical_slice bytes ~start ~stop ~has_newline then begin
                   let length = stop - start + 1 in
                   slices := String_map.add id { Board_posts_rows.offset = start; length } !slices;
                   covered := !covered - prev_len + length
                 end else begin
                   slices := String_map.remove id !slices;
                   covered := !covered - prev_len
                 end)
            | exception Yojson.Json_error _ ->
              rejected := true;
              raise_notrace Bad_row)
   with Bad_row -> ());
  if !rejected then Error (Io_error "Board data is unavailable.")
  else
    let index = { by_id = !by_id; slices = !slices; covered_bytes = !covered } in
    Board_posts_rows.Snapshot_bytes_cache.replace comments_cache bytes index;
    Ok index

let get_comments_index (snapshot : Fs_compat.private_jsonl_snapshot) =
  match Board_posts_rows.Snapshot_bytes_cache.find_opt comments_cache snapshot.bytes with
  | Some index -> Ok index
  | None -> parse_comments_index snapshot.bytes

let find_in_snapshot ~comment_id snapshot =
  match get_comments_index snapshot with
  | Error _ as error -> error
  | Ok index ->
    (match String_map.find_opt comment_id index.by_id with
     | Some comment -> Ok comment
     | None -> Error (Comment_not_found comment_id))

let children_in_snapshot ~post_id snapshot =
  match get_comments_index snapshot with
  | Error _ as error -> error
  | Ok index ->
    (* [index.by_id] is keyed by comment_id in ascending string order, so
       collecting matching comments in reverse and reversing produces the exact
       same ascending Comment_id order as [Comment_set.elements]. *)
    let rev_ids =
      String_map.fold
        (fun _ (comment : comment) acc ->
           if String.equal (Post_id.to_string comment.post_id) post_id
           then comment.id :: acc
           else acc)
        index.by_id
        []
    in
    Ok (List.rev rev_ids)

type planned_comment_row =
  | Reuse_comment_slice of { key : string; comment : comment; offset : int; length : int }
  | Fresh_comment_line of { key : string; comment : comment; line : string }

let render_comments_snapshot ~base_bytes (table : (string, comment) Hashtbl.t) =
  let index_opt =
    Board_posts_rows.Snapshot_bytes_cache.find_opt comments_cache base_bytes
  in
  let unchanged_fast_path =
    match index_opt with
    | Some idx
      when idx.covered_bytes = String.length base_bytes
           && Hashtbl.length table = String_map.cardinal idx.by_id ->
      let all_match = ref true in
      Hashtbl.iter
        (fun key comment ->
           if !all_match then
             match String_map.find_opt key idx.by_id with
             | Some prev when prev == comment -> ()
             | Some _ | None -> all_match := false)
        table;
      !all_match
    | Some _ | None -> false
  in
  if unchanged_fast_path then base_bytes
  else
    let total_len, rows_rev =
      Hashtbl.fold
        (fun key (comment : comment) (total, acc) ->
           let planned =
             match index_opt with
             | Some idx ->
               (match String_map.find_opt key idx.by_id, String_map.find_opt key idx.slices with
                | Some prev, Some { Board_posts_rows.offset; length } when prev == comment ->
                  Reuse_comment_slice { key; comment; offset; length }
                | _ ->
                  let line = Yojson.Safe.to_string (Board_content_json.comment_to_yojson comment) ^ "\n" in
                  Fresh_comment_line { key; comment; line })
             | None ->
               let line = Yojson.Safe.to_string (Board_content_json.comment_to_yojson comment) ^ "\n" in
               Fresh_comment_line { key; comment; line }
           in
           let row_len =
             match planned with
             | Reuse_comment_slice { length; _ } -> length
             | Fresh_comment_line { line; _ } -> String.length line
           in
           total + row_len, planned :: acc)
        table
        (0, [])
    in
    if total_len = 0 then begin
      register_comments_snapshot ~bytes:"" ~by_id:String_map.empty ~slices:String_map.empty ~covered_bytes:0;
      ""
    end else begin
      let out = Bytes.create total_len in
      let by_id = ref String_map.empty in
      let slices = ref String_map.empty in
      let rec blit dst = function
        | [] -> ()
        | Reuse_comment_slice { key; comment; offset; length } :: rest ->
          let start = dst - length in
          Bytes.blit_string base_bytes offset out start length;
          by_id := String_map.add key comment !by_id;
          slices := String_map.add key { Board_posts_rows.offset = start; length } !slices;
          blit start rest
        | Fresh_comment_line { key; comment; line } :: rest ->
          let length = String.length line in
          let start = dst - length in
          Bytes.blit_string line 0 out start length;
          by_id := String_map.add key comment !by_id;
          slices := String_map.add key { Board_posts_rows.offset = start; length } !slices;
          blit start rest
      in
      blit total_len rows_rev;
      let bytes = Bytes.unsafe_to_string out in
      register_comments_snapshot ~bytes ~by_id:!by_id ~slices:!slices ~covered_bytes:total_len;
      bytes
    end

type read =
  | Complete of { observation : comments_source_observation; comments : comment list;
                  diagnostics : comments_source_diagnostic list }
  | Partial of { observation : comments_source_observation; comments : comment list;
                 errors : comments_row_error list; diagnostics : comments_source_diagnostic list }
  | Unavailable of { failure : comments_source_failure;
                     diagnostics : comments_source_diagnostic list }
  | Display_only of { comments : comment list; failure : comments_source_failure;
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
  | Comments_guard_diagnostic failure -> Board_posts_source.reserved_transaction failure.guard_error
  | Comments_workspace_diagnostic rejection ->
    Option.bind (Board_workspace_binding.raised rejection) Board_posts_source.reserved_exception
  | Comments_display_diagnostic error ->
    (match error with
     | Fs_compat.Private_jsonl_unique_fold.Non_regular_file _ | Snapshot_changed -> None
     | Binding_refused error -> Board_posts_source.reserved_transaction error
     | Operation_failed failure -> Board_posts_source.reserved_exception (failure.exception_, failure.backtrace))
  | Comments_display_cleanup_diagnostic failure ->
    Board_posts_source.reserved_exception (failure.exception_, failure.backtrace)
  | Comments_raised_diagnostic { exception_; backtrace; _ } ->
    Board_posts_source.reserved_exception (exception_, backtrace))

let stage_name = function
  | Read_comments -> "read comments" | Decode_comments -> "decode comments"
  | Encode_comments -> "encode comments" | Write_comments -> "write comments"
  | Project_comments -> "project comments" | Report_comments -> "report comments"

let diagnostic_to_string = function
  | Comments_file_diagnostic error -> Fs_compat.private_jsonl_transaction_error_to_string error
  | Comments_guard_diagnostic failure -> failure.guard_path ^ ": " ^
    Fs_compat.private_jsonl_transaction_error_to_string failure.guard_error
  | Comments_workspace_diagnostic rejection -> Board_workspace_binding.rejection_to_string rejection
  | Comments_display_diagnostic error -> Fs_compat.Private_jsonl_unique_fold.error_to_string error
  | Comments_display_cleanup_diagnostic failure -> Fs_compat.private_jsonl_operation_failure_to_string failure
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
  | Comments_unobserved -> No_comments_observation
  | Comments_readable receipt | Comments_publishing receipt -> Comments_observed receipt.observation
  | Comments_recovered receipt -> Comments_observed receipt.fence
  | Comments_refused { last_observed; _ } -> last_observed
  | Comments_unsettled { pending; _ } -> Comments_observed pending.expected

let refuse store failure diagnostics = match store.comments_source with
  | Comments_unsettled _ | Comments_publishing _ | Comments_recovered _ -> ()
  | Comments_unobserved | Comments_readable _ | Comments_refused _ ->
    store.comments_source <- Comments_refused {
      last_observed = history store.comments_source; failure; diagnostics }

let refuse_present store failure diagnostics =
  let last_observed = match history store.comments_source with
    | No_comments_observation | Comments_present_without_snapshot -> Comments_present_without_snapshot
    | Comments_observed observation as previous ->
      if Fs_compat.Private_jsonl_cursor.is_missing observation.snapshot.cursor
      then Comments_present_without_snapshot else previous in
  match store.comments_source with
  | Comments_unsettled _ | Comments_publishing _ | Comments_recovered _ -> ()
  | Comments_unobserved | Comments_readable _ | Comments_refused _ ->
    store.comments_source <- Comments_refused { last_observed; failure; diagnostics }

let expected store = match store.comments_source with
  | Comments_readable { observation; _ } ->
    if String.equal observation.source_path (Board_paths.comments_path store)
    then Ok observation else Error Comments_source_binding_mismatch
  | Comments_unobserved -> Error Comments_not_observed
  | Comments_publishing _ -> Error Comments_publication_pending
  | Comments_recovered _ -> Error Comments_reload_required
  | Comments_refused { failure; _ } | Comments_unsettled { failure; _ } -> Error failure

let require_readable store = expected store |> Result.map (fun _ -> ())
  |> Result.map_error failure_to_board_error

let read_diagnostics = function
  | Complete { diagnostics; _ } | Partial { diagnostics; _ }
  | Unavailable { diagnostics; _ } | Display_only { diagnostics; _ } -> diagnostics

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
    | Unavailable { failure; _ } | Display_only { failure; _ } -> Error (failure_to_board_error failure) in
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
  | No_comments_observation -> true
  | Comments_present_without_snapshot -> false
  | Comments_observed observation -> Fs_compat.Private_jsonl_cursor.is_missing observation.snapshot.cursor

let receipt_diagnostics error = match error with
  | None -> [] | Some error -> [Comments_file_diagnostic error]

(* The fold callback is pure and runs in the Fs worker. This second read is
   display-only: it does not fabricate a stable snapshot from prefix bytes. *)
let read_display_prefix store path =
  let decode (comments, diagnostics) text =
    if not (Board_posts_rows.slice_has_content text ~start:0 ~stop:(String.length text))
    then comments, diagnostics
    else match Yojson.Safe.from_string text with
      | json ->
        let decoded = Board_content_json.comment_of_yojson json in
        let comments = match decoded.value with None -> comments | Some comment -> comment :: comments in
        comments, List.rev_append decoded.diagnostics diagnostics
      | exception Yojson.Json_error _ -> comments, diagnostics in
  let result = match store.comments_source_io with
    | None -> Fs_compat.fold_private_jsonl_unique_regular_locked_result path ~init:([], []) ~f:decode
    | Some io -> Fs_compat.fold_private_jsonl_unique_regular_locked_with_io_for_testing
        ~io path ~init:([], []) ~f:decode in
  let value, diagnostics = match result with
    | Fs_compat.Private_file_succeeded value -> Some value, []
    | Private_file_succeeded_with_cleanup_failure { value; cleanup_failure } ->
      Some value, [Comments_display_cleanup_diagnostic cleanup_failure]
    | Private_file_failed error -> None, [Comments_display_diagnostic error]
    | Private_file_failed_with_cleanup_failure { error; cleanup_failure } ->
      None, [Comments_display_diagnostic error; Comments_display_cleanup_diagnostic cleanup_failure] in
  let rows = match value with
    | None | Some Fs_compat.Private_jsonl_fold.Missing -> None
    | Some (Present { value; _ }) -> Some value in
  rows, diagnostics

let read store = match store.comments_source with
  | Comments_unsettled { failure; _ } -> Unavailable { failure; diagnostics = [] }
  | Comments_publishing _ -> Unavailable { failure = Comments_publication_pending; diagnostics = [] }
  | Comments_recovered _ -> Unavailable { failure = Comments_reload_required; diagnostics = [] }
  | Comments_unobserved | Comments_readable _ | Comments_refused _ ->
    let diagnostics = ref [] and stage = ref Read_comments and saw_present = ref false in
    let unavailable failure =
      (if !saw_present then refuse_present else refuse) store failure !diagnostics;
      Unavailable { failure; diagnostics = !diagnostics } in
    try
      match observe_workspace store with
      | Error rejection -> diagnostics := [Comments_workspace_diagnostic rejection];
        unavailable (Comments_workspace_refused rejection)
      | Ok before ->
        let path = Board_paths.comments_path store in
        match Fs_compat.private_jsonl_snapshot_success_receipt (read_file store path) with
        | Error error ->
          diagnostics := [Comments_file_diagnostic error];
          let failure = Comments_transaction_failed error in
          if not (Fs_compat.private_jsonl_transaction_error_is_incomplete_tail error)
          then unavailable failure
          else (
            saw_present := true;
            refuse_present store failure !diagnostics;
            match reserved_diagnostics !diagnostics with
            | Some _ -> unavailable failure
            | None ->
              let rows, display_diagnostics = read_display_prefix store path in
              diagnostics := !diagnostics @ display_diagnostics;
              match reserved_diagnostics !diagnostics, rows with
              | Some _, _ | None, None -> unavailable failure
              | None, Some (comments, content_diagnostics) ->
                match finish_workspace store before with
                | Error rejection ->
                  diagnostics := !diagnostics @ [Comments_workspace_diagnostic rejection];
                  unavailable (Comments_workspace_refused rejection)
                | Ok _ ->
                  stage := Decode_comments;
                  Board_content_diagnostics.emit (List.rev content_diagnostics);
                  refuse_present store failure !diagnostics;
                  Display_only { comments = List.rev comments; failure; diagnostics = !diagnostics })
        | Ok receipt ->
          diagnostics := receipt_diagnostics receipt.settlement_error;
          saw_present := not (Fs_compat.Private_jsonl_cursor.is_missing receipt.value.cursor);
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
                let raw_bytes = receipt.value.bytes in
                let comments = ref []
                and errors = ref []
                and by_id = ref String_map.empty
                and slices = ref String_map.empty
                and covered = ref 0 in
                Board_posts_rows.iter_lines_with_offsets raw_bytes
                  (fun ~line_number ~start ~stop ~has_newline ->
                    if Board_posts_rows.slice_has_content raw_bytes ~start ~stop then
                      let text = String.sub raw_bytes start (stop - start) in
                      match Yojson.Safe.from_string text with
                      | json ->
                        let decoded = Board_content_json.comment_of_yojson json in
                        Board_content_diagnostics.emit decoded.diagnostics;
                        (match decoded.value with
                         | Some comment ->
                           comments := comment :: !comments;
                           let id = Comment_id.to_string comment.id in
                           by_id := String_map.add id comment !by_id;
                           let prev_len =
                             match String_map.find_opt id !slices with
                             | Some (s : Board_posts_rows.slice) -> s.length
                             | None -> 0
                           in
                           if Board_posts_rows.is_canonical_slice raw_bytes ~start ~stop ~has_newline then begin
                             let length = stop - start + 1 in
                             slices := String_map.add id { Board_posts_rows.offset = start; length } !slices;
                             covered := !covered - prev_len + length
                           end else begin
                             slices := String_map.remove id !slices;
                             covered := !covered - prev_len
                           end
                         | None -> errors := Invalid_comments_row { line = line_number } :: !errors)
                      | exception Yojson.Json_error detail ->
                        errors := Invalid_comments_json { line = line_number; detail } :: !errors);
                let observation : comments_source_observation =
                  { source_path = path; snapshot = receipt.value; workspace_observation } in
                match List.rev !errors with
                | [] ->
                  register_comments_snapshot ~bytes:raw_bytes ~by_id:!by_id
                    ~slices:!slices ~covered_bytes:!covered;
                  Complete { observation; comments = List.rev !comments; diagnostics = !diagnostics }
                | errors -> Partial { observation; comments = List.rev !comments; errors; diagnostics = !diagnostics })
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Comments_raised_diagnostic { stage = !stage; exception_; backtrace }];
      unavailable (Comments_raised { exception_; backtrace })

let publish_read store outcome = match store.comments_source with
  | Comments_unsettled _ | Comments_publishing _ | Comments_recovered _ -> ()
  | Comments_unobserved | Comments_readable _ | Comments_refused _ ->
    match outcome with
    | Complete { observation; diagnostics; _ } ->
      store.comments_source <- Comments_readable { observation; diagnostics }
    | Partial { observation; errors; diagnostics; _ } ->
      store.comments_source <- Comments_refused { last_observed = Comments_observed observation;
        failure = Comments_rows_rejected errors; diagnostics }
    | Display_only { failure; diagnostics; _ } -> refuse_present store failure diagnostics
    | Unavailable { failure; diagnostics } -> refuse store failure diagnostics

let fail_read store outcome ~stage exception_ backtrace =
  let diagnostics = read_diagnostics outcome @ [Comments_raised_diagnostic { stage; exception_; backtrace }] in
  let failure = match outcome with
    | Unavailable { failure; _ } | Display_only { failure; _ } -> failure
    | Complete _ | Partial _ -> Comments_raised { exception_; backtrace } in
  (match outcome, store.comments_source with
   | (Complete { observation; _ } | Partial { observation; _ }),
     (Comments_unobserved | Comments_readable _ | Comments_refused _) ->
     store.comments_source <- Comments_refused { last_observed = Comments_observed observation;
       failure; diagnostics }
   | (Complete _ | Partial _), (Comments_unsettled _ | Comments_publishing _ | Comments_recovered _)
   | (Unavailable _ | Display_only _),
     (Comments_unobserved | Comments_readable _ | Comments_refused _
      | Comments_unsettled _ | Comments_publishing _ | Comments_recovered _) ->
     refuse store failure diagnostics);
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

(* #55449: a refusal that only proves this store's observation stale (another
   writer moved the file) is cleared by one fresh read, as the posts source
   is (task-4036). A refusal for any other reason is not: the same file would
   refuse again. *)
let stale_observation = function
  | Comments_transaction_failed error -> contradicts_observation error
  | Comments_not_observed | Comments_rows_rejected _ | Comments_missing
  | Comments_source_binding_mismatch | Comments_snapshot_stale | Comments_publication_pending
  | Comments_reload_required | Comments_workspace_refused _ | Comments_raised _ -> false

let reobservation_due store = match store.comments_source with
  | Comments_refused { failure; _ } -> stale_observation failure
  | Comments_unobserved | Comments_readable _ | Comments_publishing _ | Comments_recovered _
  | Comments_unsettled _ -> false

let observe_guard_refusal store observation failure =
  match store.comments_source with
  | Comments_readable current when current.observation == observation
      && String.equal failure.Fs_compat.guard_path observation.source_path
      && contradicts_observation failure.guard_error ->
    refuse store (Comments_transaction_failed failure.guard_error) [Comments_guard_diagnostic failure]
  | Comments_readable _ | Comments_unobserved | Comments_publishing _
  | Comments_refused _ | Comments_unsettled _ | Comments_recovered _ -> ()

let not_written failure diagnostics = Not_written { failure; diagnostics }

type file_result = (Fs_compat.Private_jsonl_cursor.t, Fs_compat.private_jsonl_transaction_error) result
type write_io =
  | Direct_io of file_result
  | Parent_io of posts_source_observation * file_result Fs_compat.private_jsonl_guard_result
  | Parent_policy_io of posts_source_observation * sub_boards_source_observation *
      file_result Fs_compat.private_jsonl_guard_result Fs_compat.private_jsonl_guard_result

let write store ~(before : comments_source_observation) ~kind ~bytes perform =
  let pending = { expected = before; kind; intended_bytes = bytes } in
  let unknown failure diagnostics =
    store.comments_source <- Comments_unsettled { pending; failure; diagnostics };
    Unknown { failure; diagnostics } in
  let classify result guard_diagnostics =
    match Fs_compat.private_jsonl_cursor_success_receipt result with
    | Ok receipt ->
      let diagnostics = receipt_diagnostics receipt.settlement_error @ guard_diagnostics in
      let observation : comments_source_observation = { before with
        snapshot = { Fs_compat.bytes = bytes; cursor = receipt.value } } in
      let publication = { observation; diagnostics } in
      store.comments_source <- (match kind with
        | Comments_append -> Comments_publishing publication
        | Comments_rewrite -> Comments_readable publication);
      Written { value = publication; diagnostics }
    | Error error ->
      let diagnostics = Comments_file_diagnostic error :: guard_diagnostics in
      let failure = Comments_transaction_failed error in
      if Board_posts_source.definitely_not_written error then (
        if contradicts_observation error then refuse store failure diagnostics;
        not_written failure diagnostics)
      else unknown failure diagnostics in
  let guard_refused failure cleanup =
    let diagnostics = List.map (fun failure -> Comments_guard_diagnostic failure)
        (failure :: cleanup) in
    (* No append ran. Keep the comments expectation, and retain guard cleanup
       evidence before finishing can propagate a reserved cause. *)
    (match store.comments_source with
     | Comments_readable receipt -> store.comments_source <- Comments_readable {
         receipt with diagnostics = receipt.diagnostics @ diagnostics }
     | Comments_unobserved | Comments_publishing _ | Comments_recovered _
     | Comments_refused _ | Comments_unsettled _ -> ());
    not_written (Comments_transaction_failed failure.guard_error) diagnostics in
  let cleanup failures = List.map (fun failure -> Comments_guard_diagnostic failure) failures in
  try match perform () with
    | Direct_io result -> classify result []
    | Parent_io (parent, Fs_compat.Guard_refused failure)
    | Parent_policy_io (parent, _, Fs_compat.Guard_refused failure) ->
      Board_posts_source.observe_guard_refusal store parent failure;
      guard_refused failure []
    | Parent_io (_, Fs_compat.Guard_executed { value; cleanup_failures }) ->
      classify value (cleanup cleanup_failures)
    | Parent_policy_io (_, policy, Fs_compat.Guard_executed {
        value = Fs_compat.Guard_refused failure; cleanup_failures }) ->
      Board_sub_boards_source.observe_guard_refusal store policy failure;
      guard_refused failure cleanup_failures
    | Parent_policy_io (_, _, Fs_compat.Guard_executed {
        value = Fs_compat.Guard_executed { value; cleanup_failures = policy_cleanup };
        cleanup_failures = parent_cleanup }) ->
      classify value (cleanup (policy_cleanup @ parent_cleanup))
  with exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    let diagnostics = [Comments_raised_diagnostic { stage = Write_comments; exception_; backtrace }] in
    unknown (Comments_raised { exception_; backtrace }) diagnostics

let workspace_failure store rejection =
  let failure = Comments_workspace_refused rejection in
  let diagnostics = [Comments_workspace_diagnostic rejection] in
  refuse store failure diagnostics;
  not_written failure diagnostics

let guard_with_io io path ~expected ~f = match io with
  | None -> Fs_compat.with_private_jsonl_snapshot_guard_result path ~expected ~f
  | Some io -> Fs_compat.with_private_jsonl_snapshot_guard_with_io_for_testing ~io path ~expected ~f

let append store ~(admission : Board_comment_admission.t) (comment : comment) = match expected store with
  | Error failure -> not_written failure []
  | Ok before ->
    match revalidate store before with
    | Error rejection -> workspace_failure store rejection
    | Ok () ->
      let workspace = try
        let open Result.Syntax in
        let* () = Board_workspace_binding.revalidate store.workspace_binding
            admission.parent.workspace_observation in
        match admission.policy with
        | None -> Ok ()
        | Some policy -> Board_workspace_binding.revalidate store.workspace_binding policy.policy_workspace
        with exception_ -> Error (Board_workspace_binding.Raised {
          exception_; backtrace = Printexc.get_raw_backtrace () }) in
      match workspace with
      | Error rejection -> workspace_failure store rejection
      | Ok () ->
      let encoded = try Ok (Yojson.Safe.to_string (Board_content_json.comment_to_yojson comment) ^ "\n")
        with exception_ -> Error (exception_, Printexc.get_raw_backtrace ()) in
      match encoded with
      | Error (exception_, backtrace) ->
        not_written (Comments_raised { exception_; backtrace })
          [Comments_raised_diagnostic { stage = Encode_comments; exception_; backtrace }]
      | Ok suffix ->
        let comments_io = store.comments_source_io in
        let parent_io = store.posts_source_io.posts in
        let policy_io = store.sub_boards_source_io in
        let before_bytes = before.snapshot.bytes in
        let after_bytes = before_bytes ^ suffix in
        let outcome =
          write store ~before ~kind:Comments_append ~bytes:after_bytes
            (fun () ->
              (* Nested callbacks execute in the filesystem worker. Capture every
                 IO/source value above; publish source/model state only on return. *)
              let append () = match comments_io with
                | None -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_result
                    before.source_path ~expected:before.snapshot suffix
                | Some io -> Fs_compat.append_private_jsonl_durable_locked_at_snapshot_with_io_for_testing
                    ~io before.source_path ~expected:before.snapshot suffix in
              match admission.policy with
              | None -> Parent_io (admission.parent, guard_with_io parent_io admission.parent.source_path
                  ~expected:admission.parent.snapshot ~f:append)
              | Some policy -> Parent_policy_io (admission.parent, policy, guard_with_io parent_io admission.parent.source_path
                  ~expected:admission.parent.snapshot ~f:(fun () ->
                    guard_with_io policy_io policy.policy_path ~expected:policy.policy_snapshot ~f:append)))
        in
        (match outcome with
         | Written _ ->
           register_comments_append ~before_bytes ~after_bytes
             ~offset:(String.length before_bytes) ~length:(String.length suffix) comment
         | Not_written _ | Unknown _ -> ());
        outcome

let publish_append store receipt = match store.comments_source with
  | Comments_publishing current when current == receipt ->
    store.comments_source <- Comments_readable receipt;
    Written { value = (); diagnostics = receipt.diagnostics }
  | Comments_publishing _ | Comments_unobserved | Comments_readable _
  | Comments_refused _ | Comments_unsettled _ | Comments_recovered _ -> not_written Comments_snapshot_stale []

let capture store =
  let expected = expected store in
  let bytes = match expected with
    | Error _ -> ""
    | Ok observation ->
      render_comments_snapshot ~base_bytes:observation.snapshot.bytes store.comments in
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
            (fun () -> Direct_io (rewrite_file store before.source_path ~expected:before.snapshot snapshot.bytes)) in
  match result with
  | Written { diagnostics; _ } -> Written { value = (); diagnostics }
  | Not_written { failure; diagnostics } -> Not_written { failure; diagnostics }
  | Unknown { failure; diagnostics } -> Unknown { failure; diagnostics }

let settle store = match store.comments_source with
  | Comments_publishing _ -> not_written Comments_publication_pending []
  | Comments_recovered receipt -> Written { value = Some receipt; diagnostics = [] }
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
                    let receipt = { interrupted = pending; prior_failure; fence; diagnostics = !diagnostics } in
                    store.comments_source <- Comments_recovered receipt;
                    Written { value = Some receipt;
                      diagnostics = !diagnostics })
    with exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      diagnostics := !diagnostics @ [Comments_raised_diagnostic { stage = Write_comments; exception_; backtrace }];
      inconclusive (Comments_raised { exception_; backtrace })

let acknowledge_recovery store receipt = match store.comments_source with
  | Comments_recovered current when current == receipt ->
    store.comments_source <- Comments_refused { last_observed = Comments_observed receipt.fence;
      failure = Comments_reload_required; diagnostics = receipt.diagnostics };
    Ok ()
  | Comments_unobserved | Comments_readable _ | Comments_refused _
  | Comments_unsettled _ | Comments_publishing _ | Comments_recovered _ ->
    Error (failure_to_board_error Comments_snapshot_stale)
