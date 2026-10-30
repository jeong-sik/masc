open Alcotest
open Masc

(* A name written after [@] is a target only when the recipient lookup the
   server installed declares it (RFC-at-name-resolves-to-declared-recipient).
   Each test below installs its own lookup and writes through the dispatcher,
   so what is asserted is what the write path decided and stored. *)

let fresh_test_base_path () =
  let dir =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-board-recipient-%06x" (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir
;;

let () = Random.self_init ()

(* The clock of the running test, for the lock probes below. *)
let clock = ref None

let started ~lookup f () =
  Eio_main.run
  @@ fun env ->
  clock := Some (Eio.Stdenv.clock env);
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_dispatch.init_jsonl ~recipient_lookup:lookup ();
  f ()
;;

let agent name =
  match Board.Agent_id.parse name with
  | Ok id -> id
  | Error error -> fail (Board.show_board_error error)
;;

let get = function
  | Ok value -> value
  | Error error -> fail (Board.show_board_error error)
;;

let spelled = Recipient_lookup.Candidate.to_string

(* The recipient each spelling stands for, whatever its case.  Two spellings
   may stand for one recipient; the resolution keeps it once. *)
let table = [ "alice", "alice"; "a-team", "alice"; "bob", "bob" ]

let declared_from table candidate =
  match List.assoc_opt (String.lowercase_ascii (spelled candidate)) table with
  | Some keeper -> Ok (Some (agent keeper))
  | None -> Ok None
;;

let declaring table = Recipient_lookup.make (declared_from table)

let contains ~sub text =
  let sub_length = String.length sub in
  let rec from index =
    index + sub_length <= String.length text
    && (String.equal (String.sub text index sub_length) sub || from (index + 1))
  in
  from 0
;;

let target_names = function
  | Some (Board.Targets targets) -> List.map Board.Agent_id.to_string targets
  | Some _ | None -> fail "expected a Targets audience"
;;

let label = function
  | Some audience -> Board.audience_label audience
  | None -> "none"
;;

let write ?(visibility = Board.Internal) ?(post_kind = Board.Human_post) content =
  Board_dispatch.create_post_with_unresolved
    ~author:"writer"
    ~content
    ~post_kind
    ~visibility
    ()
;;

let post_id (post : Board.post) = Board.Post_id.to_string post.id

let test_declared_names_are_targets_and_the_rest_are_reported =
  started ~lookup:(declaring table) (fun () ->
    let post, unresolved =
      get (write "@alice and @bob please look, @check is a dune alias and @Param a doc tag")
    in
    check
      (list string)
      "the targets are the declared Keepers"
      [ "alice"; "bob" ]
      (target_names post.audience);
    check
      (list string)
      "the undeclared names come back as written"
      [ "check"; "Param" ]
      unresolved;
    let stored = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check
      (list string)
      "the stored record is what the write decided"
      [ "alice"; "bob" ]
      (target_names stored.audience))
;;

let test_spellings_standing_for_one_recipient_are_one_target =
  started ~lookup:(declaring table) (fun () ->
    let post, unresolved = get (write "@Alice @a-team @ALICE") in
    check (list string) "one recipient, once" [ "alice" ] (target_names post.audience);
    check (list string) "nothing is left over" [] unresolved)
;;

let test_an_undeclared_name_does_not_reject_the_post =
  started ~lookup:(declaring table) (fun () ->
    let post, unresolved = get (write ~visibility:Board.Public "@check please") in
    check string "the post is open to discovery" "discoverable" (label post.audience);
    check (list string) "the name is reported" [ "check" ] unresolved;
    (* A refused post returns no [unresolved], so the refusal names them. *)
    match write ~visibility:Board.Direct "@check and @param please" with
    | Error (Board.Validation_error detail) ->
      List.iter
        (fun name ->
           check
             bool
             (Printf.sprintf "the refusal names @%s (%s)" name detail)
             true
             (contains ~sub:("@" ^ name) detail))
        [ "check"; "param" ]
    | Ok _ -> fail "a Direct post with no declared target must be refused"
    | Error error -> fail (Board.show_board_error error))
;;

let test_a_comment_resolves_the_same_way =
  started ~lookup:(declaring table) (fun () ->
    let post, _ = get (write "thread root") in
    let comment, unresolved =
      get
        (Board_dispatch.add_comment_with_unresolved
           ~post_id:(post_id post)
           ~author:"other"
           ~content:"@a-team ping, not @check"
           ())
    in
    check (list string) "the alias is the Keeper" [ "alice" ] (target_names comment.audience);
    check (list string) "the undeclared name is reported" [ "check" ] unresolved)
;;

(* Whether any file the Board keeps under its data directory holds [marker].
   A refused write leaves nothing in memory and nothing on disk. *)
let persisted_text_contains marker =
  let dir = Filename.dirname (Board.persist_path ()) in
  Sys.file_exists dir
  && Array.exists
       (fun name ->
          let path = Filename.concat dir name in
          (not (Sys.is_directory path))
          && contains ~sub:marker (In_channel.with_open_bin path In_channel.input_all))
       (Sys.readdir dir)
;;

(* A lookup that cannot answer refuses the write: recording "no recipient" for
   a name that may be declared would lose the address for good. *)
let test_a_lookup_failure_refuses_the_write_and_stores_nothing =
  let failing =
    Recipient_lookup.make (fun candidate ->
      if String.equal (spelled candidate) "broken"
      then Error "the settings of the Keeper broken are unreadable"
      else Ok None)
  in
  started ~lookup:failing (fun () ->
    (match write "@broken look zzmarker-create" with
     | Error (Board.Recipient_lookup_failed detail) ->
       check bool "the error says what is broken" true (contains ~sub:"broken" detail)
     | Ok _ -> fail "the write must be refused"
     | Error error -> fail (Board.show_board_error error));
    check int "nothing was stored" 0 (List.length (Board_dispatch.list_posts ()));
    check bool "nothing reached the disk" false (persisted_text_contains "zzmarker-create");
    let post, _ = get (write "original text, no address") in
    (match
       Board_dispatch.update_post_with_unresolved
         ~post_id:(post_id post)
         ~editor:"writer"
         ~content:"edited, now @broken zzmarker-edit"
         ()
     with
     | Error (Board.Recipient_lookup_failed _) -> ()
     | Ok _ -> fail "the edit must be refused"
     | Error error -> fail (Board.show_board_error error));
    let unchanged = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check string "the post is as it was" "original text, no address" unchanged.body;
    check bool "the edit reached no disk" false (persisted_text_contains "zzmarker-edit");
    (match
       Board_dispatch.add_comment_with_unresolved
         ~post_id:(post_id post)
         ~author:"other"
         ~content:"@broken ping zzmarker-comment"
         ()
     with
     | Error (Board.Recipient_lookup_failed _) -> ()
     | Ok _ -> fail "the comment must be refused"
     | Error error -> fail (Board.show_board_error error));
    check
      int
      "no comment was stored"
      0
      (List.length (get (Board_dispatch.get_comments ~post_id:(post_id post))));
    check bool "the comment reached no disk" false (persisted_text_contains "zzmarker-comment");
    (* The control: a stored post does show up in those files, so the checks
       above are able to see a write. *)
    ignore (get (write "a stored post zzmarker-control"));
    check bool "a stored post reaches the disk" true (persisted_text_contains "zzmarker-control"))
;;

(* Platform code decides whom a system post reaches. Its text is evidence, so a
   Keeper whose settings cannot be read must not stop it. *)
let test_a_system_post_never_asks_the_lookup =
  let asked = ref 0 in
  let counting =
    Recipient_lookup.make (fun _ ->
      incr asked;
      Error "must not be asked")
  in
  started ~lookup:counting (fun () ->
    let post, unresolved =
      get (write ~post_kind:Board.System_post ~visibility:Board.Unlisted "refused: @broken")
    in
    check string "the audience follows the visibility" "thread_participants" (label post.audience);
    check (list string) "nothing is reported" [] unresolved;
    check int "the lookup was not asked" 0 !asked)
;;

(* The lookup answers once per uncontended write, and the signal carries that
   answer. A dispatcher that asked again to build the signal would get "undeclared", and
   one that read the text again would get the alias as it was written. *)
let test_the_write_asks_once_and_the_signal_carries_that_answer =
  let armed = ref false in
  let asked = ref 0 in
  let one_shot =
    Recipient_lookup.make (fun candidate ->
      incr asked;
      if !armed
      then (
        armed := false;
        declared_from table candidate)
      else Ok None)
  in
  started ~lookup:one_shot (fun () ->
    let seen = ref None in
    Board_dispatch.set_board_signal_hook (fun addressed ->
      seen := Some addressed.Board_dispatch.audience);
    let expect_once ~step =
      check int (step ^ ": the lookup was asked once") 1 !asked;
      (match !seen with
       | Some (Board.Targets [ target ]) ->
         check string (step ^ ": the signal names the Keeper") "alice" (Board.Agent_id.to_string target)
       | Some _ | None -> fail (step ^ ": the signal must carry the declared target"));
      seen := None;
      asked := 0
    in
    armed := true;
    let post, _ = get (write "@a-team hello") in
    expect_once ~step:"create";
    check (list string) "create: the record agrees" [ "alice" ] (target_names post.audience);
    armed := true;
    let edited, _ =
      get
        (Board_dispatch.update_post_with_unresolved
           ~post_id:(post_id post)
           ~editor:"writer"
           ~content:"@a-team again, edited"
           ())
    in
    expect_once ~step:"edit";
    check (list string) "edit: the record agrees" [ "alice" ] (target_names edited.audience);
    armed := true;
    let comment, _ =
      get
        (Board_dispatch.add_comment_with_unresolved
           ~post_id:(post_id post)
           ~author:"other"
           ~content:"@a-team ping"
           ())
    in
    expect_once ~step:"comment";
    check (list string) "comment: the record agrees" [ "alice" ] (target_names comment.audience))
;;

let test_an_edit_resolves_again_with_the_current_declaration =
  let current = ref table in
  let lookup = Recipient_lookup.make (fun candidate -> declared_from !current candidate) in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "@alice first") in
    check (list string) "declared at the first write" [ "alice" ] (target_names post.audience);
    current := [ "bob", "bob" ];
    let edited, unresolved =
      get
        (Board_dispatch.update_post_with_unresolved
           ~post_id:(post_id post)
           ~editor:"writer"
           ~content:"@alice second"
           ())
    in
    check string "alice is no longer declared" "discoverable" (label edited.audience);
    check (list string) "so the name is reported" [ "alice" ] unresolved)
;;

(* A lookup made per write starts once for each uncontended addressed write,
   however many names the text has, and is started again for the next write. *)
let test_a_per_write_lookup_starts_once_for_each_uncontended_write =
  let starts = ref 0 in
  let lookup =
    Recipient_lookup.make_per_write (fun () ->
      incr starts;
      declared_from table)
  in
  started ~lookup (fun () ->
    ignore (get (write "@alice @bob @check @nobody @other"));
    check int "one start for a write with five names" 1 !starts;
    ignore (get (write "@alice"));
    check int "the next write starts again" 2 !starts;
    ignore (get (write "no address here"));
    check int "a text with no name starts nothing" 2 !starts)
;;

(* Whether an operation that starts now has to wait for a Board lock: one that
   has not finished after this long is waiting.  A free lock lets it finish in
   milliseconds, however often it stops for the disk on the way. *)
let would_wait operation =
  match !clock with
  | None -> fail "the lock probes need the clock of a running test"
  | Some clock ->
    Eio.Fiber.first
      (fun () ->
         operation ();
         false)
      (fun () ->
         Eio.Time.sleep clock 0.3;
         true)
;;

(* A reader waits for the store lock and a writer for the persistence lock.
   Raising here ends the write that holds the lock, so a lookup that runs under
   a lock fails the test instead of leaving it waiting on that lock. *)
let require_no_lock_is_held () =
  if would_wait (fun () -> ignore (Board_dispatch.list_posts ()))
  then fail "the lookup ran while the store lock was held";
  if would_wait (fun () -> ignore (write "lock probe"))
  then fail "the lookup ran while the persistence lock was held"
;;

(* The lookup reads the disk.  A write asks it before it takes any lock, so no
   reader or writer waits behind the disk, whether the write creates a post,
   comments or edits. *)
let test_no_write_asks_the_lookup_while_a_lock_is_held =
  let armed = ref false in
  let asked = ref 0 in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      if !armed
      then (
        incr asked;
        require_no_lock_is_held ());
      declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write "first") in
    armed := true;
    ignore (get (write "@alice a new post"));
    ignore
      (get
         (Board_dispatch.add_comment_with_unresolved
            ~post_id:(post_id post)
            ~author:"other"
            ~content:"@bob a comment"
            ()));
    ignore
      (get
         (Board_dispatch.update_post_with_unresolved
            ~post_id:(post_id post)
            ~editor:"writer"
            ~content:"@alice an edit"
            ()));
    check int "each of the three writes asked the lookup once" 3 !asked)
;;

(* Only the owner's edit is worked out before the locks.  Somebody else's edit
   is refused under them and asks the lookup nothing. *)
let test_an_edit_by_somebody_else_asks_the_lookup_nothing =
  let armed = ref false in
  let asked = ref 0 in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      if !armed then incr asked;
      declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write "first") in
    armed := true;
    (match
       Board_dispatch.update_post_with_unresolved
         ~post_id:(post_id post)
         ~editor:"somebody-else"
         ~content:"@alice and @bob"
         ()
     with
     | Error (Board.Unauthorized _) -> ()
     | Ok _ -> fail "somebody else must not edit the post"
     | Error error -> fail (Board.show_board_error error));
    check int "the lookup was not asked" 0 !asked)
;;

(* What an edit worked out before the locks belongs to the post it saw.  When
   another write replaces that post during the lookup, the edit works it out
   again on the new post instead of storing from the old one. *)
let test_an_edit_works_out_again_when_the_post_changed_during_the_lookup =
  let alice_asked = ref 0 in
  let during_the_lookup = ref (fun () -> ()) in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      if String.equal (spelled candidate) "alice"
      then (
        incr alice_asked;
        require_no_lock_is_held ();
        if !alice_asked = 1
        then !during_the_lookup ());
      declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "first") in
    during_the_lookup :=
      (fun () ->
         ignore
           (get
              (Board_dispatch.update_post_with_unresolved
                 ~post_id:(post_id post)
                 ~editor:"writer"
                 ~content:"changed in between"
                 ())));
    let edited, _ =
      get
        (Board_dispatch.update_post_with_unresolved
           ~post_id:(post_id post)
           ~editor:"writer"
           ~content:"@alice @bob"
           ())
    in
    check int "alice was asked again after the post changed" 2 !alice_asked;
    check
      (list string)
      "the edit records its own addresses"
      [ "alice"; "bob" ]
      (target_names edited.audience);
    let stored = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check string "the stored text is the edit's" "@alice @bob" stored.body)
;;

(* Several changes to the same post can invalidate consecutive plans. Every
   lookup must be outside both locks and the eventual write uses the last plan. *)
let test_an_edit_replans_after_repeated_changes_without_holding_a_lock =
  let starts = ref 0 in
  let alice_asked = ref 0 in
  let missing_asked = ref 0 in
  let during_the_lookup = ref (fun () -> ()) in
  let lookup =
    Recipient_lookup.make_per_write (fun () ->
      incr starts;
      fun candidate ->
        require_no_lock_is_held ();
        if String.equal (spelled candidate) "alice"
        then (
          incr alice_asked;
          if !alice_asked <= 2 then !during_the_lookup ());
        if String.equal (spelled candidate) "missing" then incr missing_asked;
        declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "first") in
    during_the_lookup :=
      (fun () ->
         ignore
           (get
              (Board_dispatch.update_post_with_unresolved
                 ~post_id:(post_id post)
                 ~editor:"writer"
                 ~content:(Printf.sprintf "other edit %d" !alice_asked)
                 ())));
    let edited, unresolved =
      get
        (Board_dispatch.update_post_with_unresolved
           ~post_id:(post_id post)
           ~editor:"writer"
           ~content:"@alice @missing"
           ())
    in
    check int "the lookup started once per plan" 3 !starts;
    check int "the lookup was asked after both changes" 3 !alice_asked;
    check int "each plan asked about the other name" 3 !missing_asked;
    check (list string) "the final audience" [ "alice" ] (target_names edited.audience);
    check (list string) "the final unresolved name" [ "missing" ] unresolved;
    let stored = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check string "the final text was stored" "@alice @missing" stored.body)
;;

(* An adversarial lookup that always changes the same post prevents a stable
   plan. The retry yields without a lock, so the caller can cancel it. *)
let test_an_edit_can_be_cancelled_during_continuous_changes =
  let alice_asked = ref 0 in
  let during_the_lookup = ref (fun () -> ()) in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      if String.equal (spelled candidate) "alice"
      then (
        incr alice_asked;
        !during_the_lookup ());
      declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "first") in
    during_the_lookup :=
      (fun () ->
         ignore
           (get
              (Board_dispatch.update_post_with_unresolved
                 ~post_id:(post_id post)
                 ~editor:"writer"
                 ~content:(Printf.sprintf "other edit %d" !alice_asked)
                 ())));
    let result =
      Eio.Fiber.first
        (fun () ->
           ignore
             (Board_dispatch.update_post_with_unresolved
                ~post_id:(post_id post)
                ~editor:"writer"
                ~content:"@alice never stable"
                ());
           `Finished)
        (fun () ->
           while !alice_asked < 3 do Eio.Fiber.yield () done;
           `Cancel)
    in
    check bool "the caller cancelled repeated replanning" true (result = `Cancel);
    let stored = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check bool "the cancelled edit did not land" false
      (String.equal stored.body "@alice never stable");
    ignore (get (write "a later write")))
;;

(* A changed owner is checked again before using the first plan. *)
let test_an_edit_refuses_if_the_owner_changes_during_lookup =
  let alice_asked = ref 0 in
  let during_the_lookup = ref (fun () -> ()) in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      if String.equal (spelled candidate) "alice"
      then (
        incr alice_asked;
        require_no_lock_is_held ();
        if !alice_asked = 1 then !during_the_lookup ());
      declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "first") in
    during_the_lookup :=
      (fun () ->
         ignore
           (get
              (Board_dispatch.update_post_with_unresolved
                 ~post_id:(post_id post)
                 ~editor:"writer"
                 ~new_author:"other"
                 ~content:"ownership transferred"
                 ())));
    (match
       Board_dispatch.update_post_with_unresolved
         ~post_id:(post_id post)
         ~editor:"writer"
         ~content:"@alice stale edit"
         ()
     with
     | Error (Board.Unauthorized _) -> ()
     | Ok _ -> fail "the previous owner must not write after the transfer"
     | Error error -> fail (Board.show_board_error error));
    check int "there was no lookup after the transfer" 1 !alice_asked;
    let stored = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check string "the transfer stayed stored" "other" (Board.Agent_id.to_string stored.author);
    check string "the stale edit was not stored" "ownership transferred" stored.body)
;;

(* A failed replan must not overwrite the concurrent change. *)
let test_an_edit_keeps_the_concurrent_write_if_the_replan_fails =
  let alice_asked = ref 0 in
  let during_the_lookup = ref (fun () -> ()) in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      if String.equal (spelled candidate) "alice"
      then (
        incr alice_asked;
        require_no_lock_is_held ();
        if !alice_asked = 1 then !during_the_lookup ());
      if String.equal (spelled candidate) "alice" && !alice_asked = 2
      then Error "lookup failed during replan"
      else declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "first") in
    during_the_lookup :=
      (fun () ->
         ignore
           (get
              (Board_dispatch.update_post_with_unresolved
                 ~post_id:(post_id post)
                 ~editor:"writer"
                 ~content:"concurrent edit zzmarker-peer"
                 ())));
    (match
       Board_dispatch.update_post_with_unresolved
         ~post_id:(post_id post)
         ~editor:"writer"
         ~content:"@alice rejected edit zzmarker-rejected"
         ()
     with
     | Error (Board.Recipient_lookup_failed _) -> ()
     | Ok _ -> fail "a failed replan must not be written"
     | Error error -> fail (Board.show_board_error error));
    check int "the second lookup failed" 2 !alice_asked;
    let stored = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check string "the concurrent edit stayed stored" "concurrent edit zzmarker-peer" stored.body;
    check bool "the concurrent edit reached disk" true (persisted_text_contains "zzmarker-peer");
    check bool "the failed edit did not reach disk" false (persisted_text_contains "zzmarker-rejected"))
;;

(* An edit that leaves the text alone does not address anybody anew.  The
   recorded audience stays what it was written as and the lookup is not asked,
   so a declaration that changed since then does not rewrite it. *)
let test_an_edit_that_leaves_the_text_alone_keeps_the_recorded_audience =
  let current = ref table in
  let asked = ref 0 in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      incr asked;
      declared_from !current candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "@alice same text") in
    check (list string) "declared when written" [ "alice" ] (target_names post.audience);
    current := [ "bob", "bob" ];
    asked := 0;
    let edited, unresolved =
      get
        (Board_dispatch.update_post_with_unresolved
           ~post_id:(post_id post)
           ~editor:"writer"
           ~content:"@alice same text"
           ())
    in
    check (list string) "the recorded audience stays" [ "alice" ] (target_names edited.audience);
    check (list string) "nothing is reported again" [] unresolved;
    check int "the lookup was not asked" 0 !asked)
;;

(* A comment replaces the post record and leaves what the edit's early work read
   alone, so the edit does not ask again. *)
let test_a_comment_during_the_lookup_does_not_make_the_edit_ask_again =
  let alice_asked = ref 0 in
  let during_the_lookup = ref (fun () -> ()) in
  let lookup =
    Recipient_lookup.make (fun candidate ->
      if String.equal (spelled candidate) "alice"
      then (
        incr alice_asked;
        if !alice_asked = 1
        then (
          require_no_lock_is_held ();
          !during_the_lookup ()));
      declared_from table candidate)
  in
  started ~lookup (fun () ->
    let post, _ = get (write ~visibility:Board.Public "first") in
    during_the_lookup :=
      (fun () ->
         ignore
           (get
              (Board_dispatch.add_comment_with_unresolved
                 ~post_id:(post_id post)
                 ~author:"other"
                 ~content:"a plain comment"
                 ())));
    let edited, _ =
      get
        (Board_dispatch.update_post_with_unresolved
           ~post_id:(post_id post)
           ~editor:"writer"
           ~content:"@alice edited"
           ())
    in
    check int "alice was asked once" 1 !alice_asked;
    check (list string) "the edit recorded its address" [ "alice" ] (target_names edited.audience))
;;

(* The targets are stored in name order, not in the order they were written, so
   the same names make the same record. *)
let test_targets_are_stored_in_name_order =
  started ~lookup:(declaring table) (fun () ->
    let post, _ = get (write "@bob and then @alice") in
    check (list string) "name order" [ "alice"; "bob" ] (target_names post.audience))
;;

(* A read can start the backend before the server does. That backend has no
   lookup, so a text with an address in it is refused until one is installed. *)
let test_a_backend_started_by_a_read_refuses_addresses_until_a_lookup_is_installed () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  ignore (fresh_test_base_path ());
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  ignore (Board_dispatch.list_posts ());
  (match write "@alice hello" with
   | Error (Board.Recipient_lookup_failed _) -> ()
   | Ok _ -> fail "an address must be refused without a lookup"
   | Error error -> fail (Board.show_board_error error));
  ignore (get (write "no address here"));
  Board_dispatch.init_jsonl ~recipient_lookup:(declaring table) ();
  let post, _ = get (write "@alice hello") in
  check (list string) "the installed lookup is used" [ "alice" ] (target_names post.audience)
;;

let test_a_second_init_keeps_the_first_lookup =
  started ~lookup:(declaring table) (fun () ->
    Board_dispatch.init_jsonl ~recipient_lookup:Recipient_lookup.none_declared ();
    let post, _ = get (write "@alice hello") in
    check (list string) "the first lookup stays" [ "alice" ] (target_names post.audience))
;;

let test_the_post_tool_answers_with_the_unresolved_names =
  started ~lookup:(declaring table) (fun () ->
    let result =
      Board_tool.handle_tool
        ~result_boundary:Tool_output.Sent_to_client
        "masc_board_post"
        (`Assoc [ "author", `String "writer"; "content", `String "@alice look at @check" ])
    in
    check bool "the tool succeeded" true (Tool_result.is_success result);
    let data = Tool_result.data result in
    check
      (list string)
      "the response lists the undeclared name"
      [ "check" ]
      Yojson.Safe.Util.(data |> member "unresolved" |> to_list |> List.map to_string);
    match Board_tool.post_of_write_data data with
    | Some post ->
      check (list string) "the post reads back" [ "alice" ] (target_names post.audience)
    | None -> fail "the response must still read back as a post")
;;

(* The comment and the edit tool answer like the post tool does. *)
let test_the_comment_and_edit_tools_answer_with_the_unresolved_names =
  started ~lookup:(declaring table) (fun () ->
    let post, _ = get (write "first") in
    let call name args =
      Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name (`Assoc args)
    in
    let unresolved_names result =
      Yojson.Safe.Util.(Tool_result.data result |> member "unresolved" |> to_list |> List.map to_string)
    in
    let commented =
      call
        "masc_board_comment"
        [ "post_id", `String (post_id post)
        ; "author", `String "other"
        ; "content", `String "@alice and @check"
        ]
    in
    check bool "the comment tool succeeded" true (Tool_result.is_success commented);
    check (list string) "the comment response lists the undeclared name" [ "check" ] (unresolved_names commented);
    let edited =
      call
        "masc_board_post_update"
        [ "post_id", `String (post_id post)
        ; "author", `String "writer"
        ; "content", `String "@bob and @param"
        ]
    in
    check bool "the edit tool succeeded" true (Tool_result.is_success edited);
    check (list string) "the edit response lists the undeclared name" [ "param" ] (unresolved_names edited))
;;

let () =
  run
    "Board recipient resolution"
    [ ( "write"
      , [ test_case
            "declared names are targets and the rest are reported"
            `Quick
            test_declared_names_are_targets_and_the_rest_are_reported
        ; test_case
            "spellings standing for one recipient are one target"
            `Quick
            test_spellings_standing_for_one_recipient_are_one_target
        ; test_case
            "an undeclared name does not reject the post"
            `Quick
            test_an_undeclared_name_does_not_reject_the_post
        ; test_case
            "a comment resolves the same way"
            `Quick
            test_a_comment_resolves_the_same_way
        ; test_case
            "a lookup failure refuses the write and stores nothing"
            `Quick
            test_a_lookup_failure_refuses_the_write_and_stores_nothing
        ; test_case
            "a system post never asks the lookup"
            `Quick
            test_a_system_post_never_asks_the_lookup
        ; test_case
            "the write asks once and the signal carries that answer"
            `Quick
            test_the_write_asks_once_and_the_signal_carries_that_answer
        ; test_case
            "an edit resolves again with the current declaration"
            `Quick
            test_an_edit_resolves_again_with_the_current_declaration
        ; test_case
            "a per-write lookup starts once for each uncontended write"
            `Quick
            test_a_per_write_lookup_starts_once_for_each_uncontended_write
        ; test_case
            "no write asks the lookup while a lock is held"
            `Quick
            test_no_write_asks_the_lookup_while_a_lock_is_held
        ; test_case
            "an edit by somebody else asks the lookup nothing"
            `Quick
            test_an_edit_by_somebody_else_asks_the_lookup_nothing
        ; test_case
            "an edit works out again when the post changed during the lookup"
            `Quick
            test_an_edit_works_out_again_when_the_post_changed_during_the_lookup
        ; test_case
            "an edit replans after repeated changes without holding a lock"
            `Quick
            test_an_edit_replans_after_repeated_changes_without_holding_a_lock
        ; test_case
            "an edit can be cancelled during continuous changes"
            `Quick
            test_an_edit_can_be_cancelled_during_continuous_changes
        ; test_case
            "an edit refuses if the owner changes during lookup"
            `Quick
            test_an_edit_refuses_if_the_owner_changes_during_lookup
        ; test_case
            "an edit keeps the concurrent write if the replan fails"
            `Quick
            test_an_edit_keeps_the_concurrent_write_if_the_replan_fails
        ; test_case
            "an edit that leaves the text alone keeps the recorded audience"
            `Quick
            test_an_edit_that_leaves_the_text_alone_keeps_the_recorded_audience
        ; test_case
            "a comment during the lookup does not make the edit ask again"
            `Quick
            test_a_comment_during_the_lookup_does_not_make_the_edit_ask_again
        ; test_case
            "targets are stored in name order"
            `Quick
            test_targets_are_stored_in_name_order
        ] )
    ; ( "backend"
      , [ test_case
            "a backend started by a read refuses addresses until a lookup is installed"
            `Quick
            test_a_backend_started_by_a_read_refuses_addresses_until_a_lookup_is_installed
        ; test_case
            "a second init keeps the first lookup"
            `Quick
            test_a_second_init_keeps_the_first_lookup
        ] )
    ; ( "tool"
      , [ test_case
            "the post tool answers with the unresolved names"
            `Quick
            test_the_post_tool_answers_with_the_unresolved_names
        ; test_case
            "the comment and edit tools answer with the unresolved names"
            `Quick
            test_the_comment_and_edit_tools_answer_with_the_unresolved_names
        ] )
    ]
;;
