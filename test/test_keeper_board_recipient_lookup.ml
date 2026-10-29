open Alcotest
open Masc

(* The Keeper side of the Board recipient lookup reads the persisted Keeper
   settings: a name is declared when a Keeper answers to it, which is its
   [mention_targets] when it has any and its own name when it has none, the
   same question the Board router asks.  Each case writes real settings under a
   temporary base path and asks through the same [Recipient_lookup.resolve] the
   write path uses. *)

let rec remove_tree path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path)
    else Sys.remove path
;;

let with_workspace f () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Filename.temp_dir "keeper-recipient-lookup" "" in
  let previous_base_path = Sys.getenv_opt "MASC_BASE_PATH" in
  Unix.putenv "MASC_BASE_PATH" base_path;
  let config = Workspace.default_config base_path in
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "MASC_BASE_PATH" (Option.value previous_base_path ~default:"");
      try remove_tree base_path with Sys_error _ | Unix.Unix_error _ -> ())
    (fun () ->
       ignore (Workspace.init config ~agent_name:None : string);
       f config)
;;

(* The [mention_targets] are part of the Keeper's configuration, so they go in
   its TOML; the persisted settings are overlaid with it when they are read.
   Without them the Keeper answers to its own name alone. *)
let register_keeper config ?(mention_targets = []) name =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc
          [ "name", `String name
            (* A trace id is at most 64 bytes, a Keeper name at most 128. *)
          ; "trace_id", `String ("trace-" ^ String.sub name 0 (min 16 (String.length name)))
          ])
    with
    | Ok meta -> meta
    | Error detail -> fail detail
  in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.Workspace.base_path
  in
  Fs_compat.mkdir_p keepers_dir;
  let alias_line =
    match mention_targets with
    | [] -> ""
    | _ :: _ ->
      Printf.sprintf
        "mention_targets = [%s]\n"
        (String.concat ", " (List.map (Printf.sprintf "%S") mention_targets))
  in
  Out_channel.with_open_text (Filename.concat keepers_dir (name ^ ".toml")) (fun oc ->
    output_string
      oc
      ("[keeper]\n\
        instructions = \"Review Board evidence.\"\n\
        sandbox_profile = \"docker\"\n\
        sandbox_image = \"base\"\n"
       ^ alias_line));
  match Keeper_meta_store.replace_snapshot config meta with
  | Ok () -> ()
  | Error detail -> fail detail
;;

let lookup config = Keeper_board_recipient_lookup.make ~base_path:config.Workspace.base_path

let contains ~sub text =
  let sub_length = String.length sub in
  let rec from index =
    index + sub_length <= String.length text
    && (String.equal (String.sub text index sub_length) sub || from (index + 1))
  in
  from 0
;;

(* What one name resolves to: the Keepers it stands for and the names left over. *)
let ask config name =
  match Recipient_lookup.Candidate.of_string name with
  | None -> fail (Printf.sprintf "%S is not shaped like a name" name)
  | Some candidate ->
    Recipient_lookup.resolve (lookup config) [ candidate ]
    |> Result.map (fun (resolution : Board.Agent_id.t Recipient_lookup.resolution) ->
      List.map Board.Agent_id.to_string resolution.recipients, resolution.unresolved)
;;

let answer = pair (list string) (list string)

let expect_ok label expected = function
  | Ok found -> check answer label expected found
  | Error detail -> fail (Printf.sprintf "%s: the lookup failed: %s" label detail)
;;

let expect_error label ~mentioning = function
  | Ok (recipients, _) ->
    fail (Printf.sprintf "%s: expected a failure, got %s" label (String.concat "," recipients))
  | Error detail ->
    List.iter
      (fun sub ->
         check
           bool
           (Printf.sprintf "%s: the detail mentions %S (%s)" label sub detail)
           true
           (contains ~sub detail))
      mentioning
;;

(* A post from somebody who is no Keeper's own lane. *)
let post_signal : Board_dispatch.board_signal =
  { kind = Board_dispatch.Board_post_created
  ; post_id = "post-1"
  ; author = "carol"
  ; title = "title"
  ; content = "content"
  ; hearth = None
  ; updated_at = None
  }
;;

(* Whether the Board router delivers a post recorded for [recipient] to the
   Keeper [keeper]: the question the recorded name has to answer yes to. *)
let routed_to config ~keeper recipient =
  match
    Keeper_meta_store.read_effective_meta config keeper
    , Keeper_identity.Keeper_id.of_string recipient
  with
  | Ok (Some meta), Some id ->
    (match
       Keeper_board_audience.route_for_keeper
         ~audience:(Keeper_board_audience.Targets [ id ])
         ~meta
         ~signal:post_signal
     with
     | Keeper_world_observation_board_signal.Available (Keeper_board_audience.Deliver _) ->
       true
     | Keeper_world_observation_board_signal.Available
         (Keeper_board_audience.Judge_discoverable | Keeper_board_audience.Ignore)
     | Keeper_world_observation_board_signal.Unavailable _ -> false)
  | Ok None, _ -> fail (Printf.sprintf "no Keeper named %S" keeper)
  | Error detail, _ -> fail detail
  | Ok (Some _), None -> fail (Printf.sprintf "%S is not a Keeper id" recipient)
;;

let test_a_keepers_own_name_in_any_case config =
  register_keeper config "alice";
  expect_ok "lower case" ([ "alice" ], []) (ask config "alice");
  expect_ok "upper case" ([ "alice" ], []) (ask config "ALICE")
;;

(* An alias is recorded as the name the author wrote, in lower case.  The
   router matches a recorded target against the names a Keeper answers to, and
   the alias is one of them. *)
let test_an_alias_is_recorded_as_the_name_its_keeper_answers_to config =
  register_keeper config ~mention_targets:[ "alice"; "a-team"; "Release-Leader" ] "alice";
  register_keeper config "bob";
  expect_ok "alias" ([ "a-team" ], []) (ask config "a-team");
  expect_ok "alias in another case" ([ "release-leader" ], []) (ask config "RELEASE-leader");
  expect_ok "the Keeper's own name, which it lists" ([ "alice" ], []) (ask config "alice")
;;

(* A Keeper that lists aliases and leaves its own name out is not addressed by
   that name: the router does not count it once a list exists.  Declaring it
   would record a target nobody is woken for and tell the author nothing. *)
let test_a_keeper_that_lists_only_aliases_is_not_declared_by_its_own_name config =
  register_keeper config ~mention_targets:[ "a-team" ] "alice";
  expect_ok "alias" ([ "a-team" ], []) (ask config "a-team");
  expect_ok "own name" ([], [ "alice" ]) (ask config "alice")
;;

let test_a_name_another_keeper_lists_is_declared_by_that_keeper config =
  register_keeper config ~mention_targets:[ "a-team" ] "alice";
  register_keeper config ~mention_targets:[ "bob"; "alice" ] "bob";
  expect_ok "alice is bob's alias" ([ "alice" ], []) (ask config "alice");
  check bool "bob is routed on it" true (routed_to config ~keeper:"bob" "alice");
  check bool "alice is not" false (routed_to config ~keeper:"alice" "alice")
;;

(* The recorded name is what the router delivers on, for a Keeper that lists
   nothing, one that lists its own name and an alias, and one that lists only an
   alias. *)
let test_every_recorded_name_reaches_the_keeper_that_declared_it config =
  register_keeper config "plain";
  register_keeper config ~mention_targets:[ "listed"; "listed-alias" ] "listed";
  register_keeper config ~mention_targets:[ "only-alias" ] "aliased";
  List.iter
    (fun (keeper, name) ->
       match ask config name with
       | Ok ([ recipient ], []) ->
         check
           bool
           (Printf.sprintf "@%s reaches %s" name keeper)
           true
           (routed_to config ~keeper recipient)
       | Ok _ | Error _ -> fail (Printf.sprintf "@%s should be declared by %s" name keeper))
    [ "plain", "plain"
    ; "plain", "PLAIN"
    ; "listed", "listed"
    ; "listed", "listed-alias"
    ; "listed", "LISTED-ALIAS"
    ; "aliased", "only-alias"
    ]
;;

let test_an_unknown_name_is_not_declared config =
  register_keeper config "alice";
  expect_ok "unknown" ([], [ "nobody" ]) (ask config "nobody")
;;

(* The lookup builds a file name from the name it is given.  A name no Keeper
   can have is answered before any file name exists. *)
let test_a_name_no_keeper_can_have_is_not_declared config =
  register_keeper config "alice";
  let beyond_the_name_rule = String.make 129 'a' in
  expect_ok
    "129 bytes"
    ([], [ beyond_the_name_rule ])
    (ask config beyond_the_name_rule);
  (* Past 250 bytes the name and its ".json" no longer fit a file name, so
     reading it would fail with ENAMETOOLONG instead of finding nothing. *)
  let beyond_a_file_name = String.make 300 'a' in
  expect_ok
    "300 bytes"
    ([], [ beyond_a_file_name ])
    (ask config beyond_a_file_name)
;;

let test_two_keepers_claiming_one_alias_fail_the_lookup config =
  register_keeper config ~mention_targets:[ "alice"; "shared" ] "alice";
  register_keeper config ~mention_targets:[ "bob"; "shared" ] "bob";
  expect_error
    "shared alias"
    ~mentioning:[ "@shared"; "alice"; "bob" ]
    (ask config "shared")
;;

(* A Keeper's own name reads that Keeper's settings alone.  Any other name is
   looked for in every Keeper's settings, so one unreadable setting fails it. *)
let test_an_unreadable_setting_fails_an_alias_lookup_only config =
  register_keeper config "alice";
  Out_channel.with_open_text (Keeper_types_profile.keeper_meta_path config "broken") (fun oc ->
    output_string oc "{ this is not json");
  expect_ok "the exact name never reads the others" ([ "alice" ], []) (ask config "alice");
  expect_error "an alias scan reads the broken one" ~mentioning:[ "@someone"; "broken" ] (ask config "someone")
;;

(* A Keeper's own name is declared by that Keeper whoever else lists it, as the
   broadcast path reads it.  Two other Keepers listing the same name do not make
   it a collision. *)
let test_an_own_name_wins_over_aliases_that_collide config =
  register_keeper config "x";
  register_keeper config ~mention_targets:[ "z"; "x" ] "z";
  register_keeper config ~mention_targets:[ "w"; "x" ] "w";
  expect_ok "own name" ([ "x" ], []) (ask config "x");
  (* With no Keeper of that name, the same two claims are a collision. *)
  register_keeper config ~mention_targets:[ "z2"; "y" ] "z2";
  register_keeper config ~mention_targets:[ "w2"; "y" ] "w2";
  expect_error "two aliases and no own name" ~mentioning:[ "@y"; "z2"; "w2" ] (ask config "y")
;;

(* A file at a Keeper's path that this build does not decode as the current
   schema reads as no Keeper in other readers.  Here it fails the lookup, for
   its own name and for any name a scan has to reach it for: taking it for "no
   such Keeper" would turn the address into prose without a word to the author. *)
let test_a_keeper_file_this_build_cannot_read_fails_the_lookup config =
  register_keeper config "alice";
  Out_channel.with_open_text (Keeper_types_profile.keeper_meta_path config "stale") (fun oc ->
    output_string oc "{ \"unexpected\": true }");
  expect_ok "a healthy Keeper's own name reads that Keeper alone" ([ "alice" ], []) (ask config "alice");
  expect_error "its own name" ~mentioning:[ "@stale"; "stale" ] (ask config "stale");
  expect_error "a scan reaches it" ~mentioning:[ "@someone"; "stale" ] (ask config "someone")
;;

(* The settings are read from disk.  A base path that cannot hold them makes the
   read raise; that is a failed lookup, not an exception through the write. *)
let test_a_read_that_raises_fails_the_lookup () =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let file = Filename.temp_file "keeper-recipient-lookup" "" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove file with Sys_error _ -> ())
    (fun () ->
       (* A directory cannot be made under a regular file. *)
       let config = Workspace.default_config (Filename.concat file "base") in
       match ask config "someone" with
       | Error _ -> ()
       | Ok (recipients, unresolved) ->
         fail
           (Printf.sprintf
              "expected a failure, got %s / %s"
              (String.concat "," recipients)
              (String.concat "," unresolved))
       | exception exn -> fail ("the lookup raised " ^ Printexc.to_string exn))
;;

(* The broadcast path finds a Keeper by alias with
   [persisted_keeper_for_mention_target].  It shares its scan with the lookup,
   so what it answers is pinned here: one claim finds the Keeper, no claim finds
   nobody, two claims or an unreadable setting are errors, and a target that is
   not a Keeper id reads nothing. *)
let test_the_alias_scan_the_broadcast_path_uses_answers_as_before config =
  register_keeper config ~mention_targets:[ "alice"; "a-team" ] "alice";
  register_keeper config ~mention_targets:[ "bob"; "shared" ] "bob";
  register_keeper config ~mention_targets:[ "carol"; "shared" ] "carol";
  let scan target =
    Keeper_meta_store.persisted_keeper_for_mention_target config ~mention_target:target
  in
  (match scan "A-Team" with
   | Ok (Some (keeper_name, _)) -> check string "one claim finds its Keeper" "alice" keeper_name
   | Ok None | Error _ -> fail "an alias one Keeper claims must find that Keeper");
  (match scan "nobody" with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "a name nobody claims finds nobody");
  (match scan "shared" with
   | Error detail ->
     List.iter
       (fun sub ->
          check bool (Printf.sprintf "the error mentions %S (%s)" sub detail) true (contains ~sub detail))
       [ "shared"; "bob"; "carol" ]
   | Ok _ -> fail "two claims on one alias must be an error");
  Out_channel.with_open_text (Keeper_types_profile.keeper_meta_path config "broken") (fun oc ->
    output_string oc "{ this is not json");
  (match scan "a-team" with
   | Error detail ->
     check bool (Printf.sprintf "the error names the unreadable Keeper (%s)" detail) true (contains ~sub:"broken" detail)
   | Ok _ -> fail "an unreadable setting must be an error");
  (match scan "" with
   | Ok None -> ()
   | Ok (Some _) | Error _ -> fail "a blank target reads no setting")
;;

(* A Board identity is 1 to 64 bytes.  A Keeper name may be longer, but then it
   cannot be recorded as a target, and saying "not declared" would hide that a
   Keeper by that name exists. *)
let test_a_keeper_name_too_long_for_a_board_identity_fails_the_lookup config =
  let name = String.make 65 'k' in
  register_keeper config name;
  expect_error "65 bytes" ~mentioning:[ "Board recipient" ] (ask config name)
;;

let () =
  run
    "Keeper Board recipient lookup"
    [ ( "lookup"
      , [ test_case "a Keeper's own name in any case" `Quick
            (with_workspace test_a_keepers_own_name_in_any_case)
        ; test_case "an alias is recorded as the name its Keeper answers to" `Quick
            (with_workspace test_an_alias_is_recorded_as_the_name_its_keeper_answers_to)
        ; test_case "a Keeper that lists only aliases is not declared by its own name" `Quick
            (with_workspace test_a_keeper_that_lists_only_aliases_is_not_declared_by_its_own_name)
        ; test_case "a name another Keeper lists is declared by that Keeper" `Quick
            (with_workspace test_a_name_another_keeper_lists_is_declared_by_that_keeper)
        ; test_case "every recorded name reaches the Keeper that declared it" `Quick
            (with_workspace test_every_recorded_name_reaches_the_keeper_that_declared_it)
        ; test_case "an unknown name is not declared" `Quick
            (with_workspace test_an_unknown_name_is_not_declared)
        ; test_case "a name no Keeper can have is not declared" `Quick
            (with_workspace test_a_name_no_keeper_can_have_is_not_declared)
        ; test_case "two Keepers claiming one alias fail the lookup" `Quick
            (with_workspace test_two_keepers_claiming_one_alias_fail_the_lookup)
        ; test_case "an unreadable setting fails an alias lookup only" `Quick
            (with_workspace test_an_unreadable_setting_fails_an_alias_lookup_only)
        ; test_case "an own name wins over aliases that collide" `Quick
            (with_workspace test_an_own_name_wins_over_aliases_that_collide)
        ; test_case "a Keeper file this build cannot read fails the lookup" `Quick
            (with_workspace test_a_keeper_file_this_build_cannot_read_fails_the_lookup)
        ; test_case "a read that raises fails the lookup" `Quick
            test_a_read_that_raises_fails_the_lookup
        ; test_case "the alias scan the broadcast path uses answers as before" `Quick
            (with_workspace test_the_alias_scan_the_broadcast_path_uses_answers_as_before)
        ; test_case "a Keeper name too long for a Board identity fails the lookup" `Quick
            (with_workspace test_a_keeper_name_too_long_for_a_board_identity_fails_the_lookup)
        ] )
    ]
;;
