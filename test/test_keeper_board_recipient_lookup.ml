open Alcotest
open Masc

(* The Keeper side of the Board recipient lookup reads the persisted Keeper
   settings: a name stands for a Keeper when it is the Keeper's own name or one
   of its [mention_targets].  Each case writes real settings under a temporary
   base path and asks through the same [Recipient_lookup.resolve] the write path
   uses. *)

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

(* The aliases are part of the Keeper's configuration, so they go in its TOML;
   the persisted settings are overlaid with it when they are read. *)
let register_keeper config ?(aliases = []) name =
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
    match aliases with
    | [] -> ""
    | _ :: _ ->
      Printf.sprintf
        "mention_targets = [%s]\n"
        (String.concat ", " (List.map (Printf.sprintf "%S") aliases))
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

let test_a_keepers_own_name_in_any_case config =
  register_keeper config "alice";
  expect_ok "lower case" ([ "alice" ], []) (ask config "alice");
  expect_ok "upper case" ([ "alice" ], []) (ask config "ALICE")
;;

let test_an_alias_stands_for_its_keeper config =
  register_keeper config ~aliases:[ "a-team"; "Release-Leader" ] "alice";
  register_keeper config "bob";
  expect_ok "alias" ([ "alice" ], []) (ask config "a-team");
  expect_ok "alias in another case" ([ "alice" ], []) (ask config "RELEASE-leader")
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
  register_keeper config ~aliases:[ "shared" ] "alice";
  register_keeper config ~aliases:[ "shared" ] "bob";
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
        ; test_case "an alias stands for its Keeper" `Quick
            (with_workspace test_an_alias_stands_for_its_keeper)
        ; test_case "an unknown name is not declared" `Quick
            (with_workspace test_an_unknown_name_is_not_declared)
        ; test_case "a name no Keeper can have is not declared" `Quick
            (with_workspace test_a_name_no_keeper_can_have_is_not_declared)
        ; test_case "two Keepers claiming one alias fail the lookup" `Quick
            (with_workspace test_two_keepers_claiming_one_alias_fail_the_lookup)
        ; test_case "an unreadable setting fails an alias lookup only" `Quick
            (with_workspace test_an_unreadable_setting_fails_an_alias_lookup_only)
        ; test_case "a Keeper name too long for a Board identity fails the lookup" `Quick
            (with_workspace test_a_keeper_name_too_long_for_a_board_identity_fails_the_lookup)
        ] )
    ]
;;
