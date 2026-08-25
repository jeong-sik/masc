(* Slack_user_directory — cache, label precedence and mention rewriting
   (issue #28376). Fetch and clock are injected, so every case is
   deterministic: the fake fetch counts its calls and the fake clock is a
   mutable ref. *)

open Alcotest
module D = Slack_user_directory
module R = Slack_rest_client

let info ?name ?real_name ?display_name user_id : R.user_info_ok =
  { user_id; name; real_name; display_name }

let directory ?success_ttl_sec ?failure_ttl_sec ~now_ref responses =
  let calls = ref 0 in
  let fetch ~user_id =
    incr calls;
    match List.assoc_opt user_id responses with
    | Some result -> result
    | None -> Error (R.Slack_api { error = "user_not_found" })
  in
  ( D.create ?success_ttl_sec ?failure_ttl_sec ~fetch
      ~now:(fun () -> !now_ref)
      ()
  , calls )

let test_label_precedence () =
  check (option string) "display_name wins" (Some "Vincent")
    (D.label_of_user_info
       (info ~name:"vincent" ~real_name:"윤정식" ~display_name:"Vincent" "U1"));
  check (option string) "real_name next" (Some "윤정식")
    (D.label_of_user_info (info ~name:"vincent" ~real_name:"윤정식" "U1"));
  check (option string) "legacy handle last" (Some "vincent")
    (D.label_of_user_info (info ~name:"vincent" "U1"));
  check (option string) "no usable name" None (D.label_of_user_info (info "U1"))

let test_success_is_cached_within_ttl () =
  let now_ref = ref 1000.0 in
  let t, calls =
    directory ~now_ref [ ("U1", Ok (info ~display_name:"Vincent" "U1")) ]
  in
  check (option string) "first lookup fetches" (Some "Vincent")
    (D.display_label t ~user_id:"U1");
  check (option string) "second lookup serves cache" (Some "Vincent")
    (D.display_label t ~user_id:"U1");
  check int "one fetch for two lookups" 1 !calls;
  now_ref := 1000.0 +. D.default_success_ttl_sec +. 1.0;
  check (option string) "expired entry refetches" (Some "Vincent")
    (D.display_label t ~user_id:"U1");
  check int "expiry caused the second fetch" 2 !calls

let test_failure_is_cached_on_its_own_ttl () =
  let now_ref = ref 1000.0 in
  let t, calls =
    directory ~now_ref [ ("U1", Error (R.Slack_api { error = "missing_scope" })) ]
  in
  check (option string) "failed lookup renders raw id" None
    (D.display_label t ~user_id:"U1");
  check (option string) "failure serves from cache" None
    (D.display_label t ~user_id:"U1");
  check int "no refetch inside the failure ttl" 1 !calls;
  now_ref := 1000.0 +. D.default_failure_ttl_sec +. 1.0;
  ignore (D.display_label t ~user_id:"U1");
  check int "failure ttl expiry retries" 2 !calls

let test_mention_rewrite () =
  let now_ref = ref 0.0 in
  let t, _ =
    directory ~now_ref
      [ ("U09L0RHPW7P", Ok (info ~display_name:"Vincent" "U09L0RHPW7P"))
      ; ("U060QL6SV1V", Ok (info ~real_name:"KinoBot" "U060QL6SV1V"))
      ]
  in
  check string "resolved mention becomes a name"
    "@KinoBot 뭔데"
    (D.rewrite_mentions t "<@U060QL6SV1V> 뭔데");
  check string "multiple mentions in one message"
    "@Vincent님, @KinoBot 확인 부탁"
    (D.rewrite_mentions t "<@U09L0RHPW7P>님, <@U060QL6SV1V> 확인 부탁");
  check string "labelled escape uses the supplied label without a fetch"
    "@alice 안녕"
    (D.rewrite_mentions t "<@U000UNKNOWN0|alice> 안녕");
  check string "unresolvable mention keeps its exact wire form"
    "<@U000UNKNOWN0> ping"
    (D.rewrite_mentions t "<@U000UNKNOWN0> ping");
  check string "channel, special and link escapes pass through"
    "<#C123|general> <!here> <https://example.com|link>"
    (D.rewrite_mentions t "<#C123|general> <!here> <https://example.com|link>");
  check string "text without mentions is unchanged"
    "plain @text < unrelated >"
    (D.rewrite_mentions t "plain @text < unrelated >")

let test_empty_user_id_never_fetches () =
  let now_ref = ref 0.0 in
  let t, calls = directory ~now_ref [ ("U1", Ok (info ~display_name:"Vincent" "U1")) ] in
  check (option string) "empty id resolves to nothing" None (D.display_label t ~user_id:"");
  check int "empty id never fetches" 0 !calls;
  (* The guard must not poison the cache under the empty key: the next real id
     still reaches the fetch. *)
  check (option string) "a real id still resolves" (Some "Vincent")
    (D.display_label t ~user_id:"U1");
  check int "the real id is the first fetch" 1 !calls

let test_mention_rewrite_malformed_tokens_pass_through () =
  let now_ref = ref 0.0 in
  let t, calls = directory ~now_ref [] in
  check string "unterminated mention stays verbatim" "<@U123"
    (D.rewrite_mentions t "<@U123");
  check string "empty label keeps the wire form" "<@U000UNKNOWN0|> hi"
    (D.rewrite_mentions t "<@U000UNKNOWN0|> hi");
  check string "short id stays verbatim" "<@U> hi"
    (D.rewrite_mentions t "<@U> hi");
  check int "malformed tokens never fetch" 0 !calls

let () =
  run "slack_user_directory"
    [
      ( "labels",
        [ test_case "precedence" `Quick test_label_precedence ] );
      ( "cache",
        [
          test_case "success ttl" `Quick test_success_is_cached_within_ttl;
          test_case "failure ttl" `Quick test_failure_is_cached_on_its_own_ttl;
        ] );
      ( "mentions",
        [
          test_case "rewrite" `Quick test_mention_rewrite;
          test_case "malformed tokens pass through" `Quick
            test_mention_rewrite_malformed_tokens_pass_through;
          test_case "empty user id never fetches" `Quick
            test_empty_user_id_never_fetches;
        ] );
    ]
