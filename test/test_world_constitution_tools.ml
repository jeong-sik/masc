(** The keeper tools that write and take back a world's norms (RFC-0442). *)

module Tools = Masc.Keeper_tool_constitution_runtime
module Store = Masc.World_constitution_store
module Types = Masc.World_constitution_types
module Render = Masc.World_constitution_render
module Execution = Masc.Keeper_tool_execution

let repo_source_root () =
  match Sys.getenv_opt "DUNE_SOURCEROOT" with
  | Some root -> root
  | None -> Sys.getcwd ()

let () =
  Prompt_registry.set_markdown_dir
    (Filename.concat (repo_source_root ()) "config/prompts");
  Masc.Prompt_defaults.init ()
;;

let make_meta name =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc [ "name", `String name; "trace_id", `String ("trace-" ^ name) ])
  with
  | Error error -> Alcotest.fail ("meta fixture failed: " ^ error)
  | Ok meta -> meta

(* Durable metadata names form the roster, independently of whether the live
   registry can currently operate the Keeper. *)
let with_world f =
  let dir = Filename.temp_file "world-constitution-tools-" ".tmp" in
  Sys.remove dir;
  Unix.mkdir dir 0o700;
  let register keeper =
    let config = Masc.Workspace.default_config dir in
    let path = Masc.Keeper_types_profile.keeper_meta_path config keeper in
    Yojson.Safe.to_file path (Masc.Keeper_meta_json.meta_to_json (make_meta keeper));
    ignore
      (Masc.Keeper_registry.For_testing.register ~base_path:dir keeper
         (make_meta keeper))
  in
  let unregister keeper =
    Masc.Keeper_registry.For_testing.unregister ~base_path:dir keeper
  in
  register "lane-smith";
  register "critic";
  Fun.protect
    ~finally:(fun () ->
      unregister "lane-smith";
      unregister "critic";
      Fs_compat.remove_tree dir)
    (fun () -> f dir)

let failed execution =
  match execution.Execution.disposition with
  | Tool_result.Failed _ -> true
  | Tool_result.Completed () | Tool_result.Deferred () -> false

let output execution = execution.Execution.raw_output

(* Whose it is to fix: a refused sentence or id is the caller's
   (policy_rejection), a full world is a state to change first
   (workflow_rejection). *)
let failure_class execution =
  match execution.Execution.disposition with
  | Tool_result.Failed failure_class ->
    Some (Tool_result.tool_failure_class_to_string failure_class)
  | Tool_result.Completed () | Tool_result.Deferred () -> None

let write ~base_path ?(keeper = "lane-smith") args =
  Tools.write_with_outcome
    ~config:(Masc.Workspace.default_config base_path)
    ~meta:(make_meta keeper) ~args

let remove ~base_path ?(keeper = "critic") ?reason article_id =
  Tools.remove_with_outcome
    ~config:(Masc.Workspace.default_config base_path)
    ~meta:(make_meta keeper)
    ~args:(`Assoc
      ([ "article_id", `String article_id ]
       @ match reason with None -> [] | Some value -> [ "reason", `String value ]))

let held ~base_path =
  match Store.load ~base_path ~resolve_subject:(fun _ -> true) with
  | Ok ledger -> ledger.Store.articles
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let entries ~base_path =
  match Store.load ~base_path ~resolve_subject:(fun _ -> true) with
  | Ok ledger -> ledger.Store.entries
  | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)

let contains ~sub s =
  let n = String.length s and m = String.length sub in
  let rec scan i =
    i + m <= n && (String.equal (String.sub s i m) sub || scan (i + 1))
  in
  m = 0 || scan 0

let article_id_of execution =
  match Yojson.Safe.from_string (output execution) with
  | `Assoc fields -> (
    match List.assoc_opt "article_id" fields with
    | Some (`String id) -> id
    | _ -> Alcotest.failf "no article_id in %s" (output execution))
  | _ -> Alcotest.failf "unexpected output %s" (output execution)

let test_a_written_norm_reaches_the_rendered_articles () =
  with_world (fun base_path ->
      let execution =
        write ~base_path
          (`Assoc [ "text", `String "open before you record" ])
      in
      Alcotest.(check bool) "the write succeeded" false (failed execution);
      (* The seam this closes: the tool wrote into the world's own ledger, and
         what the prompt slot renders comes back out of that same ledger. *)
      let rendered = Render.articles (held ~base_path) in
      Alcotest.(check bool)
        "the norm is in what the prompt would render" true
        (Option.is_some
           (let sub = "open before you record" in
            let n = String.length rendered and m = String.length sub in
            let rec scan i =
              if i + m > n then None
              else if String.equal (String.sub rendered i m) sub then Some i
              else scan (i + 1)
            in
            scan 0));
      match held ~base_path with
      | [ article ] ->
        Alcotest.(check string) "the caller is recorded as author" "lane-smith"
          article.Types.author
      | others ->
        Alcotest.failf "expected one article, got %d" (List.length others))

(* The seam every earlier test stopped short of: the tool writes, and the
   prompt a real turn is built from renders it. Between them sit the ledger,
   the fold, the render and the slot, each proven alone. *)
let test_a_written_norm_reaches_the_turn_prompt () =
  with_world (fun base_path ->
      let config = Masc.Workspace.default_config base_path in
      let meta = make_meta "prompt-reader" in
      let prompt () =
        match Masc.Keeper_unified_prompt.build_system_prompt
          ~workspace_root:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta) ~meta ~config () with
        | Ok prompt -> prompt
        | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)
      in
      let check_guidance stage prompt =
        List.iter
          (fun instruction ->
            Alcotest.(check bool) (stage ^ ": " ^ instruction) true
              (contains ~sub:instruction prompt))
          [ "keeper_constitution_write"; "keeper_constitution_remove";
            "keeper_constitution_read"; "reason 한 줄" ]
      in
      let before = prompt () in
      check_guidance "fresh world" before;
      Alcotest.(check bool)
        "the norm is absent before anyone writes it" false
        (contains ~sub:"open before you record" before);
      let execution =
        write ~base_path (`Assoc [ "text", `String "open before you record" ])
      in
      Alcotest.(check bool) "the write succeeded" false (failed execution);
      let id = article_id_of execution in
      let after = prompt () in
      check_guidance "world with an article" after;
      Alcotest.(check bool)
        "the norm is in the prompt a turn would be built from" true
        (contains ~sub:"open before you record" after);
      Alcotest.(check bool)
        "and so is the id needed to take it back" true
        (contains ~sub:id after);
      Alcotest.(check bool) "the removal succeeded" false
        (failed (remove ~base_path id));
      let after_removal = prompt () in
      check_guidance "final article removed" after_removal;
      Alcotest.(check bool)
        "taking it back stops it reaching the prompt" false
        (contains ~sub:"open before you record" after_removal))

let test_an_empty_norm_is_refused () =
  with_world (fun base_path ->
      Alcotest.(check (option string))
        "a blank sentence is refused as the caller's to correct"
        (Some "policy_rejection")
        (failure_class (write ~base_path (`Assoc [ "text", `String "   " ])));
      Alcotest.(check (option string))
        "a missing sentence is refused as the caller's to correct"
        (Some "policy_rejection")
        (failure_class (write ~base_path (`Assoc [])));
      Alcotest.(check int) "nothing was written" 0
        (List.length (held ~base_path)))

let test_the_byte_ceiling_blocks_the_write_that_would_cross_it () =
  with_world (fun base_path ->
      let line = String.make 200 'x' in
      let rec fill written =
        let execution = write ~base_path (`Assoc [ "text", `String line ]) in
        if failed execution then (written, execution)
        else if written > 100 then
          Alcotest.fail "the ceiling never blocked a write"
        else fill (written + 1)
      in
      let written, blocked = fill 0 in
      Alcotest.(check bool) "some writes landed first" true (written > 0);
      Alcotest.(check (option string))
        "a full world is a state to change first, not a bad sentence"
        (Some "workflow_rejection")
        (failure_class blocked);
      let rendered = Render.articles (held ~base_path) in
      Alcotest.(check bool)
        (Printf.sprintf "held articles stay under the ceiling (%d bytes)"
           (String.length rendered))
        true
        (String.length rendered <= Tools.render_byte_ceiling);
      Alcotest.(check int) "the blocked write added nothing" written
        (List.length (held ~base_path)))

let test_the_byte_ceiling_is_the_agreed_12288 () =
  Alcotest.(check int) "the world's article ceiling is 12288 bytes" 12288
    Tools.render_byte_ceiling

let test_the_byte_ceiling_admits_a_render_of_exactly_the_ceiling () =
  with_world (fun base_path ->
      let ceiling = Tools.render_byte_ceiling in
      (* The runtime refuses a single article over 512 bytes; fill with
         200-byte lines until one more such article could not fit, so the next
         write can land exactly on the ceiling. *)
      let article_cap = 512 in
      let line = String.make 200 'x' in
      let rec fill () =
        let rendered = String.length (Render.articles (held ~base_path)) in
        if rendered >= ceiling - 40 - article_cap then ()
        else (
          let execution = write ~base_path (`Assoc [ "text", `String line ]) in
          Alcotest.(check bool) "filling stays under the ceiling" false
            (failed execution);
          fill ())
      in
      fill ();
      let rendered = String.length (Render.articles (held ~base_path)) in
      (* A new article costs one LF, "- [", the 34-char id, "] " and its text. *)
      let text_len = ceiling - rendered - 40 in
      Alcotest.(check bool)
        (Printf.sprintf "room for one single-sentence article (%d bytes)" text_len)
        true (text_len >= 1 && text_len <= article_cap);
      let at_ceiling =
        write ~base_path (`Assoc [ "text", `String (String.make text_len 'y') ])
      in
      Alcotest.(check bool) "a render of exactly the ceiling is admitted" false
        (failed at_ceiling);
      Alcotest.(check int) "the render lands exactly on the ceiling" ceiling
        (String.length (Render.articles (held ~base_path)));
      let over = write ~base_path (`Assoc [ "text", `String "z" ]) in
      Alcotest.(check bool) "one byte over the ceiling is refused" true
        (failed over);
      Alcotest.(check (option string)) "a full world is a state to change first"
        (Some "workflow_rejection") (failure_class over))

let test_a_norm_longer_than_one_sentence_is_refused () =
  with_world (fun base_path ->
      let execution =
        write ~base_path
          (`Assoc [ "text", `String (String.make 600 'x') ])
      in
      Alcotest.(check bool) "an overlong norm is refused" true
        (failed execution);
      (* The ceiling message would tell a keeper to remove something from an
         empty world; this one says what the keeper can actually change. *)
      Alcotest.(check bool)
        (Printf.sprintf "and says to shorten it (%s)" (output execution))
        true
        (contains ~sub:"one sentence" (output execution));
      Alcotest.(check int) "nothing was written" 0
        (List.length (held ~base_path)))

let test_evidence_uri_reaches_the_ledger () =
  with_world (fun base_path ->
      let execution =
        write ~base_path
          (`Assoc
            [ "text", `String "a norm the board argued out"
            ; "evidence_uri", `String "c-0123456789abcdef0123456789abcdef"
            ])
      in
      Alcotest.(check bool) "the write succeeded" false (failed execution);
      (match held ~base_path with
       | [ article ] -> (
         match article.Types.evidence with
         | [ { Types.uri } ] ->
           Alcotest.(check string) "the coordinate survives a round trip"
             "c-0123456789abcdef0123456789abcdef" uri
         | others ->
           Alcotest.failf "expected one evidence row, got %d"
             (List.length others))
       | others ->
         Alcotest.failf "expected one article, got %d" (List.length others));
      (* A blank coordinate is a rejection, not a silently dropped argument. *)
      Alcotest.(check bool)
        "a blank evidence_uri fails the write" true
        (failed
           (write ~base_path
              (`Assoc
                [ "text", `String "another norm"
                ; "evidence_uri", `String "  "
                ]))))

let test_unreadable_lines_are_reported_to_the_caller () =
  with_world (fun base_path ->
      (* The first write creates the directory; the broken line goes in after
         it, so the reported line number is the second. *)
      ignore (write ~base_path (`Assoc [ "text", `String "a readable norm" ]));
      let channel =
        open_out_gen [ Open_append; Open_creat; Open_text ] 0o600
          (Store.ledger_path ~base_path)
      in
      output_string channel "{\"kind\":\"added\",\"article\":{}}\n";
      close_out channel;
      let execution = write ~base_path (`Assoc [ "text", `String "a norm" ]) in
      Alcotest.(check bool) "the write still succeeds" false (failed execution);
      match Yojson.Safe.from_string (output execution) with
      | `Assoc fields -> (
        match List.assoc_opt "unreadable_ledger_lines" fields with
        | Some (`List [ `Assoc row ]) ->
          Alcotest.(check bool)
            "the caller is told which line" true
            (List.assoc_opt "line" row = Some (`Int 2))
        | Some other ->
          Alcotest.failf "unexpected shape %s" (Yojson.Safe.to_string other)
        | None ->
          Alcotest.failf "the unreadable line was not reported: %s"
            (output execution))
      | _ -> Alcotest.failf "unexpected output %s" (output execution))

let test_removing_takes_the_norm_out () =
  with_world (fun base_path ->
      let execution =
        write ~base_path (`Assoc [ "text", `String "a norm to take back" ])
      in
      let id = article_id_of execution in
      Alcotest.(check bool) "the removal succeeded" false
        (failed (remove ~base_path id));
      Alcotest.(check int) "the world holds nothing" 0
        (List.length (held ~base_path));
      Alcotest.(check string) "and renders nothing" ""
        (Render.articles (held ~base_path)))

let test_removing_an_id_the_world_does_not_hold_is_a_failure () =
  with_world (fun base_path ->
      let execution = remove ~base_path ("a-" ^ String.make 32 'f') in
      Alcotest.(check (option string))
        "an id nobody wrote does not report success"
        (Some "policy_rejection")
        (failure_class execution);
      Alcotest.(check (option string))
        "a hand-written id is refused before the ledger is touched"
        (Some "policy_rejection")
        (failure_class (remove ~base_path "a-placeholder")))

let test_invalid_removal_reasons_preserve_the_ledger () =
  with_world (fun base_path ->
      let written = write ~base_path (`Assoc [ "text", `String "keep this norm" ]) in
      let id = article_id_of written in
      let ledger_path = Store.ledger_path ~base_path in
      let ledger_bytes () = In_channel.with_open_bin ledger_path In_channel.input_all in
      let before = ledger_bytes () in
      List.iter
        (fun (label, reason) ->
          let rejected = remove ~base_path ~reason id in
          Alcotest.(check (option string)) label (Some "policy_rejection")
            (failure_class rejected);
          Alcotest.(check string) (label ^ " leaves every ledger byte intact")
            before (ledger_bytes ());
          Alcotest.(check int) (label ^ " leaves the article held") 1
            (List.length (held ~base_path)))
        [ "LF", "first reason\nsecond reason"
        ; "CR", "first reason\rsecond reason"
        ; "CRLF", "first reason\r\nsecond reason"
        ; "trailing LF", "one reason\n"
        ; "blank", "  "
        ; "overlong", String.make 513 'x'
        ];
      let reason = String.make 512 'x' in
      let removed = remove ~base_path ~reason id in
      Alcotest.(check bool) "a one-line reason at the boundary succeeds" false
        (failed removed);
      Alcotest.(check int) "the accepted reason removes the article" 0
        (List.length (held ~base_path));
      match Yojson.Safe.from_string (output removed) with
      | `Assoc fields ->
          Alcotest.(check bool) "the accepted reason is returned intact" true
            (List.assoc_opt "reason" fields = Some (`String reason))
      | _ -> Alcotest.failf "unexpected output %s" (output removed))

(* #38354: a ledger that exists but cannot be read is not a world without
   norms. The prompt builder used to log and render the same text a fresh
   world gets, so the turn ran without its articles and nothing downstream
   could tell the two apart. The ledger path is made a directory: the store
   sees something there, reading it fails, and [load] answers [Unreadable]. *)
let test_an_unreadable_ledger_is_not_rendered_as_no_articles () =
  with_world (fun base_path ->
      let meta = make_meta "prompt-reader" in
      let config = Masc.Workspace.default_config base_path in
      let prompt () =
        Masc.Keeper_unified_prompt.build_system_prompt
          ~workspace_root:(Masc.Keeper_sandbox.host_root_abs_of_meta ~config meta) ~meta ~config ()
      in
      (match prompt () with
       | Ok _ -> ()
       | Error error ->
         Alcotest.failf "a world with no ledger yet has a prompt: %s"
           (Store.read_error_to_string error));
      let ledger = Store.ledger_path ~base_path in
      Fs_compat.mkdir_p ledger;
      (match prompt () with
       | Error (Store.Unreadable { path; detail = _ }) ->
         Alcotest.(check string) "the error names the ledger" ledger path
       | Ok _ -> Alcotest.fail "an unreadable ledger built a prompt");
      Unix.rmdir ledger;
      match prompt () with
      | Ok _ -> ()
      | Error error ->
        Alcotest.failf "the prompt builds again once the ledger reads: %s"
          (Store.read_error_to_string error))

(* RFC-0504 §2.2: naming held articles in [replaces] retires them and records
   the norm as their replacement. *)
let test_replacing_merges_held_norms_into_one () =
  with_world (fun base_path ->
      let first =
        write ~base_path (`Assoc [ "text", `String "the first overlapping norm" ])
      in
      let second =
        write ~base_path (`Assoc [ "text", `String "the second overlapping norm" ])
      in
      let first_id = article_id_of first in
      let second_id = article_id_of second in
      let merged =
        write ~base_path
          (`Assoc
            [ "text", `String "the merged norm"
            ; "replaces", `List [ `String first_id; `String second_id ]
            ; "reason", `String "the board merged the twins"
            ])
      in
      Alcotest.(check bool) "the merge succeeded" false (failed merged);
      (match held ~base_path with
      | [ article ] ->
        Alcotest.(check string) "the replacement is what is held" "the merged norm"
          article.Types.text
      | others ->
        Alcotest.failf "expected one article, got %d" (List.length others));
      (match List.rev (entries ~base_path) with
      | Types.Replaced { superseded; article; by; reason; _ } :: _ ->
        Alcotest.(check (list string))
          "the ledger keeps which norms were retired in the order named"
          [ first_id; second_id ]
          (List.map Types.Article_id.to_string superseded);
        Alcotest.(check string) "the replacer is recorded" "lane-smith" by;
        Alcotest.(check (option string))
          "the reason is recorded" (Some "the board merged the twins") reason;
        Alcotest.(check string) "the replacement text is recorded" "the merged norm"
          article.Types.text
      | _ -> Alcotest.fail "the last ledger line is not the replacement");
      match Yojson.Safe.from_string (output merged) with
      | `Assoc fields ->
        Alcotest.(check bool) "the answer counts one held norm" true
          (List.assoc_opt "articles_held" fields = Some (`Int 1))
      | _ -> Alcotest.failf "unexpected output %s" (output merged))

let test_replacing_an_unheld_or_doubled_id_is_a_failure () =
  with_world (fun base_path ->
      let written =
        write ~base_path (`Assoc [ "text", `String "a norm that stays" ])
      in
      let id = article_id_of written in
      let missing = "a-" ^ String.make 32 'f' in
      let attempt label replaces =
        let execution =
          write ~base_path
            (`Assoc
              [ "text", `String "a merge that must not land"
              ; "replaces", `List (List.map (fun s -> `String s) replaces)
              ])
        in
        Alcotest.(check (option string)) label (Some "policy_rejection")
          (failure_class execution)
      in
      attempt "an id nobody wrote is refused" [ missing ];
      attempt "a held id beside a missing one is refused" [ id; missing ];
      attempt "naming one id twice is refused" [ id; id ];
      Alcotest.(check (list string)) "nothing was retired" [ "a norm that stays" ]
        (List.map (fun (a : Types.t) -> a.Types.text) (held ~base_path));
      Alcotest.(check int) "nothing was appended" 1
        (List.length (entries ~base_path)))

let test_malformed_replaces_is_refused_before_the_ledger_is_touched () =
  with_world (fun base_path ->
      let attempt label replaces =
        let execution =
          write ~base_path
            (`Assoc [ "text", `String "a norm"; "replaces", replaces ])
        in
        Alcotest.(check (option string)) label (Some "policy_rejection")
          (failure_class execution)
      in
      attempt "replaces must be an array"
        (`String "a-0123456789abcdef0123456789abcdef");
      attempt "replaces items must be strings" (`List [ `Int 7 ]);
      attempt "replaces items must be minted ids"
        (`List [ `String "a-placeholder" ]);
      Alcotest.(check int) "nothing was written" 0
        (List.length (held ~base_path)))

(* RFC-0504 §2.3: the replacement must render smaller than the bundle it
   retires, while the render stays within the ceiling. The per-article cap
   does not bind a merge. *)
let test_a_merge_must_shrink_the_render () =
  with_world (fun base_path ->
      let first = write ~base_path (`Assoc [ "text", `String "aa" ]) in
      let second = write ~base_path (`Assoc [ "text", `String "bb" ]) in
      let grown =
        write ~base_path
          (`Assoc
            [ "text", `String (String.make 200 'x')
            ; "replaces",
              `List [ `String (article_id_of first); `String (article_id_of second) ]
            ])
      in
      Alcotest.(check bool) "a merge that grows the render is refused" true
        (failed grown);
      Alcotest.(check (option string)) "growing the render is the caller's to fix"
        (Some "policy_rejection") (failure_class grown);
      Alcotest.(check int) "nothing was retired" 2 (List.length (held ~base_path)))

let test_a_merge_is_not_bound_by_the_per_article_cap () =
  with_world (fun base_path ->
      let first =
        write ~base_path (`Assoc [ "text", `String (String.make 400 'a') ])
      in
      let second =
        write ~base_path (`Assoc [ "text", `String (String.make 400 'b') ])
      in
      Alcotest.(check bool) "the bundle writes succeeded" false
        (failed first || failed second);
      let merged =
        write ~base_path
          (`Assoc
            [ "text", `String (String.make 600 'm')
            ; "replaces",
              `List [ `String (article_id_of first); `String (article_id_of second) ]
            ])
      in
      Alcotest.(check bool) "a 600-byte merge lands" false (failed merged);
      Alcotest.(check int) "one norm is held" 1 (List.length (held ~base_path)))

let test_reason_is_refused_on_a_plain_write () =
  with_world (fun base_path ->
      let execution =
        write ~base_path
          (`Assoc [ "text", `String "a norm"; "reason", `String "no bundle" ])
      in
      Alcotest.(check (option string)) "a reason without a bundle is refused"
        (Some "policy_rejection") (failure_class execution);
      Alcotest.(check int) "nothing was written" 0
        (List.length (held ~base_path)))

let test_null_or_empty_replaces_writes_a_plain_norm () =
  with_world (fun base_path ->
      let plain =
        write ~base_path (`Assoc [ "text", `String "first"; "replaces", `Null ])
      in
      let empty =
        write ~base_path (`Assoc [ "text", `String "second"; "replaces", `List [] ])
      in
      Alcotest.(check bool) "null replaces writes" false (failed plain);
      Alcotest.(check bool) "empty replaces writes" false (failed empty);
      Alcotest.(check int) "two norms are held" 2 (List.length (held ~base_path));
      (match entries ~base_path with
      | [ Types.Added _; Types.Added _ ] -> ()
      | others ->
        Alcotest.failf "expected two plain additions, got %d entries"
          (List.length others)))

(* A merge that leaves the world over the ceiling is refused like any other
   crossing write — reachable only when the ledger already exceeds it, since
   a merge shrinks the render. *)
let test_a_merge_over_the_ceiling_is_refused () =
  with_world (fun base_path ->
      let make_big author text =
        match
          Types.make ~id:(Types.Article_id.generate ()) ~text ~author ~at:1.0
            ~evidence:[]
        with
        | Ok article -> article
        | Error invalid ->
          Alcotest.failf "article rejected: %s" (Types.invalid_to_string invalid)
      in
      let append entry =
        let end_offset =
          match Store.load ~base_path ~resolve_subject:(fun _ -> true) with
          | Ok ledger -> ledger.Store.end_offset
          | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)
        in
        match Store.append_at ~base_path ~expected_end_offset:end_offset entry with
        | Ok () -> ()
        | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error)
      in
      let first = make_big "lane-smith" (String.make 6500 'a') in
      let second = make_big "lane-smith" (String.make 6500 'b') in
      append (Types.Added first);
      append (Types.Added second);
      let over =
        write ~base_path
          (`Assoc
            [ "text", `String (String.make 12300 'm')
            ; "replaces",
              `List
                [ `String (Types.Article_id.to_string first.Types.id)
                ; `String (Types.Article_id.to_string second.Types.id)
                ]
            ])
      in
      Alcotest.(check bool) "the crossing merge is refused" true (failed over);
      Alcotest.(check (option string)) "a full world is a state to change first"
        (Some "workflow_rejection") (failure_class over);
      Alcotest.(check int) "nothing was retired" 2 (List.length (held ~base_path)))

(* RFC-0504 §2.4: the read reports lines from outside the roster beside the
   unreadable ones, and counts only the roster's norms as held. *)
let test_isolated_lines_are_reported_to_the_caller () =
  with_world (fun base_path ->
      ignore
        (write ~base_path (`Assoc [ "text", `String "a norm the world holds" ]));
      let outsider =
        match
          Types.make ~id:(Types.Article_id.generate ())
            ~text:"a norm from outside the tool" ~author:"codex-operator" ~at:2.0
            ~evidence:[]
        with
        | Ok article -> article
        | Error invalid ->
          Alcotest.failf "article rejected: %s" (Types.invalid_to_string invalid)
      in
      let end_offset =
        match Store.load ~base_path ~resolve_subject:(fun _ -> true) with
        | Ok ledger -> ledger.Store.end_offset
        | Error error -> Alcotest.failf "%s" (Store.read_error_to_string error)
      in
      (match
         Store.append_at ~base_path ~expected_end_offset:end_offset
           (Types.Added outsider)
       with
      | Ok () -> ()
      | Error error -> Alcotest.failf "%s" (Store.append_error_to_string error));
      let execution =
        Tools.read_with_outcome ~config:(Masc.Workspace.default_config base_path)
      in
      Alcotest.(check bool) "the read succeeds" false (failed execution);
      match Yojson.Safe.from_string (output execution) with
      | `Assoc fields -> (
        Alcotest.(check bool) "one norm is held" true
          (List.assoc_opt "articles_held" fields = Some (`Int 1));
        match List.assoc_opt "isolated_ledger_lines" fields with
        | Some (`List [ `Assoc row ]) ->
          Alcotest.(check bool) "the caller is told which line" true
            (List.assoc_opt "line" row = Some (`Int 2));
          Alcotest.(check bool) "the caller is told whose" true
            (List.assoc_opt "subject" row = Some (`String "codex-operator"));
          Alcotest.(check bool) "the caller is told which article is withheld" true
            (List.assoc_opt "article_ids" row =
               Some (`List [ `String (Types.Article_id.to_string outsider.Types.id) ]))
        | Some other ->
          Alcotest.failf "unexpected shape %s" (Yojson.Safe.to_string other)
        | None ->
          Alcotest.failf "the isolated line was not reported: %s" (output execution))
      | _ -> Alcotest.failf "unexpected output %s" (output execution))

let test_a_retired_remover_does_not_reactivate_a_withdrawn_norm () =
  with_world (fun base_path ->
      let config = Masc.Workspace.default_config base_path in
      let withdrawn =
        write ~base_path (`Assoc [ "text", `String "a norm withdrawn by a former keeper" ]) in
      let unrelated =
        write ~base_path (`Assoc [ "text", `String "an unrelated norm" ]) in
      let withdrawn_id = article_id_of withdrawn in
      let unrelated_id = article_id_of unrelated in
      Alcotest.(check bool) "the original removal succeeded" false
        (failed (remove ~base_path ~reason:"the board withdrew it" withdrawn_id));
      let original_entries = entries ~base_path in
      let ledger_bytes () =
        In_channel.with_open_bin (Store.ledger_path ~base_path) In_channel.input_all in
      let before_retirement = ledger_bytes () in
      Masc.Keeper_registry.For_testing.unregister ~base_path "critic";
      Sys.remove (Masc.Keeper_types_profile.keeper_meta_path config "critic");
      let inspect execution articles_held =
        Alcotest.(check bool) "the rostered operation succeeds" false (failed execution);
        match Yojson.Safe.from_string (output execution) with
        | `Assoc fields ->
            Alcotest.(check bool) "only current norms are counted" true
              (List.assoc_opt "articles_held" fields = Some (`Int articles_held));
            (match List.assoc_opt "isolated_ledger_lines" fields with
             | Some (`List [ `Assoc row ]) ->
                 Alcotest.(check bool) "the removal line and former keeper remain visible" true
                   (List.assoc_opt "line" row = Some (`Int 3)
                    && List.assoc_opt "subject" row = Some (`String "critic"));
                 Alcotest.(check bool) "the affected id remains visible" true
                   (List.assoc_opt "article_ids" row = Some (`List [ `String withdrawn_id ]))
             | Some other -> Alcotest.failf "unexpected isolation %s" (Yojson.Safe.to_string other)
             | None -> Alcotest.fail "the unresolved removal was not reported");
            fields
        | _ -> Alcotest.failf "unexpected output %s" (output execution)
      in
      let read = inspect (Tools.read_with_outcome ~config) 1 in
      Alcotest.(check bool) "the read retains the original addition and removal history" true
        (List.assoc_opt "entries" read =
           Some (`List (List.map Masc.World_constitution_wire.entry_to_json original_entries)));
      Alcotest.(check string) "quarantine does not rewrite the ledger"
        before_retirement (ledger_bytes ());
      Alcotest.(check (option string)) "the withheld id cannot be removed as a current norm"
        (Some "policy_rejection")
        (failure_class (remove ~base_path ~keeper:"lane-smith" withdrawn_id));
      Alcotest.(check (option string)) "the withheld id cannot authorize a replacement"
        (Some "policy_rejection")
        (failure_class
           (write ~base_path
              (`Assoc [ "text", `String "short";
                        "replaces", `List [ `String withdrawn_id ] ])));
      Alcotest.(check string) "neither refused mutation appends a retirement"
        before_retirement (ledger_bytes ());
      let (_ : (string * Yojson.Safe.t) list) =
        inspect (write ~base_path (`Assoc [ "text", `String "a newly adopted norm" ])) 2 in
      let (_ : (string * Yojson.Safe.t) list) =
        inspect (remove ~base_path ~keeper:"lane-smith" unrelated_id) 1 in
      let (_ : (string * Yojson.Safe.t) list) =
        inspect (Tools.read_with_outcome ~config) 1 in
      ())

let test_a_retained_author_survives_registry_loss_and_bad_metadata () =
  with_world (fun base_path ->
      let config = Masc.Workspace.default_config base_path in
      ignore (write ~base_path (`Assoc [ "text", `String "a retained norm" ]));
      Masc.Keeper_registry.For_testing.unregister ~base_path "lane-smith";
      let path = Masc.Keeper_types_profile.keeper_meta_path config "lane-smith" in
      let channel = open_out path in
      output_string channel "not current metadata";
      close_out channel;
      let execution = Tools.read_with_outcome ~config in
      Alcotest.(check bool) "the read succeeds" false (failed execution);
      match Yojson.Safe.from_string (output execution) with
      | `Assoc fields ->
          Alcotest.(check bool) "the retained author's norm still holds" true
            (List.assoc_opt "articles_held" fields = Some (`Int 1));
          Alcotest.(check bool) "a retained name is not an isolated subject" true
            (List.assoc_opt "isolated_ledger_lines" fields = None)
      | _ -> Alcotest.failf "unexpected output %s" (output execution))

let test_an_unreadable_roster_refuses_the_read () =
  with_world (fun base_path ->
      let config = Masc.Workspace.default_config base_path in
      let root = Masc.Workspace.keepers_runtime_dir config in
      Unix.rename root (root ^ ".retained");
      let channel = open_out root in
      close_out channel;
      let execution = Tools.read_with_outcome ~config in
      Alcotest.(check (option string)) "a roster failure is not an empty world"
        (Some "runtime_failure") (failure_class execution))

let () =
  Alcotest.run "world_constitution_tools"
    [ ( "end to end",
        [ Alcotest.test_case "a written norm reaches the turn prompt" `Quick
            test_a_written_norm_reaches_the_turn_prompt;
          Alcotest.test_case "an unreadable ledger is not rendered as no articles"
            `Quick test_an_unreadable_ledger_is_not_rendered_as_no_articles;
          Alcotest.test_case "a retained author survives unavailable runtime metadata"
            `Quick test_a_retained_author_survives_registry_loss_and_bad_metadata;
          Alcotest.test_case "a retired remover does not reactivate a withdrawn norm"
            `Quick test_a_retired_remover_does_not_reactivate_a_withdrawn_norm;
          Alcotest.test_case "an unreadable roster refuses the read"
            `Quick test_an_unreadable_roster_refuses_the_read;
        ] );
      ( "write",
        [ Alcotest.test_case "a written norm reaches the rendered articles"
            `Quick test_a_written_norm_reaches_the_rendered_articles;
          Alcotest.test_case "an empty norm is refused" `Quick
            test_an_empty_norm_is_refused;
          Alcotest.test_case "the byte ceiling blocks the crossing write" `Quick
            test_the_byte_ceiling_blocks_the_write_that_would_cross_it;
          Alcotest.test_case "the byte ceiling is the agreed 12288" `Quick
            test_the_byte_ceiling_is_the_agreed_12288;
          Alcotest.test_case "a render of exactly the ceiling is admitted"
            `Quick test_the_byte_ceiling_admits_a_render_of_exactly_the_ceiling;
          Alcotest.test_case "a norm longer than one sentence is refused"
            `Quick test_a_norm_longer_than_one_sentence_is_refused;
          Alcotest.test_case "evidence_uri reaches the ledger" `Quick
            test_evidence_uri_reaches_the_ledger;
          Alcotest.test_case "unreadable lines are reported to the caller"
            `Quick test_unreadable_lines_are_reported_to_the_caller;
          Alcotest.test_case "isolated lines are reported to the caller"
            `Quick test_isolated_lines_are_reported_to_the_caller;
        ] );
      ( "replace",
        [ Alcotest.test_case "replacing merges held norms into one" `Quick
            test_replacing_merges_held_norms_into_one;
          Alcotest.test_case "replacing an unheld or doubled id is a failure"
            `Quick test_replacing_an_unheld_or_doubled_id_is_a_failure;
          Alcotest.test_case "malformed replaces is refused early" `Quick
            test_malformed_replaces_is_refused_before_the_ledger_is_touched;
          Alcotest.test_case "a merge must shrink the render" `Quick
            test_a_merge_must_shrink_the_render;
          Alcotest.test_case "a merge is not bound by the per-article cap"
            `Quick test_a_merge_is_not_bound_by_the_per_article_cap;
          Alcotest.test_case "reason is refused on a plain write" `Quick
            test_reason_is_refused_on_a_plain_write;
          Alcotest.test_case "null or empty replaces writes a plain norm"
            `Quick test_null_or_empty_replaces_writes_a_plain_norm;
          Alcotest.test_case "a merge over the ceiling is refused" `Quick
            test_a_merge_over_the_ceiling_is_refused;
        ] );
      ( "remove",
        [ Alcotest.test_case "removing takes the norm out" `Quick
            test_removing_takes_the_norm_out;
          Alcotest.test_case "removing an unheld id is a failure" `Quick
            test_removing_an_id_the_world_does_not_hold_is_a_failure;
          Alcotest.test_case "invalid removal reasons preserve the ledger" `Quick
            test_invalid_removal_reasons_preserve_the_ledger;
        ] );
    ]
