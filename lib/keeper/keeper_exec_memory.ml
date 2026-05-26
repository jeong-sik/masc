open Keeper_types
open Keeper_exec_shared
open Keeper_exec_context


(** Memory search types, history search, bank search, and unified
    dispatch extracted to [Keeper_exec_memory_search].  Context status
    and explicit memory write below. *)

include Keeper_exec_memory_search

let keeper_context_status_json
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(ctx_work : working_context)
  =
  let progress_snapshot =
    Keeper_memory_policy.read_progress_snapshot ~config ~name:meta.name
  in
  let checkpoint_snapshot =
    Keeper_memory_policy.latest_state_snapshot_from_messages
      (messages_of_context ctx_work)
  in
  let continuity, recovery_source =
    match progress_snapshot with
    | Some snapshot -> Some snapshot, "progress_log"
    | None ->
      (match checkpoint_snapshot with
       | Some snapshot -> Some snapshot, "checkpoint"
       | None ->
         (match
            Keeper_memory_policy.state_snapshot_of_summary_text meta.continuity_summary
          with
          | Some snapshot -> Some snapshot, "meta_summary"
          | None -> None, "none"))
  in
  let continuity_summary =
    match continuity with
    | None ->
      Keeper_memory_policy.continuity_fallback_summary_text
        ~continuity_summary:meta.continuity_summary
        ~last_continuity_update_ts:meta.runtime.last_continuity_update_ts
    | Some snapshot -> Keeper_memory_policy.keeper_state_snapshot_to_summary_text snapshot
  in
  let ctx_tokens = count_context_tokens ctx_work in
  let ctx_max = Keeper_exec_context.max_tokens_of_context ctx_work in
  let ctx_ratio =
    if ctx_max = 0 then 0.0 else float_of_int ctx_tokens /. float_of_int ctx_max
  in
  (* RFC-0149 §3.1 — route through typed Result resolver so a memory
     bank IO fault surfaces as the sibling [memory_tier_error_class]
     field instead of an empty [memory_tier_summary] that is
     indistinguishable from "no recorded horizons". *)
  let memory_tier_summary, memory_tier_error_class =
    match
      Keeper_memory_recall.read_memory_horizon_counts_result
        config
        ~name:meta.name
        ~max_bytes:(128 * 1024)
        ~max_lines:300
    with
    | Ok counts ->
      let json =
        List.map (fun (horizon, count) -> horizon, `Int count) counts
      in
      json, None
    | Error exn_class ->
      [], Some (Keeper_memory_recall_exn_class.to_label exn_class)
  in
  (* Give the keeper sandbox-relative paths from the SSOT so it never needs
     to interpolate host storage paths such as ".masc/playground/<name>/". *)
  let sandbox = Keeper_sandbox.of_meta ~config ~meta in
  let playground_bundle = sandbox.root_arg in
  let playground_mind = sandbox.mind_arg in
  let playground_repos = sandbox.repos_arg in
  let sandbox_live =
    Keeper_sandbox_control.live_status_json
      ~include_preflight:true
      ~config
      ~meta
      ~timeout_sec:(Env_config_exec_timeout.timeout_sec ~caller:Memory_audit ())
      ~verbose:false
      ()
  in
  Yojson.Safe.to_string
    (`Assoc
        ([ "name", `String meta.name
         ; "trace_id", `String (Keeper_id.Trace_id.to_string meta.runtime.trace_id)
         ; "generation", `Int meta.runtime.generation
         ; "context_ratio", `Float ctx_ratio
         ; "context_tokens", `Int ctx_tokens
         ; "context_max", `Int ctx_max
         ; "message_count", `Int (List.length (messages_of_context ctx_work))
         ; "last_model_used", `Null
         ]
         @ Keeper_sandbox.context_status_fields sandbox
         @ [ "sandbox_live", sandbox_live
           ; (* Legacy aliases kept for one release. Prompts use sandbox_*.
             Values are still present for old keeper continuations. *)
             "playground_bundle", `String playground_bundle
           ; "playground_mind", `String playground_mind
           ; "playground_repos", `String playground_repos
           ; ( "tool_paths"
             , `Assoc
                 [ "mind", `String sandbox.mind_arg
                 ; "repos", `String sandbox.repos_arg
                 ; "bundle", `String sandbox.root_arg
                 ] )
           ; ( "continuity_state"
             , match continuity with
               | None -> `Null
               | Some snapshot ->
                 Keeper_memory_policy.keeper_state_snapshot_to_json snapshot )
           ; "continuity_summary", `String continuity_summary
           ; "recovery_source", `String recovery_source
           ; "memory_tier_summary", `Assoc memory_tier_summary
           ; ( "memory_tier_error_class"
             , match memory_tier_error_class with
               | Some label -> `String label
               | None -> `Null )
           ]))
;;

(* --- Memory bank search (structured notes from [STATE] blocks) --- *)

(* --- Explicit memory write (RFC-0035 P4 surface) ----------------- *)

(** Maps memory_kind enum to the corresponding [keeper_state_snapshot]
    field. Returns a snapshot with only that field populated.  Mirrors
    the field-to-kind mapping in
    [Keeper_memory_bank.memory_candidates_from_snapshot]:
      goal          -> snapshot.goal (option)
      progress      -> snapshot.progress (option)
      next          -> snapshot.next_items (list)
      decision      -> snapshot.decisions (list)
      open_question -> snapshot.open_questions (list)
      constraints   -> snapshot.constraints (list)
    [long_term] is intentionally not supported via explicit write; it is
    produced from tool-result emission only.  See RFC-0035 §3 (P4). *)
let single_field_snapshot_for_kind ~(kind : string) ~(text : string)
  : Keeper_memory_policy.keeper_state_snapshot option
  =
  let empty = Keeper_memory_policy.empty_keeper_state_snapshot in
  match kind with
  | "goal" -> Some { empty with goal = Some text }
  | "progress" -> Some { empty with progress = Some text }
  | "next" -> Some { empty with next_items = [ text ] }
  | "decision" -> Some { empty with decisions = [ text ] }
  | "open_question" -> Some { empty with open_questions = [ text ] }
  | "constraints" -> Some { empty with constraints = [ text ] }
  | _ -> None
;;

let keeper_memory_write_max_title_chars = 120

(** Pure validation result for a [keeper_memory_write] call. Splitting
    this from the persistence step lets tests pin the error_kind
    taxonomy without constructing a [Coord.config]. *)
type memory_write_error_kind =
  | Invalid_memory_kind
  | Title_too_long
  | Content_empty
  | Long_term_via_explicit_write_not_yet_supported
  | Rows_dropped_by_cap
  | No_memory_write_error

let memory_write_error_kind_to_string = function
  | Invalid_memory_kind -> "invalid_memory_kind"
  | Title_too_long -> "title_too_long"
  | Content_empty -> "content_empty"
  | Long_term_via_explicit_write_not_yet_supported ->
    "long_term_via_explicit_write_not_yet_supported"
  | Rows_dropped_by_cap -> "rows_dropped_by_cap"
  | No_memory_write_error -> ""
;;

type memory_write_validation =
  | Memory_write_ok of
      { kind : string
      ; body : string
      ; snapshot : Keeper_memory_policy.keeper_state_snapshot
      }
  | Memory_write_invalid of
      { error_kind : memory_write_error_kind
      ; extras : (string * Yojson.Safe.t) list
      }

let validate_memory_write_args (args : Yojson.Safe.t) : memory_write_validation =
  let kind = Safe_ops.json_string ~default:"" "kind" args |> String.trim in
  let title = Safe_ops.json_string ~default:"" "title" args |> String.trim in
  let content = Safe_ops.json_string ~default:"" "content" args |> String.trim in
  if not (List.mem kind Keeper_memory_policy.valid_memory_kind_strings)
  then
    Memory_write_invalid
      { error_kind = Invalid_memory_kind
      ; extras =
          [ "provided_kind", `String kind
          ; ( "supported_kinds"
            , `List
                (List.map
                   (fun k -> `String k)
                   Keeper_memory_policy.valid_memory_kind_strings) )
          ]
      }
  else if String.length title > keeper_memory_write_max_title_chars
  then
    Memory_write_invalid
      { error_kind = Title_too_long
      ; extras =
          [ "max_chars", `Int keeper_memory_write_max_title_chars
          ; "title_chars", `Int (String.length title)
          ]
      }
  else if content = ""
  then Memory_write_invalid { error_kind = Content_empty; extras = [] }
  else if kind = "long_term"
  then
    Memory_write_invalid
      { error_kind = Long_term_via_explicit_write_not_yet_supported; extras = [] }
  else (
    let body = if title = "" then content else Printf.sprintf "**%s** %s" title content in
    match single_field_snapshot_for_kind ~kind ~text:body with
    | None ->
      (* Defensive — validation above should have caught this. *)
      Memory_write_invalid
        { error_kind = Invalid_memory_kind; extras = [ "provided_kind", `String kind ] }
    | Some snapshot -> Memory_write_ok { kind; body; snapshot })
;;

let keeper_memory_write_json
      ~(config : Coord.config)
      ~(meta : keeper_meta)
      ~(args : Yojson.Safe.t)
  : string
  =
  let respond ~ok ~error_kind extras =
    let error_kind = memory_write_error_kind_to_string error_kind in
    Yojson.Safe.to_string
      (`Assoc ([ "ok", `Bool ok; "error_kind", `String error_kind ] @ extras))
  in
  match validate_memory_write_args args with
  | Memory_write_invalid { error_kind; extras } ->
    respond ~ok:false ~error_kind extras
  | Memory_write_ok { kind; body = _; snapshot } ->
    let rows_written, kinds_written =
      Keeper_memory_bank.append_memory_notes_from_reply
        config
        meta
        ~snapshot
        ~turn:0
        ~reply:""
        ()
    in
    if rows_written = 0
    then
      respond
        ~ok:false
        ~error_kind:Rows_dropped_by_cap
        [ "kind", `String kind
        ; ( "hint"
          , `String
              "per-kind or total cap reached; older entries take precedence until \
               rotation lands." )
        ]
    else
      respond
        ~ok:true
        ~error_kind:No_memory_write_error
        [ "rows_written", `Int rows_written
        ; "kinds_written", `List (List.map (fun k -> `String k) kinds_written)
        ; "kind", `String kind
        ]
;;
