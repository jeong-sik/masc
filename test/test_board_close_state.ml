(** Typed close state for Board posts (task-1758/#39356).

    A post minted before this field existed, and every open post since,
    carries no ["closed"] key on disk: [Board_votes_json.optional_closed]
    reads that absence as [None] (open). [Board_votes.set_closed] and
    [reopen] write the JSONL row the same durable way as [set_pinned]
    (append, then commit in memory), so a restart between the write and
    the next read sees exactly what was persisted -- these tests restart
    the store after each mutation rather than trusting the in-memory
    copy. *)

open Masc

let () = Mirage_crypto_rng_unix.use_default ()
let () = Random.self_init ()

let fresh_test_base_path () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-close-%06x" (Random.bits ()))
  in
  Fs_compat.mkdir_p dir;
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

let with_eio f () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ());
  f ()

let create_post_exn ~author ~content =
  match
    Board_dispatch.create_post ~author ~content ~post_kind:Board.Human_post ()
  with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.Post_publication_failure.to_string e)

let store () = Board_dispatch.backend ()

let restart () =
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Result.get_ok (Board_dispatch.init_jsonl
    ~base_path:(Env_config_core.base_path ())
    ~recipient_lookup:Recipient_lookup.none_declared ())

let get_post_exn post_id =
  match Board_dispatch.get_post ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
  | Ok post -> post
  | Error e -> Alcotest.fail (Board.show_board_error e)

(* Close, restart (forcing a disk read, not the in-memory copy), and check
   every field of the recorded [closed] state round-trips: who closed it,
   the successor it names, and the summary. Also pins the pre-close state
   (no ["closed"] key at all) as the same shape a post minted before this
   field existed would have on disk. *)
let test_close_persists_successor_and_summary_across_restart () =
  let post =
    create_post_exn ~author:"close-author" ~content:"thread to close"
  in
  let post_id = Board.Post_id.to_string post.id in
  let successor =
    create_post_exn ~author:"close-author" ~content:"continues here"
  in
  let successor_id = Board.Post_id.to_string successor.id in
  restart ();
  let pre = get_post_exn post_id in
  Alcotest.(check bool) "open before any close call" true
    (Option.is_none pre.closed);
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"close-author"
       ~successor:(Board.Successor successor_id)
       ~summary:"moved to the successor" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  let closed = get_post_exn post_id in
  match closed.closed with
  | None -> Alcotest.fail "expected closed state to survive a restart"
  | Some c ->
    Alcotest.(check string) "closed_by round-trips"
      "close-author" (Board.Agent_id.to_string c.closed_by);
    Alcotest.(check bool) "successor_id round-trips" true
      (match c.successor_id with
       | Some id -> String.equal (Board.Post_id.to_string id) successor_id
       | None -> false);
    Alcotest.(check (option string)) "summary round-trips"
      (Some "moved to the successor") c.summary;
    Alcotest.(check bool) "closed_at is a real timestamp" true
      (Float.is_finite c.closed_at && c.closed_at > 0.0)

(* Reopen clears [closed] back to [None] and that clearing is itself
   durable -- a restart after reopen must not resurrect the old close. *)
let test_reopen_clears_closed_state_across_restart () =
  let post =
    create_post_exn ~author:"reopen-author" ~content:"thread to reopen"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"reopen-author"
       ~successor:Board.No_successor ~summary:"closing to reopen" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  Alcotest.(check bool) "closed after set_closed" true
    (Option.is_some (get_post_exn post_id).closed);
  (match Board_votes.reopen (store ()) ~post_id with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  Alcotest.(check bool) "open again after reopen + restart" true
    (Option.is_none (get_post_exn post_id).closed);
  (* True no-op (context-reviewer, review 5329575031): reopening an
     already-open post must not bump [updated_at] or append a new row,
     or a change-cursor / Updated-sort listing would read it as fresh
     activity when nothing changed. *)
  let before = get_post_exn post_id in
  let rows_before =
    List.length
      (List.filter
         (fun row ->
           match Yojson.Safe.Util.member "id" row with
           | `String id -> String.equal id post_id
           | _ -> false)
         (Fs_compat.load_jsonl (Board.persist_path (Board.global ()))))
  in
  (match Board_votes.reopen (store ()) ~post_id with
   | Ok () -> ()
   | Error e ->
     Alcotest.fail ("reopen on an open post must be Ok (), got " ^
                     Board.show_board_error e));
  let after = get_post_exn post_id in
  Alcotest.(check (float 0.0)) "no-op reopen leaves updated_at untouched"
    before.updated_at after.updated_at;
  let rows_after =
    List.length
      (List.filter
         (fun row ->
           match Yojson.Safe.Util.member "id" row with
           | `String id -> String.equal id post_id
           | _ -> false)
         (Fs_compat.load_jsonl (Board.persist_path (Board.global ()))))
  in
  Alcotest.(check int) "no-op reopen appends no new posts.jsonl row"
    rows_before rows_after

(* Re-closing an already-closed post overwrites the previous close (last
   write wins), it does not error and does not merge the two summaries. *)
let test_reclosing_overwrites_the_previous_close () =
  let post =
    create_post_exn ~author:"reclose-author" ~content:"closed twice"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"first-closer"
       ~successor:Board.No_successor ~summary:"first reason" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"second-closer"
       ~successor:Board.No_successor ~summary:"second reason" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  match (get_post_exn post_id).closed with
  | None -> Alcotest.fail "expected the post to remain closed"
  | Some c ->
    Alcotest.(check string) "second close_by wins"
      "second-closer" (Board.Agent_id.to_string c.closed_by);
    Alcotest.(check (option string)) "second summary wins"
      (Some "second reason") c.summary

(* set_closed and reopen on a post_id that does not exist report
   Post_not_found rather than silently doing nothing. *)
let test_close_and_reopen_report_post_not_found () =
  (match Board_votes.set_closed (store ()) ~post_id:"p-doesnotexist"
           ~closed_by:"someone" ~successor:Board.No_successor
           ~summary:"no such post" () with
   | Error (Board.Post_not_found _) -> ()
   | Ok () -> Alcotest.fail "set_closed on a missing post must not be Ok ()"
   | Error e ->
     Alcotest.fail ("expected Post_not_found, got " ^ Board.show_board_error e));
  match Board_votes.reopen (store ()) ~post_id:"p-doesnotexist" with
  | Error (Board.Post_not_found _) -> ()
  | Ok () -> Alcotest.fail "reopen on a missing post must not be Ok ()"
  | Error e ->
    Alcotest.fail ("expected Post_not_found, got " ^ Board.show_board_error e)

(* A closed thread does not grow (task-1758/#39356): a new comment on a
   closed post is refused, at the durable-write boundary, not just as an
   input-validation nicety. Checked both before the append (fast path) and
   the identical outcome must hold whether the post was closed long ago or
   moments before the call. *)
let test_closed_post_refuses_new_comments () =
  let post =
    create_post_exn ~author:"closed-thread-author" ~content:"no more replies"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"closed-thread-author"
       ~successor:Board.No_successor ~summary:"closing this thread" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  (match
     Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"latecomer"
       ~content:"can I still reply?" ()
   with
   | Error (Board.Validation_error msg) ->
     Alcotest.(check bool) "error names the post as closed" true
       (Astring.String.is_infix ~affix:"closed" msg)
   | Ok _ -> Alcotest.fail "a comment on a closed post must not succeed"
   | Error e ->
     Alcotest.fail ("expected Validation_error, got " ^ Board.show_board_error e));
  (match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Ok [] -> ()
   | Ok comments ->
     Alcotest.failf "refused comment left %d row(s) behind"
       (List.length comments)
   | Error e -> Alcotest.fail (Board.show_board_error e));
  Alcotest.(check int) "reply_count unchanged by the refused comment" 0
    (get_post_exn post_id).reply_count;
  (* Reopening lifts the refusal. *)
  (match Board_votes.reopen (store ()) ~post_id with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  match
    Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"latecomer"
      ~content:"now I can reply" ()
  with
  | Ok _ -> ()
  | Error e ->
    Alcotest.fail ("comment after reopen must succeed, got " ^
                    Board.show_board_error e)

(* task-1758/#39356 completion criterion 2 (context-reviewer FAIL 5329688359):
   a comment refused on a closed post must name the successor when one was
   recorded at close time, in both the staging-phase and commit-phase
   rejection branches, not just say "closed" with no way forward. *)
let test_closed_post_rejection_names_the_successor () =
  let post =
    create_post_exn ~author:"closed-thread-author" ~content:"no more replies"
  in
  let post_id = Board.Post_id.to_string post.id in
  let successor =
    create_post_exn ~author:"closed-thread-author" ~content:"continues here"
  in
  let successor_id = Board.Post_id.to_string successor.id in
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"closed-thread-author"
       ~successor:(Board.Successor successor_id)
       ~summary:"moved to the successor" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  match
    Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"latecomer"
      ~content:"can I still reply?" ()
  with
  | Error (Board.Validation_error msg) ->
    Alcotest.(check bool) "rejection message names the successor id" true
      (Astring.String.is_infix ~affix:successor_id msg)
  | Ok _ -> Alcotest.fail "a comment on a closed post must not succeed"
  | Error e ->
    Alcotest.fail ("expected Validation_error, got " ^ Board.show_board_error e)

(* A [successor_id] that does not resolve to any post in the live store is
   refused before anything is written: a dangling successor pointer would
   otherwise sit in posts.jsonl forever with no way for a reader to notice
   it goes nowhere. *)
let test_close_rejects_nonexistent_successor () =
  let post =
    create_post_exn ~author:"close-author" ~content:"thread to close"
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_votes.set_closed (store ()) ~post_id ~closed_by:"close-author"
       ~successor:(Board.Successor "p-0000000000000000000000000000dead")
       ~summary:"dangling successor" ()
   with
   | Ok () -> Alcotest.fail "expected Validation_error for a nonexistent successor"
   | Error (Board.Validation_error _) -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  restart ();
  Alcotest.(check bool) "post stayed open after the rejected close" true
    (Option.is_none (get_post_exn post_id).closed)

(* A post cannot name itself as its own successor -- that would make the
   "read the successor instead" pointer a cycle of one. *)
let test_close_rejects_self_as_successor () =
  let post =
    create_post_exn ~author:"close-author" ~content:"thread to close"
  in
  let post_id = Board.Post_id.to_string post.id in
  match
    Board_votes.set_closed (store ()) ~post_id ~closed_by:"close-author"
      ~successor:(Board.Successor post_id) ~summary:"self successor" ()
  with
  | Ok () -> Alcotest.fail "expected Validation_error for a self-referential successor"
  | Error (Board.Validation_error _) -> ()
  | Error e -> Alcotest.fail (Board.show_board_error e)

(* task-1758/#39356 scope extension (Board p-89d779f1 c-0542e7f5): a post
   that reaches [Limits.comment_count_cap] comments stops growing. The
   cap-th comment still lands -- the boundary is inclusive of the cap, not
   exclusive -- and the very next one is refused at the write boundary
   with a message naming the cap and pointing at opening a successor
   post, the same shape the closed-post refusal uses but for size instead
   of an explicit close. *)
let fill_to_the_cap ~post_id =
  let rec fill n =
    if n = 0
    then ()
    else (
      match
        Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"cap-filler"
          ~content:(Printf.sprintf "filler %d" n) ()
      with
      | Ok _ -> fill (n - 1)
      | Error e ->
        Alcotest.failf "filler comment %d must succeed: %s" n
          (Board.show_board_error e))
  in
  fill Board.Limits.comment_count_cap

let test_comment_past_the_cap_is_refused_with_successor_hint () =
  let post =
    create_post_exn ~author:"cap-thread-author" ~content:"fill me to the cap"
  in
  let post_id = Board.Post_id.to_string post.id in
  let cap = Board.Limits.comment_count_cap in
  fill_to_the_cap ~post_id;
  (match
     Board_dispatch.add_comment ~reader:Masc_board_handlers.Board_access.Operator ~post_id ~author:"latecomer"
       ~content:"one past the cap" ()
   with
   | Error (Board.Validation_error msg) ->
     Alcotest.(check bool) "refusal names the cap value" true
       (Astring.String.is_infix ~affix:(string_of_int cap) msg);
     Alcotest.(check bool) "refusal points at a successor post" true
       (Astring.String.is_infix ~affix:"successor" msg)
   | Ok _ -> Alcotest.fail "a comment past the cap must not succeed"
   | Error e ->
     Alcotest.fail ("expected Validation_error, got " ^
                     Board.show_board_error e));
  (match Board_dispatch.get_comments ~reader:Masc_board_handlers.Board_access.Operator ~post_id with
   | Ok comments ->
     Alcotest.(check int) "no row landed past the cap" cap
       (List.length comments)
   | Error e -> Alcotest.fail (Board.show_board_error e));
  Alcotest.(check int) "reply_count frozen at the cap" cap
    (get_post_exn post_id).reply_count

(* The same refusals through [masc_board_comment]. A full thread, a closed
   thread and a body that names an unsupported broadcast selector refuse the
   call the same way each time it is repeated, and the message names the way
   on (the successor post, other text). They are workflow rejections. They
   were reported as runtime failures, which told the model to report a fault
   instead of correcting the call. *)
let test_tool_answers_a_refused_comment_as_a_workflow_rejection () =
  let comment ~post_id content =
    Board_tool.handle_tool ~reader:Masc_board_handlers.Board_access.Operator
      ~result_boundary:Tool_output.Sent_to_client "masc_board_comment"
      (`Assoc
        [ "post_id", `String post_id
        ; "author", `String "latecomer"
        ; "content", `String content
        ])
  in
  let require_workflow_rejection ~label ~affix result =
    match result with
    | Tool_result.Failed
        { Tool_result.class_ = Tool_result.Workflow_rejection; message; _ } ->
      Alcotest.(check bool) (label ^ " names the way on") true
        (Astring.String.is_infix ~affix message)
    | Tool_result.Failed { Tool_result.class_; _ } ->
      Alcotest.failf "%s: expected workflow_rejection, got %s" label
        (Tool_result.tool_failure_class_to_string class_)
    | Tool_result.Completed _ | Tool_result.Deferred _ ->
      Alcotest.failf "%s must be refused" label
  in
  let full =
    create_post_exn ~author:"cap-tool-author" ~content:"fill me to the cap"
  in
  let full_id = Board.Post_id.to_string full.id in
  fill_to_the_cap ~post_id:full_id;
  require_workflow_rejection ~label:"a comment past the cap" ~affix:"successor"
    (comment ~post_id:full_id "one past the cap");
  let closed =
    create_post_exn ~author:"closed-tool-author" ~content:"no more replies"
  in
  let closed_id = Board.Post_id.to_string closed.id in
  let successor =
    create_post_exn ~author:"closed-tool-author" ~content:"continues here"
  in
  let successor_id = Board.Post_id.to_string successor.id in
  (match
     Board_votes.set_closed (store ()) ~post_id:closed_id
       ~closed_by:"closed-tool-author"
       ~successor:(Board.Successor successor_id)
       ~summary:"moved to the successor" ()
   with
   | Ok () -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  require_workflow_rejection ~label:"a comment on a closed post"
    ~affix:successor_id (comment ~post_id:closed_id "can I still reply?");
  let open_post =
    create_post_exn ~author:"selector-author" ~content:"an open thread"
  in
  require_workflow_rejection ~label:"a body with an unsupported selector"
    ~affix:"@@deriving"
    (comment ~post_id:(Board.Post_id.to_string open_post.id)
       "type t = A [@@deriving show]")

(* A close or reopen by someone who did not write the post reads the server's
   moderator list. With a readable list that does not name the actor, the
   call is refused and a different actor can succeed: a workflow rejection.
   With a list the server cannot read, no change to the call helps and the
   operator has to repair [runtime.toml]: a runtime failure. Every case runs
   for close and reopen, and the message names the cause, so a failure of the
   embedded default cannot stand in for a failure of the workspace file. *)
let test_tool_reports_an_unreadable_moderator_list_as_a_runtime_failure () =
  let write_runtime_toml content =
    let path =
      Config_dir_resolver.runtime_toml_path_for_base_path
        ~base_path:(Env_config_core.base_path ())
    in
    Fs_compat.mkdir_p (Filename.dirname path);
    Out_channel.with_open_bin path (fun oc -> output_string oc content)
  in
  let post =
    create_post_exn ~author:"moderated-author" ~content:"a post to moderate"
  in
  let post_id = Board.Post_id.to_string post.id in
  let call tool args =
    Board_tool.handle_tool ~reader:Masc_board_handlers.Board_access.Operator
      ~result_boundary:Tool_output.Sent_to_client tool (`Assoc args)
  in
  let close () =
    call "masc_board_close"
      [ "post_id", `String post_id
      ; "closed_by", `String "outsider"
      ; "summary", `String "no longer current"
      ; "no_successor", `Bool true
      ]
  in
  let reopen () =
    call "masc_board_reopen"
      [ "post_id", `String post_id; "reopened_by", `String "outsider" ]
  in
  let require_failure ~label ~expected_class ~affix result =
    match result with
    | Tool_result.Failed { Tool_result.class_; message; _ } ->
      Alcotest.(check string) (label ^ " class") expected_class
        (Tool_result.tool_failure_class_to_string class_);
      Alcotest.(check bool) (label ^ " names " ^ affix) true
        (Astring.String.is_infix ~affix message)
    | Tool_result.Completed _ | Tool_result.Deferred _ ->
      Alcotest.failf "%s must fail" label
  in
  write_runtime_toml "[board]\nmoderators = [\"a-moderator\"]\n";
  require_failure ~label:"close by an actor the list does not name"
    ~expected_class:"workflow_rejection"
    ~affix:"not author or configured Board moderator" (close ());
  require_failure ~label:"reopen by an actor the list does not name"
    ~expected_class:"workflow_rejection"
    ~affix:"not author or configured Board moderator" (reopen ());
  List.iter
    (fun (cause, toml, affix) ->
       write_runtime_toml toml;
       require_failure ~label:("close with " ^ cause)
         ~expected_class:"runtime_failure" ~affix (close ());
       require_failure ~label:("reopen with " ^ cause)
         ~expected_class:"runtime_failure" ~affix (reopen ()))
    [ "invalid TOML", "board = [\n", "runtime.toml is invalid TOML"
    ; "a [board] that is not a table", "board = 1\n", "[board] must be a table"
    ; ( "moderators that are not an array"
      , "[board]\nmoderators = \"a-moderator\"\n"
      , "moderators must be an array of keeper names" )
    ; ( "a moderator name that is not a keeper name"
      , "[board]\nmoderators = [\"not a keeper\"]\n"
      , "moderators contains an invalid keeper name" )
    ]

(* Which refusals tell the model to correct the call and which tell it to
   report a fault. [Validation_error] sat with the faults, so a comment on a
   full thread came back as "the tool failed inside the runtime, not on your
   arguments" while its message said to open a successor post. *)
let test_board_error_failure_class () =
  let class_of error =
    Tool_result.tool_failure_class_to_string
      (Board_tool_format.board_error_failure_class error)
  in
  List.iter
    (fun (label, error, expected) ->
       Alcotest.(check string) label expected (class_of error))
    [ "invalid_id", Board.Invalid_id "x", "workflow_rejection"
    ; "post_not_found", Board.Post_not_found "x", "workflow_rejection"
    ; "comment_not_found", Board.Comment_not_found "x", "workflow_rejection"
    ; "unauthorized", Board.Unauthorized "x", "workflow_rejection"
    ; "validation_error", Board.Validation_error "x", "workflow_rejection"
    ; "io_error", Board.Io_error "x", "runtime_failure"
    ; "recipient_lookup_failed", Board.Recipient_lookup_failed "x", "runtime_failure"
    ; "already_voted", Board.Already_voted "x", "runtime_failure"
    ; "already_exists", Board.Already_exists "x", "runtime_failure"
    ]

(* Ruling on issuecomment-5858752752 (wool-nova FAIL 5858744915): the
   non-positive cap opt-out must not be silent. The pure decider warns for
   0 and -1 and stays quiet at the default 100, and every warning names
   MASC_BOARD_COMMENT_COUNT_CAP so an operator can find the variable. *)
let test_cap_warning_message_decides_the_nonpositive_opt_out () =
  (match Board.Limits.cap_warning_message ~cap:100 () with
   | None -> ()
   | Some msg -> Alcotest.failf "cap 100 must be silent, got warning %S" msg);
  (match Board.Limits.cap_warning_message ~cap:0 () with
   | Some msg ->
     Alcotest.(check bool) "zero-cap warning names the variable" true
       (Astring.String.is_infix ~affix:"MASC_BOARD_COMMENT_COUNT_CAP" msg)
   | None -> Alcotest.fail "cap 0 switches the cap off and must warn");
  match Board.Limits.cap_warning_message ~cap:(-1) () with
  | Some msg ->
    Alcotest.(check bool) "negative-cap warning names the variable" true
      (Astring.String.is_infix ~affix:"MASC_BOARD_COMMENT_COUNT_CAP" msg)
  | None -> Alcotest.fail "cap -1 switches the cap off and must warn"

(* task-1758/#39356: the storage boundary refuses a close with no reason.
   A blank summary -- empty or whitespace-only -- is a [Validation_error]
   and nothing is written, so the dashboard route (which shares this
   boundary) cannot record a close without a summary either. *)
let test_close_rejects_blank_summary () =
  let post =
    create_post_exn ~author:"blank-summary-author" ~content:"needs a reason"
  in
  let post_id = Board.Post_id.to_string post.id in
  let attempt label summary =
    match
      Board_votes.set_closed (store ()) ~post_id ~closed_by:"blank-summary-author"
        ~successor:Board.No_successor ~summary ()
    with
    | Ok () -> Alcotest.fail (label ^ " must be refused")
    | Error (Board.Validation_error _) -> ()
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  attempt "empty summary" "";
  attempt "whitespace-only summary" "   \t ";
  attempt "non-breaking-space summary" "\194\160";
  restart ();
  Alcotest.(check bool) "post stayed open after refused closes" true
    (Option.is_none (get_post_exn post_id).closed)

let () =
  Alcotest.run "board_close_state"
    [ ( "close_state"
      , [ Alcotest.test_case
            "close persists successor and summary across restart" `Quick
            (with_eio test_close_persists_successor_and_summary_across_restart)
        ; Alcotest.test_case
            "reopen clears closed state across restart" `Quick
            (with_eio test_reopen_clears_closed_state_across_restart)
        ; Alcotest.test_case
            "reclosing overwrites the previous close" `Quick
            (with_eio test_reclosing_overwrites_the_previous_close)
        ; Alcotest.test_case
            "close and reopen report post_not_found" `Quick
            (with_eio test_close_and_reopen_report_post_not_found)
        ; Alcotest.test_case
            "closed post refuses new comments" `Quick
            (with_eio test_closed_post_refuses_new_comments)
        ; Alcotest.test_case
            "closed post rejection names the successor" `Quick
            (with_eio test_closed_post_rejection_names_the_successor)
        ; Alcotest.test_case
            "close rejects nonexistent successor" `Quick
            (with_eio test_close_rejects_nonexistent_successor)
        ; Alcotest.test_case
            "close rejects self as successor" `Quick
            (with_eio test_close_rejects_self_as_successor)
        ; Alcotest.test_case
            "comment past the cap is refused with the successor hint" `Quick
            (with_eio test_comment_past_the_cap_is_refused_with_successor_hint)
        ; Alcotest.test_case
            "tool answers a refused comment as a workflow rejection" `Quick
            (with_eio test_tool_answers_a_refused_comment_as_a_workflow_rejection)
        ; Alcotest.test_case
            "tool reports an unreadable moderator list as a runtime failure" `Quick
            (with_eio test_tool_reports_an_unreadable_moderator_list_as_a_runtime_failure)
        ; Alcotest.test_case
            "close rejects a blank summary" `Quick
            (with_eio test_close_rejects_blank_summary)
        ; Alcotest.test_case
            "cap warning message for the non-positive opt-out" `Quick
            test_cap_warning_message_decides_the_nonpositive_opt_out
        ] )
    ; ( "failure_class"
      , [ Alcotest.test_case
            "each board error has the class its recovery needs" `Quick
            test_board_error_failure_class
        ] )
    ]
