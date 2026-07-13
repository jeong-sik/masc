open Masc_board_handlers

module Format = Stdlib.Format
module Map = Stdlib.Map
module Set = Stdlib.Set
module Queue = Stdlib.Queue
module Hashtbl = Stdlib.Hashtbl
module Mutex = Stdlib.Mutex
module Option = Stdlib.Option
module Result = Stdlib.Result
module Sys = Stdlib.Sys
module Filename = Stdlib.Filename
module List = Stdlib.List
module Array = Stdlib.Array
module String = Stdlib.String
module Char = Stdlib.Char
module Int = Stdlib.Int
module Float = Stdlib.Float

(** Board_tool_handlers — non-post mutating / read handlers and the
    shared agent-lookup / SOUL-evolution callbacks.

    Hosts the vote / search / profile / reaction / hearths / stats /
    delete / board_cleanup handlers along with the
    [agent_lookup_hook] / [evolution_hook] state. Post handlers live in
    {!Board_tool_post}, sub-board handlers in {!Board_tool_sub_board},
    curation handlers in {!Board_tool_curation}.

    Stage 10 split of lib/board_tool.ml. *)

open Tool_args

(** {1 Agent lookup callback} *)

(** Set once at server startup for optional agent-to-agent feedback hooks. *)
let agent_lookup_hook : (string -> bool) option Atomic.t = Atomic.make None

let set_agent_lookup f = Atomic.set agent_lookup_hook (Some f)
let set_agent_lookup_none () = Atomic.set agent_lookup_hook None

(** Check whether [name] is a registered agent. Uses the registry
    lookup ([Workspace.is_agent_session_bound]) when available via
    [agent_lookup_hook]; returns [false] when no hook is installed. *)
let is_agent name =
  match Atomic.get agent_lookup_hook with
  | Some lookup -> lookup name
  | None -> false
;;

let agent_id_arg ~field args =
  let raw = get_string args field "" |> String.trim in
  if String.equal raw ""
  then Error (Board.Validation_error (field ^ " is required"))
  else Board.Agent_id.of_string raw
;;

let same_agent_id left right =
  String.equal (Board.Agent_id.to_string left) (Board.Agent_id.to_string right)
;;

let require_post_author ~post_id ~author =
  match Board_dispatch.get_post ~post_id with
  | Error _ as err -> err
  | Ok post ->
    if same_agent_id post.Board.author author
    then Ok ()
    else
      Error
        (Board.Unauthorized
           (Printf.sprintf
              "agent %s cannot delete post %s owned by %s"
              (Board.Agent_id.to_string author)
              post_id
              (Board.Agent_id.to_string post.author)))
;;

let resolve_board_post_kind (raw_kind : string option)
  : (Board.post_kind, string) Stdlib.result
  =
  match raw_kind with
  | Some raw ->
    (match Board.post_kind_of_string (String.lowercase_ascii (String.trim raw)) with
     | Some Board.System_post ->
       Error "system posts are reserved for platform/internal surfaces"
     | Some kind -> Ok kind
     | None -> Error (Printf.sprintf "unknown post_kind: %s" raw))
  | None -> Ok Board.Human_post
;;

(** {1 SOUL Evolution callback} *)

(** Registered at startup to break dependency cycle. *)
type evolution_callback =
  { get_primary_value : string -> string option
  ; record_feedback : name:string -> dimension:string -> is_positive:bool -> unit
  }

let evolution_hook : evolution_callback option Atomic.t = Atomic.make None
let register_evolution_callback cb = Atomic.set evolution_hook (Some cb)

(** {1 Vote / stats / search handlers} *)

(* RFC-0189 PR-1b.1 — handlers in this module return the typed
   [Tool_result.result] variant. Errors carry an explicit [~class_] at
   the catch site (no string-classifier fallback). *)

let invalid_vote_direction ~tool_name ~start_time raw : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Workflow_rejection
    ~start_time
    (Printf.sprintf "invalid vote direction %S; expected up or down" raw)
;;

(* Rejection tombstone for the retired [vote] parameter. Deleting it (#23710)
   made a legacy {vote:"down"} call silently default direction to "up" —
   an inverted vote instead of a typed rejection (main red #23901, voting). *)
let legacy_vote_parameter_removed ~tool_name ~start_time raw : Tool_result.result =
  Tool_result.make_err
    ~tool_name
    ~class_:Tool_result.Policy_rejection
    ~start_time
    (Printf.sprintf
       "legacy vote parameter %S is no longer accepted; use direction"
       raw)
;;

let handle_vote ~tool_name ~start_time args =
  let post_id = get_string args "post_id" "" in
  let voter = get_string args "voter" "anonymous" in
  match Safe_ops.json_string_opt "direction" args, get_string_opt args "vote" with
  | None, Some raw ->
    legacy_vote_parameter_removed ~tool_name ~start_time raw
  | direction_arg, _ ->
    let direction_str =
      match direction_arg with
      | Some raw -> raw
      | None -> "up"
    in
    (match Board.vote_direction_of_string_opt direction_str with
     | None -> invalid_vote_direction ~tool_name ~start_time direction_str
     | Some direction ->
       (match Board_dispatch.vote ~voter ~post_id ~direction with
        | Ok new_score ->
          let arrow = if direction = Board.Up then "↑" else "↓" in
          (* SOUL Evolution via callback (breaks compile-time dependency cycle). *)
          let evolution_msg =
            match Atomic.get evolution_hook with
            | None -> "" (* Not initialized yet. *)
            | Some cb ->
              (match Board_dispatch.get_post ~post_id with
               | Ok post ->
                 let author = Board.Agent_id.to_string post.author in
                 (* Agent-only evolution: 에이전트끼리만 서로 진화시킴. *)
                 if is_agent voter && is_agent author
                 then (
                   let dimension =
                     match cb.get_primary_value author with
                     | Some pv -> pv
                     | None -> "Creativity"
                   in
                   let is_positive = direction = Board.Up in
                   cb.record_feedback ~name:author ~dimension ~is_positive;
                   Printf.sprintf
                     " [%s evolved: %s %s]"
                     author
                     dimension
                     (if is_positive then "+0.01" else "-0.01"))
                 else ""
               | Error e ->
                 Log.Misc.warn
                   "[ToolBoard] get_reputation_evolution failed: %s"
                   (Board_tool_format.board_error_to_string e);
                 "")
          in
          Tool_result.make_ok
            ~tool_name
            ~start_time
            ~data:
              (`String
                 (Printf.sprintf
                    "%s Vote recorded. New score: %+d%s"
                    arrow
                    new_score
                    evolution_msg))
            ()
        | Error (Board.Already_voted _) ->
          (* Idempotent: same-direction duplicate vote is a no-op success.
             The desired state already exists, so the tool call succeeds. *)
          (match Board_dispatch.get_post ~post_id with
           | Ok post ->
             let score = post.votes_up - post.votes_down in
             let arrow = if direction = Board.Up then "↑" else "↓" in
             Tool_result.make_ok
               ~tool_name
               ~start_time
               ~data:
                 (`String
                    (Printf.sprintf
                       "%s Already voted (idempotent). Score: %+d"
                       arrow
                       score))
               ()
           | Error _ ->
             Tool_result.make_ok
               ~tool_name
               ~start_time
               ~data:(`String "Already voted (idempotent). Score unchanged.")
               ())
        | Error e ->
          Board_tool_format.error_of_board_error ~tool_name ~start_time e))
;;

let handle_stats ~tool_name ~start_time _args : Tool_result.result =
  let stats = Board_dispatch.stats () in
  Tool_result.make_ok ~tool_name ~start_time ~data:stats ()
;;

(** Search posts by keyword. *)
let handle_search ~tool_name ~start_time args : Tool_result.result =
  let query = get_string args "query" "" in
  let limit = get_int args "limit" 20 |> max 1 |> min 100 in
  let compact = get_bool args "compact" true in
  if String.equal query ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "query required"
  else (
    let results = Board_dispatch.search ~query ~limit in
    if Stdlib.List.length results = 0
    then
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:(`String (Printf.sprintf "'%s' 검색 결과 없음" query))
        ()
    else (
      let fmt =
        if compact
        then Board_tool_format.format_post_compact
        else Board_tool_format.format_post
      in
      let formatted = List.map fmt results in
      let separator = if compact then "\n" else "\n---\n" in
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:
          (`String
             (Printf.sprintf
                "'%s' 검색 결과 (%d개):\n\n%s"
                query
                (List.length results)
                (String.concat separator formatted)))
        ()))
;;

(** Vote on comment. *)
let handle_comment_vote ~tool_name ~start_time args : Tool_result.result =
  let comment_id = get_string args "comment_id" "" in
  let voter = get_string args "voter" "anonymous" in
  let direction_str = get_string args "direction" "up" in
  match Board.vote_direction_of_string_opt direction_str with
  | None -> invalid_vote_direction ~tool_name ~start_time direction_str
  | Some direction ->
    if String.equal comment_id ""
    then
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        "comment_id required"
    else (
      match Board_dispatch.vote_comment ~voter ~comment_id ~direction with
      | Ok score ->
        Tool_result.make_ok
          ~tool_name
          ~start_time
          ~data:
            (`String
               (Printf.sprintf
                  "%s 코멘트 투표 완료! 점수: %+d"
                  (if String.equal direction_str "down" then "👎" else "👍")
                  score))
          ()
      | Error (Board.Already_voted _) ->
        Tool_result.make_ok
          ~tool_name
          ~start_time
          ~data:
            (`String
               (Printf.sprintf
                  "%s Already voted (idempotent)."
                  (if String.equal direction_str "down" then "👎" else "👍")))
          ()
      | Error e ->
        Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;

let handle_reaction ~tool_name ~start_time args : Tool_result.result =
  let target_type_raw = get_string args "target_type" "" in
  let target_id = get_string args "target_id" "" in
  let user_id = get_string args "user_id" (get_string args "user" "anonymous") in
  let emoji = get_string args "emoji" "" in
  match Board.reaction_target_type_of_string_opt target_type_raw with
  | None ->
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "target_type must be post or comment"
  | Some target_type ->
    if String.equal (String.trim target_id) ""
    then
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        "target_id required"
    else if
      String.equal (String.trim user_id) ""
      || String.equal (String.trim user_id) "anonymous"
    then
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Workflow_rejection
        ~start_time
        "user_id required"
    else (
      match Board_dispatch.toggle_reaction ~target_type ~target_id ~user_id ~emoji with
      | Ok result ->
        (* Pass structured [data] directly (no prose label here), instead of a
           `String holding stringified JSON that consumers would double-encode. *)
        Tool_result.make_ok
          ~tool_name
          ~start_time
          ~data:(Board.reaction_toggle_result_to_yojson result)
          ()
      | Error e ->
        Board_tool_format.error_of_board_error ~tool_name ~start_time e)
;;

(** Agent profile. *)
let handle_profile ~tool_name ~start_time args : Tool_result.result =
  let agent = get_string args "agent" "" in
  if String.equal agent ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "agent required"
  else (
    let all_posts : Board.post list = Board_dispatch.list_posts ~limit:1000 () in
    let norm s = String.lowercase_ascii (String.trim s) in
    let agent_norm = norm agent in
    let agent_posts =
      List.filter
        (fun (p : Board.post) ->
           String.equal (norm (Board.Agent_id.to_string p.author)) agent_norm)
        all_posts
    in
    let post_votes =
      List.fold_left
        (fun acc (p : Board.post) -> acc + p.votes_up - p.votes_down)
        0
        agent_posts
    in
    let all_comments : Board.comment list = Board_dispatch.list_comments () in
    let agent_comments =
      List.filter
        (fun (c : Board.comment) ->
           String.equal (norm (Board.Agent_id.to_string c.author)) agent_norm)
        all_comments
    in
    let comment_votes =
      List.fold_left
        (fun acc (c : Board.comment) -> acc + c.votes_up - c.votes_down)
        0
        agent_comments
    in
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`String
           (Printf.sprintf
              "**%s** 프로필\n게시물: %d개 (%+d점)\n코멘트: %d개 (%+d점)\n총: %+d점"
              agent
              (List.length agent_posts)
              post_votes
              (List.length agent_comments)
              comment_votes
              (post_votes + comment_votes)))
      ())
;;

(** Hearth list. *)
let handle_hearth_list ~tool_name ~start_time _args : Tool_result.result =
  let hearths = Board_dispatch.list_hearths () in
  if Stdlib.List.length hearths = 0
  then
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:(`String "No active hearths.")
      ()
  else (
    let formatted =
      List.map
        (fun (name, count) -> Printf.sprintf "**%s** (%d posts)" name count)
        hearths
    in
    Tool_result.make_ok
      ~tool_name
      ~start_time
      ~data:
        (`String
           (Printf.sprintf "Active Hearths:\n%s" (String.concat "\n" formatted)))
      ())
;;

(** {1 Delete / cleanup handlers} *)

let handle_delete ~tool_name ~start_time args : Tool_result.result =
  let post_id = String.trim (get_string args "post_id" "") in
  if String.equal post_id ""
  then
    Tool_result.make_err
      ~tool_name
      ~class_:Tool_result.Workflow_rejection
      ~start_time
      "post_id is required"
  else (
    match agent_id_arg ~field:"author" args with
    | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e
    | Ok author ->
    match require_post_author ~post_id ~author with
    | Error e -> Board_tool_format.error_of_board_error ~tool_name ~start_time e
    | Ok () ->
    match Board_dispatch.delete_post ~post_id with
    | Ok () ->
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:(`String (Printf.sprintf "Deleted post %s" post_id))
        ()
    | Error e ->
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        (Printf.sprintf
           "Delete failed: %s"
           (Board_tool_format.board_error_to_string e)))
;;

let handle_board_cleanup ~tool_name ~start_time args : Tool_result.result =
  let max_age_hours = get_int args "max_age_hours" 24 |> max 1 in
  let require_no_comments = get_bool args "require_no_comments" true in
  let require_no_votes = get_bool args "require_no_votes" true in
  let dry_run = get_bool args "dry_run" true in
  let limit = get_int args "limit" 10 |> max 1 |> min 50 in
  let title_pattern = get_string_opt args "title_pattern" in
  let author_pattern = get_string_opt args "author_pattern" in
  let now = Time_compat.now () in
  let age_threshold = now -. (Stdlib.Float.of_int max_age_hours *. Masc_time_constants.hour) in
  let title_needle = Option.map String.lowercase_ascii title_pattern in
  let author_needle = Option.map String.lowercase_ascii author_pattern in
  let matches_opt needle s =
    match needle with
    | None -> true
    | Some n -> String_util.contains_substring (String.lowercase_ascii s) n
  in
  let all_posts =
    Board_dispatch.list_posts ~sort_by:Board_tool_format.Recent ~limit:500 ()
  in
  let candidates =
    List.filter
      (fun (p : Board.post) ->
         Stdlib.Float.compare p.created_at age_threshold < 0
         && ((not require_no_comments) || p.reply_count = 0)
         && ((not require_no_votes) || (p.votes_up = 0 && p.votes_down = 0))
         && matches_opt title_needle p.title
         && matches_opt author_needle (Board.Agent_id.to_string p.author))
      all_posts
  in
  let targets = List.filteri (fun i _ -> i < limit) candidates in
  if dry_run
  then (
    let count = List.length targets in
    if count = 0
    then
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:
          (`String
             (Printf.sprintf
                "Scan complete: 0 candidates (scanned %d posts, age>%dh)"
                (List.length all_posts)
                max_age_hours))
        ()
    else (
      let lines =
        List.map
          (fun (p : Board.post) ->
             Printf.sprintf
               "  - %s | %s | by %s | %s | replies=%d votes=%d"
               (Board.Post_id.to_string p.id)
               p.title
               (Board.Agent_id.to_string p.author)
               (Board_tool_format.format_timestamp_relative p.created_at)
               p.reply_count
               (p.votes_up + p.votes_down))
          targets
      in
      Tool_result.make_ok
        ~tool_name
        ~start_time
        ~data:
          (`String
             (Printf.sprintf
                "Dry-run: %d candidates (scanned %d, age>%dh):\n%s"
                count
                (List.length all_posts)
                max_age_hours
                (String.concat "\n" lines)))
        ()))
  else (
    let deleted = ref 0 in
    let failed = ref 0 in
    List.iter
      (fun (p : Board.post) ->
         let pid = Board.Post_id.to_string p.id in
         try
           match Board_dispatch.delete_post ~post_id:pid with
           | Ok () -> Stdlib.incr deleted
           | Error _ -> Stdlib.incr failed
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | _exn -> Stdlib.incr failed)
      targets;
    let message =
      Printf.sprintf
        "Cleanup done: %d deleted, %d failed (scanned %d, age>%dh)"
        !deleted
        !failed
        (List.length all_posts)
        max_age_hours
    in
    if !failed > 0
    then
      Tool_result.make_err
        ~tool_name
        ~class_:Tool_result.Runtime_failure
        ~start_time
        message
    else Tool_result.make_ok ~tool_name ~start_time ~data:(`String message) ())
;;
