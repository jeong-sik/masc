open Keeper_types
open Keeper_meta_contract
open Keeper_types_profile
open Keeper_tool_shared_runtime
open Keeper_context_runtime
module StringSet = Set_util.StringSet


(* Issue #8484: Variant SSOT for memory search scope. Adding a new
   constructor forces compilation in [memory_search_source_to_string]
   AND extends [valid_memory_search_source_strings]; the schema in
   [tool_shard.ml] mirrors the SSOT (cycle: Tool_shard ->
   Keeper_tool_memory_runtime -> ... -> Tool_shard prevented via local mirror,
   sync test catches drift). The previous code used a string match
   with a wildcard `_ -> memory` branch which silently routed any
   unknown source to memory. Now unknown values are rejected at the
   tool boundary. *)
type memory_search_source =
  | Memory
  | History
  | All

let memory_search_source_to_string = function
  | Memory -> "memory"
  | History -> "history"
  | All -> "all"
;;

let memory_search_source_of_string_opt raw =
  match String.trim (String.lowercase_ascii raw) with
  | "memory" -> Some Memory
  | "history" -> Some History
  | "all" -> Some All
  | _ -> None
;;

let all_memory_search_sources = [ Memory; History; All ]

let valid_memory_search_source_strings =
  List.map memory_search_source_to_string all_memory_search_sources
;;

(* --- Durable fact search (Memory OS store) --- *)

type fact_match =
  { claim : string
  ; category : string
  }

let read_current_facts ~keepers_dir ~keeper_id =
  match
    Keeper_memory_os_current.read_for_keepers_dir ~keepers_dir ~keeper_id
  with
  | Ok None -> []
  | Ok (Some snapshot) -> snapshot.facts
  | Error detail -> failwith detail
;;

(* Filter the keeper's current facts by an explicit query substring while
   preserving snapshot order. Search does not assign value scores or introduce
   a recency authority. *)
let search_durable_facts
      ~(config : Workspace.config)
      ~(keepers_dir : string)
      ~(meta : keeper_meta)
      ~(query : string)
      ~(limit : int)
  : fact_match list * int
  =
  let facts = read_current_facts ~keepers_dir ~keeper_id:meta.name in
  let source_projection =
    match
      Keeper_memory_source_current.revalidate
        ~config
        ~meta
        ~keepers_dir
        ~now:(Time_compat.now ())
        ()
    with
    | Ok projection -> projection
    | Error detail -> failwith detail
  in
  let source_facts = source_projection.facts in
  let total_candidates = List.length facts + List.length source_facts in
  let matched =
    if String.equal query ""
    then facts
    else
      List.filter
        (fun (fact : Keeper_memory_os_types.fact) ->
          String_util.contains_substring_ci fact.claim query)
        facts
  in
  let source_matched =
    if String.equal query ""
    then source_facts
    else
      List.filter
        (fun (fact : Keeper_memory_source_current.fact) ->
           String_util.contains_substring_ci fact.claim query)
        source_facts
  in
  let ordinary_matches =
    matched
    |> List.map (fun (fact : Keeper_memory_os_types.fact) ->
      { claim = fact.claim
      ; category = Keeper_memory_os_types.category_to_string fact.category
      })
  in
  let source_matches =
    List.map
      (fun (fact : Keeper_memory_source_current.fact) ->
         { claim = fact.claim; category = "fact" })
      source_matched
  in
  take limit (ordinary_matches @ source_matches), total_candidates
;;

let fact_match_to_json (m : fact_match) : Yojson.Safe.t =
  `Assoc
    [ "text", `String m.claim
    ; "category", `String m.category
    ]
;;

(* --- History search (checkpoint + trace history) --- *)

let search_history
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(query : string)
      ~(limit : int)
  : string list
  =
  (* RFC-0149 §3.1 — aggregation site.  Multiple history files are
     concatenated for search; a per-path Read failure is dropped to
     [[]] so a single corrupt history does not suppress matches from
     the others.  The decision to elide is made *here* rather than
     hidden inside a silent facade — failures still surface via the
     [metric_keeper_memory_recall_read_errors] counter emitted by
     [Keeper_memory_recall.load_history_user_messages_result]. *)
  let current_history =
    match
      Keeper_memory_recall.load_history_user_messages_result
        ~path:
          (Keeper_types_support.keeper_history_path
             config
             (Keeper_id.Trace_id.to_string meta.runtime.trace_id))
        ~max_n:50
    with
    | Ok msgs -> msgs
    | Error _ -> []
  in
  let prev_history =
    meta.runtime.trace_history
    |> List.concat_map (fun old_trace_id ->
      match
        Keeper_memory_recall.load_history_user_messages_result
          ~path:(Keeper_types_support.keeper_history_path config old_trace_id)
          ~max_n:20
      with
      | Ok msgs -> msgs
      | Error _ -> [])
  in
  let checkpoint_user_msgs =
    Keeper_memory_recall.recent_user_messages (messages_of_context ctx_work) ~max_n:100
  in
  let key_of s =
    let len = min 100 (String.length s) in
    String.sub s 0 len
  in
  let seen0 =
    List.fold_left
      (fun acc s -> StringSet.add (key_of s) acc)
      StringSet.empty
      checkpoint_user_msgs
  in
  let dedup seen lst =
    List.fold_left
      (fun (acc, seen) s ->
         let k = key_of s in
         if StringSet.mem k seen then acc, seen else s :: acc, StringSet.add k seen)
      ([], seen)
      lst
    |> fun (acc, seen) -> List.rev acc, seen
  in
  let all_candidates =
    checkpoint_user_msgs
    @ fst (dedup seen0 current_history)
    @ fst (dedup (snd (dedup seen0 current_history)) prev_history)
  in
  all_candidates
  |> List.filter (fun msg -> query <> "" && String_util.contains_all_tokens_ci msg query)
  |> List.rev
  |> take limit
;;

(* --- Unified keeper_memory_search dispatch --- *)

let keeper_memory_search_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
      ~(args : Yojson.Safe.t)
  =
  let query = Safe_ops.json_string ~default:"" "query" args |> String.trim in
  let limit = max 1 (min 10 (Safe_ops.json_int ~default:5 "limit" args)) in
  (* [Safe_ops.json_string] returns its default for an absent key and for a key
     whose value is not a string, so {"source": ["memory"]} used to reach Memory
     while the merely misspelled {"source": "memry"} was refused below. Read the
     member so a non-string lands on the same rejection a bad string does; the
     schema documents "memory" as the default for absence only. *)
  let source_member = Safe_ops.safe_member "source" args in
  let source_raw =
    match source_member with
    | `Null -> memory_search_source_to_string Memory
    | `String raw -> raw
    | other -> Yojson.Safe.to_string other
  in
  let parsed_source =
    match source_member with
    | `Null -> Some Memory
    | `String raw -> memory_search_source_of_string_opt raw
    | _ -> None
  in
  match parsed_source with
  | None ->
    Keeper_tool_execution.failure
      ~class_:Tool_result.Policy_rejection
      (error_json
         ~fields:
           [ "error_kind", `String "invalid_memory_search_source"
           ; "provided_source", `String source_raw
           ; ( "supported_sources"
             , `List (List.map (fun s -> `String s) valid_memory_search_source_strings) )
           ]
         "invalid keeper_memory_search source")
  | Some source ->
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    let source_label = memory_search_source_to_string source in
    let result =
    match source with
    | History ->
      let matches = search_history ~config ~meta ~ctx_work ~query ~limit in
      let no_match = matches = [] in
      let match_jsons = List.map (fun msg -> `String msg) matches in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "match_count", `Int (List.length matches)
         ; "matches", `List match_jsons
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
    | All ->
      let fact_matches, fact_total =
        search_durable_facts ~config ~keepers_dir ~meta ~query ~limit
      in
      let history_limit = max 0 (limit - List.length fact_matches) in
      let history_matches =
        if history_limit > 0
        then search_history ~config ~meta ~ctx_work ~query ~limit:history_limit
        else []
      in
      let total_matches = List.length fact_matches + List.length history_matches in
      let no_match = total_matches = 0 in
      let fact_jsons = List.map fact_match_to_json fact_matches in
      let history_jsons =
        List.map
          (fun msg ->
             `Assoc
               [ "source", `String (memory_search_source_to_string History)
               ; "text", `String msg
               ])
          history_matches
      in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int fact_total
         ; "match_count", `Int total_matches
         ; "matches", `List (fact_jsons @ history_jsons)
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
    | Memory ->
      let matches, total_candidates =
        search_durable_facts ~config ~keepers_dir ~meta ~query ~limit
      in
      let no_match = matches = [] in
      let match_jsons = List.map fact_match_to_json matches in
      `Assoc
        ([ "query", `String query
         ; "source", `String source_label
         ; "total_candidates", `Int total_candidates
         ; "match_count", `Int (List.length matches)
         ; "matches", `List match_jsons
         ]
         @ if no_match then [ "no_match", `Bool true ] else [])
  in
  (* Day-1 search logging: append search event to decisions log. *)
  let log_match_count =
    match result with
    | `Assoc fields ->
      (match List.assoc_opt "match_count" fields with
       | Some (`Int n) -> n
       | _ -> 0)
    | _ -> 0
  in
  (try
     let log_entry =
       `Assoc
         [ "ts_unix", `Float (Time_compat.now ())
         ; "event", `String "memory_search"
         ; "query", `String query
         ; "source", `String source_label
         ; "match_count", `Int log_match_count
         ]
     in
     Keeper_types_support.append_jsonl_line
       (Keeper_types_support.keeper_decision_log_path config meta.name)
       log_entry
   with
   | Eio.Cancel.Cancelled _ as e -> raise e
   | exn ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string DecisionAuditFlushFailures)
       ~labels:[ "keeper", meta.name ]
       ();
     Log.Keeper.warn ~keeper_name:meta.name
       "memory_search decision-log append failed: %s"
       (Printexc.to_string exn));
  Keeper_tool_execution.success (Yojson.Safe.to_string result)
;;

let keeper_memory_search_json ~config ~meta ~ctx_work ~args =
  (keeper_memory_search_with_outcome ~config ~meta ~ctx_work ~args).raw_output
;;

let keeper_context_status_json
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
  =
  let checkpoint_bytes = Keeper_context_runtime.serialized_bytes ctx_work in
  let keepers_dir =
    Config_dir_resolver.keepers_dir_for_base_path
      ~base_path:config.Workspace.base_path
  in
  let memory_facts_total =
    read_current_facts ~keepers_dir ~keeper_id:meta.name |> List.length
  in
  let source_memory_facts_total, source_memory_invalidations_total =
    match
      Keeper_memory_source_current.revalidate
        ~config
        ~meta
        ~keepers_dir
        ~now:(Time_compat.now ())
        ()
    with
    | Ok projection -> List.length projection.facts, List.length projection.invalidations
    | Error detail ->
      Log.Keeper.warn
        ~keeper_name:meta.name
        "source-bound memory status unavailable: %s"
        detail;
      0, 0
  in
  (* Give the keeper sandbox-relative paths from the SSOT so it never needs
     to interpolate host storage paths such as ".masc/playground/<name>/". *)
  let sandbox = Keeper_sandbox.of_meta ~config ~meta in
  let sandbox_live =
    Keeper_sandbox_control.live_status_json
      ~include_preflight:true
      ~config
      ~meta
      ~timeout_sec:(Env_config_sandbox.Shell_timeout.timeout_sec ~bucket:Io ())
      ~verbose:false
      ()
  in
  Yojson.Safe.to_string
    (`Assoc
        ([ "name", `String meta.name
         ; "trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         ; "checkpoint_bytes", `Int checkpoint_bytes
         ; "message_count", `Int (List.length (messages_of_context ctx_work))
         ]
         @ Keeper_sandbox.context_status_fields sandbox
         @ [ "sandbox_live", sandbox_live
           ; "memory_facts_total", `Int memory_facts_total
           ; "source_memory_facts_total", `Int source_memory_facts_total
           ; ( "source_memory_invalidations_total"
             , `Int source_memory_invalidations_total )
           ]))
;;

(* --- Explicit memory write surface ------------------------------- *)

let keeper_memory_write_max_title_chars = 120

(* Upper bound on the composed [**title** content] body. A durable fact is a
   claim, not a document; the bound matches the cap the retired bank enforced
   so existing producers see the same boundary. *)
let keeper_memory_write_max_body_chars = 4096
let keeper_memory_write_max_source_path_chars = 4096

(** Pure validation result for a [keeper_memory_write] call. Splitting
    this from the persistence step lets tests pin the error_kind
    taxonomy without constructing a [Workspace.config]. *)
type memory_write_error_kind =
  | Title_too_long
  | Content_empty
  | Content_too_long
  | Source_path_invalid
  | Source_path_too_long
  | Source_read_failed
  | Persistence_failed
  | No_memory_write_error

let memory_write_error_kind_to_string = function
  | Title_too_long -> "title_too_long"
  | Content_empty -> "content_empty"
  | Content_too_long -> "content_too_long"
  | Source_path_invalid -> "source_path_invalid"
  | Source_path_too_long -> "source_path_too_long"
  | Source_read_failed -> "source_read_failed"
  | Persistence_failed -> "persistence_failed"
  | No_memory_write_error -> ""
;;

type memory_write_validation =
  | Memory_write_ok of
      { body : string
      ; source_path : string option
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

let validate_memory_write_args (args : Yojson.Safe.t) : memory_write_validation =
  let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
  let content = Safe_ops.json_string ~default:"" "content" args |> String.trim in
  let source_path =
    match Safe_ops.safe_member "source_path" args with
    | `Null -> Ok None
    | `String raw ->
      let path = String.trim raw in
      if
        String.equal path ""
        || String.contains path '\n'
        || String.contains path '\r'
      then Error Source_path_invalid
      else if String.length path > keeper_memory_write_max_source_path_chars
      then Error Source_path_too_long
      else Ok (Some path)
    | _ -> Error Source_path_invalid
  in
  if String.length title > keeper_memory_write_max_title_chars
  then
    Memory_write_invalid
      { error_kind = Title_too_long
      ; extras =
          [ "max_chars", `Int keeper_memory_write_max_title_chars
          ]
      }
  else
    match source_path with
    | Error error_kind ->
      Memory_write_invalid
        { error_kind
        ; extras =
            (match error_kind with
             | Source_path_too_long ->
               [ "max_chars", `Int keeper_memory_write_max_source_path_chars ]
             | _ -> [])
        }
    | Ok source_path ->
      if content = ""
      then Memory_write_invalid { error_kind = Content_empty; extras = [] }
      else
        let body =
          if title = "" then content else Printf.sprintf "**%s** %s" title content
        in
        if String.length body > keeper_memory_write_max_body_chars
        then
          Memory_write_invalid
            { error_kind = Content_too_long
            ; extras = [ "max_chars", `Int keeper_memory_write_max_body_chars ]
            }
        else Memory_write_ok { body; source_path }
;;

(* An explicit write is a claim a later turn reads back; the current Memory OS
   snapshot is the only store it reaches.

   No local importance, recency, or echo heuristic participates. The explicit
   write upserts one exact identity; the Librarian remains responsible for
   deciding the complete current selection on its next pass. *)
let upsert_explicit_fact
      ~(keepers_dir : string)
      ~(meta : keeper_meta)
      ~(body : string)
  : (Keeper_memory_os_current.t, string) result
  =
  let keeper_id = meta.name in
  let now = Time_compat.now () in
  let fact : Keeper_memory_os_types.fact =
    { claim = body
    ; category = Keeper_memory_os_types.Fact
    ; first_seen = now
    }
  in
  let result =
    Keeper_memory_os_current.upsert_fact
      ~keepers_dir
      ~keeper_id
      ~now
      ~source:
        { kind = Keeper_memory_os_current.Explicit_write
        ; trace_id = Keeper_id.Trace_id.to_string meta.runtime.trace_id
        }
      fact
  in
  (match result with
   | Ok _ ->
     Otel_metric_store.inc_counter
       Keeper_metrics.(to_string MemoryOsExplicitFactWrite)
       ~labels:[ "keeper", keeper_id ]
       ()
   | Error _ -> ());
  result
;;

let keeper_memory_write_with_outcome
      ~(config : Workspace.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : Keeper_tool_execution.t
  =
  let respond
        ?memory_revision
        ?(effect_disposition = Tool_result.Effect_outcome_unknown)
        ~ok
        ~error_kind
        extras
    =
    let error_kind = memory_write_error_kind_to_string error_kind in
    let payload =
      Yojson.Safe.to_string
        (`Assoc ([ "ok", `Bool ok; "error_kind", `String error_kind ] @ extras))
    in
    if ok
    then
      let completed = Keeper_tool_execution.success payload in
      Option.fold
        ~none:completed
        ~some:(fun revision ->
          Keeper_tool_execution.with_memory_write_receipt ~revision completed)
        memory_revision
    else
      Keeper_tool_execution.failure
        ~class_:Tool_result.Workflow_rejection
        ~effect_disposition
        payload
  in
  match validate_memory_write_args args with
  | Memory_write_invalid { error_kind; extras } ->
    respond
      ~effect_disposition:Tool_result.Proven_pre_effect
      ~ok:false
      ~error_kind
      extras
  | Memory_write_ok { body; source_path } ->
    let keepers_dir =
      Config_dir_resolver.keepers_dir_for_base_path
        ~base_path:config.Workspace.base_path
    in
    (match source_path with
     | Some source_path ->
       (match
          Keeper_memory_source_current.upsert_file_fact
            ~config
            ~meta
            ~keepers_dir
            ~now:(Time_compat.now ())
            ~claim:body
            ~source_path
            ()
        with
        | Ok snapshot ->
          let source_sha256 =
            List.find_map
              (fun fact ->
                 if String.equal fact.Keeper_memory_source_current.source.path source_path
                 then Some fact.source.sha256
                 else None)
              snapshot.facts
            |> Option.value ~default:""
          in
          respond
            ~memory_revision:snapshot.revision
            ~ok:true
            ~error_kind:No_memory_write_error
            [ "rows_written", `Int 1
            ; "revision", `Int snapshot.revision
            ; "outcome", `String "persisted_source_bound_current"
            ; "store", `String "source_bound_current_memory"
            ; "source_path", `String source_path
            ; "source_sha256", `String source_sha256
            ]
        | Error (Keeper_memory_source_current.Source_read_failed detail) ->
          respond
            ~effect_disposition:Tool_result.Proven_pre_effect
            ~ok:false
            ~error_kind:Source_read_failed
            [ "detail", `String detail ]
        | Error (Keeper_memory_source_current.Store_write_failed detail) ->
          Log.Keeper.warn
            "explicit source-bound memory write failed keeper=%s: %s"
            meta.name
            detail;
          respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ]
        | exception (Eio.Cancel.Cancelled _ as error) -> raise error
        | exception exn ->
          let detail = Printexc.to_string exn in
          Log.Keeper.warn
            "explicit source-bound memory write failed keeper=%s: %s"
            meta.name
            detail;
          respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ])
     | None ->
    (match upsert_explicit_fact ~keepers_dir ~meta ~body with
     | Ok snapshot ->
       respond
         ~memory_revision:snapshot.revision
         ~ok:true
         ~error_kind:No_memory_write_error
         [ "rows_written", `Int 1
         ; "revision", `Int snapshot.revision
         ; "outcome", `String "persisted_current_snapshot"
         ; "store", `String "current_memory_snapshot"
         ]
     | Error detail ->
       Log.Keeper.warn
         "explicit current Memory write failed keeper=%s: %s"
         meta.name
         detail;
       respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ]
     | exception (Eio.Cancel.Cancelled _ as e) -> raise e
     | exception exn ->
       (* The store is the only place a long-term claim survives, so a
          failed write is reported as failed. Presenting it as saved would
          lose the claim silently. *)
       let detail = Printexc.to_string exn in
       Log.Keeper.warn
         "explicit current Memory write failed keeper=%s: %s"
         meta.name
         detail;
       respond ~ok:false ~error_kind:Persistence_failed [ "detail", `String detail ]))
;;
