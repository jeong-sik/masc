type codebase_partition =
  | By_url of string
      (** canonical URL 정상 resolved: host_path slug. *)
  | No_canonical_url
      (** [canonical_url_of_remote] returned None: blank [repo.url] or malformed
          remote. IDE Observation Plane v2 §7 "(1) 빈 repo/remote 없음". *)
  | Unmatched
      (** Caller passed [repo_id] but the repository store could not resolve it
          (not-found / empty-url / load-error). v2 §7 "(2) repo_id unmatched". *)
  | Base_unresolved
      (** [file_path] falls under no registered repo [local_path] (unregistered
          worktree, outside [.masc/playground]). v2 §7 "(4) base 경로 소실" —
          the write-path [unregistered_repo] producer is the live instance. *)
  | Legacy_default
      (** Neither [canonical_url] nor [repo_id] was supplied, or the record
          carries no [partition] field at all (tool/turn/pr_event,
          annotation_request). Structural ceiling, NOT a soft fallback.
          v2 §7 "(3) default 미갱신". *)

type tool_event =
  { base_path : string
  ; partition : codebase_partition
  ; tool_name : string
  ; keeper_id : string
  ; turn_id : string
  ; outcome : string
  ; typed_outcome : string
  ; duration_ms : float
  ; output_text : string
  ; input : Yojson.Safe.t
  }

type pr_event =
  { base_path : string
  ; partition : codebase_partition
  ; keeper_id : string
  ; turn_id : string
  ; output_text : string
  ; tool_name : string
  ; success : bool
  }

type turn_event =
  { base_path : string
  ; partition : codebase_partition
  ; turn_id : string
  ; keeper_id : string
  ; phase : string
  ; model_used : string option
  ; tools_used : string list
  ; stop_reason : string option
  ; duration_ms : int option
  ; timestamp_ms : int64
  }


(* RFC-0128 §4.1 neutral codebase slug derivation.

   Kept below the Keeper/IDE boundary so runtime producers can route
   observations without depending on the IDE storage module. *)
let strip_prefix ~prefix s =
  let n = String.length prefix in
  String.sub s n (String.length s - n)
;;

let strip_suffix ~suffix s =
  let ns = String.length s in
  let nf = String.length suffix in
  if ns >= nf && String.sub s (ns - nf) nf = suffix
  then String.sub s 0 (ns - nf)
  else s
;;

let split_host_path s =
  match String.index_opt s '/' with
  | None -> (s, "")
  | Some i ->
    let host = String.sub s 0 i in
    let path = String.sub s (i + 1) (String.length s - i - 1) in
    (host, path)
;;

let normalize_scp_like s =
  match String.index_opt s '@' with
  | None -> s
  | Some at ->
    let after = String.sub s (at + 1) (String.length s - at - 1) in
    (match String.index_opt after ':' with
     | None -> s
     | Some colon ->
       (match String.index_opt after '/' with
        | Some slash when slash < colon -> s
        | _ ->
          let host = String.sub after 0 colon in
          let path = String.sub after (colon + 1) (String.length after - colon - 1) in
          host ^ "/" ^ path))
;;

let strip_scheme s =
  let candidates = [ "https://"; "http://"; "ssh://"; "git://" ] in
  match List.find_opt (fun p -> String.starts_with ~prefix:p s) candidates with
  | Some p -> strip_prefix ~prefix:p s
  | None -> s
;;

let strip_userinfo s =
  match String.index_opt s '@' with
  | None -> s
  | Some at ->
    (match String.index_opt s '/' with
     | Some slash when slash < at -> s
     | _ -> String.sub s (at + 1) (String.length s - at - 1))
;;

let is_slug_char c =
  (c >= 'a' && c <= 'z')
  || (c >= '0' && c <= '9')
  || c = '_'
  || c = '-'
  || c = '.'
;;

let path_segment_to_slug seg =
  if seg = "" then None
  else if String.length seg >= 2 && String.sub seg 0 2 = ".."
  then None
  else if String.for_all is_slug_char seg
  then Some seg
  else None
;;

let canonical_url_of_remote raw =
  let trimmed = String.trim raw in
  if trimmed = "" then None
  else
    let s = String.lowercase_ascii trimmed in
    let s = normalize_scp_like s in
    let s = strip_scheme s in
    let s = strip_userinfo s in
    let host, path = split_host_path s in
    if host = "" || path = "" then None
    else
      let path = strip_suffix ~suffix:".git" path in
      let segments =
        String.split_on_char '/' path |> List.filter (fun seg -> seg <> "")
      in
      if segments = [] then None
      else
        match path_segment_to_slug host with
        | None -> None
        | Some host_slug ->
          let rec collect acc = function
            | [] -> Some (List.rev acc)
            | seg :: rest ->
              (match path_segment_to_slug seg with
               | None -> None
               | Some s -> collect (s :: acc) rest)
          in
          (match collect [] segments with
           | None -> None
           | Some segs -> Some (String.concat "_" (host_slug :: segs)))
;;

type write_region_event =
  { base_path : string
  ; partition : codebase_partition
  ; keeper_id : string
  ; turn : int
  ; tool_call_json : Yojson.Safe.t
  }

type annotation_kind =
  | Comment
  | Decision
  | Question
  | Bookmark

let annotation_kind_to_string = function
  | Comment -> "Comment"
  | Decision -> "Decision"
  | Question -> "Question"
  | Bookmark -> "Bookmark"
;;

let annotation_kind_of_string = function
  | "Comment" -> Some Comment
  | "Decision" -> Some Decision
  | "Question" -> Some Question
  | "Bookmark" -> Some Bookmark
  | _ -> None
;;

type annotation_request =
  { base_path : string
  ; partition : codebase_partition
  ; keeper_id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  ; kind : annotation_kind
  ; content : string
  ; goal_id : string option
  ; task_id : string option
  ; board_post_id : string option
  ; comment_id : string option
  ; pr_id : string option
  ; git_ref : string option
  ; log_id : string option
  ; session_id : string option
  ; operation_id : string option
  ; worker_run_id : string option
  }

type annotation_result =
  { id : string
  ; file_path : string
  ; line_start : int
  ; line_end : int
  }

type tool_event_sink = tool_event -> unit
type pr_event_sink = pr_event -> unit
type turn_event_sink = turn_event -> unit
type write_region_sink = write_region_event -> unit
type annotation_sink = annotation_request -> (annotation_result, string) result

let noop_tool_event_sink (_ : tool_event) = ()
let noop_pr_event_sink (_ : pr_event) = ()
let noop_turn_event_sink (_ : turn_event) = ()
let noop_write_region_sink (_ : write_region_event) = ()
let noop_annotation_sink (_ : annotation_request) = Error "annotation sink is not installed"

let tool_event_sink = Atomic.make noop_tool_event_sink
let pr_event_sink = Atomic.make noop_pr_event_sink
let turn_event_sink = Atomic.make noop_turn_event_sink
let write_region_sink = Atomic.make noop_write_region_sink
let annotation_sink = Atomic.make noop_annotation_sink

let register_tool_event_sink sink = Atomic.set tool_event_sink sink
let register_pr_event_sink sink = Atomic.set pr_event_sink sink
let register_turn_event_sink sink = Atomic.set turn_event_sink sink
let register_write_region_sink sink = Atomic.set write_region_sink sink
let register_annotation_sink sink = Atomic.set annotation_sink sink

let emit_tool_event event = Atomic.get tool_event_sink event
let emit_pr_event event = Atomic.get pr_event_sink event
let emit_turn_event event = Atomic.get turn_event_sink event
let emit_write_region_event event = Atomic.get write_region_sink event
let emit_annotation_request request = Atomic.get annotation_sink request

let reset_for_testing () =
  Atomic.set tool_event_sink noop_tool_event_sink;
  Atomic.set pr_event_sink noop_pr_event_sink;
  Atomic.set turn_event_sink noop_turn_event_sink;
  Atomic.set write_region_sink noop_write_region_sink;
  Atomic.set annotation_sink noop_annotation_sink
;;
