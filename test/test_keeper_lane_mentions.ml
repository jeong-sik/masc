(* Boundary mention parsing and persisted chat mentions. *)

open Alcotest

module Lane = Masc.Keeper_lane_mentions
module Kid = Masc.Keeper_identity.Keeper_id
module Store = Masc.Keeper_chat_store

let ids = list string

let parse content =
  Lane.mention_ids_of_content content |> List.map Kid.to_string

(* ── 1. Parser goldens ── *)

let test_parser_goldens () =
  check ids "plain mention" [ "alice" ] (parse "hey @alice look");
  check ids "different token" [ "alicex" ] (parse "ping @alicex now");
  check ids "email is one token" [] (parse "send to email@alice.com");
  check ids "case folded" [ "alice" ] (parse "PING @ALICE NOW");
  (* #25601: the shared grammar preserves case; the case-fold now happens
     only inside [Keeper_id.of_string], so duplicate casings of the same
     mention still mint ONE canonical id. *)
  check ids "duplicate casings mint one id" [ "alice" ]
    (parse "@ALICE and @alice");
  check ids "trailing punctuation" [ "alice" ] (parse "ok @alice, thanks");
  check ids "no mention" [] (parse "just chatting here");
  check ids "newline separated" [ "alice" ] (parse "line one\n@alice two");
  check ids "deduplicated" [ "alice" ] (parse "@alice and @alice again");
  check ids "two distinct"
    [ "alice"; "alpha" ]
    (parse "@alpha and @alice please");
  (* Not "alice". RFC-0393 hard cut: the keeper name is the only spelling,
     so a keeper-shaped token is its own id and matches no keeper called
     alice. #33104 recorded the same cut in test_playground_paths. *)
  check ids "keeper-shaped form is its own id, not a second spelling"
    [ "keeper-alice" ]
    (parse "cc @keeper-alice");
  (* Apostrophe is an internal (kept) character — "@alpha's" is its own
     token and never reaches "alpha"; same as the legacy tokenizer. *)
  check ids "possessive stays distinct" [ "alpha's" ] (parse "@alpha's note")

let test_explicit_address_is_closed () =
  let check_address label expected content =
    let actual =
      match Lane.explicit_address_of_content content with
      | Lane.No_explicit_address -> "none"
      | Lane.Broadcast_all -> "broadcast"
      | Lane.Targets targets ->
        "targets:" ^ String.concat "," (List.map Kid.to_string targets)
      | Lane.Unsupported_broadcast selectors ->
        "unsupported:" ^ String.concat "," selectors
    in
    check string label expected actual
  in
  check_address "unaddressed" "none" "plain Board update";
  check_address "targets" "targets:alpha,beta" "@beta and @alpha";
  check_address "exact broadcast" "broadcast" "release note @@all";
  check_address
    "generic agent-type broadcast is not Keeper authority"
    "unsupported:delta"
    "release note @@delta";
  check_address "empty broadcast selector fails closed" "unsupported:" "release @@";
  check_address
    "mixed valid and unsupported broadcast fails closed"
    "unsupported:all,delta"
    "@@all @@delta";
  check_address
    "broadcast precedence"
    "broadcast"
    "@@all and @alpha"

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun name -> remove_tree (Filename.concat path name));
      Unix.rmdir path
    end
    else Sys.remove path

let temp_base_path prefix =
  Filename.concat
    (Filename.get_temp_dir_name ())
    (Printf.sprintf "%s-%d-%d" prefix (Unix.getpid ()) (Random.bits ()))

let with_base prefix f =
  let base = temp_base_path prefix in
  Fun.protect ~finally:(fun () -> remove_tree base) (fun () -> f base)

let message_mentions (m : Store.chat_message) =
  List.map Kid.to_string m.mentions

let test_append_persists_mentions () =
  with_base "lane-mentions-append" (fun base ->
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"@alice please look at @alpha note" ();
      Store.append_turn ~base_dir:base ~keeper_name:"alice"
        ~user_content:"thanks @delta" ~user_attachments:[]
        ~assistant_content:"done" ();
      match Store.load ~base_dir:base ~keeper_name:"alice" with
      | [ first; second; third ] ->
          check ids "user message mentions"
            [ "alice"; "alpha" ]
            (message_mentions first);
          check ids "turn user line mentions" [ "delta" ]
            (message_mentions second);
          check ids "assistant line has none" [] (message_mentions third)
      | other ->
          failf "expected 3 lane lines, got %d" (List.length other))

let test_extra_mentions_merge () =
  with_base "lane-mentions-extra" (fun base ->
      let extra = Option.to_list (Kid.of_string "alice") in
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"no at-token here" ~extra_mentions:extra ();
      match Store.load ~base_dir:base ~keeper_name:"alice" with
      | [ only ] ->
          check ids "connector-provided mention persisted" [ "alice" ]
            (message_mentions only)
      | other -> failf "expected 1 lane line, got %d" (List.length other))

let () =
  Random.self_init ();
  run "keeper_lane_mentions"
    [
      ( "parser",
        [ test_case "goldens" `Quick test_parser_goldens;
          test_case "closed explicit address" `Quick
            test_explicit_address_is_closed;
        ] );
      ( "store_roundtrip",
        [
          test_case "append persists mentions" `Quick
            test_append_persists_mentions;
          test_case "extra mentions merge" `Quick test_extra_mentions_merge;
        ] );
    ]
