module Types = Masc_domain

open Masc_mcp

(** {1 Test helpers} *)

(** Temp directory for test isolation — set before any Board.global call *)
let _test_base_path =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "masc-test-tool-board" in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(** Clear all Board global state for test isolation.
    Must call inside Eio_main.run since Board.store contains Eio.Mutex. *)
let rng_initialized = ref false

let rec remove_path path =
  if Sys.file_exists path then
    if Sys.is_directory path then begin
      Sys.readdir path
      |> Array.iter (fun entry -> remove_path (Filename.concat path entry));
      Unix.rmdir path
    end else
      Sys.remove path

let cleanup () =
  if not !rng_initialized then begin
    Mirage_crypto_rng_unix.use_default ();
    rng_initialized := true
  end;
  Board.reset_global_for_test ();
  Board_dispatch.reset_for_test ();
  Board_curation.reset_for_test ();
  remove_path (Filename.concat _test_base_path Common.masc_dirname);
  Board_dispatch.init_jsonl ()

let dispatch name args =
  let result = Tool_board.handle_tool name args in
  (result.success, Tool_result.message result)

let make_args pairs = `Assoc pairs

let parse_create_response_json body =
  let trimmed = String.trim body in
  if String.length trimmed > 0 && Char.equal trimmed.[0] '{' then
    Yojson.Safe.from_string trimmed
  else
    match String.index_opt body '\n' with
    | Some idx ->
        Yojson.Safe.from_string
          (String.sub body (idx + 1) (String.length body - idx - 1))
    | None ->
        Alcotest.failf "expected JSON payload in create response: %s" body

let make_keeper_meta ?(name = "judge-keeper") () : Keeper_types.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [
           ("name", `String name);
           ("agent_name", `String name);
           ("trace_id", `String "test-trace-board");
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_keeper_meta failed: %s" e)

let contains_substring haystack needle =
  try
    ignore (Str.search_forward (Str.regexp_string needle) haystack 0);
    true
  with Not_found -> false

(** {2 Group 1: Helper / Formatting Functions} *)

let test_visibility_of_string () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  Alcotest.(check string) "public" "public"
    (match Tool_board.visibility_of_string "public" with
     | Some Board.Public -> "public" | _ -> "other");
  Alcotest.(check string) "unlisted" "unlisted"
    (match Tool_board.visibility_of_string "unlisted" with
     | Some Board.Unlisted -> "unlisted" | _ -> "other");
  Alcotest.(check string) "internal" "internal"
    (match Tool_board.visibility_of_string "internal" with
     | Some Board.Internal -> "internal" | _ -> "other");
  Alcotest.(check string) "direct" "direct"
    (match Tool_board.visibility_of_string "direct" with
     | Some Board.Direct -> "direct" | _ -> "other");
  Alcotest.(check string) "unknown returns None" "none"
    (match Tool_board.visibility_of_string "garbage" with
     | None -> "none" | _ -> "other")

(* Issue #8449 PR B: [Tool_board.sort_order_of_string] removed —
   replaced by [parse_sort_order] (Result-returning) which delegates to
   [Board_dispatch.sort_order_of_string_opt]. The previous silent
   "unknown defaults to Hot" behavior is now an explicit Error so
   garbage input is surfaced instead of swallowed. *)
let test_sort_order_of_string () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let check name expected input =
    match Tool_board.parse_sort_order input with
    | Ok v when v = expected -> Alcotest.(check string) name name name
    | Ok _ -> Alcotest.failf "%s: parsed wrong variant" name
    | Error e -> Alcotest.failf "%s: expected Ok, got Error: %s" name e
  in
  check "hot" Tool_board.Hot "hot";
  check "trending" Tool_board.Trending "trending";
  check "recent" Tool_board.Recent "recent";
  check "updated" Tool_board.Updated "updated";
  check "discussed" Tool_board.Discussed "discussed";
  (* Garbage input is now an explicit Error, not a silent Hot default. *)
  Alcotest.(check bool) "garbage rejected" true
    (match Tool_board.parse_sort_order "xyz" with Error _ -> true | Ok _ -> false)

let test_board_error_to_string () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let s = Tool_board.board_error_to_string (Board.Post_not_found "test-id") in
  Alcotest.(check bool) "post_not_found has text" true (String.length s > 0);
  let s2 = Tool_board.board_error_to_string (Board.Validation_error "bad") in
  Alcotest.(check bool) "validation_error" true (String.contains s2 'b')

let test_is_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  (* is_agent uses agent_lookup_hook — returns false when no hook installed *)
  Alcotest.(check bool) "no hook = not agent" false
    (Tool_board.is_agent "dreamer");
  (* Install a mock hook that recognises "dreamer" *)
  Tool_board.set_agent_lookup (fun name -> name = "dreamer");
  Fun.protect ~finally:Tool_board.set_agent_lookup_none (fun () ->
    Alcotest.(check bool) "registered agent" true
      (Tool_board.is_agent "dreamer");
    Alcotest.(check bool) "unregistered agent" false
      (Tool_board.is_agent "unknown");
    Alcotest.(check bool) "empty = not agent" false
      (Tool_board.is_agent ""))

let test_format_timestamp_relative () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let now = Time_compat.now () in
  let s = Tool_board.format_timestamp_relative now in
  Alcotest.(check string) "recent timestamp" "just now" s;
  let old = now -. 86400.0 in
  let s2 = Tool_board.format_timestamp_relative old in
  Alcotest.(check bool) "1-day old has 'd'" true (String.contains s2 'd');
  let minutes_ago = now -. 120.0 in
  let s3 = Tool_board.format_timestamp_relative minutes_ago in
  Alcotest.(check bool) "2min ago has 'm'" true (String.contains s3 'm')

let json_member_string json key =
  match Yojson.Safe.Util.member key json with
  | `String value -> value
  | _ -> Alcotest.failf "expected string field %s" key

let json_member_int json key =
  match Yojson.Safe.Util.member key json with
  | `Int value -> value
  | _ -> Alcotest.failf "expected int field %s" key

let json_member_bool json key =
  match Yojson.Safe.Util.member key json with
  | `Bool value -> value
  | _ -> Alcotest.failf "expected bool field %s" key

let json_member_list json key =
  match Yojson.Safe.Util.member key json with
  | `List values -> values
  | _ -> Alcotest.failf "expected list field %s" key

let test_board_actor_identity_canonicalizes_keeper_alias () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let json = Server_utils.board_actor_identity_json "keeper-analyst-agent" in
  Alcotest.(check string) "kind" "keeper" (json_member_string json "kind");
  Alcotest.(check string) "id" "analyst" (json_member_string json "id");
  Alcotest.(check string) "key" "keeper:analyst" (json_member_string json "key");
  Alcotest.(check string) "raw" "keeper-analyst-agent"
    (json_member_string json "raw");
  Alcotest.(check string) "source" "keeper_alias_contract"
    (json_member_string json "source");
  Alcotest.(check string) "runtime agent" "keeper-analyst-agent"
    (json_member_string json "runtime_agent_name")

let test_board_actor_identity_keeps_non_keeper_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let json = Server_utils.board_actor_identity_json "codex" in
  Alcotest.(check string) "kind" "agent" (json_member_string json "kind");
  Alcotest.(check string) "id" "codex" (json_member_string json "id");
  Alcotest.(check string) "key" "agent:codex" (json_member_string json "key");
  Alcotest.(check string) "source" "raw_agent"
    (json_member_string json "source")

let test_board_dashboard_json_embeds_reaction_summaries () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post =
    match
      Board_dispatch.create_post ~author:"reaction-author"
        ~content:"reactable post" ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let post_id = Board.Post_id.to_string post.id in
  (match
     Board_dispatch.toggle_reaction ~target_type:Board.Reaction_post
       ~target_id:post_id ~user_id:"reactor" ~emoji:"🚀"
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let comment =
    match
      Board_dispatch.add_comment ~post_id ~author:"commenter"
        ~content:"reactable comment" ()
    with
    | Ok comment -> comment
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let comment_id = Board.Comment_id.to_string comment.id in
  (match
     Board_dispatch.toggle_reaction ~target_type:Board.Reaction_comment
       ~target_id:comment_id ~user_id:"reactor" ~emoji:"👏"
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let post_reactions =
    Server_utils.board_reactions_for_post ~voter:(Some "reactor") ~post_id
  in
  let post_json =
    Server_utils.board_post_dashboard_json ~reactions:post_reactions
      ~author_karma:0 post
  in
  let post_summary =
    match json_member_list post_json "reactions" with
    | summary :: _ -> summary
    | [] -> Alcotest.fail "expected post reaction summary"
  in
  Alcotest.(check string) "post reaction emoji" "🚀"
    (json_member_string post_summary "emoji");
  Alcotest.(check int) "post reaction count" 1
    (json_member_int post_summary "count");
  Alcotest.(check bool) "post reaction selected" true
    (json_member_bool post_summary "has_reacted");
  let comment_reactions =
    Server_utils.board_reactions_for_comment ~voter:(Some "reactor") ~comment_id
  in
  let comment_json =
    Server_utils.board_comment_dashboard_json ~reactions:comment_reactions comment
  in
  let comment_summary =
    match json_member_list comment_json "reactions" with
    | summary :: _ -> summary
    | [] -> Alcotest.fail "expected comment reaction summary"
  in
  Alcotest.(check string) "comment reaction emoji" "👏"
    (json_member_string comment_summary "emoji");
  Alcotest.(check bool) "comment reaction selected" true
    (json_member_bool comment_summary "has_reacted")

let test_inline_board_post_author_rewrites_caller_claim () =
  let args =
    make_args
      [
        ("content", `String "ctx-owned post");
        ("author", `String "analyst");
        ("meta", `Assoc [ ("trace", `String "probe-10297") ]);
      ]
  in
  let normalized =
    Tool_inline_dispatch_extra.ensure_board_post_author
      ~agent_name:"keeper-velvet-hammer-agent" args
  in
  Alcotest.(check string) "author from ctx" "velvet-hammer"
    Yojson.Safe.Util.(normalized |> member "author" |> to_string);
  Alcotest.(check string) "caller claim preserved" "analyst"
    Yojson.Safe.Util.(
      normalized |> member "meta" |> member "caller_supplied_author" |> to_string);
  Alcotest.(check string) "rewrite reason preserved" "caller_author_mismatch"
    Yojson.Safe.Util.(
      normalized |> member "meta" |> member "author_rewrite_reason" |> to_string);
  Alcotest.(check string) "raw ctx agent preserved" "keeper-velvet-hammer-agent"
    Yojson.Safe.Util.(
      normalized |> member "meta" |> member "author_raw_agent_name" |> to_string);
  Alcotest.(check string) "existing meta preserved" "probe-10297"
    Yojson.Safe.Util.(normalized |> member "meta" |> member "trace" |> to_string)

let test_inline_board_post_author_accepts_matching_alias () =
  let args =
    make_args
      [
        ("content", `String "ctx-owned post");
        ("author", `String "keeper-analyst-agent");
      ]
  in
  let normalized =
    Tool_inline_dispatch_extra.ensure_board_post_author
      ~agent_name:"keeper-analyst-agent" args
  in
  Alcotest.(check string) "author canonical" "analyst"
    Yojson.Safe.Util.(normalized |> member "author" |> to_string);
  Alcotest.(check bool) "no mismatch claim" true
    Yojson.Safe.Util.(
      normalized |> member "meta" |> member "caller_supplied_author" = `Null)

(** {2 Group 2: JSON helper functions} *)

let test_get_string () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("key", `String "value")] in
  Alcotest.(check string) "get existing" "value"
    (Tool_args.get_string args "key" "default");
  Alcotest.(check string) "get missing" "default"
    (Tool_args.get_string args "missing" "default")

let test_get_string_opt () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("key", `String "value")] in
  Alcotest.(check (option string)) "get existing" (Some "value")
    (Tool_args.get_string_opt args "key");
  Alcotest.(check (option string)) "get missing" None
    (Tool_args.get_string_opt args "missing")

let test_get_int () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("n", `Int 42)] in
  Alcotest.(check int) "get existing" 42
    (Tool_args.get_int args "n" 0);
  Alcotest.(check int) "get missing" 0
    (Tool_args.get_int args "missing" 0)

let test_get_bool () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("flag", `Bool true)] in
  Alcotest.(check bool) "get existing" true
    (Tool_args.get_bool args "flag" false);
  Alcotest.(check bool) "get missing" false
    (Tool_args.get_bool args "missing" false)

(** {2 Group 3: Post Create / List / Get} *)

let test_post_create_success () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board"); ("author", `String "tester")]) in
  Alcotest.(check bool) "create ok" true ok;
  Alcotest.(check bool) "body has post" true (String.length body > 0)

let test_post_create_structured_payload () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args
       [
         ("title", `String "Why");
         ("content", `String "Visible answer\n\n[STATE]\nGoal: keep context\n[/STATE]");
         ("author", `String "sangsu");
         ("meta", `Assoc [ ("source", `String "keeper_autonomy") ]);
       ])
  in
  Alcotest.(check bool) "create ok" true ok;
  let json = parse_create_response_json body in
  Alcotest.(check string) "title kept" "Why"
    Yojson.Safe.Util.(json |> member "title" |> to_string);
  Alcotest.(check string) "body stripped" "Visible answer"
    Yojson.Safe.Util.(json |> member "body" |> to_string);
  Alcotest.(check string) "content alias" "Visible answer"
    Yojson.Safe.Util.(json |> member "content" |> to_string);
  Alcotest.(check string) "public posts stay direct" "direct"
    Yojson.Safe.Util.(json |> member "post_kind" |> to_string);
  Alcotest.(check string) "source meta kept" "keeper_autonomy"
    Yojson.Safe.Util.(json |> member "meta" |> member "source" |> to_string);
  (* state_block is stripped by tool_board before reaching board_core,
     so meta.state_block is absent (null) in the created post. *)
  Alcotest.(check bool) "state_block absent after strip" true
    (Yojson.Safe.Util.(json |> member "meta" |> member "state_block") = `Null)

let test_post_create_judgment_roundtrip () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let summary =
    "LLM judged this as a direct post because it is a user-authored explanation rather than automation output."
  in
  let ok, body =
    dispatch "masc_board_post"
      (make_args
         [
           ("content", `String "Judged board post");
           ("author", `String "tester");
           ( "judgment",
             `Assoc
               [
                 ("summary", `String summary);
                 ("confidence", `Float 0.77);
               ] );
         ])
  in
  Alcotest.(check bool) "create ok" true ok;
  let json = parse_create_response_json body in
  Alcotest.(check string) "classification reason from judgment" summary
    Yojson.Safe.Util.(json |> member "classification_reason" |> to_string);
  Alcotest.(check string) "judgment summary kept in meta" summary
    Yojson.Safe.Util.(json |> member "meta" |> member "judgment" |> member "summary" |> to_string)

let test_post_create_sources_footer_and_meta () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body =
    dispatch "masc_board_post"
      (make_args
         [
           ("content", `String "External claim: prompt contracts need evidence.");
           ("author", `String "tester");
           ( "sources",
             `List
               [
                 `Assoc
                   [
                     ("url", `String "https://example.com/docs");
                     ("quote", `String "evidence beats assertion");
                   ];
               ] );
         ])
  in
  Alcotest.(check bool) "create ok" true ok;
  let json = parse_create_response_json body in
  let content = Yojson.Safe.Util.(json |> member "content" |> to_string) in
  Alcotest.(check bool) "sources footer appended" true
    (contains_substring content "## Sources");
  Alcotest.(check bool) "source url rendered" true
    (contains_substring content "<https://example.com/docs>");
  Alcotest.(check string) "source url persisted" "https://example.com/docs"
    Yojson.Safe.Util.(
      json |> member "meta" |> member "sources" |> index 0 |> member "url"
      |> to_string);
  Alcotest.(check bool) "external source flag" true
    Yojson.Safe.Util.(json |> member "meta" |> member "has_external_sources" |> to_bool)

let test_keeper_board_post_preserves_meta_reason () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"judge-keeper" () in
  let reason =
    "LLM judged this as automation because it broadcasts a keeper-owned status update."
  in
  let body =
    Keeper_exec_board.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_post"
      ~args:
        (make_args
           [
             ("content", `String "keeper authored update");
             ( "meta",
               `Assoc
                 [
                   ("classification_reason", `String reason);
                   ("trace", `String "probe-1");
                 ] );
           ])
  in
  let json = parse_create_response_json body in
  Alcotest.(check string) "classification reason kept" reason
    Yojson.Safe.Util.(json |> member "classification_reason" |> to_string);
  Alcotest.(check string) "keeper source injected" "keeper_board_post"
    Yojson.Safe.Util.(json |> member "meta" |> member "source" |> to_string);
  Alcotest.(check string) "existing meta preserved" "probe-1"
    Yojson.Safe.Util.(json |> member "meta" |> member "trace" |> to_string);
  Alcotest.(check string) "author forced from keeper meta" "judge-keeper"
    Yojson.Safe.Util.(json |> member "author" |> to_string)

let test_keeper_board_dispatch_uses_typed_tool_names () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"typed-keeper" () in
  let fake =
    Keeper_exec_board.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_fake"
      ~args:(make_args [])
  in
  Alcotest.(check bool) "fake board name rejected" true
    (contains_substring fake "unknown_board_tool");
  let comment_vote =
    Keeper_exec_board.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_comment_vote"
      ~args:(make_args [ ("comment_id", `String "") ])
  in
  Alcotest.(check bool) "typed comment vote reaches board handler" true
    (contains_substring comment_vote "comment_id required");
  Alcotest.(check bool) "typed comment vote is not unknown" false
    (contains_substring comment_vote "unknown_board_tool");
  let curation =
    Keeper_exec_board.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_curation_read"
      ~args:(make_args [])
  in
  Alcotest.(check string) "typed curation read reaches board handler" "null" curation;
  Alcotest.(check bool) "typed curation read is not unknown" false
    (contains_substring curation "unknown_board_tool");
  let curation_submit =
    Keeper_exec_board.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_curation_submit"
      ~args:
        (make_args
           [
             ("summary", `String "Two active threads need routing.");
             ("ordering", `List [ `String "p-1"; `String "p-2" ]);
             ("highlights", `List [ `String "p-1" ]);
             ("tag_suggestions",
              `List
                [
                  `Assoc
                    [
                      ("post_id", `String "p-1");
                      ("tags", `List [ `String "ops" ]);
                      ("rationale", `String "Operational thread");
                    ];
                ]);
             ("answer_matches",
              `List
                [
                  `Assoc
                    [
                      ("question_post_id", `String "p-1");
                      ("answer_post_id", `String "p-2");
                      ("score", `Float 0.8);
                      ("rationale", `String "Same issue");
                    ];
                ]);
             ("health_score", `Float 0.7);
             ("health_components",
              `List
                [
                  `Assoc
                    [
                      ("name", `String "answer_rate");
                      ("score", `Float 0.7);
                      ("weight", `Float 0.25);
                      ("rationale", `String "Some answers present");
                    ];
                ]);
             ("rationale", `String "Summarize active board activity");
             ("provenance", `Assoc [ ("source", `String "test") ]);
           ])
  in
  Alcotest.(check bool) "typed curation submit is not unknown" false
    (contains_substring curation_submit "unknown_board_tool");
  let submit_json = Yojson.Safe.from_string curation_submit in
  Alcotest.(check string) "keeper source injected for curation" "typed-keeper"
    Yojson.Safe.Util.(submit_json |> member "submitted_by" |> to_string);
  Alcotest.(check string) "curation summary persisted"
    "Two active threads need routing."
    Yojson.Safe.Util.(submit_json |> member "summary" |> to_string)

let test_board_curation_read_empty_returns_json_null () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_curation_read" (make_args []) in
  Alcotest.(check bool) "curation read ok" true ok;
  Alcotest.(check string) "empty curation snapshot is JSON null" "null" body

let test_board_curation_submit_roundtrips_to_read () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let missing_ok, missing_body =
    dispatch "masc_board_curation_submit"
      (make_args [ ("rationale", `String "missing submitted_by") ])
  in
  Alcotest.(check bool) "raw submit requires submitted_by" false missing_ok;
  Alcotest.(check string) "missing submitted_by error" "submitted_by required"
    missing_body;
  let invalid_score_ok, invalid_score_body =
    dispatch "masc_board_curation_submit"
      (make_args
         [
           ("submitted_by", `String "curator");
           ("rationale", `String "score out of range");
           ("health_score", `Float 1.5);
         ])
  in
  Alcotest.(check bool) "raw submit rejects out-of-range health score" false
    invalid_score_ok;
  Alcotest.(check bool) "invalid score error mentions health_score" true
    (contains_substring invalid_score_body "health_score");
  let invalid_provenance_ok, invalid_provenance_body =
    dispatch "masc_board_curation_submit"
      (make_args
         [
           ("submitted_by", `String "curator");
           ("rationale", `String "provenance shape");
           ("provenance", `String "not-an-object");
         ])
  in
  Alcotest.(check bool) "raw submit rejects non-object provenance" false
    invalid_provenance_ok;
  Alcotest.(check bool) "invalid provenance error mentions object" true
    (contains_substring invalid_provenance_body "object");
  let ok, body =
    dispatch "masc_board_curation_submit"
      (make_args
         [
           ("submitted_by", `String "curator");
           ("model", `String " test-model ");
           ("summary", `String " Board has one high-priority routing item. ");
           ("ordering", `List [ `String " p-7 "; `String " "; `String "" ]);
           ("highlights", `List [ `String " p-7 "; `String " " ]);
           ("tag_suggestions",
            `List
              [
                `Assoc
                  [
                    ("post_id", `String "p-7");
                    ("tags", `List [ `String "routing"; `String "ops" ]);
                    ("rationale", `String "Needs owner routing");
                  ];
              ]);
           ("answer_matches",
            `List
              [
                `Assoc
                  [
                    ("question_post_id", `String "p-7");
                    ("answer_post_id", `String "p-8");
                    ("score", `Float 0.9);
                    ("rationale", `String "Direct answer candidate");
                  ];
              ]);
           ("health_score", `Float 0.65);
           ("health_components",
            `List
              [
                `Assoc
                  [
                    ("name", `String "routing_latency");
                    ("score", `Float 0.65);
                    ("weight", `Float 0.5);
                    ("rationale", `String "Some delay visible");
                  ];
              ]);
           ("rationale", `String "Useful routing snapshot");
           ("provenance", `Assoc [ ("source", `String "unit-test") ]);
         ])
  in
  Alcotest.(check bool) "curation submit ok" true ok;
  let submitted = Yojson.Safe.from_string body in
  Alcotest.(check string) "submitted_by persisted" "curator"
    Yojson.Safe.Util.(submitted |> member "submitted_by" |> to_string);
  Alcotest.(check string) "model trimmed" "test-model"
    Yojson.Safe.Util.(submitted |> member "model" |> to_string);
  Alcotest.(check string) "summary persisted"
    "Board has one high-priority routing item."
    Yojson.Safe.Util.(submitted |> member "summary" |> to_string);
  Alcotest.(check (list string)) "ordering trims and drops blanks" [ "p-7" ]
    Yojson.Safe.Util.(submitted |> member "ordering" |> to_list |> List.map to_string);
  Alcotest.(check (list string)) "highlights trim and drop blanks" [ "p-7" ]
    Yojson.Safe.Util.(submitted |> member "highlights" |> to_list |> List.map to_string);
  Alcotest.(check (float 0.0001)) "health score persisted" 0.65
    Yojson.Safe.Util.(submitted |> member "health_score" |> to_float);
  let read_ok, read_body = dispatch "masc_board_curation_read" (make_args []) in
  Alcotest.(check bool) "curation read after submit ok" true read_ok;
  let read_json = Yojson.Safe.from_string read_body in
  Alcotest.(check string) "read returns latest id"
    Yojson.Safe.Util.(submitted |> member "id" |> to_string)
    Yojson.Safe.Util.(read_json |> member "id" |> to_string);
  Alcotest.(check string) "read returns latest summary"
    "Board has one high-priority routing item."
    Yojson.Safe.Util.(read_json |> member "summary" |> to_string)

let test_post_create_accepts_automation_rejects_system () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok_auto, _body_auto = dispatch "masc_board_post"
    (make_args
       [
         ("content", `String "automation attempt");
         ("author", `String "tester");
         ("post_kind", `String "automation");
       ])
  in
  Alcotest.(check bool) "automation accepted" true ok_auto;
  let ok_sys, body_sys = dispatch "masc_board_post"
    (make_args
       [
         ("content", `String "system attempt");
         ("author", `String "tester");
         ("post_kind", `String "system");
       ])
  in
  Alcotest.(check bool) "system rejected" false ok_sys;
  Alcotest.(check bool) "error mentions reserved" true
    (contains_substring body_sys "reserved")

let test_post_create_empty_content () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String ""); ("author", `String "tester")]) in
  (* Empty content: either rejected (ok=false) or accepted (ok=true) — verify consistent response *)
  Alcotest.(check bool) "response has body" true (String.length body > 0);
  if not ok then
    Alcotest.(check bool) "error mentions reason" true
      (String.length body > 0)

let test_post_create_empty_title_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args
       [ ("title", `String "   "); ("content", `String "Hello board");
         ("author", `String "tester") ]) in
  Alcotest.(check bool) "empty title rejected" false ok;
  Alcotest.(check bool) "error mentions title" true
    (contains_substring body "title" || contains_substring body "Title")

let test_post_create_missing_author_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board")]) in
  Alcotest.(check bool) "missing author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (contains_substring body "author")

let test_post_create_anonymous_author_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board"); ("author", `String "anonymous")]) in
  Alcotest.(check bool) "anonymous author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (contains_substring body "author")

let test_post_list_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_list" (make_args []) in
  Alcotest.(check bool) "list ok" true ok;
  Alcotest.(check bool) "no posts msg" true
    (String.length body > 0)

let test_cleanup_clears_persisted_jsonl () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok1, _ =
    dispatch "masc_board_post"
      (make_args [ ("content", `String "persist me"); ("author", `String "tester") ])
  in
  Alcotest.(check bool) "create ok" true ok1;
  cleanup ();
  let ok2, body = dispatch "masc_board_list" (make_args []) in
  Alcotest.(check bool) "list ok after cleanup" true ok2;
  Alcotest.(check bool) "persisted content removed" false
    (contains_substring body "persist me")

let test_post_list_with_posts () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok1, _ = dispatch "masc_board_post"
    (make_args [("content", `String "Post 1"); ("author", `String "a")]) in
  Alcotest.(check bool) "create 1" true ok1;
  let ok2, _ = dispatch "masc_board_post"
    (make_args [("content", `String "Post 2"); ("author", `String "b")]) in
  Alcotest.(check bool) "create 2" true ok2;
  let ok, body = dispatch "masc_board_list"
    (make_args [("limit", `Int 10)]) in
  Alcotest.(check bool) "list ok" true ok;
  Alcotest.(check bool) "body has content" true
    (String.length body > 20)

let test_post_list_limit_clamping () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  (* Create 3 posts *)
  for _ = 1 to 3 do
    ignore (dispatch "masc_board_post"
      (make_args [("content", `String "x"); ("author", `String "a")]))
  done;
  let ok, body = dispatch "masc_board_list"
    (make_args [("limit", `Int 1)]) in
  Alcotest.(check bool) "list ok" true ok;
  (* With limit=1, should show only 1 post *)
  Alcotest.(check bool) "body has posts" true (String.length body > 0)

let test_post_list_sort_orders () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  ignore (dispatch "masc_board_post"
    (make_args [("content", `String "sort test"); ("author", `String "a")]));
  let sorts = ["hot"; "trending"; "recent"; "updated"; "discussed"] in
  List.iter (fun s ->
    let ok, body = dispatch "masc_board_list"
      (make_args [("sort_by", `String s)]) in
    Alcotest.(check bool) (Printf.sprintf "sort %s ok" s) true ok;
    Alcotest.(check bool) (Printf.sprintf "sort %s has content" s) true (String.length body > 0)
  ) sorts

let test_post_list_invalid_sort_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  ignore (dispatch "masc_board_post"
    (make_args [("content", `String "sort test"); ("author", `String "a")]));
  let ok, body = dispatch "masc_board_list"
    (make_args [("sort", `String "invalid_xyz")]) in
  Alcotest.(check bool) "invalid sort rejected" false ok;
  Alcotest.(check bool) "error mentions valid sorts" true
    (contains_substring body "invalid sort. Valid: hot, trending, recent, updated, discussed")

let test_post_list_filter_combinations () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  ignore (dispatch "masc_board_post"
    (make_args [("content", `String "human"); ("author", `String "human-author")]));
  ignore (Board_dispatch.create_post ~author:"dashboard-harness-bot"
            ~content:"automation" ~visibility:Board.Internal ~ttl_hours:1
            ~hearth:"dashboard-harness" ~post_kind:Board.Automation_post ());
  ignore (Board_dispatch.create_post ~author:"dm-keeper" ~content:"keeper"
            ~post_kind:Board.Automation_post
            ~meta_json:(`Assoc [ ("source", `String "keeper_board_post") ]) ());
  ignore (Board_dispatch.create_post ~author:"keeper-alert-bot" ~content:"system"
            ~post_kind:Board.System_post ());
  let ok1, body1 = dispatch "masc_board_list"
    (make_args [("exclude_system", `Bool true)]) in
  let ok2, body2 = dispatch "masc_board_list"
    (make_args [("exclude_automation", `Bool true)]) in
  let ok3, body3 = dispatch "masc_board_list"
    (make_args [("exclude_system", `Bool true); ("exclude_automation", `Bool true)]) in
  Alcotest.(check bool) "exclude_system ok" true ok1;
  Alcotest.(check bool) "exclude_automation ok" true ok2;
  Alcotest.(check bool) "exclude both ok" true ok3;
  Alcotest.(check bool) "exclude_system hides system" false
    (contains_substring body1 "keeper-alert-bot");
  Alcotest.(check bool) "exclude_system keeps keeper" true
    (contains_substring body1 "dm-keeper");
  Alcotest.(check bool) "exclude_automation keeps system" true
    (contains_substring body2 "keeper-alert-bot");
  Alcotest.(check bool) "exclude_automation hides keeper" false
    (contains_substring body2 "dm-keeper");
  Alcotest.(check bool) "exclude_automation hides harness" false
    (contains_substring body2 "dashboard-harness-bot");
  Alcotest.(check bool) "exclude both keeps human" true
    (contains_substring body3 "human-author");
  Alcotest.(check bool) "exclude both hides keeper" false
    (contains_substring body3 "dm-keeper");
  Alcotest.(check bool) "exclude both hides harness" false
    (contains_substring body3 "dashboard-harness-bot")

let test_dispatch_delete_success () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let _ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "to be deleted"); ("author", `String "tester")]) in
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  let ok_del, msg_del = dispatch "masc_board_delete"
    (make_args [("post_id", `String post_id)]) in
  Alcotest.(check bool) "delete ok" true ok_del;
  Alcotest.(check bool) "delete msg contains id" true
    (contains_substring msg_del post_id)

let test_dispatch_delete_not_found () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_delete"
    (make_args [("post_id", `String "nonexistent-id")]) in
  Alcotest.(check bool) "delete not found" false ok;
  Alcotest.(check bool) "error message present" true
    (contains_substring body "Delete failed")

let test_dispatch_delete_empty_id () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_delete"
    (make_args [("post_id", `String "")]) in
  Alcotest.(check bool) "empty id rejected" false ok;
  Alcotest.(check bool) "error mentions required" true
    (contains_substring body "required")

let test_post_get_success () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Get me"); ("author", `String "tester")]) in
  Alcotest.(check bool) "create ok" true ok;
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  Alcotest.(check bool) "post_id not empty" true (String.length post_id > 0);
  let ok2, body2 = dispatch "masc_board_get"
    (make_args [("post_id", `String post_id)]) in
  Alcotest.(check bool) "get ok" true ok2;
  Alcotest.(check bool) "get has content" true (String.length body2 > 0)

let test_post_get_not_found () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_get"
    (make_args [("post_id", `String "nonexistent-id")]) in
  Alcotest.(check bool) "not found is idempotent success" true ok;
  Alcotest.(check bool) "body mentions gone" true
    (String_util.contains_substring_ci body "no longer exists")

(** {2 Group 4: Voting} *)

let test_vote_not_found () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_vote"
    (make_args [("post_id", `String "missing"); ("voter", `String "v"); ("direction", `String "up")]) in
  Alcotest.(check bool) "vote on missing fails" false ok;
  Alcotest.(check bool) "has error" true (String.length body > 0)

(** {2 Group 5: Comment} *)

let test_comment_add_missing_post () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment"
    (make_args [("post_id", `String "missing"); ("content", `String "hi"); ("author", `String "a")]) in
  Alcotest.(check bool) "comment on missing post fails" false ok;
  Alcotest.(check bool) "has error" true (String.length body > 0)

let test_comment_add_missing_author_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment"
    (make_args [("post_id", `String "missing"); ("content", `String "hi")]) in
  Alcotest.(check bool) "missing author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (contains_substring body "author")

let test_comment_add_anonymous_author_rejected () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment"
    (make_args
       [("post_id", `String "missing"); ("content", `String "hi"); ("author", `String "anonymous")]) in
  Alcotest.(check bool) "anonymous author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (contains_substring body "author")

let test_comment_vote_missing () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment_vote"
    (make_args [("comment_id", `String ""); ("voter", `String "v"); ("direction", `String "up")]) in
  Alcotest.(check bool) "empty comment_id fails" false ok;
  Alcotest.(check bool) "error msg" true (String.length body > 0)

(** {2 Group 6: Search / Stats / Profile / Hearths} *)

let test_search_empty_query () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_search"
    (make_args [("query", `String "")]) in
  Alcotest.(check bool) "empty query fails" false ok;
  Alcotest.(check bool) "has error" true (String.length body > 0)

let test_search_no_results () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_search"
    (make_args [("query", `String "nonexistent_xyz_123")]) in
  Alcotest.(check bool) "search ok" true ok;
  Alcotest.(check bool) "no results msg" true (String.length body > 0)

let test_stats () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_stats" (make_args []) in
  Alcotest.(check bool) "stats ok" true ok;
  Alcotest.(check bool) "stats has content" true (String.length body > 0)

let test_profile_empty_agent () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_profile"
    (make_args [("agent", `String "")]) in
  Alcotest.(check bool) "empty agent fails" false ok;
  Alcotest.(check bool) "has error" true (String.length body > 0)

let test_profile_with_posts () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  ignore (dispatch "masc_board_post"
    (make_args [("content", `String "profiled"); ("author", `String "profiler")]));
  let ok, body = dispatch "masc_board_profile"
    (make_args [("agent", `String "profiler")]) in
  Alcotest.(check bool) "profile ok" true ok;
  Alcotest.(check bool) "has profiler name" true
    (try ignore (Str.search_forward (Str.regexp_string "profiler") body 0); true
     with Not_found -> false)

let test_hearth_list_empty () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_hearths" (make_args []) in
  Alcotest.(check bool) "hearth list ok" true ok;
  Alcotest.(check bool) "has content" true (String.length body > 0)

(** {2 Group 7: Dispatch Routing} *)

let test_dispatch_unknown_tool () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_nonexistent" (make_args []) in
  Alcotest.(check bool) "unknown tool fails" false ok;
  Alcotest.(check bool) "has unknown msg" true
    (try ignore (Str.search_forward (Str.regexp_string "Unknown") body 0); true
     with Not_found -> false)

(** {2 Group 8: Tool Schema Definitions} *)

let test_tools_count () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  Alcotest.(check int) "14 tool schemas" 14 (List.length Tool_board.tools)

let test_tools_names_unique () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name) Tool_board.tools in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int) "all names unique" (List.length names) (List.length unique)

let test_tools_all_have_descriptions () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  List.iter (fun (t : Masc_domain.tool_schema) ->
    Alcotest.(check bool) (Printf.sprintf "%s has description" t.name) true
      (String.length t.description > 0)
  ) Tool_board.tools

(** {1 Test Runner} *)

let () =
  Alcotest.run "Tool_board_coverage"
    [
      ( "helpers",
        [
          Alcotest.test_case "visibility_of_string" `Quick test_visibility_of_string;
          Alcotest.test_case "sort_order_of_string" `Quick test_sort_order_of_string;
          Alcotest.test_case "board_error_to_string" `Quick test_board_error_to_string;
          Alcotest.test_case "is_agent" `Quick test_is_agent;
          Alcotest.test_case "format_timestamp_relative" `Quick test_format_timestamp_relative;
          Alcotest.test_case "board actor identity canonicalizes keeper alias"
            `Quick test_board_actor_identity_canonicalizes_keeper_alias;
          Alcotest.test_case "board actor identity keeps non-keeper agent"
            `Quick test_board_actor_identity_keeps_non_keeper_agent;
          Alcotest.test_case "board dashboard json embeds reaction summaries"
            `Quick test_board_dashboard_json_embeds_reaction_summaries;
          Alcotest.test_case "inline board post author rewrites caller claim"
            `Quick test_inline_board_post_author_rewrites_caller_claim;
          Alcotest.test_case "inline board post author accepts matching alias"
            `Quick test_inline_board_post_author_accepts_matching_alias;
        ] );
      ( "json_helpers",
        [
          Alcotest.test_case "get_string" `Quick test_get_string;
          Alcotest.test_case "get_string_opt" `Quick test_get_string_opt;
          Alcotest.test_case "get_int" `Quick test_get_int;
          Alcotest.test_case "get_bool" `Quick test_get_bool;
        ] );
      ( "post_crud",
        [
          Alcotest.test_case "create success" `Quick test_post_create_success;
          Alcotest.test_case "create structured payload" `Quick
            test_post_create_structured_payload;
          Alcotest.test_case "create judgment roundtrip" `Quick
            test_post_create_judgment_roundtrip;
          Alcotest.test_case "create sources footer and meta" `Quick
            test_post_create_sources_footer_and_meta;
          Alcotest.test_case "keeper board post preserves meta reason" `Quick
            test_keeper_board_post_preserves_meta_reason;
          Alcotest.test_case "keeper board dispatch uses typed names" `Quick
            test_keeper_board_dispatch_uses_typed_tool_names;
          Alcotest.test_case "curation read empty returns JSON null" `Quick
            test_board_curation_read_empty_returns_json_null;
          Alcotest.test_case "curation submit roundtrips to read" `Quick
            test_board_curation_submit_roundtrips_to_read;
          Alcotest.test_case "accept automation reject system" `Quick
            test_post_create_accepts_automation_rejects_system;
          Alcotest.test_case "create empty content" `Quick test_post_create_empty_content;
          Alcotest.test_case "create empty title rejected" `Quick
            test_post_create_empty_title_rejected;
          Alcotest.test_case "create missing author rejected" `Quick
            test_post_create_missing_author_rejected;
          Alcotest.test_case "create anonymous author rejected" `Quick
            test_post_create_anonymous_author_rejected;
          Alcotest.test_case "list empty" `Quick test_post_list_empty;
          Alcotest.test_case "cleanup clears persisted jsonl" `Quick
            test_cleanup_clears_persisted_jsonl;
          Alcotest.test_case "list with posts" `Quick test_post_list_with_posts;
          Alcotest.test_case "list limit clamping" `Quick test_post_list_limit_clamping;
          Alcotest.test_case "list sort orders" `Quick test_post_list_sort_orders;
          Alcotest.test_case "list invalid sort rejected" `Quick
            test_post_list_invalid_sort_rejected;
          Alcotest.test_case "list filter combinations" `Quick
            test_post_list_filter_combinations;
          Alcotest.test_case "get success" `Quick test_post_get_success;
          Alcotest.test_case "get not found" `Quick test_post_get_not_found;
        ] );
      ( "voting",
        [
          Alcotest.test_case "vote not found" `Quick test_vote_not_found;
        ] );
      ( "comments",
        [
          Alcotest.test_case "comment missing post" `Quick test_comment_add_missing_post;
          Alcotest.test_case "comment missing author rejected" `Quick
            test_comment_add_missing_author_rejected;
          Alcotest.test_case "comment anonymous author rejected" `Quick
            test_comment_add_anonymous_author_rejected;
          Alcotest.test_case "comment vote missing" `Quick test_comment_vote_missing;
        ] );
      ( "search_stats",
        [
          Alcotest.test_case "search empty query" `Quick test_search_empty_query;
          Alcotest.test_case "search no results" `Quick test_search_no_results;
          Alcotest.test_case "stats" `Quick test_stats;
          Alcotest.test_case "profile empty agent" `Quick test_profile_empty_agent;
          Alcotest.test_case "profile with posts" `Quick test_profile_with_posts;
          Alcotest.test_case "hearth list empty" `Quick test_hearth_list_empty;
        ] );
      ( "dispatch",
        [
          Alcotest.test_case "unknown tool" `Quick test_dispatch_unknown_tool;
          Alcotest.test_case "delete success" `Quick test_dispatch_delete_success;
          Alcotest.test_case "delete not found" `Quick test_dispatch_delete_not_found;
          Alcotest.test_case "delete empty id" `Quick test_dispatch_delete_empty_id;
        ] );
      ( "schemas",
        [
          Alcotest.test_case "tools count" `Quick test_tools_count;
          Alcotest.test_case "unique names" `Quick test_tools_names_unique;
          Alcotest.test_case "all have descriptions" `Quick test_tools_all_have_descriptions;
        ] );
      ( "post_kind_registry",
        [
          Alcotest.test_case "no hook: defaults to direct" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.set_agent_lookup_none ();
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "claude-agent")
            ]) in
            Alcotest.(check bool) "post created" true ok;
            Alcotest.(check string) "classified as direct" "direct"
              Yojson.Safe.Util.(
                parse_create_response_json msg |> member "post_kind" |> to_string));
          Alcotest.test_case "with hook: agent classified as automation" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.set_agent_lookup (fun name -> name = "claude-agent");
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "claude-agent")
            ]) in
            Alcotest.(check bool) "post created" true ok;
            Alcotest.(check string) "classified as automation" "automation"
              Yojson.Safe.Util.(
                parse_create_response_json msg |> member "post_kind" |> to_string));
          Alcotest.test_case "with hook: non-agent stays direct" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.set_agent_lookup (fun _name -> false);
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "sangsu")
            ]) in
            Alcotest.(check bool) "post created" true ok;
            Alcotest.(check string) "classified as direct" "direct"
              Yojson.Safe.Util.(
                parse_create_response_json msg |> member "post_kind" |> to_string));
          Alcotest.test_case "legacy human override normalizes to direct" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.set_agent_lookup (fun _name -> true);
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "claude-agent");
              ("post_kind", `String "human")
            ]) in
            Alcotest.(check bool) "post created" true ok;
            Alcotest.(check string) "legacy override normalized to direct" "direct"
              Yojson.Safe.Util.(
                parse_create_response_json msg |> member "post_kind" |> to_string));
        ] );
      ( "board_list_cache",
        [
          Alcotest.test_case "cache hit returns same result" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.invalidate_board_list_cache ();
            (* Create a post so list is non-empty *)
            let (_ok, _msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "cached"); ("content", `String "hello");
              ("author", `String "tester")
            ]) in
            (* Invalidation from the post already happened, so the first list
               call populates the cache *)
            let args = make_args [("limit", `Int 10)] in
            let (ok1, body1) = dispatch "masc_board_list" args in
            Alcotest.(check bool) "first list ok" true ok1;
            (* Second call with same args should return identical result *)
            let (ok2, body2) = dispatch "masc_board_list" args in
            Alcotest.(check bool) "second list ok" true ok2;
            Alcotest.(check string) "cache hit returns identical body" body1 body2);
          Alcotest.test_case "mutation invalidates cache" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.invalidate_board_list_cache ();
            let (_ok, _msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "first"); ("content", `String "hello");
              ("author", `String "tester")
            ]) in
            let args = make_args [("limit", `Int 50)] in
            let (_ok1, body1) = dispatch "masc_board_list" args in
            (* Add another post — this invalidates the cache *)
            let (_ok, _msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "second"); ("content", `String "world");
              ("author", `String "tester")
            ]) in
            let (_ok2, body2) = dispatch "masc_board_list" args in
            (* body2 should include the new post, so it differs from body1 *)
            Alcotest.(check bool) "cache invalidated — different result"
              true (body1 <> body2));
          Alcotest.test_case "different args produce independent entries" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.invalidate_board_list_cache ();
            let (_ok, _msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "tester")
            ]) in
            let args_recent = make_args [("limit", `Int 10); ("sort_by", `String "recent")] in
            let args_hot = make_args [("limit", `Int 10); ("sort_by", `String "hot")] in
            let (_ok1, body_recent) = dispatch "masc_board_list" args_recent in
            let (_ok2, body_hot) = dispatch "masc_board_list" args_hot in
            (* Cache key differs, so the hot call recomputes *)
            Alcotest.(check bool) "recent result non-empty" true
              (String.length body_recent > 0);
            Alcotest.(check bool) "hot result non-empty" true
              (String.length body_hot > 0));
          Alcotest.test_case "random=true bypasses cache" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.invalidate_board_list_cache ();
            (* Create multiple posts so random shuffle can differ *)
            List.iter (fun i ->
              let (_ok, _msg) = dispatch "masc_board_post" (make_args [
                ("title", `String (Printf.sprintf "post-%d" i));
                ("content", `String "content");
                ("author", `String "tester")
              ]) in ()) [1; 2; 3; 4; 5];
            let args = make_args [("random", `Bool true); ("limit", `Int 5)] in
            let (ok1, _body1) = dispatch "masc_board_list" args in
            Alcotest.(check bool) "random list ok" true ok1);
          Alcotest.test_case "delete invalidates cache" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.invalidate_board_list_cache ();
            let (_ok, create_msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "to-delete"); ("content", `String "hello");
              ("author", `String "tester")
            ]) in
            let args = make_args [("limit", `Int 50)] in
            let (_ok1, body1) = dispatch "masc_board_list" args in
            Alcotest.(check bool) "list has post" true
              (contains_substring body1 "to-delete");
            (* Extract post_id from creation response *)
            let json = parse_create_response_json create_msg in
            let post_id = Yojson.Safe.Util.(json |> member "id" |> to_string) in
            let (_ok, _msg) = dispatch "masc_board_delete" (make_args [
              ("post_id", `String post_id)
            ]) in
            let (_ok2, body2) = dispatch "masc_board_list" args in
            Alcotest.(check bool) "cache invalidated after delete" true
              (not (contains_substring body2 "to-delete")));
          Alcotest.test_case "comment invalidates cache" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.invalidate_board_list_cache ();
            let (_ok, create_msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "for-comment"); ("content", `String "hello");
              ("author", `String "tester")
            ]) in
            let args = make_args [("limit", `Int 50)] in
            let (_ok1, body1) = dispatch "masc_board_list" args in
            let json = parse_create_response_json create_msg in
            let post_id = Yojson.Safe.Util.(json |> member "id" |> to_string) in
            let (_ok, _msg) = dispatch "masc_board_comment" (make_args [
              ("post_id", `String post_id);
              ("content", `String "a comment");
              ("author", `String "tester")
            ]) in
            (* After comment, cache should be invalidated.
               The reply count will differ. *)
            let (_ok2, body2) = dispatch "masc_board_list" args in
            Alcotest.(check bool) "cache invalidated after comment" true
              (body1 <> body2));
          Alcotest.test_case "vote invalidates cache" `Quick (fun () ->
            Eio_main.run @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Tool_board.invalidate_board_list_cache ();
            let (_ok, create_msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "for-vote"); ("content", `String "hello");
              ("author", `String "tester")
            ]) in
            let args = make_args [("limit", `Int 50)] in
            let (_ok1, body1) = dispatch "masc_board_list" args in
            let json = parse_create_response_json create_msg in
            let post_id = Yojson.Safe.Util.(json |> member "id" |> to_string) in
            let (_ok, _msg) = dispatch "masc_board_vote" (make_args [
              ("post_id", `String post_id);
              ("voter", `String "voter1");
              ("direction", `String "up")
            ]) in
            let (_ok2, body2) = dispatch "masc_board_list" args in
            Alcotest.(check bool) "cache invalidated after vote" true
              (body1 <> body2));
        ] );
    ]
