module Types = Masc_domain

open Masc

(** {1 Test helpers} *)

(** Temp directory for test isolation — set before any Board.global call *)
let _test_base_path =
  let dir = Filename.concat (Filename.get_temp_dir_name ()) "masc-test-tool-board" in
  Unix.putenv "MASC_BASE_PATH" dir;
  dir

(** Clear all Board global state for test isolation.
    Must call inside [with_eio] since Board.store contains Eio.Mutex. *)
let rng_initialized = ref false
let current_eio_env = ref None

let with_eio f =
  match !current_eio_env with
  | Some env -> f env
  | None -> Eio_main.run f

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
  Fs_compat.reset_fd_cache_for_testing ();
  Fs_compat.reset_mkdir_memo_for_testing ();
  remove_path (Filename.concat _test_base_path Common.masc_dirname);
  Board_dispatch.init_jsonl ()

(* The MCP route: MASC hands the result over whole. *)
let dispatch name args =
  let result = Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name args in
  ((Tool_result.is_success result), (Tool_result.message result))

let dispatch_result name args =
  Board_tool.handle_tool ~result_boundary:Tool_output.Sent_to_client name args

let check_failure_class name expected result =
  let actual =
    (Tool_result.failure_class result)
    |> Option.map Tool_result.tool_failure_class_to_string
  in
  Alcotest.(check (option string)) name expected actual

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

let sha256_hex text = Digestif.SHA256.(digest_string text |> to_hex)

let source_snapshot_for_created_post json =
  let open Yojson.Safe.Util in
  let post_id = json |> member "id" |> to_string in
  let updated_at = json |> member "updated_at" |> to_float in
  let body = json |> member "body" |> to_string in
  `Assoc
    [ "post_id", `String post_id
    ; "post_updated_at", `Float updated_at
    ; "body_sha256", `String ("sha256:" ^ sha256_hex body)
    ; "body_excerpt", `String body
    ; "read_at", `Float (Time_compat.now ())
    ]

let make_keeper_meta ?(name = "judge-keeper") () : Keeper_meta_contract.keeper_meta =
  match
    Masc_test_deps.meta_of_json_fixture
      (`Assoc
         [
           ("name", `String name);
           (* The decoder requires the derived form, not the raw name
              (keeper_meta_json_parse.ml:367). Passing [name] here made every
              fixture in this file fail construction, which is why five of its
              assertions have never run. *)
           ("trace_id", `String "test-trace-board");
         ])
  with
  | Ok meta -> meta
  | Error e -> failwith (Printf.sprintf "make_keeper_meta failed: %s" e)

(** {2 Group 1: Helper / Formatting Functions} *)

let test_visibility_of_string () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  Alcotest.(check string) "public" "public"
    (match Board_tool.visibility_of_string "public" with
     | Some Board.Public -> "public" | _ -> "other");
  Alcotest.(check string) "unlisted" "unlisted"
    (match Board_tool.visibility_of_string "unlisted" with
     | Some Board.Unlisted -> "unlisted" | _ -> "other");
  Alcotest.(check string) "internal" "internal"
    (match Board_tool.visibility_of_string "internal" with
     | Some Board.Internal -> "internal" | _ -> "other");
  Alcotest.(check string) "direct" "direct"
    (match Board_tool.visibility_of_string "direct" with
     | Some Board.Direct -> "direct" | _ -> "other");
  Alcotest.(check string) "unknown returns None" "none"
    (match Board_tool.visibility_of_string "garbage" with
     | None -> "none" | _ -> "other")

(* Issue #8449 PR B: [Board_tool.sort_order_of_string] removed —
   replaced by [parse_sort_order] (Result-returning) which delegates to
   [Board_dispatch.sort_order_of_string_opt]. The previous silent
   "unknown defaults to Hot" behavior is now an explicit Error so
   garbage input is surfaced instead of swallowed. *)
let test_sort_order_of_string () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let check name expected input =
    match Board_tool.parse_sort_order input with
    | Ok v when v = expected -> Alcotest.(check string) name name name
    | Ok _ -> Alcotest.failf "%s: parsed wrong variant" name
    | Error e -> Alcotest.failf "%s: expected Ok, got Error: %s" name e
  in
  check "hot" Board_tool.Hot "hot";
  check "trending" Board_tool.Trending "trending";
  check "recent" Board_tool.Recent "recent";
  check "updated" Board_tool.Updated "updated";
  check "discussed" Board_tool.Discussed "discussed";
  (* Garbage input is now an explicit Error, not a silent Hot default. *)
  Alcotest.(check bool) "garbage rejected" true
    (match Board_tool.parse_sort_order "xyz" with Error _ -> true | Ok _ -> false)

let test_board_error_to_string () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  (* Whole-string compares, because every arm of [board_error_to_string]
     echoes its payload: "has text" held for all eight, and 'b' was satisfied
     by the payload "bad" rather than by the label — "Validation error" has no
     'b' in it, so the old check tested none of what it was named for.  Two
     arms rendered under one label would have passed both. *)
  let s = Board_tool.board_error_to_string (Board.Post_not_found "test-id") in
  Alcotest.(check string) "post_not_found renders its own label"
    "Post not found: test-id" s;
  let s2 = Board_tool.board_error_to_string (Board.Validation_error "bad") in
  Alcotest.(check string) "validation_error renders its own label"
    "Validation error: bad" s2;
  (* A guessed id can carry the accepted c-hex shape (keeper:polisher voted
     c-000…0 on 2026-08-24), so the shape check lets it through and the
     lookup miss is the only reply the caller gets. It must name the two
     producers of real ids instead of only repeating the dead one. *)
  let s3 =
    Board_tool.board_error_to_string
      (Board.Comment_not_found "c-00000000000000000000000000000000")
  in
  Alcotest.(check bool)
    "comment_not_found names the post_get producer" true
    (String_util.contains_substring s3 "masc_board_post_get");
  Alcotest.(check bool)
    "comment_not_found names the comment producer" true
    (String_util.contains_substring s3 "masc_board_comment")

let test_is_agent () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  (* is_agent uses agent_lookup_hook — returns false when no hook installed *)
  Alcotest.(check bool) "no hook = not agent" false
    (Board_tool.is_agent "alice");
  (* Install a mock hook that recognises "alice" *)
  Board_tool.set_agent_lookup (fun name -> name = "alice");
  Fun.protect ~finally:Board_tool.set_agent_lookup_none (fun () ->
    Alcotest.(check bool) "registered agent" true
      (Board_tool.is_agent "alice");
    Alcotest.(check bool) "unregistered agent" false
      (Board_tool.is_agent "unknown");
    Alcotest.(check bool) "empty = not agent" false
      (Board_tool.is_agent ""))

(* Pins the input -> output mapping exactly, in both renderers. The predecessors
   ([format_timestamp_relative] / [format_ttl_remaining]) read
   [Time_compat.now ()] inside a [float -> string] signature, so the same post
   rendered differently from one minute to the next: every board payload was
   byte-new, [Board_tool_cache] could never hit, and a keeper read the drifting
   minute counter as a board change. The exact expectations below fail if a
   clock read is reintroduced; the predecessor assertions could not catch it
   because they only checked that the output contained the letters 'd' / 'm'. *)
let test_format_timestamp_absolute () =
  Alcotest.(check string)
    "epoch renders as ISO8601 UTC"
    "1970-01-01T00:00:00Z"
    (Board_tool.format_timestamp_absolute 0.0);
  Alcotest.(check string)
    "fixed instant renders as ISO8601 UTC"
    "2023-11-14T22:13:20Z"
    (Board_tool.format_timestamp_absolute 1_700_000_000.0);
  (* [0.0] is the stored no-expiry sentinel, so "permanent" is derived from the
     data rather than from a clock comparison. *)
  Alcotest.(check string)
    "no-expiry sentinel"
    "permanent"
    (Board_tool_format.format_expiry 0.0);
  Alcotest.(check string)
    "expiry instant renders as ISO8601 UTC"
    "2023-11-14T22:13:20Z"
    (Board_tool_format.format_expiry 1_700_000_000.0)

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

(* RFC-0393: keeper-ness is a registry lookup, not a name shape. With no
   registered keeper, the old wrapper spelling is an ordinary agent name —
   nothing is recovered from the string. *)
let test_board_actor_identity_is_registry_backed () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let json = Server_utils.board_actor_identity_json "keeper-delta-agent" in
  Alcotest.(check string) "kind" "agent" (json_member_string json "kind");
  Alcotest.(check string) "id" "keeper-delta-agent" (json_member_string json "id");
  Alcotest.(check string) "key" "agent:keeper-delta-agent"
    (json_member_string json "key");
  Alcotest.(check string) "source" "raw_agent" (json_member_string json "source")

let test_board_actor_identity_keeps_non_keeper_agent () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let json = Server_utils.board_actor_identity_json "codex" in
  Alcotest.(check string) "kind" "agent" (json_member_string json "kind");
  Alcotest.(check string) "id" "codex" (json_member_string json "id");
  Alcotest.(check string) "key" "agent:codex" (json_member_string json "key");
  Alcotest.(check string) "source" "raw_agent"
    (json_member_string json "source")

let test_board_dashboard_json_embeds_reaction_summaries () =
  with_eio @@ fun env ->
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
        ("author", `String "delta");
        ("meta", `Assoc [ ("trace", `String "probe-10297") ]);
      ]
  in
  let normalized =
    Mcp_tool_runtime_board.ensure_board_post_author
      ~agent_name:"xi-hammer" args
  in
  Alcotest.(check string) "author from ctx" "xi-hammer"
    Yojson.Safe.Util.(normalized |> member "author" |> to_string);
  Alcotest.(check string) "caller claim preserved" "delta"
    Yojson.Safe.Util.(
      normalized |> member "meta" |> member "author_caller_claim" |> to_string);
  Alcotest.(check string) "existing meta preserved" "probe-10297"
    Yojson.Safe.Util.(normalized |> member "meta" |> member "trace" |> to_string)

let test_inline_board_post_author_accepts_matching_alias () =
  let args =
    make_args
      [
        ("content", `String "ctx-owned post");
        ("author", `String "delta");
      ]
  in
  let normalized =
    Mcp_tool_runtime_board.ensure_board_post_author ~agent_name:"delta" args
  in
  Alcotest.(check string) "author canonical" "delta"
    Yojson.Safe.Util.(normalized |> member "author" |> to_string);
  Alcotest.(check bool) "no mismatch claim" true
    (match Yojson.Safe.Util.member "meta" normalized with
     | `Null -> true
     | meta -> Yojson.Safe.Util.member "author_caller_claim" meta = `Null)

(** {2 Group 2: JSON helper functions} *)

let test_get_string () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("key", `String "value")] in
  Alcotest.(check string) "get existing" "value"
    (Tool_args.get_string args "key" "default");
  Alcotest.(check string) "get missing" "default"
    (Tool_args.get_string args "missing" "default")

let test_get_string_opt () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("key", `String "value")] in
  Alcotest.(check (option string)) "get existing" (Some "value")
    (Tool_args.get_string_opt args "key");
  Alcotest.(check (option string)) "get missing" None
    (Tool_args.get_string_opt args "missing")

let test_get_int () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("n", `Int 42)] in
  Alcotest.(check int) "get existing" 42
    (Tool_args.get_int args "n" 0);
  Alcotest.(check int) "get missing" 0
    (Tool_args.get_int args "missing" 0)

let test_get_bool () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let args = make_args [("flag", `Bool true)] in
  Alcotest.(check bool) "get existing" true
    (Tool_args.get_bool args "flag" false);
  Alcotest.(check bool) "get missing" false
    (Tool_args.get_bool args "missing" false)

(** {2 Group 3: Post Create / List / Get} *)

let test_post_create_success () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board"); ("author", `String "tester")]) in
  Alcotest.(check bool) "create ok" true ok;
  Alcotest.(check bool) "body has post" true (String.length body > 0)

let test_post_create_metadata_payload () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args
       [
         ("title", `String "Why");
         ("content", `String "Visible answer\n\nSupporting detail");
         ("author", `String "alpha");
         ("meta", `Assoc [ ("source", `String "keeper_autonomy") ]);
       ])
  in
  Alcotest.(check bool) "create ok" true ok;
  let json = parse_create_response_json body in
  Alcotest.(check string) "title kept" "Why"
    Yojson.Safe.Util.(json |> member "title" |> to_string);
  Alcotest.(check string) "body kept" "Visible answer\n\nSupporting detail"
    Yojson.Safe.Util.(json |> member "body" |> to_string);
  Alcotest.(check string) "public posts stay direct" "direct"
    Yojson.Safe.Util.(json |> member "post_kind" |> to_string);
  Alcotest.(check string) "source meta kept" "keeper_autonomy"
    Yojson.Safe.Util.(json |> member "meta" |> member "source" |> to_string)

(* Regression guard: board_post must return STRUCTURED [data] (`Assoc), not a
   `String that embeds stringified JSON. The `String form double-encodes the
   payload — a consumer that re-serializes the result (e.g. the dashboard's
   JSON.stringify) escapes the inner newlines back to literal "\n". Unlike
   [test_post_create_metadata_payload], which parses [message] (and passes for
   either shape via parse_create_response_json's `\n`-suffix branch), this test
   inspects [Tool_result.data] directly and fails on the `String shape. Guards
   against reverting to [make_ok ~data:(`String "Post created:\n...")]. *)
let test_post_create_data_is_structured () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let result =
    dispatch_result "masc_board_post"
      (make_args
         [ ("content", `String "Structured body"); ("author", `String "tester") ])
  in
  Alcotest.(check bool) "create ok" true (Tool_result.is_success result);
  (match Tool_result.data result with
   | `Assoc fields ->
     Alcotest.(check bool) "structured data carries post id" true
       (List.mem_assoc "id" fields)
   | `String _ ->
       Alcotest.fail
       "board_post data is a raw `String (double-encoded JSON); expected structured `Assoc"
   | other ->
     Alcotest.failf "unexpected board_post data shape: %s"
       (Yojson.Safe.to_string other))

let test_activity_projection_failure_preserves_primary_effect () =
  let primary_result =
    Tool_result.make_ok
      ~tool_name:"masc_board_post"
      ~start_time:0.0
      ~data:(`Assoc [ ("id", `String "post-1") ])
      ()
  in
  let result =
    Mcp_tool_runtime_board.For_testing.result_after_activity_projection
      ~tool_name:"masc_board_post"
      ~start_time:0.0
      ~primary_result
      ~operation:"posted"
      (fun () -> Error "activity graph unavailable")
  in
  Alcotest.(check bool) "projection failure is not success" false
    (Tool_result.is_success result);
  Alcotest.(check (option string)) "projection failure is runtime failure"
    (Some "runtime_failure")
    (Tool_result.failure_class result
     |> Option.map Tool_result.tool_failure_class_to_string);
  let data = Tool_result.data result in
  Alcotest.(check string) "committed primary effect is explicit"
    "proven_post_effect"
    Yojson.Safe.Util.(data |> member "effect_disposition" |> to_string);
  Alcotest.(check string) "operation is explicit" "posted"
    Yojson.Safe.Util.(data |> member "projection" |> to_string);
  Alcotest.(check string) "primary result is preserved" "post-1"
    Yojson.Safe.Util.(data |> member "primary_result" |> member "id" |> to_string)

let test_post_create_judgment_roundtrip () =
  with_eio @@ fun env ->
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
  Alcotest.(check string) "judgment summary kept in meta" summary
    Yojson.Safe.Util.(json |> member "meta" |> member "judgment" |> member "summary" |> to_string)

(** Judgment as JSON List (e.g. [{summary: "...", confidence: 0.9}])
    was silently dropped before the fix. Issue #16300. *)
let test_post_create_judgment_list_roundtrip () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body =
    dispatch "masc_board_post"
      (make_args
         [
           ("content", `String "List-judged board post");
           ("author", `String "tester");
           ( "judgment",
             `List [ `Assoc [ ("summary", `String "list-judged"); ("score", `Float 0.85) ] ] );
         ])
  in
  Alcotest.(check bool) "create ok" true ok;
  let json = parse_create_response_json body in
  let judgment_json = Yojson.Safe.Util.(json |> member "meta" |> member "judgment") in
  (* The List judgment must be preserved, not silently dropped. *)
  Alcotest.(check bool) "list judgment is a non-null value" true
    (judgment_json <> `Null);
  let summary = Yojson.Safe.Util.(judgment_json |> index 0 |> member "summary" |> to_string) in
  Alcotest.(check string) "list judgment summary preserved" "list-judged" summary

(** Scalar JSON types (Bool, Int, Float, Intlit) for judgment must not
    silently produce a valid post with judgment absent. They are coerced
    to strings so the data is preserved. Issue #16300. *)
let test_post_create_judgment_scalar_types_ignored () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let scalars =
    [
      ("Bool", `Bool true);
      ("Int", `Int 42);
      ("Float", `Float 3.14);
      ("Intlit", `Intlit "999999999999999999999999");
    ]
  in
  List.iter
    (fun (label, scalar_value) ->
       cleanup ();
       let ok, body =
         dispatch "masc_board_post"
           (make_args
              [
                ("content", `String ("scalar-judgment-" ^ label));
                ("author", `String "tester");
                ("judgment", scalar_value);
              ])
       in
       Alcotest.(check bool) (label ^ ": create ok") true ok;
       let json = parse_create_response_json body in
       let judgment_json =
         try Yojson.Safe.Util.(json |> member "meta" |> member "judgment")
         with _ -> `Null
       in
       Alcotest.(check (option string))
         (label ^ ": scalar judgment coerced to string")
         (Some (Yojson.Safe.to_string scalar_value))
         Yojson.Safe.Util.(to_string_option judgment_json))
    scalars

let test_post_create_sources_footer_and_meta () =
  with_eio @@ fun env ->
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
  let content = Yojson.Safe.Util.(json |> member "body" |> to_string) in
  Alcotest.(check bool) "sources footer appended" true
    (String_util.contains_substring content "## Sources");
  Alcotest.(check bool) "source url rendered" true
    (String_util.contains_substring content "<https://example.com/docs>");
  Alcotest.(check string) "source url persisted" "https://example.com/docs"
    Yojson.Safe.Util.(
      json |> member "meta" |> member "sources" |> index 0 |> member "url"
      |> to_string);
  Alcotest.(check bool) "external source flag" true
    Yojson.Safe.Util.(json |> member "meta" |> member "has_external_sources" |> to_bool)

let test_masc_board_post_preserves_meta_reason () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"judge-keeper" () in
  let reason =
    "LLM judged this as automation because it broadcasts a keeper-owned status update."
  in
  let body =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_post"
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
    Yojson.Safe.Util.(json |> member "meta" |> member "classification_reason" |> to_string);
  Alcotest.(check string) "keeper source injected" "masc_board_post"
    Yojson.Safe.Util.(json |> member "meta" |> member "source" |> to_string);
  Alcotest.(check string) "existing meta preserved" "probe-1"
    Yojson.Safe.Util.(json |> member "meta" |> member "trace" |> to_string);
  Alcotest.(check string) "author forced from keeper meta" "judge-keeper"
    Yojson.Safe.Util.(json |> member "author" |> to_string);
  Alcotest.(check string) "keeper provenance remains automation" "automation"
    Yojson.Safe.Util.(json |> member "post_kind" |> to_string)

let test_keeper_board_sub_board_owner_is_runtime_bound () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"sub-board-keeper" () in
  let slug = "typed-owner-boundary" in
  let created =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_sub_board_create"
      ~args:
        (make_args
           [ "slug", `String slug
           ; "name", `String "Typed owner boundary"
           ; "description", `String "owner comes from keeper identity"
           ; "owner", `String "spoofed-owner"
           ])
  in
  Alcotest.(check bool) "sub-board create succeeds" false
    (String_util.contains_substring created "error");
  let fetched =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_sub_board_get"
      ~args:(make_args [ "sub_board_id", `String slug ])
  in
  Alcotest.(check bool) "owner is keeper identity" true
    (String_util.contains_substring fetched "Owner: sub-board-keeper");
  Alcotest.(check bool) "spoofed owner is absent" false
    (String_util.contains_substring fetched "spoofed-owner")

(* An access value the handler cannot read is refused with the accepted
   values named; it never becomes [Open] on create or a no-op on update. *)
let test_sub_board_unknown_access_is_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, message =
    dispatch
      "masc_board_sub_board_create"
      (make_args
         [ "slug", `String "wrong-case-access"
         ; "name", `String "Wrong case"
         ; "owner", `String "access-owner"
         ; "access", `String "Members_only"
         ])
  in
  Alcotest.(check bool) "create with unknown access fails" false ok;
  Alcotest.(check bool) "create error names members_only" true
    (String_util.contains_substring message "members_only");
  Alcotest.(check bool) "no sub-board was created" true
    (Result.is_error
       (Board_dispatch.get_sub_board ~sub_board_id:"wrong-case-access"));
  let ok, _ =
    dispatch
      "masc_board_sub_board_create"
      (make_args
         [ "slug", `String "guarded-access"
         ; "name", `String "Guarded"
         ; "owner", `String "access-owner"
         ; "access", `String "owner_only"
         ])
  in
  Alcotest.(check bool) "create with owner_only succeeds" true ok;
  let ok, message =
    dispatch
      "masc_board_sub_board_update"
      (make_args
         [ "sub_board_id", `String "guarded-access"
         ; "owner", `String "access-owner"
         ; "access", `String "private"
         ])
  in
  Alcotest.(check bool) "update with unknown access fails" false ok;
  Alcotest.(check bool) "update error names owner_only" true
    (String_util.contains_substring message "owner_only");
  match Board_dispatch.get_sub_board ~sub_board_id:"guarded-access" with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok sb ->
    Alcotest.(check bool) "stored access unchanged" true
      (sb.Board.access = Board.Owner_only)

let test_direct_board_reaction_binds_keeper_identity () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, created =
    dispatch
      "masc_board_post"
      (make_args
         [ "content", `String "reaction identity target"
         ; "author", `String "post-author"
         ])
  in
  Alcotest.(check bool) "target post created" true ok;
  let post_id =
    Yojson.Safe.Util.(parse_create_response_json created |> member "id" |> to_string)
  in
  let keeper_meta = make_keeper_meta ~name:"reaction-keeper" () in
  let reacted =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_reaction"
      ~args:
        (make_args
           [ "target_type", `String "post"
           ; "target_id", `String post_id
           ; "user_id", `String "spoofed-user"
           ; "emoji", `String "👍"
           ])
    |> Yojson.Safe.from_string
  in
  Alcotest.(check string) "reaction identity is runtime-owned" "reaction-keeper"
    Yojson.Safe.Util.(reacted |> member "user_id" |> to_string)

let test_model_visible_board_maintenance_dispatches_in_process () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let model_names = Keeper_tool_policy.keeper_model_tool_names () in
  Alcotest.(check bool) "cleanup descriptor is model-visible" true
    (List.mem "masc_board_cleanup" model_names);
  Alcotest.(check bool) "delete descriptor is model-visible" true
    (List.mem "masc_board_delete" model_names);
  let keeper_meta = make_keeper_meta ~name:"maintenance-keeper" () in
  let cleanup_result =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_cleanup"
      ~args:(make_args [ "dry_run", `Bool true ])
  in
  Alcotest.(check bool) "cleanup reaches its Board handler" true
    (String.starts_with ~prefix:"Scan complete:" cleanup_result
     || String.starts_with ~prefix:"Dry-run:" cleanup_result);
  let ok, created =
    dispatch
      "masc_board_post"
      (make_args
         [ "content", `String "in-process delete target"
         ; "author", `String keeper_meta.name
         ])
  in
  Alcotest.(check bool) "delete target created" true ok;
  let post_id =
    Yojson.Safe.Util.(parse_create_response_json created |> member "id" |> to_string)
  in
  let delete_result =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_delete"
      ~args:
        (make_args
           [ "post_id", `String post_id; "author", `String "spoofed-author" ])
  in
  Alcotest.(check bool) "delete reaches its Board handler" true
    (String_util.contains_substring delete_result post_id);
  match Board_dispatch.get_post ~post_id with
  | Ok _ -> Alcotest.fail "model-visible in-process delete left the post behind"
  | Error _ -> ()

let test_keeper_board_dispatch_uses_typed_tool_names () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"typed-keeper" () in
  let fake =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_fake"
      ~args:(make_args [])
  in
  Alcotest.(check bool) "fake board name rejected" true
    (String_util.contains_substring fake "unknown_board_tool");
  let comment_vote =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_comment_vote"
      ~args:(make_args [ ("comment_id", `String ""); ("direction", `String "up") ])
  in
  Alcotest.(check bool) "typed comment vote reaches board handler" true
    (String_util.contains_substring comment_vote "comment_id required");
  Alcotest.(check bool) "typed comment vote is not unknown" false
    (String_util.contains_substring comment_vote "unknown_board_tool");
  let curation =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_curation_read"
      ~args:(make_args [])
  in
  Alcotest.(check string) "typed curation read reaches board handler" "null" curation;
  Alcotest.(check bool) "typed curation read is not unknown" false
    (String_util.contains_substring curation "unknown_board_tool");
  let curation_submit =
    Keeper_tool_board_runtime.handle_board_tool
      ~meta:keeper_meta
      ~result_projection:Tool_output.default_model_projection
      ~name:"masc_board_curation_submit"
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
             ("rationale", `String "Summarize active board activity");
             ("provenance", `Assoc [ ("source", `String "test") ]);
           ])
  in
  Alcotest.(check bool) "typed curation submit is not unknown" false
    (String_util.contains_substring curation_submit "unknown_board_tool");
  let submit_json = Yojson.Safe.from_string curation_submit in
  Alcotest.(check string) "keeper source injected for curation" "typed-keeper"
    Yojson.Safe.Util.(submit_json |> member "submitted_by" |> to_string);
  Alcotest.(check string) "curation summary persisted"
    "Two active threads need routing."
    Yojson.Safe.Util.(submit_json |> member "summary" |> to_string)

let test_board_curation_read_empty_returns_json_null () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_curation_read" (make_args []) in
  Alcotest.(check bool) "curation read ok" true ok;
  Alcotest.(check string) "empty curation snapshot is JSON null" "null" body

let test_board_curation_submit_roundtrips_to_read () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let missing_ok, missing_body =
    dispatch "masc_board_curation_submit"
      (make_args [ ("rationale", `String "missing submitted_by") ])
  in
  Alcotest.(check bool) "raw submit requires submitted_by" false missing_ok;
  Alcotest.(check string) "missing submitted_by error" "submitted_by required"
    missing_body;
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
    (String_util.contains_substring invalid_provenance_body "object");
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
                    ("score", `String " 0.9 ");
                    ("rationale", `String "Direct answer candidate");
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
  Alcotest.(check bool) "model omitted from board curation contract" true
    Yojson.Safe.Util.(submitted |> member "model" = `Null);
  Alcotest.(check string) "summary persisted"
    "Board has one high-priority routing item."
    Yojson.Safe.Util.(submitted |> member "summary" |> to_string);
  Alcotest.(check (list string)) "ordering trims and drops blanks" [ "p-7" ]
    Yojson.Safe.Util.(submitted |> member "ordering" |> to_list |> List.map to_string);
  Alcotest.(check (list string)) "highlights trim and drop blanks" [ "p-7" ]
    Yojson.Safe.Util.(submitted |> member "highlights" |> to_list |> List.map to_string);
  Alcotest.(check bool) "health score omitted from board curation contract" true
    Yojson.Safe.Util.(submitted |> member "health_score" = `Null);
  Alcotest.(check bool) "health components omitted from board curation contract" true
    Yojson.Safe.Util.(submitted |> member "health_components" = `Null);
  let answer_match =
    Yojson.Safe.Util.(submitted |> member "answer_matches" |> to_list |> List.hd)
  in
  Alcotest.(check (float 0.0001)) "string answer score parsed" 0.9
    Yojson.Safe.Util.(answer_match |> member "score" |> to_float);
  let read_ok, read_body = dispatch "masc_board_curation_read" (make_args []) in
  Alcotest.(check bool) "curation read after submit ok" true read_ok;
  let read_json = Yojson.Safe.from_string read_body in
  Alcotest.(check string) "read returns latest id"
    Yojson.Safe.Util.(submitted |> member "id" |> to_string)
    Yojson.Safe.Util.(read_json |> member "id" |> to_string);
  Alcotest.(check string) "read returns latest summary"
    "Board has one high-priority routing item."
    Yojson.Safe.Util.(read_json |> member "summary" |> to_string)

let mcp_runtime_board_dispatch name args =
  let state = Mcp_server.For_testing.create_state ~base_path:_test_base_path in
  Mcp_tool_runtime_board.dispatch ~config:(Mcp_server.workspace_config state)
    ~agent_name:"mcp-runtime-curator" ~arguments:args ~state ~name
    ~start_time:(Unix.gettimeofday ())

let require_mcp_runtime_result name args =
  match mcp_runtime_board_dispatch name args with
  | Some result -> ((Tool_result.is_success result), (Tool_result.message result))
  | None -> Alcotest.failf "%s not routed by MCP runtime board dispatch" name

let test_board_curation_mcp_runtime_routes_read_and_submit () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  (* The switch stays: [with_eio] scopes the fibers this test runs under. The
     clock binding existed only to reach [dispatch], which never read it. *)
  Eio.Switch.run @@ fun _sw ->
  let read_ok, read_body =
    require_mcp_runtime_result "masc_board_curation_read" (make_args [])
  in
  Alcotest.(check bool) "MCP runtime curation read ok" true read_ok;
  Alcotest.(check string) "MCP runtime curation read empty" "null" read_body;
  let submit_ok, submit_body =
    require_mcp_runtime_result "masc_board_curation_submit"
      (make_args
         [
           ("submitted_by", `String "mcp-runtime-curator");
           ("summary", `String "MCP runtime curation route works.");
           ("rationale", `String "Pin schema-to-dispatch curation routing");
         ])
  in
  Alcotest.(check bool) "MCP runtime curation submit ok" true submit_ok;
  let submitted = Yojson.Safe.from_string submit_body in
  (* #23489 routes curation_submit through [enforce_caller_identity];
     RFC-0393: the caller's name is stored verbatim — nothing is recovered
     from its shape. *)
  Alcotest.(check string) "MCP runtime submitted_by persisted"
    "mcp-runtime-curator"
    Yojson.Safe.Util.(submitted |> member "submitted_by" |> to_string);
  let read2_ok, read2_body =
    require_mcp_runtime_result "masc_board_curation_read" (make_args [])
  in
  Alcotest.(check bool) "MCP runtime curation read after submit ok" true read2_ok;
  Alcotest.(check string) "MCP runtime curation read after submit summary"
    "MCP runtime curation route works."
    Yojson.Safe.Util.(
      Yojson.Safe.from_string read2_body |> member "summary" |> to_string)

let test_post_create_accepts_automation_rejects_system () =
  with_eio @@ fun env ->
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
    (String_util.contains_substring body_sys "reserved")

let test_post_create_empty_content () =
  with_eio @@ fun env ->
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
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args
       [ ("title", `String "   "); ("content", `String "Hello board");
         ("author", `String "tester") ]) in
  Alcotest.(check bool) "empty title rejected" false ok;
  Alcotest.(check bool) "error mentions title" true
    (String_util.contains_substring body "title" || String_util.contains_substring body "Title")

let test_post_create_missing_author_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board")]) in
  Alcotest.(check bool) "missing author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (String_util.contains_substring body "author")

let test_post_create_anonymous_author_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board"); ("author", `String "anonymous")]) in
  Alcotest.(check bool) "anonymous author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (String_util.contains_substring body "author")

let test_post_list_empty () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_list" (make_args []) in
  Alcotest.(check bool) "list ok" true ok;
  Alcotest.(check bool) "no posts msg" true
    (String.length body > 0)

let test_cleanup_clears_persisted_jsonl () =
  with_eio @@ fun env ->
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
    (String_util.contains_substring body "persist me")

let test_post_list_with_posts () =
  with_eio @@ fun env ->
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
  with_eio @@ fun env ->
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
  with_eio @@ fun env ->
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
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  ignore (dispatch "masc_board_post"
    (make_args [("content", `String "sort test"); ("author", `String "a")]));
  let ok, body = dispatch "masc_board_list"
    (make_args [("sort", `String "invalid_xyz")]) in
  Alcotest.(check bool) "invalid sort rejected" false ok;
  Alcotest.(check bool) "error mentions valid sorts" true
    (String_util.contains_substring body "invalid sort. Valid: hot, trending, recent, updated, discussed")

let test_post_list_filter_combinations () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  ignore (dispatch "masc_board_post"
    (make_args [("content", `String "human"); ("author", `String "human-author")]));
  ignore (Board_dispatch.create_post ~author:"dashboard-harness-bot"
            ~content:"automation" ~visibility:Board.Internal ~ttl_hours:1
            ~hearth:"dashboard-harness" ~post_kind:Board.Automation_post ());
  ignore (Board_dispatch.create_post ~author:"dm-keeper" ~content:"keeper"
            ~post_kind:Board.Automation_post
            ~meta_json:(`Assoc [ ("source", `String "masc_board_post") ]) ());
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
    (String_util.contains_substring body1 "keeper-alert-bot");
  Alcotest.(check bool) "exclude_system keeps keeper" true
    (String_util.contains_substring body1 "dm-keeper");
  Alcotest.(check bool) "exclude_automation keeps system" true
    (String_util.contains_substring body2 "keeper-alert-bot");
  Alcotest.(check bool) "exclude_automation hides keeper" false
    (String_util.contains_substring body2 "dm-keeper");
  Alcotest.(check bool) "exclude_automation hides harness" false
    (String_util.contains_substring body2 "dashboard-harness-bot");
  Alcotest.(check bool) "exclude both keeps human" true
    (String_util.contains_substring body3 "human-author");
  Alcotest.(check bool) "exclude both hides keeper" false
    (String_util.contains_substring body3 "dm-keeper");
  Alcotest.(check bool) "exclude both hides harness" false
    (String_util.contains_substring body3 "dashboard-harness-bot")

let test_dispatch_delete_success () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let _ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "to be deleted"); ("author", `String "tester")]) in
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  let ok_del, msg_del =
    dispatch
      "masc_board_delete"
      (make_args [ ("post_id", `String post_id); ("author", `String "tester") ])
  in
  Alcotest.(check bool) "delete ok" true ok_del;
  Alcotest.(check bool) "delete msg contains id" true
    (String_util.contains_substring msg_del post_id)

let test_dispatch_delete_not_found () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body =
    dispatch
      "masc_board_delete"
      (make_args [ ("post_id", `String "nonexistent-id"); ("author", `String "tester") ])
  in
  Alcotest.(check bool) "delete not found" false ok;
  Alcotest.(check bool) "error message present" true
    (String_util.contains_substring body "Post not found" || String_util.contains_substring body "nonexistent-id")

let test_dispatch_delete_empty_id () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_delete"
    (make_args [("post_id", `String "")]) in
  Alcotest.(check bool) "empty id rejected" false ok;
  Alcotest.(check bool) "error mentions required" true
    (String_util.contains_substring body "required")

let test_dispatch_post_update_success () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let _ok, body =
    dispatch "masc_board_post"
      (make_args
         [ ("content", `String "original tool body")
         ; ("author", `String "edit-tool-author")
         ])
  in
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  let ok_edit, msg_edit =
    dispatch "masc_board_post_update"
      (make_args
         [ ("post_id", `String post_id)
         ; ("author", `String "edit-tool-author")
         ; ("content", `String "edited tool body")
         ])
  in
  Alcotest.(check bool) "edit ok" true ok_edit;
  Alcotest.(check bool) "edit msg contains new body" true
    (String_util.contains_substring msg_edit "edited tool body");
  (match Board_dispatch.get_post ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok post -> Alcotest.(check string) "edit persisted" "edited tool body" post.body)

let test_dispatch_post_update_rejects_non_owner () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let _ok, body =
    dispatch "masc_board_post"
      (make_args
         [ ("content", `String "owned tool body"); ("author", `String "tool-owner") ])
  in
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  let ok_edit, _msg =
    dispatch "masc_board_post_update"
      (make_args
         [ ("post_id", `String post_id)
         ; ("author", `String "tool-intruder")
         ; ("content", `String "hijacked tool body")
         ])
  in
  Alcotest.(check bool) "non-owner edit rejected" false ok_edit;
  (* the rejected edit must not touch the stored content *)
  (match Board_dispatch.get_post ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok post ->
     Alcotest.(check string) "original preserved on rejected edit" "owned tool body"
       post.body)

let test_dispatch_post_update_transfers_author () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let _ok, body =
    dispatch "masc_board_post"
      (make_args
         [ ("content", `String "transfer tool body")
         ; ("author", `String "tool-transfer-owner")
         ])
  in
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  let ok_edit, msg_edit =
    dispatch "masc_board_post_update"
      (make_args
         [ ("post_id", `String post_id)
         ; ("author", `String "tool-transfer-owner")
         ; ("content", `String "transferred tool body")
         ; ("new_author", `String "tool-transfer-next")
         ])
  in
  Alcotest.(check bool) "transfer edit ok" true ok_edit;
  Alcotest.(check bool) "edit msg contains new author" true
    (String_util.contains_substring msg_edit "tool-transfer-next");
  match Board_dispatch.get_post ~post_id with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      Alcotest.(check string) "tool transfer author persisted"
        "tool-transfer-next"
        (Board.Agent_id.to_string post.author);
      Alcotest.(check string) "tool transfer content persisted"
        "transferred tool body" post.body

let test_dispatch_post_update_missing_id () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body =
    dispatch "masc_board_post_update"
      (make_args [ ("author", `String "x"); ("content", `String "y") ])
  in
  Alcotest.(check bool) "missing post_id rejected" false ok;
  Alcotest.(check bool) "error mentions required" true (String_util.contains_substring body "required")

let test_post_get_success () =
  with_eio @@ fun env ->
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
  let ok2, body2 = dispatch "masc_board_post_get"
    (make_args [("post_id", `String post_id)]) in
  Alcotest.(check bool) "get ok" true ok2;
  Alcotest.(check bool) "get has content" true (String.length body2 > 0)

let create_post_with_comments ~count =
  let ok, body =
    dispatch
      "masc_board_post"
      (make_args
         [ "content", `String (Printf.sprintf "Get comments %d" count)
         ; "author", `String (Printf.sprintf "tester-%d" count)
         ])
  in
  Alcotest.(check bool) "create ok" true ok;
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  for i = 1 to count do
    let ok, _body =
      dispatch
        "masc_board_comment"
        (make_args
           [ "post_id", `String post_id
           ; "content", `String (Printf.sprintf "comment-%03d" i)
           ; "author", `String (Printf.sprintf "commenter-%03d" i)
           ])
    in
    Alcotest.(check bool) (Printf.sprintf "comment %d ok" i) true ok
  done;
  post_id

let post_get_args post_id args = make_args (("post_id", `String post_id) :: args)

let contains haystack needle = String_util.contains_substring haystack needle

(* A Keeper call on each lane: the official-client lane stores a result above
   the wire ceiling as a blob, the agent-core lane only above its own. *)
let official_client_lane =
  Tool_output.Projected_for_model Tool_output.default_model_projection

let agent_core_lane =
  Tool_output.Projected_for_model Tool_output.agent_core_model_projection

(* A page as its reader gets it: [body] is the text the model reads, which is
   what a boundary measures, and the rest is the position the result carries
   beside it -- read back through its decoder, never parsed out of the text. *)
type page_view =
  { body : string
  ; thread : string
  ; offset : int
  ; returned : int
  ; total : int
  ; next_offset : int option
  }

let page_view_of ~body ~metadata =
  let position =
    match Board.Comment_page.Position.of_metadata metadata with
    | Some position -> position
    | None -> Alcotest.failf "the page carries no position: %s" body
  in
  let first_line =
    match String.index_opt body '\n' with
    | Some index -> String.sub body 0 index
    | None -> body
  in
  Alcotest.(check string)
    "the page's first line is the position, from the one printer"
    (Board.Comment_page.Position.line position)
    first_line;
  { body
  ; thread = body
  ; offset = position.Board.Comment_page.Position.offset
  ; returned = position.Board.Comment_page.Position.returned
  ; total = position.Board.Comment_page.Position.total
  ; next_offset = position.Board.Comment_page.Position.next_offset
  }

let read_page ~result_boundary ~label post_id args =
  let result =
    Board_tool.handle_tool
      ~result_boundary
      "masc_board_post_get"
      (post_get_args post_id args)
  in
  Alcotest.(check bool) (label ^ " get ok") true (Tool_result.is_success result);
  page_view_of ~body:(Tool_result.message result) ~metadata:(Tool_result.metadata result)

let check_page ~label page ~offset ~returned ~total ~next_offset =
  Alcotest.(check int) (label ^ ": offset") offset page.offset;
  Alcotest.(check int) (label ^ ": returned") returned page.returned;
  Alcotest.(check int) (label ^ ": total") total page.total;
  Alcotest.(check (option int)) (label ^ ": next_offset") next_offset page.next_offset

let check_get_rejected ~label post_id args expected =
  let result = dispatch_result "masc_board_post_get" (post_get_args post_id args) in
  Alcotest.(check bool) (label ^ " is not a successful read") false
    (Tool_result.is_success result);
  check_failure_class (label ^ " needs a corrected call") (Some "workflow_rejection") result;
  Alcotest.(check bool)
    (label ^ ": " ^ expected)
    true
    (contains (Tool_result.message result) expected)

let add_comment_id ~post_id ?parent_id content =
  let parent_arg =
    match parent_id with
    | Some parent -> [ "parent_id", `String parent ]
    | None -> []
  in
  let ok, body =
    dispatch
      "masc_board_comment"
      (make_args
         ([ "post_id", `String post_id
          ; "content", `String content
          ; "author", `String "thread-reader"
          ]
          @ parent_arg))
  in
  Alcotest.(check bool) (content ^ " comment ok") true ok;
  parse_create_response_json body |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string

(* Every page from offset 0 until one names no next page, the way a caller
   continues. *)
let walk_thread ~result_boundary post_id =
  let rec walk offset pages =
    let label = Printf.sprintf "page at %d" offset in
    let page = read_page ~result_boundary ~label post_id [ "comment_offset", `Int offset ] in
    Alcotest.(check int) (label ^ " starts where it was asked") offset page.offset;
    Alcotest.(check bool) (label ^ " makes progress") true (page.returned > 0);
    let pages = pages @ [ page ] in
    match page.next_offset with
    | Some next ->
      Alcotest.(check int) (label ^ ": next_offset follows it") (offset + page.returned) next;
      walk next pages
    | None -> pages
  in
  walk 0 []

let long_comment_bytes = 1_500

let create_thread_of_long_comments ~count =
  let post_id = create_post_with_comments ~count:0 in
  let ids =
    List.init count (fun index ->
      add_comment_id
        ~post_id
        (Printf.sprintf "long-%03d %s" index (String.make long_comment_bytes 'x')))
  in
  post_id, ids

let test_post_get_comment_pages_carry_their_range () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:105 in
  let read ~label args =
    read_page ~result_boundary:Tool_output.Sent_to_client ~label post_id args
  in
  let default_page = read ~label:"default page" [] in
  check_page
    ~label:"default page"
    default_page
    ~offset:0
    ~returned:50
    ~total:105
    ~next_offset:(Some 50);
  Alcotest.(check bool)
    "header counts the thread it pages"
    true
    (contains default_page.thread "[105 replies]");
  check_page
    ~label:"normal page advances"
    (read ~label:"normal page" [ "comment_offset", `Int 2; "comment_limit", `Int 2 ])
    ~offset:2
    ~returned:2
    ~total:105
    ~next_offset:(Some 4);
  check_page
    ~label:"final page"
    (read ~label:"final page" [ "comment_offset", `Int 100; "comment_limit", `Int 100 ])
    ~offset:100
    ~returned:5
    ~total:105
    ~next_offset:None;
  (* A reader that finished the thread asks at its end to learn whether
     anything new arrived. That is a page, not a failure: it names the
     thread's size, so it cannot read as a thread without comments. Past the
     end is still refused. *)
  let end_page = read ~label:"end of the thread" [ "comment_offset", `Int 105 ] in
  check_page
    ~label:"the end of the thread"
    end_page
    ~offset:105
    ~returned:0
    ~total:105
    ~next_offset:None;
  Alcotest.(check bool) "the end page names the thread's size" true
    (contains end_page.body "[no comments from offset 105: the thread has 105 now.]");
  Alcotest.(check bool) "the end page does not say the thread has no comments" false
    (contains end_page.body "No comments.");
  check_get_rejected
    ~label:"offset past the end"
    post_id
    [ "comment_offset", `Int 106 ]
    "the thread now has 105 comments, at offsets 0-104";
  check_get_rejected
    ~label:"negative offset"
    post_id
    [ "comment_offset", `Int (-1) ]
    "comment_offset must be 0 or greater";
  check_get_rejected
    ~label:"limit over max"
    post_id
    [ "comment_limit", `Int 999 ]
    "comment_limit must be between 1 and 100";
  check_get_rejected
    ~label:"zero limit"
    post_id
    [ "comment_limit", `Int 0 ]
    "comment_limit must be between 1 and 100";
  let small_post_id = create_post_with_comments ~count:2 in
  check_page
    ~label:"small thread in one page"
    (read_page ~result_boundary:Tool_output.Sent_to_client ~label:"small" small_post_id [])
    ~offset:0
    ~returned:2
    ~total:2
    ~next_offset:None;
  let empty_post_id = create_post_with_comments ~count:0 in
  let empty_page =
    read_page ~result_boundary:Tool_output.Sent_to_client ~label:"empty" empty_post_id []
  in
  check_page ~label:"empty thread" empty_page ~offset:0 ~returned:0 ~total:0 ~next_offset:None;
  Alcotest.(check bool) "empty thread says so" true (contains empty_page.thread "No comments.");
  check_get_rejected
    ~label:"offset into an empty thread"
    empty_post_id
    [ "comment_offset", `Int 1 ]
    "the thread has no comments"

(* A value that is present but is not a JSON integer is refused by name. It
   used to fall back to the default page, so a caller that sent null or 2.9
   read a page it had not asked for. *)
let test_post_get_refuses_page_arguments_that_are_not_integers () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:2 in
  List.iter
    (fun (label, args, expected) -> check_get_rejected ~label post_id args expected)
    [ "null limit", [ "comment_limit", `Null ], "comment_limit must be an integer (got null)"
    ; ( "string offset"
      , [ "comment_offset", `String "abc" ]
      , "comment_offset must be an integer (got string)" )
    ; ( "boolean offset"
      , [ "comment_offset", `Bool true ]
      , "comment_offset must be an integer (got bool)" )
    ; ( "fractional limit"
      , [ "comment_limit", `Float 2.9 ]
      , "comment_limit must be an integer (got float)" )
    ; ( "literal past the int range"
      , [ "comment_offset", `Intlit "99999999999999999999999" ]
      , "comment_offset must be an integer this server can hold" )
    ; ( "float past the int range"
      , [ "comment_offset", `Float 1e30 ]
      , "comment_offset must be an integer this server can hold" )
    ]

(* What the model reads is the thread. A page whose data was a JSON object
   reached the model as that object on one line, thread text and all, which is
   the escaped wrapper this tool exists to avoid. The bridge is the path a
   Keeper's result takes, so the check runs through it. *)
let test_post_get_reaches_the_model_as_text () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:3 in
  let result =
    Board_tool.handle_tool
      ~result_boundary:official_client_lane
      "masc_board_post_get"
      (post_get_args post_id [])
  in
  match
    Tool_bridge.to_agent_core_typed_result
      ~model_projection:Tool_output.default_model_projection
      result
  with
  | Error error ->
    Alcotest.failf "the bridge refused the page: %s" error.Agent_core.Llm_provider.Types.message
  | Ok output ->
    let content = output.Agent_core.Llm_provider.Types.content in
    Alcotest.(check bool)
      "the position is the first line the model reads"
      true
      (String.starts_with ~prefix:"[comments 0-2 of 3" content);
    Alcotest.(check bool) "the thread is drawn in lines" true (String.contains content '\n');
    Alcotest.(check bool)
      "no line arrives escaped"
      false
      (contains content "\\n");
    Alcotest.(check bool)
      "the model is not handed a JSON object"
      false
      (match Yojson.Safe.from_string content with
       | `Assoc _ -> true
       | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ | `String _ | `List _ -> false
       | exception Yojson.Json_error _ -> false);
    (match
       Board.Comment_page.Position.of_metadata
         output.Agent_core.Llm_provider.Types._meta
     with
     | Some position ->
       Alcotest.(check int)
         "the position rides beside the text"
         3
         position.Board.Comment_page.Position.total
     | None -> Alcotest.fail "the bridged result carries no page position")

(* A JSON number with no fractional part is an integer, and the tool-call
   validator lets it through, so the handler must read it the same way. *)
let test_post_get_accepts_an_integer_valued_float () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:4 in
  check_page
    ~label:"integer-valued float page"
    (read_page
       ~result_boundary:Tool_output.Sent_to_client
       ~label:"integer-valued float page"
       post_id
       [ "comment_offset", `Float 2.0; "comment_limit", `Float 2.0 ])
    ~offset:2
    ~returned:2
    ~total:4
    ~next_offset:None

(* On the official-client lane a thread whose comments do not fit one inline
   result arrives as pages that each do, chained by next_offset, and every
   comment is read exactly once. *)
let test_post_get_long_thread_pages_fit_inline_and_chain () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id, ids = create_thread_of_long_comments ~count:40 in
  let pages = walk_thread ~result_boundary:official_client_lane post_id in
  List.iter
    (fun page ->
       Alcotest.(check bool)
         (Printf.sprintf "page at %d fits the wire ceiling" page.offset)
         true
         (String.length page.body <= Common.max_tool_result_wire_bytes))
    pages;
  let seen =
    List.concat_map (fun page -> List.filter (contains page.thread) ids) pages
  in
  Alcotest.(check bool) "the thread took more than one page" true (List.length pages > 1);
  Alcotest.(check int) "no comment is read twice" (List.length ids) (List.length seen);
  Alcotest.(check (list string))
    "every comment is read"
    (List.sort String.compare ids)
    (List.sort String.compare seen)

(* The same thread is one page only where the reader carries it inline
   without crossing a wire: MASC owns the process boundary on the agent-core
   lane, so nothing spills below its own ceiling and cutting the thread at
   the official-client ceiling would only cost the Keeper extra calls. An MCP
   caller crosses the same wire as the official-client lane, and
   [Tool_output.Sent_to_client] resolves to the same ceiling as
   [default_model_projection] (#36556), so both page a large thread the same
   way instead of the MCP caller taking it whole. *)
let test_post_get_page_follows_the_lane_ceiling () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let comment_count = 30 in
  let post_id, _ids = create_thread_of_long_comments ~count:comment_count in
  let agent_core =
    read_page ~result_boundary:agent_core_lane ~label:"agent-core lane" post_id []
  in
  check_page
    ~label:"agent-core lane"
    agent_core
    ~offset:0
    ~returned:comment_count
    ~total:comment_count
    ~next_offset:None;
  Alcotest.(check bool)
    "the agent-core page is larger than the wire ceiling"
    true
    (String.length agent_core.body > Common.max_tool_result_wire_bytes);
  Alcotest.(check bool)
    "and still inside the agent-core ceiling"
    true
    (String.length agent_core.body <= Common.max_agent_core_inline_result_bytes);
  let mcp_caller =
    read_page ~result_boundary:Tool_output.Sent_to_client ~label:"MCP caller" post_id []
  in
  Alcotest.(check int) "MCP caller: offset" 0 mcp_caller.offset;
  Alcotest.(check int) "MCP caller: total" comment_count mcp_caller.total;
  Alcotest.(check bool)
    "the MCP caller's page fits the wire ceiling, like the official-client lane"
    true
    (String.length mcp_caller.body <= Common.max_tool_result_wire_bytes);
  Alcotest.(check bool)
    "the MCP caller needs more than one page for a thread this large, same ceiling as the \
     official-client lane"
    true
    (mcp_caller.returned < comment_count && Option.is_some mcp_caller.next_offset);
  Alcotest.(check bool)
    "the official-client lane needs more than one page"
    true
    (List.length (walk_thread ~result_boundary:official_client_lane post_id) > 1)

(* The Keeper board runtime pages by the projection it is handed, which is
   the one the bundle resolved for the lane running the call. *)
let test_keeper_board_read_pages_by_the_projection_it_is_given () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let comment_count = 30 in
  let post_id, _ids = create_thread_of_long_comments ~count:comment_count in
  let keeper_meta = make_keeper_meta ~name:"thread-reader-keeper" () in
  let read result_projection =
    let execution =
      Keeper_tool_board_runtime.handle_board_tool_with_outcome
        ~meta:keeper_meta
        ~result_projection
        ~name:"masc_board_post_get"
        ~args:(post_get_args post_id [])
    in
    page_view_of
      ~body:execution.Keeper_tool_execution.raw_output
      ~metadata:execution.Keeper_tool_execution.metadata
  in
  check_page
    ~label:"agent-core projection"
    (read Tool_output.agent_core_model_projection)
    ~offset:0
    ~returned:comment_count
    ~total:comment_count
    ~next_offset:None;
  let official = read Tool_output.default_model_projection in
  Alcotest.(check bool)
    "the default projection stops the page early"
    true
    (Option.is_some official.next_offset);
  Alcotest.(check bool)
    "inside the wire ceiling"
    true
    (String.length official.body <= Common.max_tool_result_wire_bytes)

(* A comment larger than a page travels alone and whole; the projection then
   decides how it reaches the reader. The pages around it still fit. *)
let test_post_get_a_comment_larger_than_the_page_arrives_alone () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:0 in
  let before = add_comment_id ~post_id "before the large comment" in
  let large =
    add_comment_id
      ~post_id
      ("large " ^ String.make (Common.max_tool_result_wire_bytes + 1) 'y')
  in
  let after = add_comment_id ~post_id "after the large comment" in
  match walk_thread ~result_boundary:official_client_lane post_id with
  | [ first; middle; last ] ->
    Alcotest.(check bool) "the first page holds the comment before" true (contains first.thread before);
    Alcotest.(check int) "and only that one" 1 first.returned;
    Alcotest.(check bool) "the large comment is on its own page" true (contains middle.thread large);
    Alcotest.(check int) "alone" 1 middle.returned;
    Alcotest.(check bool)
      "whole, past the ceiling"
      true
      (String.length middle.body > Common.max_tool_result_wire_bytes);
    Alcotest.(check bool) "the last page holds the comment after" true (contains last.thread after)
  | pages -> Alcotest.failf "expected three pages, got %d" (List.length pages)

(* The body travels on the first page. When it alone passes the ceiling the
   page still carries one comment, so the read moves forward, and the pages
   after it name the post in one line and fit. *)
let test_post_get_a_body_larger_than_the_page_still_advances () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let body = String.make (Common.max_tool_result_wire_bytes + 1) 'b' in
  let ok, created =
    dispatch
      "masc_board_post"
      (make_args
         [ "title", `String "large body"; "content", `String body; "author", `String "tester" ])
  in
  Alcotest.(check bool) "create ok" true ok;
  let post_id =
    parse_create_response_json created |> Yojson.Safe.Util.member "id" |> Yojson.Safe.Util.to_string
  in
  let comment_count = 3 in
  for index = 1 to comment_count do
    ignore (add_comment_id ~post_id (Printf.sprintf "after-large-body-%d" index))
  done;
  match walk_thread ~result_boundary:official_client_lane post_id with
  | first :: rest ->
    Alcotest.(check bool) "the first page carries the body" true (contains first.thread body);
    Alcotest.(check int) "and one comment" 1 first.returned;
    Alcotest.(check int)
      "the pages after it carry the rest"
      (comment_count - 1)
      (List.fold_left (fun sum page -> sum + page.returned) 0 rest);
    List.iter
      (fun page ->
         Alcotest.(check bool)
           (Printf.sprintf "page at %d fits the wire ceiling" page.offset)
           true
           (String.length page.body <= Common.max_tool_result_wire_bytes))
      rest
  | [] -> Alcotest.fail "the thread returned no page"

(* The TTL sweep is the one thing that removes a comment from a live thread.
   An offset is a position, so a sweep between two reads moves the thread under
   it; the next page counts the thread as it is now, the old last offset reads
   as the new end, one past it is refused, and the sweep schedules its removal
   for the next flush. *)
let test_post_get_a_sweep_between_pages_shows_in_the_next_page () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let comment_count = 4 in
  let page_limit = 2 in
  let post_id = create_post_with_comments ~count:comment_count in
  check_page
    ~label:"before the sweep"
    (read_page
       ~result_boundary:Tool_output.Sent_to_client
       ~label:"before the sweep"
       post_id
       [ "comment_limit", `Int page_limit ])
    ~offset:0
    ~returned:page_limit
    ~total:comment_count
    ~next_offset:(Some page_limit);
  let (Board_dispatch.Jsonl store) = Board_dispatch.backend () in
  let oldest =
    match Board_dispatch.get_post_and_comments ~post_id with
    | Ok (_, oldest :: _) -> oldest
    | Ok (_, []) | Error _ -> Alcotest.fail "the thread has no comment to expire"
  in
  let comment_key = Board.Comment_id.to_string oldest.Board.id in
  (* Expired at epoch + 1s, then swept, the way the sweeper finds it. *)
  Hashtbl.replace store.Board.comments comment_key { oldest with Board.expires_at = 1.0 };
  store.Board.dirty_posts <- false;
  store.Board.dirty_comments <- false;
  Hashtbl.reset store.Board.dirty_post_ids;
  Hashtbl.reset store.Board.dirty_comment_ids;
  let _ : int * int = Board.sweep store in
  Alcotest.(check bool)
    "the sweep schedules the post for the next flush"
    true
    (store.Board.dirty_posts && Hashtbl.mem store.Board.dirty_post_ids post_id);
  Alcotest.(check bool)
    "and the removed comment"
    true
    (store.Board.dirty_comments && Hashtbl.mem store.Board.dirty_comment_ids comment_key);
  let remaining = comment_count - 1 in
  let next =
    read_page
      ~result_boundary:Tool_output.Sent_to_client
      ~label:"after the sweep"
      post_id
      [ "comment_offset", `Int page_limit; "comment_limit", `Int page_limit ]
  in
  Alcotest.(check int) "the next page counts the thread as it is now" remaining next.total;
  (* The old last offset is the new end: an empty page that counts the
     thread as it is now. One past it is refused. *)
  check_page
    ~label:"the old last offset"
    (read_page
       ~result_boundary:Tool_output.Sent_to_client
       ~label:"the old last offset"
       post_id
       [ "comment_offset", `Int remaining ])
    ~offset:remaining
    ~returned:0
    ~total:remaining
    ~next_offset:None;
  check_get_rejected
    ~label:"past the new end"
    post_id
    [ "comment_offset", `Int (remaining + 1) ]
    (Printf.sprintf
       "the thread now has %d comments, at offsets 0-%d"
       remaining
       (remaining - 1))

(* The deepest reply depth whose indentation still grows
   (Board_tool_format.max_comment_indent_depth). *)
let indent_cap_depth = 5

(* A reply chain deeper than the indentation cap is still drawn, so the page's
   count and its lines are the same set of comments. A reply whose place the
   indentation cannot show — past the cap, or with its parent on another page —
   names its parent. *)
let test_post_get_draws_replies_below_the_indent_cap () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:0 in
  let chain_depth = 8 in
  let root = add_comment_id ~post_id "depth-0" in
  let _, ids =
    List.fold_left
      (fun (parent, ids) depth ->
         let id =
           add_comment_id ~post_id ~parent_id:parent (Printf.sprintf "depth-%d" depth)
         in
         id, ids @ [ id ])
      (root, [ root ])
      (List.init chain_depth (fun index -> index + 1))
  in
  let total = chain_depth + 1 in
  let page = read_page ~result_boundary:Tool_output.Sent_to_client ~label:"deep thread" post_id [] in
  List.iter (fun id -> Alcotest.(check bool) (id ^ " is drawn") true (contains page.thread id)) ids;
  check_page ~label:"deep thread page" page ~offset:0 ~returned:total ~total ~next_offset:None;
  Alcotest.(check bool)
    "deep thread header"
    true
    (contains page.thread (Printf.sprintf "[%d replies]" total));
  (* A comment's own line opens its bracket with its id; a reply names it
     only after "reply to". *)
  let own_line_marker id = "[" ^ id in
  let line_of thread id =
    match
      List.find_opt
        (fun line -> contains line (own_line_marker id))
        (String.split_on_char '\n' thread)
    with
    | Some line -> line
    | None -> Alcotest.failf "%s has no line" id
  in
  List.iteri
    (fun depth id ->
       match depth with
       | 0 -> ()
       | _ ->
         let parent = List.nth ids (depth - 1) in
         Alcotest.(check bool)
           (Printf.sprintf "depth %d names its parent only past the indentation cap" depth)
           (depth > indent_cap_depth)
           (contains (line_of page.thread id) ("reply to " ^ parent)))
    ids;
  let continued_offset = 3 in
  let continued_limit = 2 in
  let continued =
    read_page
      ~result_boundary:Tool_output.Sent_to_client
      ~label:"page starting mid-chain"
      post_id
      [ "comment_offset", `Int continued_offset; "comment_limit", `Int continued_limit ]
  in
  let parent_of =
    List.mapi
      (fun depth id ->
         match depth with
         | 0 -> id, None
         | _ -> id, Some (List.nth ids (depth - 1)))
      ids
  in
  let drawn = List.filter (fun id -> contains continued.thread (own_line_marker id)) ids in
  Alcotest.(check int) "the continued page draws its comments" continued_limit (List.length drawn);
  let parent_off_page id =
    match List.assoc id parent_of with
    | Some parent -> not (List.mem parent drawn)
    | None -> false
  in
  Alcotest.(check bool)
    "the continued page holds a reply whose parent is on another page"
    true
    (List.exists parent_off_page drawn);
  List.iter
    (fun id ->
       match List.assoc id parent_of with
       | None -> ()
       | Some parent ->
         Alcotest.(check bool)
           (id ^ " names its parent only when the parent is not on the page")
           (parent_off_page id)
           (contains (line_of continued.thread id) ("reply to " ^ parent)))
    drawn

(* The header counts the comments the read returned, not the stored counter. *)
let test_post_get_header_counts_the_comments_it_read () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:3 in
  let (Board_dispatch.Jsonl store) = Board_dispatch.backend () in
  let post = Hashtbl.find store.Board.posts post_id in
  let drifted_count = 999 in
  Hashtbl.replace store.Board.posts post_id { post with Board.reply_count = drifted_count };
  let page = read_page ~result_boundary:Tool_output.Sent_to_client ~label:"header" post_id [] in
  Alcotest.(check bool) "header" true (contains page.thread "[3 replies]");
  check_page ~label:"page" page ~offset:0 ~returned:3 ~total:3 ~next_offset:None

let test_post_get_not_found () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:0 in
  let last = String.length post_id - 1 in
  let wrong_id = String.sub post_id 0 last ^ (if post_id.[last] = '0' then "1" else "0") in
  let result = dispatch_result "masc_board_post_get"
    (make_args [("post_id", `String wrong_id)]) in
  Alcotest.(check bool) "lookup miss is not a successful read" false
    (Tool_result.is_success result);
  check_failure_class "wrong reference needs correction" (Some "workflow_rejection") result;
  Alcotest.(check string) "lookup miss does not invent deletion or expiry"
    ("Post not found: " ^ wrong_id) (Tool_result.message result);
  let ok, _ = dispatch "masc_board_post_get"
    (make_args [("post_id", `String post_id)]) in
  Alcotest.(check bool) "correct source remains readable" true ok

(** {2 Group 4: Voting} *)

let test_vote_not_found () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let result =
    dispatch_result "masc_board_vote"
      (make_args
         [
           ("post_id", `String "missing");
           ("voter", `String "v");
           ("direction", `String "up");
         ])
  in
  let body = (Tool_result.message result) in
  Alcotest.(check bool) "vote on missing fails" false (Tool_result.is_success result);
  check_failure_class
    "missing post vote is workflow rejection"
    (Some "workflow_rejection")
    result;
  Alcotest.(check bool) "has error" true (String.length body > 0)

let test_vote_requires_explicit_direction () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let empty_direction =
    dispatch_result
      "masc_board_vote"
      (make_args
         [
           ("post_id", `String "missing");
           ("voter", `String "v");
           ("direction", `String "");
         ])
  in
  Alcotest.(check bool) "empty direction rejected" false (Tool_result.is_success empty_direction);
  Alcotest.(check bool)
    "empty direction error"
    true
    (String_util.contains_substring
       ((Tool_result.message empty_direction))
       "invalid vote direction");
  let missing_direction =
    dispatch_result
      "masc_board_vote"
      (make_args [ ("post_id", `String "missing"); ("voter", `String "v") ])
  in
  Alcotest.(check bool) "missing direction rejected" false (Tool_result.is_success missing_direction);
  check_failure_class
    "missing direction is workflow rejection"
    (Some "workflow_rejection")
    missing_direction;
  Alcotest.(check bool)
    "missing direction error"
    true
    (String_util.contains_substring
       ((Tool_result.message missing_direction))
       "vote direction required");
  let comment_missing_direction =
    dispatch_result
      "masc_board_comment_vote"
      (make_args [ ("comment_id", `String "c-missing"); ("voter", `String "v") ])
  in
  Alcotest.(check bool)
    "comment vote missing direction rejected"
    false
    (Tool_result.is_success comment_missing_direction);
  Alcotest.(check bool)
    "comment vote missing direction error"
    true
    (String_util.contains_substring
       ((Tool_result.message comment_missing_direction))
       "vote direction required")

(** {2 Group 5: Comment} *)

let test_comment_add_missing_post () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let result =
    dispatch_result "masc_board_comment"
      (make_args
         [
           ("post_id", `String "missing");
           ("content", `String "hi");
           ("author", `String "a");
         ])
  in
  let body = (Tool_result.message result) in
  Alcotest.(check bool) "comment on missing post fails" false (Tool_result.is_success result);
  check_failure_class
    "missing post comment is workflow rejection"
    (Some "workflow_rejection")
    result;
  Alcotest.(check bool) "has error" true (String.length body > 0)

let test_comment_add_missing_author_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment"
    (make_args [("post_id", `String "missing"); ("content", `String "hi")]) in
  Alcotest.(check bool) "missing author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (String_util.contains_substring body "author")

let test_comment_add_anonymous_author_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment"
    (make_args
       [("post_id", `String "missing"); ("content", `String "hi"); ("author", `String "anonymous")]) in
  Alcotest.(check bool) "anonymous author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (String_util.contains_substring body "author")

let test_comment_vote_missing () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment_vote"
    (make_args [("comment_id", `String ""); ("voter", `String "v"); ("direction", `String "up")]) in
  Alcotest.(check bool) "empty comment_id fails" false ok;
  Alcotest.(check bool) "error msg" true (String.length body > 0)

let test_comment_vote_not_found () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  (* Well-formed id that no comment carries: the store lookup misses. *)
  let missing_comment_id = "c-" ^ String.make 32 '0' in
  let result =
    dispatch_result "masc_board_comment_vote"
      (make_args
         [
           ("comment_id", `String missing_comment_id);
           ("voter", `String "v");
           ("direction", `String "up");
         ])
  in
  let body = (Tool_result.message result) in
  Alcotest.(check bool) "vote on missing comment fails" false (Tool_result.is_success result);
  check_failure_class
    "missing comment vote is workflow rejection"
    (Some "workflow_rejection")
    result;
  Alcotest.(check bool) "error names the miss" true
    (String_util.contains_substring body "Comment not found")

(* #29457: 109 of 134 masc_board_comment_vote calls in August 2026 carried an
   invented id ("c-placeholder", "c-b1", "BUILDER_A_DONE"). The typed id parser
   refuses them before any store lookup, and the message names the accepted
   shape so the caller can correct itself. *)
let test_comment_vote_rejects_invented_id () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  List.iter
    (fun invented ->
      let result =
        dispatch_result "masc_board_comment_vote"
          (make_args
             [
               ("comment_id", `String invented);
               ("voter", `String "v");
               ("direction", `String "up");
             ])
      in
      let body = Tool_result.message result in
      Alcotest.(check bool) (invented ^ " is refused") false
        (Tool_result.is_success result);
      check_failure_class
        (invented ^ " is a workflow rejection")
        (Some "workflow_rejection")
        result;
      Alcotest.(check bool) (invented ^ " error names the accepted shape") true
        (String_util.contains_substring body Board.Comment_id.accepted_format))
    [ "c-placeholder"; "c-b1"; "BUILDER_A_DONE"; "C-" ^ String.make 32 '0' ]

(** {2 Group 6: Search / Stats / Profile / Hearths} *)

let test_search_empty_query () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_search"
    (make_args [("query", `String "")]) in
  Alcotest.(check bool) "empty query fails" false ok;
  Alcotest.(check bool) "has error" true (String.length body > 0)

let test_search_no_results () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_search"
    (make_args [("query", `String "nonexistent_xyz_123")]) in
  Alcotest.(check bool) "search ok" true ok;
  Alcotest.(check bool) "no results msg" true (String.length body > 0)

let test_stats () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_stats" (make_args []) in
  Alcotest.(check bool) "stats ok" true ok;
  Alcotest.(check bool) "stats has content" true (String.length body > 0)

let test_profile_empty_agent () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_profile"
    (make_args [("agent", `String "")]) in
  Alcotest.(check bool) "empty agent fails" false ok;
  Alcotest.(check bool) "has error" true (String.length body > 0)

let test_profile_with_posts () =
  with_eio @@ fun env ->
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
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_hearths" (make_args []) in
  Alcotest.(check bool) "hearth list ok" true ok;
  Alcotest.(check bool) "has content" true (String.length body > 0)

(** {2 Group 7: Dispatch Routing} *)

let test_dispatch_unknown_tool () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_nonexistent" (make_args []) in
  Alcotest.(check bool) "unknown tool fails" false ok;
  Alcotest.(check bool) "has unknown msg" true
    (try ignore (Str.search_forward (Str.regexp_string "Unknown") body 0); true
     with Not_found -> false)

(** {2 Group 8: Tool Schema Definitions} *)

let test_tools_count () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name) Board_tool.tools in
  Alcotest.(check int) "21 tool schemas" 21 (List.length names);
  Alcotest.(check bool)
    "cleanup schema advertised"
    true
    (List.mem "masc_board_cleanup" names)

let test_tools_names_unique () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let names = List.map (fun (t : Masc_domain.tool_schema) -> t.name) Board_tool.tools in
  let unique = List.sort_uniq String.compare names in
  Alcotest.(check int) "all names unique" (List.length names) (List.length unique)

let test_tools_all_have_descriptions () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  List.iter (fun (t : Masc_domain.tool_schema) ->
    Alcotest.(check bool) (Printf.sprintf "%s has description" t.name) true
      (String.length t.description > 0)
  ) Board_tool.tools

let curation_schema_properties (tool : Masc_domain.tool_schema) =
  match tool.input_schema with
  | `Assoc fields ->
    (match List.assoc_opt "properties" fields with
     | Some (`Assoc properties) -> properties
     | _ -> Alcotest.failf "%s missing properties schema" tool.name)
  | _ -> Alcotest.failf "%s input_schema is not an object" tool.name

let find_tool name tools =
  match List.find_opt (fun (tool : Masc_domain.tool_schema) -> String.equal tool.name name) tools with
  | Some tool -> tool
  | None -> Alcotest.failf "missing tool schema %s" name

let test_curation_schema_omits_health_score () =
  let check_absent label tool =
    let properties = curation_schema_properties tool in
    Alcotest.(check bool) (label ^ " omits health_score") true
      (Option.is_none (List.assoc_opt "health_score" properties));
    Alcotest.(check bool) (label ^ " omits health_components") true
      (Option.is_none (List.assoc_opt "health_components" properties))
  in
  check_absent "raw curation submit"
    (find_tool "masc_board_curation_submit" Board_tool.tools);
  let keeper_projection =
    match
      Tool_shard_types.keeper_board_schema
        Tool_name.Board_name.Board_curation_submit
    with
    | Some schema -> schema
    | None -> Alcotest.fail "missing Keeper curation projection"
  in
  check_absent "keeper curation submit" keeper_projection

let test_post_update_schema_exposes_new_author () =
  let update_properties =
    curation_schema_properties
      (find_tool "masc_board_post_update" Board_tool.tools)
  in
  let create_properties =
    curation_schema_properties (find_tool "masc_board_post" Board_tool.tools)
  in
  Alcotest.(check bool) "update exposes new_author" true
    (Option.is_some (List.assoc_opt "new_author" update_properties));
  Alcotest.(check bool) "create omits new_author" true
    (Option.is_none (List.assoc_opt "new_author" create_properties))

(** {1 Test Runner} *)

(* An [@] a keeper name could never be is prose. [Agent_id] accepts 1..64 of
   [a-zA-Z0-9._-] with one optional colon, so a bare "@", an npm scope and a
   path all fail that shape -- and used to take the whole post down with them.
   Each case below is a shape the live board log carried while the post was
   refused. *)
let comment_audience content =
  Masc.Board.audience_for_comment ~content

let post_audience content =
  Masc.Board.audience_for_post ~visibility:Masc.Board.Public ~title:"t" ~content

let label_of = function
  | Ok audience -> Masc.Board.audience_label audience
  | Error _ -> "error"

let test_prose_at_is_not_an_address () =
  Alcotest.(check string) "bare @ in a comment" "thread_participants"
    (label_of (comment_audience "ping @ me later"));
  Alcotest.(check string) "npm scope" "discoverable"
    (label_of (post_audience "see @internals/libs/errors/asyncErrorHandler."));
  Alcotest.(check string) "bare @@" "thread_participants"
    (label_of (comment_audience "the @@ operator"))

let test_a_named_broadcast_selector_is_still_refused () =
  (* An author who wrote @@something meant to broadcast and named a selector
     that does not exist. That is worth refusing; the empty one is not. *)
  Alcotest.(check string) "unknown selector" "error"
    (label_of (comment_audience "heads up @@everyone"))

let test_a_well_shaped_name_is_still_a_target () =
  Alcotest.(check string) "plain name" "targets"
    (label_of (comment_audience "@delta please look"));
  Alcotest.(check string) "namespaced name" "targets"
    (label_of (comment_audience "@keeper:delta please look"))

let () =
  Eio_main.run @@ fun env ->
  current_eio_env := Some env;
  Fun.protect
    ~finally:(fun () -> current_eio_env := None)
    (fun () ->
      Alcotest.run "Board_tool_coverage"
        [
      ( "helpers",
        [
          Alcotest.test_case "visibility_of_string" `Quick test_visibility_of_string;
          Alcotest.test_case "sort_order_of_string" `Quick test_sort_order_of_string;
          Alcotest.test_case "board_error_to_string" `Quick test_board_error_to_string;
          Alcotest.test_case "is_agent" `Quick test_is_agent;
          Alcotest.test_case "format_timestamp_absolute" `Quick test_format_timestamp_absolute;
          Alcotest.test_case "board actor identity is registry backed"
            `Quick test_board_actor_identity_is_registry_backed;
          Alcotest.test_case "board actor identity keeps non-keeper agent"
            `Quick test_board_actor_identity_keeps_non_keeper_agent;
          Alcotest.test_case "board dashboard json embeds reaction summaries"
            `Quick test_board_dashboard_json_embeds_reaction_summaries;
          Alcotest.test_case "MCP runtime board post author rewrites caller claim"
            `Quick test_inline_board_post_author_rewrites_caller_claim;
          Alcotest.test_case "MCP runtime board post author accepts matching alias"
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
            test_post_create_metadata_payload;
          Alcotest.test_case "create data is structured not double-encoded" `Quick
            test_post_create_data_is_structured;
          Alcotest.test_case "projection failure preserves primary effect" `Quick
            test_activity_projection_failure_preserves_primary_effect;
          Alcotest.test_case "create judgment roundtrip" `Quick
            test_post_create_judgment_roundtrip;
          Alcotest.test_case "create judgment list roundtrip (#16300)" `Quick
            test_post_create_judgment_list_roundtrip;
          Alcotest.test_case "create judgment scalar types ignored (#16300)" `Quick
            test_post_create_judgment_scalar_types_ignored;
          Alcotest.test_case "create sources footer and meta" `Quick
            test_post_create_sources_footer_and_meta;
          Alcotest.test_case "keeper board post preserves meta reason" `Quick
            test_masc_board_post_preserves_meta_reason;
          Alcotest.test_case "keeper sub-board owner is runtime-bound" `Quick
            test_keeper_board_sub_board_owner_is_runtime_bound;
          Alcotest.test_case "sub-board unknown access is rejected" `Quick
            test_sub_board_unknown_access_is_rejected;
          Alcotest.test_case "direct Board reaction binds keeper identity" `Quick
            test_direct_board_reaction_binds_keeper_identity;
          Alcotest.test_case
            "model-visible Board maintenance dispatches in process"
            `Quick
            test_model_visible_board_maintenance_dispatches_in_process;
          Alcotest.test_case "keeper board dispatch uses typed names" `Quick
            test_keeper_board_dispatch_uses_typed_tool_names;
          Alcotest.test_case "curation read empty returns JSON null" `Quick
            test_board_curation_read_empty_returns_json_null;
          Alcotest.test_case "curation submit roundtrips to read" `Quick
            test_board_curation_submit_roundtrips_to_read;
          Alcotest.test_case "curation MCP runtime routes read and submit" `Quick
            test_board_curation_mcp_runtime_routes_read_and_submit;
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
          Alcotest.test_case
            "get comment pages carry their range"
            `Quick
            test_post_get_comment_pages_carry_their_range;
          Alcotest.test_case
            "get refuses page arguments that are not integers"
            `Quick
            test_post_get_refuses_page_arguments_that_are_not_integers;
          Alcotest.test_case
            "get accepts an integer-valued float"
            `Quick
            test_post_get_accepts_an_integer_valued_float;
          Alcotest.test_case
            "get reaches the model as text"
            `Quick
            test_post_get_reaches_the_model_as_text;
          Alcotest.test_case
            "get long thread pages fit inline and chain"
            `Quick
            test_post_get_long_thread_pages_fit_inline_and_chain;
          Alcotest.test_case
            "get page follows the lane ceiling"
            `Quick
            test_post_get_page_follows_the_lane_ceiling;
          Alcotest.test_case
            "keeper board read pages by the projection it is given"
            `Quick
            test_keeper_board_read_pages_by_the_projection_it_is_given;
          Alcotest.test_case
            "get comment larger than the page arrives alone"
            `Quick
            test_post_get_a_comment_larger_than_the_page_arrives_alone;
          Alcotest.test_case
            "get body larger than the page still advances"
            `Quick
            test_post_get_a_body_larger_than_the_page_still_advances;
          Alcotest.test_case
            "get sweep between pages shows in the next page"
            `Quick
            test_post_get_a_sweep_between_pages_shows_in_the_next_page;
          Alcotest.test_case
            "get draws replies below the indent cap"
            `Quick
            test_post_get_draws_replies_below_the_indent_cap;
          Alcotest.test_case
            "get header counts the comments it read"
            `Quick
            test_post_get_header_counts_the_comments_it_read;
          Alcotest.test_case "get not found" `Quick test_post_get_not_found;
        ] );
      ( "voting",
        [
          Alcotest.test_case "vote not found" `Quick test_vote_not_found;
          Alcotest.test_case
            "explicit direction required"
            `Quick
            test_vote_requires_explicit_direction;
        ] );
      ( "comments",
        [
          Alcotest.test_case "comment missing post" `Quick test_comment_add_missing_post;
          Alcotest.test_case "comment missing author rejected" `Quick
            test_comment_add_missing_author_rejected;
          Alcotest.test_case "comment anonymous author rejected" `Quick
            test_comment_add_anonymous_author_rejected;
          Alcotest.test_case "comment vote missing" `Quick test_comment_vote_missing;
          Alcotest.test_case "comment vote not found" `Quick
            test_comment_vote_not_found;
          Alcotest.test_case "comment vote rejects invented id" `Quick
            test_comment_vote_rejects_invented_id;
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
          Alcotest.test_case "post update by owner" `Quick
            test_dispatch_post_update_success;
          Alcotest.test_case "post update rejects non-owner" `Quick
            test_dispatch_post_update_rejects_non_owner;
          Alcotest.test_case "post update transfers author" `Quick
            test_dispatch_post_update_transfers_author;
          Alcotest.test_case "post update missing id" `Quick
            test_dispatch_post_update_missing_id;
        ] );
      ( "board addressing",
        [
          Alcotest.test_case "an @ in prose is not an address" `Quick
            test_prose_at_is_not_an_address;
          Alcotest.test_case "a named broadcast selector is still refused" `Quick
            test_a_named_broadcast_selector_is_still_refused;
          Alcotest.test_case "a well-shaped name is still a target" `Quick
            test_a_well_shaped_name_is_still_a_target;
        ] );
      ( "schemas",
        [
          Alcotest.test_case "tools count" `Quick test_tools_count;
          Alcotest.test_case "unique names" `Quick test_tools_names_unique;
          Alcotest.test_case "all have descriptions" `Quick test_tools_all_have_descriptions;
          Alcotest.test_case "curation schema omits health score" `Quick
            test_curation_schema_omits_health_score;
          Alcotest.test_case "post update schema exposes new_author" `Quick
            test_post_update_schema_exposes_new_author;
        ] );
        ])
