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

let started ~lookup f () =
  Eio_main.run
  @@ fun env ->
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

(* The Keeper each spelling stands for, whatever its case. *)
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
      get (write "@alice and @bob please look, @check is a dune alias")
    in
    check
      (list string)
      "the targets are the declared Keepers"
      [ "alice"; "bob" ]
      (target_names post.audience);
    check (list string) "the undeclared name comes back as written" [ "check" ] unresolved;
    let stored = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check
      (list string)
      "the stored record is what the write decided"
      [ "alice"; "bob" ]
      (target_names stored.audience))
;;

let test_an_alias_and_a_spelling_variant_are_one_target =
  started ~lookup:(declaring table) (fun () ->
    let post, unresolved = get (write "@Alice @a-team @ALICE") in
    check (list string) "one Keeper, once" [ "alice" ] (target_names post.audience);
    check (list string) "nothing is left over" [] unresolved)
;;

let test_an_undeclared_name_does_not_reject_the_post =
  started ~lookup:(declaring table) (fun () ->
    let post, unresolved = get (write ~visibility:Board.Public "@check please") in
    check string "the post is open to discovery" "discoverable" (label post.audience);
    check (list string) "the name is reported" [ "check" ] unresolved;
    match write ~visibility:Board.Direct "@check please" with
    | Error (Board.Validation_error _) -> ()
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
    (match write "@broken look" with
     | Error (Board.Recipient_lookup_failed detail) ->
       check bool "the error says what is broken" true (contains ~sub:"broken" detail)
     | Ok _ -> fail "the write must be refused"
     | Error error -> fail (Board.show_board_error error));
    check int "nothing was stored" 0 (List.length (Board_dispatch.list_posts ()));
    let post, _ = get (write "original text, no address") in
    (match
       Board_dispatch.update_post_with_unresolved
         ~post_id:(post_id post)
         ~editor:"writer"
         ~content:"edited, now @broken"
         ()
     with
     | Error (Board.Recipient_lookup_failed _) -> ()
     | Ok _ -> fail "the edit must be refused"
     | Error error -> fail (Board.show_board_error error));
    let unchanged = get (Board_dispatch.get_post ~post_id:(post_id post)) in
    check string "the post is as it was" "original text, no address" unchanged.body;
    (match
       Board_dispatch.add_comment_with_unresolved
         ~post_id:(post_id post)
         ~author:"other"
         ~content:"@broken ping"
         ()
     with
     | Error (Board.Recipient_lookup_failed _) -> ()
     | Ok _ -> fail "the comment must be refused"
     | Error error -> fail (Board.show_board_error error));
    check
      int
      "no comment was stored"
      0
      (List.length (get (Board_dispatch.get_comments ~post_id:(post_id post)))))
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

(* The lookup answers once per write, and the signal carries that answer. A
   dispatcher that asked again to build the signal would get "undeclared". *)
let test_the_write_asks_once_and_the_signal_carries_that_answer =
  let armed = ref false in
  let asked = ref 0 in
  let one_shot =
    Recipient_lookup.make (fun candidate ->
      incr asked;
      if !armed
      then (
        armed := false;
        Ok (Some (agent (String.lowercase_ascii (spelled candidate)))))
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
    let post, _ = get (write "@alice hello") in
    expect_once ~step:"create";
    check (list string) "create: the record agrees" [ "alice" ] (target_names post.audience);
    armed := true;
    let edited, _ =
      get
        (Board_dispatch.update_post_with_unresolved
           ~post_id:(post_id post)
           ~editor:"writer"
           ~content:"@alice again, edited"
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
           ~content:"@alice ping"
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
   | Error (Board.Recipient_lookup_failed detail) ->
     check
       bool
       "the error says no lookup was installed"
       true
       (contains ~sub:"no recipient lookup" detail)
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

let () =
  run
    "Board recipient resolution"
    [ ( "write"
      , [ test_case
            "declared names are targets and the rest are reported"
            `Quick
            test_declared_names_are_targets_and_the_rest_are_reported
        ; test_case
            "an alias and a spelling variant are one target"
            `Quick
            test_an_alias_and_a_spelling_variant_are_one_target
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
        ] )
    ]
;;
