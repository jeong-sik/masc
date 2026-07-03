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
  Board_moderation.reset_for_test ();
  remove_path (Filename.concat _test_base_path Common.masc_dirname);
  Board_dispatch.init_jsonl ()

let dispatch name args =
  let result = Board_tool.handle_tool name args in
  ((Tool_result.is_success result), (Tool_result.message result))

let dispatch_result name args =
  Board_tool.handle_tool name args

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

let make_keeper_meta ?(name = "judge-keeper") () : Keeper_meta_contract.keeper_meta =
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

let source_text rel = Masc_test_deps.read_file (Masc_test_deps.source_path rel)

let slice_between text ~start_marker ~end_marker =
  try
    let start = Str.search_forward (Str.regexp_string start_marker) text 0 in
    let stop = Str.search_forward (Str.regexp_string end_marker) text start in
    String.sub text start (stop - start)
  with Not_found ->
    Alcotest.failf "missing source marker between %S and %S" start_marker end_marker

let slice_from text ~start_marker =
  try
    let start = Str.search_forward (Str.regexp_string start_marker) text 0 in
    String.sub text start (String.length text - start)
  with Not_found -> Alcotest.failf "missing source marker %S" start_marker

let test_moderation_http_identity_bound_to_auth_source () =
  let src = source_text "lib/server/server_dashboard_http_delete_actions.ml" in
  let flag_route =
    slice_between src
      ~start_marker:{|Http.Router.post "/api/v1/dashboard/board/moderation/flag"|}
      ~end_marker:{|Http.Router.get "/api/v1/dashboard/board/moderation/queue"|}
  in
  let action_route =
    slice_from src
      ~start_marker:{|Http.Router.post "/api/v1/dashboard/board/moderation/action"|}
  in
  Alcotest.(check bool) "flag route binds authenticated agent" true
    (contains_substring flag_route "(fun _state agent_name req reqd ->");
  Alcotest.(check bool) "flag reporter uses authenticated agent" true
    (contains_substring flag_route "let reporter = agent_name");
  Alcotest.(check bool) "flag route ignores body reporter" false
    (contains_substring flag_route {|json_string_opt "reporter"|});
  Alcotest.(check bool) "action actor uses authenticated agent" true
    (contains_substring action_route "let actor = agent_name");
  Alcotest.(check bool) "action route ignores body actor" false
    (contains_substring action_route {|json_string_opt "actor"|})

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
  let s = Board_tool.board_error_to_string (Board.Post_not_found "test-id") in
  Alcotest.(check bool) "post_not_found has text" true (String.length s > 0);
  let s2 = Board_tool.board_error_to_string (Board.Validation_error "bad") in
  Alcotest.(check bool) "validation_error" true (String.contains s2 'b')

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

let test_format_timestamp_relative () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let now = Time_compat.now () in
  let s = Board_tool.format_timestamp_relative now in
  Alcotest.(check string) "recent timestamp" "just now" s;
  let old = now -. 86400.0 in
  let s2 = Board_tool.format_timestamp_relative old in
  Alcotest.(check bool) "1-day old has 'd'" true (String.contains s2 'd');
  let minutes_ago = now -. 120.0 in
  let s3 = Board_tool.format_timestamp_relative minutes_ago in
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

let json_member_null json key =
  match Yojson.Safe.Util.member key json with
  | `Null -> ()
  | _ -> Alcotest.failf "expected null field %s" key

let json_member_list json key =
  match Yojson.Safe.Util.member key json with
  | `List values -> values
  | _ -> Alcotest.failf "expected list field %s" key

let json_has_member json key =
  match Yojson.Safe.Util.member key json with
  | `Null -> false
  | _ -> true

let test_board_actor_identity_canonicalizes_keeper_alias () =
  with_eio @@ fun env ->
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

let test_board_dashboard_json_embeds_moderation_projection () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post =
    match
      Board_dispatch.create_post ~author:"moderated-author"
        ~content:"moderation projection post" ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let post_id = Board.Post_id.to_string post.id in
  let comment =
    match
      Board_dispatch.add_comment ~post_id ~author:"moderated-commenter"
        ~content:"moderation projection comment" ()
    with
    | Ok comment -> comment
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let comment_id = Board.Comment_id.to_string comment.id in
  (match
     Board_moderation.flag ~target_kind:Board_moderation.Target_post
       ~target_id:post_id ~reporter:"reporter-a" ~reason:Board_moderation.Spam
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail e);
  (match
     Board_moderation.flag ~target_kind:Board_moderation.Target_comment
       ~target_id:comment_id ~reporter:"reporter-b"
       ~reason:Board_moderation.Harassment
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail e);
  let public_post_json =
    Server_utils.board_post_dashboard_json ~author_karma:0 post
  in
  let public_comment_json = Server_utils.board_comment_dashboard_json comment in
  Alcotest.(check bool) "public post omits report count" false
    (json_has_member public_post_json "report_count");
  Alcotest.(check bool) "public post omits moderation status" false
    (json_has_member public_post_json "moderation_status");
  Alcotest.(check bool) "public comment omits report count" false
    (json_has_member public_comment_json "report_count");
  Alcotest.(check bool) "public comment omits moderation status" false
    (json_has_member public_comment_json "moderation_status");
  let post_json =
    Server_utils.board_post_dashboard_json ~include_moderation:true ~author_karma:0 post
  in
  let comment_json =
    Server_utils.board_comment_dashboard_json ~include_moderation:true comment
  in
  Alcotest.(check int) "post report count" 1
    (json_member_int post_json "report_count");
  Alcotest.(check string) "post moderation status" "flagged"
    (json_member_string post_json "moderation_status");
  Alcotest.(check int) "comment report count" 1
    (json_member_int comment_json "report_count");
  Alcotest.(check string) "comment moderation status" "flagged"
    (json_member_string comment_json "moderation_status")

let test_board_dashboard_json_hides_unvoted_scores_when_blind () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post =
    match
      Board_dispatch.create_post ~author:"blind-author"
        ~content:"vote blind post" ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let post_id = Board.Post_id.to_string post.id in
  (match Board_dispatch.vote ~voter:"peer" ~post_id ~direction:Board.Up with
  | Ok _ -> ()
  | Error e -> Alcotest.fail (Board.show_board_error e));
  let post =
    match Board_dispatch.get_post ~post_id with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let comment =
    match
      Board_dispatch.add_comment ~post_id ~author:"blind-commenter"
        ~content:"vote blind comment" ()
    with
    | Ok comment -> comment
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let comment_id = Board.Comment_id.to_string comment.id in
  (match
     Board_dispatch.vote_comment ~voter:"peer" ~comment_id
       ~direction:Board.Up
   with
   | Ok _ -> ()
   | Error e -> Alcotest.fail (Board.show_board_error e));
  let comment =
    match Board_dispatch.get_comments ~post_id with
    | Ok (comment :: _) -> comment
    | Ok [] -> Alcotest.fail "expected comment"
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let hidden_post_json =
    Server_utils.board_post_dashboard_json ~blind_votes:true
      ~current_vote:None ~author_karma:0 post
  in
  Alcotest.(check bool) "post vote blind" true
    (json_member_bool hidden_post_json "vote_blind");
  json_member_null hidden_post_json "votes";
  json_member_null hidden_post_json "score";
  json_member_null hidden_post_json "votes_up";
  json_member_null hidden_post_json "votes_down";
  Alcotest.(check string) "post blind reason" "vote_before_score"
    (json_member_string hidden_post_json "vote_blind_reason");
  let revealed_post_json =
    Server_utils.board_post_dashboard_json ~blind_votes:true
      ~current_vote:(Some Board.Up) ~author_karma:0 post
  in
  Alcotest.(check bool) "post vote revealed" false
    (json_member_bool revealed_post_json "vote_blind");
  Alcotest.(check int) "post revealed votes" 1
    (json_member_int revealed_post_json "votes");
  let hidden_comment_json =
    Server_utils.board_comment_dashboard_json ~blind_votes:true
      ~current_vote:None comment
  in
  Alcotest.(check bool) "comment vote blind" true
    (json_member_bool hidden_comment_json "vote_blind");
  json_member_null hidden_comment_json "votes";
  json_member_null hidden_comment_json "score";
  json_member_null hidden_comment_json "votes_up";
  json_member_null hidden_comment_json "votes_down";
  let revealed_comment_json =
    Server_utils.board_comment_dashboard_json ~blind_votes:true
      ~current_vote:(Some Board.Up) comment
  in
  Alcotest.(check bool) "comment vote revealed" false
    (json_member_bool revealed_comment_json "vote_blind");
  Alcotest.(check int) "comment revealed score" 1
    (json_member_int revealed_comment_json "score")

let test_board_dashboard_json_embeds_contributor_quality () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post =
    match
      Board_dispatch.create_post ~author:"quality-author"
        ~content:"quality projection post" ~post_kind:Board.Human_post ()
    with
    | Ok post -> post
    | Error e -> Alcotest.fail (Board.show_board_error e)
  in
  let rep =
    {
      (Reputation.default_reputation ~agent_name:"quality-author") with
      completion_rate = 0.8;
      response_rate = 0.6;
      board_posts = 3;
      board_comments = 5;
      accountability_score = 0.9;
      autonomy_level = "elevated";
      thompson_confidence = 0.7;
    }
  in
  let contributor_quality =
    Server_utils.board_contributor_quality_json rep
  in
  let post_json =
    Server_utils.board_post_dashboard_json ~contributor_quality
      ~author_karma:0 post
  in
  let quality =
    match Yojson.Safe.Util.member "contributor_quality" post_json with
    | `Assoc _ as quality -> quality
    | _ -> Alcotest.fail "expected contributor_quality object"
  in
  Alcotest.(check string) "quality source" "agent_reputation"
    (json_member_string quality "source");
  Alcotest.(check int) "quality board posts" 3
    (json_member_int quality "board_posts")

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
    Mcp_tool_runtime_board.ensure_board_post_author
      ~agent_name:"keeper-velvet-hammer-agent" args
  in
  Alcotest.(check string) "author from ctx" "velvet-hammer"
    Yojson.Safe.Util.(normalized |> member "author" |> to_string);
  Alcotest.(check string) "caller claim preserved" "analyst"
    Yojson.Safe.Util.(
      normalized |> member "meta" |> member "author_caller_claim" |> to_string);
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
    Mcp_tool_runtime_board.ensure_board_post_author
      ~agent_name:"keeper-analyst-agent" args
  in
  Alcotest.(check string) "author canonical" "analyst"
    Yojson.Safe.Util.(normalized |> member "author" |> to_string);
  Alcotest.(check bool) "no mismatch claim" true
    Yojson.Safe.Util.(
      normalized |> member "meta" |> member "author_caller_claim" = `Null)

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

let test_post_create_structured_payload () =
  with_eio @@ fun env ->
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
  (* state_block is stripped by board_tool before reaching board_core,
     so meta.state_block is absent (null) in the created post. *)
  Alcotest.(check bool) "state_block absent after strip" true
    (Yojson.Safe.Util.(json |> member "meta" |> member "state_block") = `Null)

(* Regression guard: board_post must return STRUCTURED [data] (`Assoc), not a
   `String that embeds stringified JSON. The `String form double-encodes the
   payload — a consumer that re-serializes the result (e.g. the dashboard's
   JSON.stringify) escapes the inner newlines back to literal "\n". Unlike
   [test_post_create_structured_payload], which parses [message] (and passes for
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
  Alcotest.(check string) "classification reason from judgment" summary
    Yojson.Safe.Util.(json |> member "classification_reason" |> to_string);
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
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"judge-keeper" () in
  let reason =
    "LLM judged this as automation because it broadcasts a keeper-owned status update."
  in
  let body =
    Keeper_tool_board_runtime.handle_keeper_board_tool
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

let test_keeper_board_post_rejects_quantitative_line_claim_without_evidence () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"audit-keeper" () in
  let body =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_post"
      ~args:
        (make_args
           [
             ( "content",
               `String
                 "Found 3 silent-empty sites at L97, L102, and L148 in \
                  keeper_tool_policy.ml." );
           ])
  in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check string)
    "evidence required"
    "keeper_board_post rejected: quantitative code claims with line/count references require quantitative_evidence metadata or inline rg/grep evidence"
    Yojson.Safe.Util.(json |> member "error" |> to_string);
  Alcotest.(check string)
    "reason"
    "missing_quantitative_evidence"
    Yojson.Safe.Util.(json |> member "reason" |> to_string);
  Alcotest.(check int) "no post created" 0
    (List.length (Board_dispatch.list_posts ~limit:10 ()))

let test_keeper_board_post_rejects_keyword_only_quantitative_evidence () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"audit-keeper" () in
  let body =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_post"
      ~args:
        (make_args
           [
             ( "content",
               `String
                 "Found 12 hits at L44 and L78; quantitative_evidence will \
                  be added later." );
           ])
  in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check string)
    "keyword is not evidence"
    "missing_quantitative_evidence"
    Yojson.Safe.Util.(json |> member "reason" |> to_string);
  Alcotest.(check int) "no post created" 0
    (List.length (Board_dispatch.list_posts ~limit:10 ()))

let test_keeper_board_post_rejects_numeric_line_claim_without_keyword () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"audit-keeper" () in
  let body =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_post"
      ~args:
        (make_args
           [
             ( "content",
               `String
                 "Found 3 regressions at L97, L102, and L148 in \
                  keeper_tool_policy.ml." );
           ])
  in
  let json = Yojson.Safe.from_string body in
  Alcotest.(check string)
    "standalone count is risky"
    "missing_quantitative_evidence"
    Yojson.Safe.Util.(json |> member "reason" |> to_string);
  Alcotest.(check int) "no post created" 0
    (List.length (Board_dispatch.list_posts ~limit:10 ()))

let test_keeper_board_post_accepts_inline_quantitative_command_evidence () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"audit-keeper" () in
  let body =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_post"
      ~args:
        (make_args
           [
             ( "content",
               `String
                 "Found 3 regressions at L97, L102, and L148.\n\
                  Command: rg -n 'regression' lib/keeper\n\
                  Output: lib/keeper/foo.ml:97:regression" );
           ])
  in
  ignore (parse_create_response_json body);
  Alcotest.(check int) "one post created" 1
    (List.length (Board_dispatch.list_posts ~limit:10 ()))

let test_keeper_board_post_accepts_quantitative_line_claim_with_evidence () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"audit-keeper" () in
  let body =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_post"
      ~args:
        (make_args
           [
             ( "content",
               `String
                 "Found 3 silent-empty sites at L97, L102, and L148 in \
                  keeper_tool_policy.ml." );
             ( "quantitative_evidence",
               `Assoc
                 [
                   ("command", `String "rg -n 'silent-empty' lib/keeper");
                   ("actual_count", `Int 3);
                 ] );
           ])
  in
  let json = parse_create_response_json body in
  Alcotest.(check string)
    "evidence command persisted"
    "rg -n 'silent-empty' lib/keeper"
    Yojson.Safe.Util.(
      json
      |> member "meta"
      |> member "quantitative_evidence"
      |> member "command"
      |> to_string);
  Alcotest.(check int) "one post created" 1
    (List.length (Board_dispatch.list_posts ~limit:10 ()))

let test_keeper_board_dispatch_uses_typed_tool_names () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let keeper_meta = make_keeper_meta ~name:"typed-keeper" () in
  let fake =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_fake"
      ~args:(make_args [])
  in
  Alcotest.(check bool) "fake board name rejected" true
    (contains_substring fake "unknown_board_tool");
  let comment_vote =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_comment_vote"
      ~args:(make_args [ ("comment_id", `String "") ])
  in
  Alcotest.(check bool) "typed comment vote reaches board handler" true
    (contains_substring comment_vote "comment_id required");
  Alcotest.(check bool) "typed comment vote is not unknown" false
    (contains_substring comment_vote "unknown_board_tool");
  let curation =
    Keeper_tool_board_runtime.handle_keeper_board_tool
      ~meta:keeper_meta
      ~name:"keeper_board_curation_read"
      ~args:(make_args [])
  in
  Alcotest.(check string) "typed curation read reaches board handler" "null" curation;
  Alcotest.(check bool) "typed curation read is not unknown" false
    (contains_substring curation "unknown_board_tool");
  let curation_submit =
    Keeper_tool_board_runtime.handle_keeper_board_tool
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

let mcp_runtime_board_dispatch ~sw ~clock name args =
  let state = Mcp_server.create_state ~base_path:_test_base_path in
  Mcp_tool_runtime_board.dispatch ~config:(Mcp_server.workspace_config state)
    ~agent_name:"mcp-runtime-curator" ~arguments:args ~state ~sw ~clock ~name
    ~start_time:(Unix.gettimeofday ())

let require_mcp_runtime_result ~sw ~clock name args =
  match mcp_runtime_board_dispatch ~sw ~clock name args with
  | Some result -> ((Tool_result.is_success result), (Tool_result.message result))
  | None -> Alcotest.failf "%s not routed by MCP runtime board dispatch" name

let test_board_curation_mcp_runtime_routes_read_and_submit () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let read_ok, read_body =
    require_mcp_runtime_result ~sw ~clock "masc_board_curation_read" (make_args [])
  in
  Alcotest.(check bool) "MCP runtime curation read ok" true read_ok;
  Alcotest.(check string) "MCP runtime curation read empty" "null" read_body;
  let submit_ok, submit_body =
    require_mcp_runtime_result ~sw ~clock "masc_board_curation_submit"
      (make_args
         [
           ("submitted_by", `String "mcp-runtime-curator");
           ("summary", `String "MCP runtime curation route works.");
           ("rationale", `String "Pin schema-to-dispatch curation routing");
         ])
  in
  Alcotest.(check bool) "MCP runtime curation submit ok" true submit_ok;
  let submitted = Yojson.Safe.from_string submit_body in
  Alcotest.(check string) "MCP runtime submitted_by persisted" "mcp-runtime-curator"
    Yojson.Safe.Util.(submitted |> member "submitted_by" |> to_string);
  let read2_ok, read2_body =
    require_mcp_runtime_result ~sw ~clock "masc_board_curation_read" (make_args [])
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
    (contains_substring body_sys "reserved")

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
    (contains_substring body "title" || contains_substring body "Title")

let test_post_create_missing_author_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board")]) in
  Alcotest.(check bool) "missing author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (contains_substring body "author")

let test_post_create_anonymous_author_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post"
    (make_args [("content", `String "Hello board"); ("author", `String "anonymous")]) in
  Alcotest.(check bool) "anonymous author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (contains_substring body "author")

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
    (contains_substring body "persist me")

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
    (contains_substring body "invalid sort. Valid: hot, trending, recent, updated, discussed")

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
  let ok_del, msg_del = dispatch "masc_board_delete"
    (make_args [("post_id", `String post_id)]) in
  Alcotest.(check bool) "delete ok" true ok_del;
  Alcotest.(check bool) "delete msg contains id" true
    (contains_substring msg_del post_id)

let test_dispatch_delete_not_found () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_delete"
    (make_args [("post_id", `String "nonexistent-id")]) in
  Alcotest.(check bool) "delete not found" false ok;
  Alcotest.(check bool) "error message present" true
    (contains_substring body "Delete failed")

let test_dispatch_delete_empty_id () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_delete"
    (make_args [("post_id", `String "")]) in
  Alcotest.(check bool) "empty id rejected" false ok;
  Alcotest.(check bool) "error mentions required" true
    (contains_substring body "required")

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
    (contains_substring msg_edit "edited tool body");
  (match Board_dispatch.get_post ~post_id with
   | Error e -> Alcotest.fail (Board.show_board_error e)
   | Ok post -> Alcotest.(check string) "edit persisted" "edited tool body" post.content)

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
       post.content)

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
    (contains_substring msg_edit "tool-transfer-next");
  match Board_dispatch.get_post ~post_id with
  | Error e -> Alcotest.fail (Board.show_board_error e)
  | Ok post ->
      Alcotest.(check string) "tool transfer author persisted"
        "tool-transfer-next"
        (Board.Agent_id.to_string post.author);
      Alcotest.(check string) "tool transfer content persisted"
        "transferred tool body" post.content

let test_dispatch_post_update_missing_id () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body =
    dispatch "masc_board_post_update"
      (make_args [ ("author", `String "x"); ("content", `String "y") ])
  in
  Alcotest.(check bool) "missing post_id rejected" false ok;
  Alcotest.(check bool) "error mentions required" true (contains_substring body "required")

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

let test_post_get_not_found () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_post_get"
    (make_args [("post_id", `String "nonexistent-id")]) in
  Alcotest.(check bool) "not found is idempotent success" true ok;
  Alcotest.(check bool) "body mentions gone" true
    (String_util.contains_substring_ci body "no longer exists")

let create_post_with_comments ~count =
  let ok, body =
    dispatch "masc_board_post"
      (make_args [ ("content", `String "Thread root"); ("author", `String "tester") ])
  in
  Alcotest.(check bool) "create root ok" true ok;
  let post_id =
    parse_create_response_json body
    |> Yojson.Safe.Util.member "id"
    |> Yojson.Safe.Util.to_string
  in
  for i = 1 to count do
    let ok, _ =
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

let check_get_footer ~label post_id args expected =
  let ok, body =
    dispatch "masc_board_post_get" (make_args (("post_id", `String post_id) :: args))
  in
  Alcotest.(check bool) (label ^ " get ok") true ok;
  Alcotest.(check bool) label true (contains_substring body expected)

let test_post_get_comment_pagination_clamps_and_advances () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let post_id = create_post_with_comments ~count:105 in
  check_get_footer
    ~label:"default limit"
    post_id
    []
    "Showing comments 1-50 of 105. Use comment_offset=50 to see more.";
  check_get_footer
    ~label:"over max limit"
    post_id
    [ "comment_limit", `Int 999 ]
    "Showing comments 1-100 of 105. Use comment_offset=100 to see more.";
  check_get_footer
    ~label:"zero limit clamps to one"
    post_id
    [ "comment_limit", `Int 0 ]
    "Showing comments 1-1 of 105. Use comment_offset=1 to see more.";
  check_get_footer
    ~label:"negative limit clamps to one"
    post_id
    [ "comment_limit", `Int (-10) ]
    "Showing comments 1-1 of 105. Use comment_offset=1 to see more.";
  check_get_footer
    ~label:"normal page advances"
    post_id
    [ "comment_offset", `Int 2; "comment_limit", `Int 2 ]
    "Showing comments 3-4 of 105. Use comment_offset=4 to see more.";
  check_get_footer
    ~label:"final page names returned range"
    post_id
    [ "comment_offset", `Int 100; "comment_limit", `Int 100 ]
    "Showing comments 101-105 of 105. No more comments.";
  check_get_footer
    ~label:"offset at end is empty final page"
    post_id
    [ "comment_offset", `Int 105; "comment_limit", `Int 100 ]
    "Showing comments 0 of 105. No more comments.";
  let small_post_id = create_post_with_comments ~count:2 in
  check_get_footer
    ~label:"all comments only when first page spans whole thread"
    small_post_id
    []
    "Showing all 2 comments."

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

let test_vote_rejects_legacy_direction_fallbacks () =
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
  let legacy_vote_alias =
    dispatch_result
      "masc_board_vote"
      (make_args
         [
           ("post_id", `String "missing");
           ("voter", `String "v");
           ("vote", `String "down");
         ])
  in
  Alcotest.(check bool) "legacy vote alias rejected" false (Tool_result.is_success legacy_vote_alias);
  Alcotest.(check bool)
    "legacy vote alias error"
    true
    (String_util.contains_substring
       ((Tool_result.message legacy_vote_alias))
       "legacy vote parameter")

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
    (contains_substring body "author")

let test_comment_add_anonymous_author_rejected () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let ok, body = dispatch "masc_board_comment"
    (make_args
       [("post_id", `String "missing"); ("content", `String "hi"); ("author", `String "anonymous")]) in
  Alcotest.(check bool) "anonymous author rejected" false ok;
  Alcotest.(check bool) "error mentions author" true
    (contains_substring body "author")

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
  let result =
    dispatch_result "masc_board_comment_vote"
      (make_args
         [
           ("comment_id", `String "missing-comment");
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
  Alcotest.(check bool) "error msg" true (String.length body > 0)

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
  Alcotest.(check int) "20 tool schemas" 20 (List.length Board_tool.tools)

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
  check_absent "keeper curation submit"
    (find_tool "keeper_board_curation_submit" Tool_shard.shard_board.tools)

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

(** {1 Comment Rate Limiting Tests} *)

(** Helper: create a post and return its id. *)
let rate_test_post_id store =
  match Board.create_post store
    ~author:"tester" ~content:"rate limit test post"
    ~post_kind:Human_post () with
  | Ok p -> Board.Post_id.to_string p.id
  | Error e -> Alcotest.failf "post create failed: %s" (Board.show_board_error e)

(** Helper: add a comment via the core API and return Ok/Error. *)
let rate_add_comment store post_id idx =
  Board.add_comment_with_status store
    ~post_id ~author:"tester"
    ~content:(Printf.sprintf "comment #%d" idx) ()

let test_rate_under_limit_succeeds () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let store = Board.create_store () in
  let post_id = rate_test_post_id store in
  for i = 1 to 28 do
    match rate_add_comment store post_id i with
    | Ok (_c, `Fresh) -> ()
    | Ok (_c, `Dedup) -> Alcotest.failf "comment %d unexpectedly deduped" i
    | Error e -> Alcotest.failf "comment %d rejected: %s" i (Board.show_board_error e)
  done

let test_rate_at_limit_rejects () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let store = Board.create_store () in
  let post_id = rate_test_post_id store in
  for i = 1 to 30 do
    ignore (rate_add_comment store post_id i : (_, _) result)
  done;
  (match rate_add_comment store post_id 31 with
   | Error (Board.Rate_limited _) -> ()
   | Ok _ -> Alcotest.fail "31st comment should have been rate-limited"
   | Error e -> Alcotest.failf "unexpected error: %s" (Board.show_board_error e))

let test_rate_different_authors_independent () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let store = Board.create_store () in
  let post_id = rate_test_post_id store in
  for i = 1 to 30 do
    ignore (Board.add_comment_with_status store
      ~post_id ~author:"author-a" ~content:(Printf.sprintf "fill-%d" i) () : (_, _) result)
  done;
  (match Board.add_comment_with_status store
    ~post_id ~author:"author-b" ~content:"b-comment" () with
   | Ok _ -> ()
   | Error e -> Alcotest.failf "author-b rejected: %s" (Board.show_board_error e))

let test_rate_retry_after_positive () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let store = Board.create_store () in
  let post_id = rate_test_post_id store in
  for i = 1 to 30 do
    ignore (rate_add_comment store post_id i)
  done;
  (match rate_add_comment store post_id 31 with
   | Error (Board.Rate_limited { retry_after }) ->
     Alcotest.(check bool) "retry_after > 0" true (retry_after > 0.0)
   | _ -> Alcotest.fail "expected Rate_limited error")

let test_rate_dedup_does_not_consume_quota () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let store = Board.create_store () in
  let post_id = rate_test_post_id store in
  for _i = 1 to 30 do
    ignore (Board.add_comment_with_status store
      ~post_id ~author:"tester" ~content:"identical" () : (_, _) result)
  done;
  (match Board.add_comment_with_status store
    ~post_id ~author:"tester" ~content:"different" () with
   | Ok _ -> ()
   | Error e -> Alcotest.failf "dedup-consumed quota: %s" (Board.show_board_error e))

let test_rate_window_expiry_allows_more () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  let store = Board.create_store () in
  let post_id = rate_test_post_id store in
  let old = Unix.gettimeofday () -. 600.0 in
  for i = 1 to 30 do
    Board_core.record_comment_timestamp ~author:"tester" ~now:(old +. float_of_int i)
  done;
  (match rate_add_comment store post_id 1 with
   | Ok _ -> ()
   | Error e -> Alcotest.failf "window expiry rejected: %s" (Board.show_board_error e))

let test_rate_disabled_when_limit_zero () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  ignore (Board.create_store ());
  (match Board_core.check_comment_rate_limit ~author:"unknown-agent" ~now:(Unix.gettimeofday ()) with
   | None -> ()
   | Some _ -> Alcotest.fail "unknown author should not be rate-limited")

let test_rate_dispatch_error_message () =
  with_eio @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  cleanup ();
  (* Use dispatch (Board.global) for everything so post exists in the right store *)
  let (_ok, create_msg) = dispatch "masc_board_post" (make_args [
    ("title", `String "rate-test"); ("content", `String "hello");
    ("author", `String "tester")
  ]) in
  let json = parse_create_response_json create_msg in
  let post_id = Yojson.Safe.Util.(json |> member "id" |> to_string) in
  for i = 1 to 30 do
    ignore (dispatch "masc_board_comment" (make_args [
      ("post_id", `String post_id);
      ("content", `String (Printf.sprintf "comment-%d" i));
      ("author", `String "tester")
    ]) : bool * string)
  done;
  let (ok, msg) = dispatch "masc_board_comment" (make_args [
    ("post_id", `String post_id);
    ("content", `String "overflow");
    ("author", `String "tester")
  ]) in
  Alcotest.(check bool) "rate limited via dispatch" false ok;
  Alcotest.(check bool) "error mentions rate/limit/retry" true
    (let lower = String.lowercase_ascii msg in
     let contains sub =
       let sub_len = String.length sub in
       let msg_len = String.length lower in
       let rec loop i =
         i + sub_len <= msg_len &&
         (String.sub lower i sub_len = sub || loop (i + 1))
       in
       loop 0
     in
     contains "rate" || contains "limit" || contains "retry")

(** {1 Test Runner} *)

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
          Alcotest.test_case "format_timestamp_relative" `Quick test_format_timestamp_relative;
          Alcotest.test_case "board actor identity canonicalizes keeper alias"
            `Quick test_board_actor_identity_canonicalizes_keeper_alias;
          Alcotest.test_case "board actor identity keeps non-keeper agent"
            `Quick test_board_actor_identity_keeps_non_keeper_agent;
          Alcotest.test_case "board dashboard json embeds reaction summaries"
            `Quick test_board_dashboard_json_embeds_reaction_summaries;
          Alcotest.test_case "board dashboard json embeds moderation projection"
            `Quick test_board_dashboard_json_embeds_moderation_projection;
          Alcotest.test_case "board dashboard json hides blind vote scores"
            `Quick test_board_dashboard_json_hides_unvoted_scores_when_blind;
          Alcotest.test_case "board dashboard json embeds contributor quality"
            `Quick test_board_dashboard_json_embeds_contributor_quality;
          Alcotest.test_case "MCP runtime board post author rewrites caller claim"
            `Quick test_inline_board_post_author_rewrites_caller_claim;
          Alcotest.test_case "MCP runtime board post author accepts matching alias"
            `Quick test_inline_board_post_author_accepts_matching_alias;
          Alcotest.test_case "moderation http identity binds to auth source"
            `Quick test_moderation_http_identity_bound_to_auth_source;
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
          Alcotest.test_case "create data is structured not double-encoded" `Quick
            test_post_create_data_is_structured;
          Alcotest.test_case "create judgment roundtrip" `Quick
            test_post_create_judgment_roundtrip;
          Alcotest.test_case "create judgment list roundtrip (#16300)" `Quick
            test_post_create_judgment_list_roundtrip;
          Alcotest.test_case "create judgment scalar types ignored (#16300)" `Quick
            test_post_create_judgment_scalar_types_ignored;
          Alcotest.test_case "create sources footer and meta" `Quick
            test_post_create_sources_footer_and_meta;
          Alcotest.test_case "keeper board post preserves meta reason" `Quick
            test_keeper_board_post_preserves_meta_reason;
          Alcotest.test_case
            "keeper board post rejects quantitative line claim without evidence"
            `Quick
            test_keeper_board_post_rejects_quantitative_line_claim_without_evidence;
          Alcotest.test_case
            "keeper board post rejects keyword-only quantitative evidence"
            `Quick
            test_keeper_board_post_rejects_keyword_only_quantitative_evidence;
          Alcotest.test_case
            "keeper board post rejects numeric line claim without keyword"
            `Quick
            test_keeper_board_post_rejects_numeric_line_claim_without_keyword;
          Alcotest.test_case
            "keeper board post accepts inline quantitative command evidence"
            `Quick
            test_keeper_board_post_accepts_inline_quantitative_command_evidence;
          Alcotest.test_case
            "keeper board post accepts quantitative line claim with evidence"
            `Quick
            test_keeper_board_post_accepts_quantitative_line_claim_with_evidence;
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
          Alcotest.test_case "get not found" `Quick test_post_get_not_found;
          Alcotest.test_case "get comment pagination" `Quick
            test_post_get_comment_pagination_clamps_and_advances;
        ] );
      ( "voting",
        [
          Alcotest.test_case "vote not found" `Quick test_vote_not_found;
          Alcotest.test_case
            "legacy direction fallbacks rejected"
            `Quick
            test_vote_rejects_legacy_direction_fallbacks;
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
      ( "post_kind_registry",
        [
          Alcotest.test_case "no hook: defaults to direct" `Quick (fun () ->
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.set_agent_lookup_none ();
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "claude-agent")
            ]) in
            Alcotest.(check bool) "post created" true ok;
            Alcotest.(check string) "classified as direct" "direct"
              Yojson.Safe.Util.(
                parse_create_response_json msg |> member "post_kind" |> to_string));
          Alcotest.test_case "with hook: agent classified as automation" `Quick (fun () ->
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.set_agent_lookup (fun name -> name = "claude-agent");
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "claude-agent")
            ]) in
            Alcotest.(check bool) "post created" true ok;
            Alcotest.(check string) "classified as automation" "automation"
              Yojson.Safe.Util.(
                parse_create_response_json msg |> member "post_kind" |> to_string));
          Alcotest.test_case "with hook: non-agent stays direct" `Quick (fun () ->
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.set_agent_lookup (fun _name -> false);
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "sangsu")
            ]) in
            Alcotest.(check bool) "post created" true ok;
            Alcotest.(check string) "classified as direct" "direct"
              Yojson.Safe.Util.(
                parse_create_response_json msg |> member "post_kind" |> to_string));
          Alcotest.test_case "human post_kind alias is rejected" `Quick (fun () ->
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.set_agent_lookup (fun _name -> true);
            let (ok, msg) = dispatch "masc_board_post" (make_args [
              ("title", `String "test"); ("content", `String "hello");
              ("author", `String "claude-agent");
              ("post_kind", `String "human")
            ]) in
            Alcotest.(check bool) "post rejected" false ok;
            Alcotest.(check bool) "unknown post_kind surfaced" true
              (contains_substring msg "unknown post_kind: human"));
        ] );
      ( "board_list_cache",
        [
          Alcotest.test_case "cache hit returns same result" `Quick (fun () ->
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.invalidate_board_list_cache ();
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
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.invalidate_board_list_cache ();
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
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.invalidate_board_list_cache ();
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
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.invalidate_board_list_cache ();
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
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.invalidate_board_list_cache ();
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
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.invalidate_board_list_cache ();
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
            with_eio @@ fun env ->
            Fs_compat.set_fs (Eio.Stdenv.fs env);
            cleanup ();
            Board_tool.invalidate_board_list_cache ();
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
      ( "comment_rate_limit",
        [
          Alcotest.test_case "under limit succeeds" `Quick test_rate_under_limit_succeeds;
          Alcotest.test_case "at limit rejects" `Quick test_rate_at_limit_rejects;
          Alcotest.test_case "different authors independent" `Quick
            test_rate_different_authors_independent;
          Alcotest.test_case "retry_after positive" `Quick test_rate_retry_after_positive;
          Alcotest.test_case "dedup does not consume quota" `Quick
            test_rate_dedup_does_not_consume_quota;
          Alcotest.test_case "window expiry allows more" `Quick
            test_rate_window_expiry_allows_more;
          Alcotest.test_case "disabled when limit zero" `Quick test_rate_disabled_when_limit_zero;
          Alcotest.test_case "dispatch error message" `Quick test_rate_dispatch_error_message;
        ] );
        ])
