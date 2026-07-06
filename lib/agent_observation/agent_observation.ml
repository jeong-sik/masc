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
type write_region_error =
  | Write_region_sink_not_installed
  | Write_region_sink_failed

let write_region_error_to_string = function
  | Write_region_sink_not_installed -> "write_region sink is not installed"
  | Write_region_sink_failed -> "write_region sink failed"
;;

type write_region_sink = write_region_event -> (unit, write_region_error) result
type annotation_sink = annotation_request -> (annotation_result, string) result

let noop_tool_event_sink (_ : tool_event) = ()
let noop_pr_event_sink (_ : pr_event) = ()
let noop_turn_event_sink (_ : turn_event) = ()
let noop_write_region_sink (_ : write_region_event) = Error Write_region_sink_not_installed
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

(* ── Observation snapshot accumulator (task-1686) ──────────────────── *)

type snapshot =
  { mutable tool_events : tool_event list
  ; mutable pr_events : pr_event list
  ; mutable turn_events : turn_event list
  ; mutable write_regions : write_region_event list
  ; mutable annotations : annotation_request list
  }

let current_snapshot =
  { tool_events = []
  ; pr_events = []
  ; turn_events = []
  ; write_regions = []
  ; annotations = []
  }
;;

let partition_to_json = function
  | By_url slug -> `Assoc [ ("type", `String "By_url"); ("slug", `String slug) ]
  | No_canonical_url -> `String "No_canonical_url"
  | Unmatched -> `String "Unmatched"
  | Base_unresolved -> `String "Base_unresolved"
  | Legacy_default -> `String "Legacy_default"
;;

let tool_event_to_json (e : tool_event) =
  `Assoc
    [ ("base_path", `String e.base_path)
    ; ("partition", partition_to_json e.partition)
    ; ("tool_name", `String e.tool_name)
    ; ("keeper_id", `String e.keeper_id)
    ; ("turn_id", `String e.turn_id)
    ; ("outcome", `String e.outcome)
    ; ("duration_ms", `Float e.duration_ms)
    ]
;;

let pr_event_to_json (e : pr_event) =
  `Assoc
    [ ("base_path", `String e.base_path)
    ; ("partition", partition_to_json e.partition)
    ; ("keeper_id", `String e.keeper_id)
    ; ("tool_name", `String e.tool_name)
    ; ("success", `Bool e.success)
    ]
;;

let turn_event_to_json (e : turn_event) =
  `Assoc
    [ ("base_path", `String e.base_path)
    ; ("partition", partition_to_json e.partition)
    ; ("turn_id", `String e.turn_id)
    ; ("keeper_id", `String e.keeper_id)
    ; ("phase", `String e.phase)
    ; ("timestamp_ms", `Int (Int64.to_int e.timestamp_ms))
    ]
;;

let write_region_to_json (e : write_region_event) =
  `Assoc
    [ ("file_path", `String e.file_path)
    ; ("line_start", `Int e.line_start)
    ; ("line_end", `Int e.line_end)
    ; ("keeper_id", `String e.keeper_id)
    ; ("partition", partition_to_json e.partition)
    ]
;;

let annotation_to_json (a : annotation_request) =
  `Assoc
    [ ("file_path", `String a.file_path)
    ; ("line_start", `Int a.line_start)
    ; ("line_end", `Int a.line_end)
    ; ("keeper_id", `String a.keeper_id)
    ; ("kind", `String (annotation_kind_to_string a.kind))
    ; ("content", `String a.content)
    ; ("partition", partition_to_json a.partition)
    ]
;;

let snapshot_to_json (snap : snapshot) =
  `Assoc
    [ ("tool_events", `List (List.map tool_event_to_json snap.tool_events))
    ; ("pr_events", `List (List.map pr_event_to_json snap.pr_events))
    ; ("turn_events", `List (List.map turn_event_to_json snap.turn_events))
    ; ("write_regions", `List (List.map write_region_to_json snap.write_regions))
    ; ("annotations", `List (List.map annotation_to_json snap.annotations))
    ; ( "summary"
      , `Assoc
          [ ("tool_event_count", `Int (List.length snap.tool_events))
          ; ("pr_event_count", `Int (List.length snap.pr_events))
          ; ("turn_event_count", `Int (List.length snap.turn_events))
          ; ("write_region_count", `Int (List.length snap.write_regions))
          ; ("annotation_count", `Int (List.length snap.annotations))
          ] )
    ]
;;

let take_snapshot () =
  let snap =
    { tool_events = List.rev current_snapshot.tool_events
    ; pr_events = List.rev current_snapshot.pr_events
    ; turn_events = List.rev current_snapshot.turn_events
    ; write_regions = List.rev current_snapshot.write_regions
    ; annotations = List.rev current_snapshot.annotations
    }
  in
  current_snapshot.tool_events <- [];
  current_snapshot.pr_events <- [];
  current_snapshot.turn_events <- [];
  current_snapshot.write_regions <- [];
  current_snapshot.annotations <- [];
  snap
;;

let peek_snapshot () =
  { tool_events = List.rev current_snapshot.tool_events
  ; pr_events = List.rev current_snapshot.pr_events
  ; turn_events = List.rev current_snapshot.turn_events
  ; write_regions = List.rev current_snapshot.write_regions
  ; annotations = List.rev current_snapshot.annotations
  }
;;

(* Emit wrappers: accumulate into snapshot + forward to registered sink. *)
let emit_tool_event event =
  current_snapshot.tool_events <- event :: current_snapshot.tool_events;
  Atomic.get tool_event_sink event
;;

let emit_pr_event event =
  current_snapshot.pr_events <- event :: current_snapshot.pr_events;
  Atomic.get pr_event_sink event
;;

let emit_turn_event event =
  current_snapshot.turn_events <- event :: current_snapshot.turn_events;
  Atomic.get turn_event_sink event
;;

let emit_write_region_event event =
  current_snapshot.write_regions <- event :: current_snapshot.write_regions;
  Atomic.get write_region_sink event
;;

let emit_annotation_request request =
  current_snapshot.annotations <- request :: current_snapshot.annotations;
  Atomic.get annotation_sink request
;;

let reset_for_testing () =
  Atomic.set tool_event_sink noop_tool_event_sink;
  Atomic.set pr_event_sink noop_pr_event_sink;
  Atomic.set turn_event_sink noop_turn_event_sink;
  Atomic.set write_region_sink noop_write_region_sink;
  Atomic.set annotation_sink noop_annotation_sink
;;
