(* RFC-0232 P4: boundary mention parse + persisted mentions + backfill.

   Pinned here:
   1. Parser goldens — the boundary tokenizer keeps the legacy
      token-equality contract (@alicex / email@alice.com never hit
      "@alice") and adds canonical minting ("@keeper-alice"
      reaches "alice": the documented widening).
   2. Legacy decision equivalence — the deleted read-time
      [line_mentions] is replicated verbatim as an oracle; over a
      corpus of contents and target sets, parse-then-match must agree
      with it everywhere (the corpus avoids keeper-shaped @-tokens,
      which are the documented widening, pinned separately).
   3. Store roundtrip — append parses at the boundary and [load]
      returns the persisted ids; pre-P4 rows read as [].
   4. Backfill — stamps exactly the user rows that need it,
      byte-preserves everything else, and is idempotent. *)

open Alcotest

module Lane = Masc.Keeper_lane_mentions
module Kid = Masc.Keeper_identity.Keeper_id
module Store = Masc.Keeper_chat_store
module Backfill = Masc.Keeper_chat_backfill

let ids = list string

let parse content =
  Lane.mention_ids_of_content content |> List.map Kid.to_string

(* ── 1. Parser goldens ── *)

let test_parser_goldens () =
  check ids "plain mention" [ "alice" ] (parse "hey @alice look");
  check ids "different token" [ "alicex" ] (parse "ping @alicex now");
  check ids "email is one token" [] (parse "send to email@alice.com");
  check ids "case folded" [ "alice" ] (parse "PING @ALICE NOW");
  check ids "trailing punctuation" [ "alice" ] (parse "ok @alice, thanks");
  check ids "no mention" [] (parse "just chatting here");
  check ids "newline separated" [ "alice" ] (parse "line one\n@alice two");
  check ids "deduplicated" [ "alice" ] (parse "@alice and @alice again");
  check ids "two distinct"
    [ "alice"; "sangsu" ]
    (parse "@sangsu and @alice please");
  check ids "keeper-shaped form canonicalizes (documented widening)"
    [ "alice" ]
    (parse "cc @keeper-alice");
  (* Apostrophe is an internal (kept) character — "@sangsu's" is its own
     token and never reaches "sangsu"; same as the legacy tokenizer. *)
  check ids "possessive stays distinct" [ "sangsu's" ] (parse "@sangsu's note")

(* ── 2. Legacy decision equivalence ── *)

(* Verbatim replica of the deleted read-time tokenizer + decision. *)
let legacy_trim_token_edges s =
  let is_word c =
    (c >= 'a' && c <= 'z')
    || (c >= '0' && c <= '9')
    || c = '@'
    || c = '_'
    || c = '-'
  in
  let n = String.length s in
  let i = ref 0 in
  let j = ref (n - 1) in
  while !i < n && not (is_word s.[!i]) do
    incr i
  done;
  while !j >= !i && not (is_word s.[!j]) do
    decr j
  done;
  if !j < !i then "" else String.sub s !i (!j - !i + 1)

let legacy_line_mentions ~targets content =
  let needles =
    List.filter_map
      (fun target ->
        let t = String.lowercase_ascii (String.trim target) in
        if t = "" then None else Some ("@" ^ t))
      targets
  in
  if needles = [] then false
  else (
    let normalized =
      String.map
        (fun c ->
          match c with
          | '\t' | '\n' | '\r' -> ' '
          | _ -> c)
        (String.lowercase_ascii content)
    in
    String.split_on_char ' ' normalized
    |> List.exists (fun token -> List.mem (legacy_trim_token_edges token) needles))

let corpus_contents =
  [ "hey @alice look"
  ; "ping @alicex now"
  ; "send to email@alice.com"
  ; "PING @DREAMER NOW"
  ; "ok @alice, thanks"
  ; "just chatting here"
  ; "@sangsu and @alice please"
  ; "@analyst: status?"
  ; "tab\t@alice\tseparated"
  ; "(@alice)"
  ; "@@alice double at"
  ; "@ bare at"
  ; ""
  ; "   "
  ; "@vincent are you there"
  ; "mid@alice token"
  ; "@alice."
  ; "...@sangsu..."
  ]

let corpus_target_sets =
  [ [ "alice" ]
  ; [ "sangsu" ]
  ; [ "alice"; "sangsu" ]
  ; [ "analyst" ]
  ; [ "vincent" ]
  ; []
  ; [ "" ]
  ; [ "DREAMER" ]
  ]

let test_legacy_equivalence () =
  List.iter
    (fun content ->
      List.iter
        (fun targets ->
          let expected = legacy_line_mentions ~targets content in
          let actual =
            Lane.ids_match
              ~target_ids:(Lane.target_ids_of targets)
              (Lane.mention_ids_of_content content)
          in
          check bool
            (Printf.sprintf "targets=[%s] content=%S"
               (String.concat ";" targets)
               content)
            expected actual)
        corpus_target_sets)
    corpus_contents

(* ── 3. Store roundtrip ── *)

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
        ~content:"@alice please look at @sangsu note" ();
      Store.append_turn ~base_dir:base ~keeper_name:"alice"
        ~user_content:"thanks @analyst" ~user_attachments:[]
        ~assistant_content:"done" ();
      match Store.load ~base_dir:base ~keeper_name:"alice" with
      | [ first; second; third ] ->
          check ids "user message mentions"
            [ "alice"; "sangsu" ]
            (message_mentions first);
          check ids "turn user line mentions" [ "analyst" ]
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

let test_pre_p4_row_reads_empty () =
  with_base "lane-mentions-prep4" (fun base ->
      (* A pre-P4 row: no [mentions] field even though the content has
         an @-token.  Reads as [] — exactly the gap the backfill closes. *)
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"seed" ();
      let dir =
        Filename.concat
          (Filename.concat base ".masc")
          "keeper_chat"
      in
      let path = Filename.concat dir "alice.jsonl" in
      let oc = open_out_gen [ Open_append ] 0o644 path in
      output_string oc
        "{\"role\":\"user\",\"content\":\"@alice legacy row\",\"ts\":2.0}\n";
      close_out oc;
      match Store.load ~base_dir:base ~keeper_name:"alice" with
      | [ _seed; legacy ] ->
          check ids "absent field decodes as no mentions" []
            (message_mentions legacy)
      | other -> failf "expected 2 lane lines, got %d" (List.length other))

(* ── 4. Backfill ── *)

let test_backfill_line () =
  (match
     Backfill.backfill_line
       "{\"role\":\"user\",\"content\":\"@alice legacy\",\"ts\":2.0}"
   with
   | Backfill.Line_rewritten line ->
     check string "legacy user row with mention is stamped"
       "{\"role\":\"user\",\"content\":\"@alice legacy\",\"ts\":2.0,\"mentions\":[\"alice\"]}"
       line
   | Backfill.Line_unchanged -> fail "legacy user row was not stamped"
   | Backfill.Line_error message -> fail ("unexpected line error: " ^ message));
  (match
     Backfill.backfill_line
       "{\"role\":\"user\",\"content\":\"no tokens\",\"ts\":2.0}"
   with
   | Backfill.Line_unchanged -> ()
   | Backfill.Line_rewritten _ -> fail "mention-free row rewritten"
   | Backfill.Line_error message -> fail ("unexpected line error: " ^ message));
  (match
     Backfill.backfill_line
       "{\"role\":\"user\",\"content\":\"@alice x\",\"ts\":2.0,\"mentions\":[]}"
   with
   | Backfill.Line_unchanged -> ()
   | Backfill.Line_rewritten _ -> fail "already-stamped row rewritten"
   | Backfill.Line_error message -> fail ("unexpected line error: " ^ message));
  (match
     Backfill.backfill_line
       "{\"role\":\"assistant\",\"content\":\"@alice x\",\"ts\":2.0}"
   with
   | Backfill.Line_unchanged -> ()
   | Backfill.Line_rewritten _ -> fail "assistant row rewritten"
   | Backfill.Line_error message -> fail ("unexpected line error: " ^ message));
  match Backfill.backfill_line "not json at all" with
  | Backfill.Line_error message ->
    check bool "garbage line reports invalid json" true
      (String.length message > 0)
  | Backfill.Line_unchanged -> fail "garbage line reported unchanged"
  | Backfill.Line_rewritten _ -> fail "garbage line rewritten"

let test_backfill_file_idempotent () =
  with_base "lane-mentions-backfill" (fun base ->
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"seed" ();
      let dir =
        Filename.concat (Filename.concat base ".masc") "keeper_chat"
      in
      let path = Filename.concat dir "alice.jsonl" in
      let oc = open_out_gen [ Open_append ] 0o644 path in
      output_string oc
        "{\"role\":\"user\",\"content\":\"@alice legacy row\",\"ts\":2.0}\n";
      output_string oc "{\"role\":\"assistant\",\"content\":\"hi\",\"ts\":3.0}\n";
      close_out oc;
      let dry =
        match Backfill.backfill_file ~dry_run:true path with
        | Ok report -> report
        | Error errors ->
          failf "dry-run backfill failed with %d error(s)" (List.length errors)
      in
      check int "dry-run counts" 1 dry.rewritten;
      let wet =
        match Backfill.backfill_file ~dry_run:false path with
        | Ok report -> report
        | Error errors ->
          failf "wet backfill failed with %d error(s)" (List.length errors)
      in
      check int "stamped" 1 wet.rewritten;
      (* The stamped row now registers as a pending mention through the
         normal load path. *)
      (match Store.load ~base_dir:base ~keeper_name:"alice" with
       | [ _seed; legacy; _assistant ] ->
           check ids "stamped row reads back" [ "alice" ]
             (message_mentions legacy)
       | other -> failf "expected 3 lane lines, got %d" (List.length other));
      let again =
        match Backfill.backfill_file ~dry_run:false path with
        | Ok report -> report
        | Error errors ->
          failf "second backfill failed with %d error(s)" (List.length errors)
      in
      check int "idempotent" 0 again.rewritten)

let test_backfill_file_reports_invalid_json () =
  with_base "lane-mentions-backfill-invalid" (fun base ->
      Store.append_user_message ~base_dir:base ~keeper_name:"alice"
        ~content:"seed" ();
      let dir =
        Filename.concat (Filename.concat base ".masc") "keeper_chat"
      in
      let path = Filename.concat dir "alice.jsonl" in
      let oc = open_out_gen [ Open_append ] 0o644 path in
      output_string oc
        "{\"role\":\"user\",\"content\":\"@alice legacy row\",\"ts\":2.0}\n";
      output_string oc "not json at all\n";
      close_out oc;
      match Backfill.backfill_file ~dry_run:false path with
      | Ok _ -> fail "invalid JSON row did not fail the file backfill"
      | Error [ error ] ->
        check int "line number" 3 error.Backfill.line_no;
        check bool "path retained" true (String.equal path error.Backfill.path);
        check bool "message retained" true (String.length error.Backfill.message > 0)
      | Error errors ->
        failf "expected one file error, got %d" (List.length errors))

let () =
  Random.self_init ();
  run "keeper_lane_mentions"
    [
      ("parser", [ test_case "goldens" `Quick test_parser_goldens ]);
      ( "legacy_equivalence",
        [ test_case "corpus matrix" `Quick test_legacy_equivalence ] );
      ( "store_roundtrip",
        [
          test_case "append persists mentions" `Quick
            test_append_persists_mentions;
          test_case "extra mentions merge" `Quick test_extra_mentions_merge;
          test_case "pre-P4 row reads empty" `Quick
            test_pre_p4_row_reads_empty;
        ] );
      ( "backfill",
        [
          test_case "line" `Quick test_backfill_line;
          test_case "file + idempotence" `Quick
            test_backfill_file_idempotent;
          test_case "file reports invalid JSON" `Quick
            test_backfill_file_reports_invalid_json;
        ] );
    ]
