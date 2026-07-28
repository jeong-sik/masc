(** Who counts as a participant in a board thread.

    [check_self_thread_status] decides whether the [Thread_participants]
    audience reaches a given keeper. It used to consult only the comment
    stream, so the author of a post was not a participant in its own thread: a
    keeper that raised a blocker as a post scored [`Never] and every reply was
    dropped before it reached the lane.

    Measured live on 2026-07-28: a keeper posted a blocker at 10:06, an
    operator answered on the post, no stimulus was produced, and the keeper
    went on calling [keeper_tasks_list] 547 times over 4h52m receiving `[]`
    each time. Re-sending the same answer with an explicit [@mention] — which
    routes through [Targets] and never reads participation — woke it in 60s.

    These cases exercise the decision function directly rather than through
    [test_keeper_keepalive_helpers], whose board fixtures currently cannot
    build a keeper meta (`meta_of_json failed: fields outside the current
    schema`) and fail identically on origin/main. *)

open Alcotest
open Masc
module Board_signal = Masc.Keeper_world_observation_board_signal

let keeper_ids name =
  List.filter_map Keeper_identity.Keeper_id.of_string [ name ]
  |> List.sort_uniq Keeper_identity.Keeper_id.compare
;;

let create_post ~author ~title =
  match
    Board_dispatch.create_post
      ~author
      ~content:"thread body"
      ~title
      ~post_kind:Board.Human_post
      ~visibility:Board.Internal
      ()
  with
  | Error error -> fail (Board.show_board_error error)
  | Ok post -> Board.Post_id.to_string post.id
;;

let comment ~post_id ~author ~content =
  match Board_dispatch.add_comment ~post_id ~author ~content () with
  | Error error -> fail (Board.show_board_error error)
  | Ok _comment -> ()
;;

let state_label = function
  | Board_signal.Unavailable u -> "unavailable:" ^ Board_signal.unavailable_to_string u
  | Board_signal.Available `Never -> "never"
  | Board_signal.Available `No_new_external -> "no_new_external"
  | Board_signal.Available (`New_external (n, author, _)) ->
    Printf.sprintf "new_external:%d:%s" n author
;;

let temp_dir () =
  let dir = Filename.temp_file "test_keeper_board_thread_participation_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  dir
;;

let rec cleanup_dir path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun name -> cleanup_dir (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

(* The board store lazily initializes under an Eio context and resolves its
   persist path from MASC_BASE_PATH, which a production guard refuses to let
   fall back to $HOME. Each case gets its own empty store so post and comment
   counts are exact. *)
let with_board f () =
  Eio_main.run
  @@ fun _env ->
  let base = temp_dir () in
  let previous = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" base;
  Unix.putenv "MASC_BASE_PATH_INPUT" base;
  Board_dispatch.reset_for_test ();
  Fun.protect
    ~finally:(fun () ->
      Board_dispatch.reset_for_test ();
      Unix.putenv "MASC_BASE_PATH" (Option.value previous ~default:"");
      Unix.putenv "MASC_BASE_PATH_INPUT" (Option.value previous ~default:"");
      cleanup_dir base)
    f
;;

(* The case that was broken: authorship is the keeper's only contribution. *)
let test_post_author_is_a_participant () =
  let self_ids = keeper_ids "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"resolved - assignment withdrawn";
  check string "reply to my own post is new external activity"
    "new_external:1:operator"
    (state_label (Board_signal.check_self_thread_status ~self_ids ~post_id))
;;

(* Authorship alone, with nobody having answered yet, is participation without
   news — not [`Never]. The distinction matters: [`Never] is what the replay
   path re-surfaces as unseen, so a keeper used to be shown its own posts. *)
let test_own_post_without_replies_is_participation_without_news () =
  let self_ids = keeper_ids "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  check string "my own unanswered post is not news to me"
    "no_new_external"
    (state_label (Board_signal.check_self_thread_status ~self_ids ~post_id))
;;

(* A keeper with no post and no comment in the thread stays a non-participant;
   widening participation must not make every keeper a participant in
   everything. *)
let test_uninvolved_keeper_is_not_a_participant () =
  let self_ids = keeper_ids "bystander" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"resolved";
  check string "no post and no comment means no participation"
    "never"
    (state_label (Board_signal.check_self_thread_status ~self_ids ~post_id))
;;

(* The pre-existing comment route must keep working unchanged. *)
let test_commenter_is_still_a_participant () =
  let self_ids = keeper_ids "rondo" in
  let post_id = create_post ~author:"external-author" ~title:"thread" in
  comment ~post_id ~author:"rondo" ~content:"rondo was here";
  comment ~post_id ~author:"operator" ~content:"follow up";
  check string "reply after my comment is new external activity"
    "new_external:1:operator"
    (state_label (Board_signal.check_self_thread_status ~self_ids ~post_id))
;;

(* The baseline is the keeper's LATEST contribution across both kinds. A reply
   older than the keeper's own comment must not re-trigger, even though the
   keeper also authored the post. *)
let test_baseline_is_the_latest_self_contribution () =
  let self_ids = keeper_ids "verifier" in
  let post_id = create_post ~author:"verifier" ~title:"blocker" in
  comment ~post_id ~author:"operator" ~content:"first answer";
  comment ~post_id ~author:"verifier" ~content:"acknowledged";
  check string "nothing external since my own last word"
    "no_new_external"
    (state_label (Board_signal.check_self_thread_status ~self_ids ~post_id));
  comment ~post_id ~author:"operator" ~content:"second answer";
  check string "a later external reply re-triggers"
    "new_external:1:operator"
    (state_label (Board_signal.check_self_thread_status ~self_ids ~post_id))
;;

let () =
  run
    "keeper_board_thread_participation"
    [ ( "post_author"
      , [ test_case "post author is a thread participant" `Quick
            (with_board test_post_author_is_a_participant)
        ; test_case "own post without replies is participation without news" `Quick
            (with_board test_own_post_without_replies_is_participation_without_news)
        ] )
    ; ( "boundaries"
      , [ test_case "uninvolved keeper is not a participant" `Quick
            (with_board test_uninvolved_keeper_is_not_a_participant)
        ; test_case "commenter is still a participant" `Quick
            (with_board test_commenter_is_still_a_participant)
        ; test_case "baseline is the latest self contribution" `Quick
            (with_board test_baseline_is_the_latest_self_contribution)
        ] )
    ]
;;
