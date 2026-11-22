module Turn_id = Ids.Turn_id
open Result.Syntax

type compaction_anchor =
  { epoch_id : int
  ; covers_through_turn : Turn_id.t
  ; archived_epochs_through : int option
  ; active_intent : string
  ; verified_facts_and_files : (string * Turn_id.t) list
  ; decisions_made : (string * Turn_id.t) list
  ; open_threads : string list
  }

type compaction_trigger =
  | Provider_context_overflow of { provider_limit_tokens : int option }
  | Explicit_hard_limit of
      { capacity_bytes : int
      ; observed_bytes : int
      }

type canonical_turn =
  { turn_id : Turn_id.t
  ; messages : Agent_core.Types.message list
  }

type microcompaction_outcome =
  { turns : canonical_turn list
  ; externalized_count : int
  ; bytes_saved : int
  ; handles : Tool_output.artifact_ref list
  }

type projection_step =
  | Fits_verbatim of
      { anchor : compaction_anchor option
      ; retained_turns : canonical_turn list
      ; messages : Agent_core.Types.message list
      }
  | Fits_after_microcompaction of
      { anchor : compaction_anchor option
      ; retained_turns : canonical_turn list
      ; messages : Agent_core.Types.message list
      ; microcompacted : microcompaction_outcome
      }
  | Needs_compaction of
      { trigger : compaction_trigger
      ; previous_anchor : compaction_anchor option
      ; evicted_turns : canonical_turn list
      ; retained_turns : canonical_turn list
      ; microcompacted : microcompaction_outcome option
      }
  | Single_turn_exceeds_capacity of
      { capacity_bytes : int
      ; reserved_bytes : int
      ; smallest_turn_bytes : int
      }

type projected_context =
  { anchor : compaction_anchor option
  ; compacted_new_epoch : bool
  ; retained_turns : canonical_turn list
  ; evicted_turns : canonical_turn list
  ; messages : Agent_core.Types.message list
  ; microcompacted_results : int
  }

type store_error =
  | Sqlite_error of
      { operation : string
      ; detail : string
      }
  | Corrupt_record of
      { context : string
      ; detail : string
      }
  | Capacity_exceeded of
      { capacity_bytes : int
      ; reserved_bytes : int
      ; smallest_turn_bytes : int
      }

let store_error_to_string = function
  | Sqlite_error { operation; detail } ->
    Printf.sprintf "compaction sqlite error (%s): %s" operation detail
  | Corrupt_record { context; detail } ->
    Printf.sprintf "compaction corrupt record (%s): %s" context detail
  | Capacity_exceeded { capacity_bytes; reserved_bytes; smallest_turn_bytes } ->
    Printf.sprintf
      "compaction capacity exceeded (capacity=%d reserved=%d smallest_turn=%d)"
      capacity_bytes
      reserved_bytes
      smallest_turn_bytes
;;

let global_on_epoch_committed
    : (keepers_dir:string -> keeper_id:string -> compaction_anchor -> unit) option Atomic.t
  =
  Atomic.make None
;;

let set_on_epoch_committed cb = Atomic.set global_on_epoch_committed cb

let global_on_canonical_epoch_committed
    : (keepers_dir:string
       -> keeper_id:string
       -> anchor:compaction_anchor
       -> evicted_turns:canonical_turn list
       -> unit)
        option
        Atomic.t
  =
  Atomic.make None
;;

let set_on_canonical_epoch_committed cb = Atomic.set global_on_canonical_epoch_committed cb

let notify_global_epoch_committed ~keepers_dir ~keeper_id ~evicted_turns anchor =
  (match Atomic.get global_on_canonical_epoch_committed with
   | None -> ()
   | Some cb ->
     (try cb ~keepers_dir ~keeper_id ~anchor ~evicted_turns with
      | Eio.Cancel.Cancelled _ as exn -> raise exn
      | exn ->
        Log.Keeper.warn
          ~keeper_name:keeper_id
          "compaction canonical watermark observer failed: %s"
          (Printexc.to_string exn)));
  match Atomic.get global_on_epoch_committed with
  | None -> ()
  | Some cb ->
    (try cb ~keepers_dir ~keeper_id anchor with
     | Eio.Cancel.Cancelled _ as exn -> raise exn
     | exn ->
       Log.Keeper.warn
         ~keeper_name:keeper_id
         "compaction on_epoch_committed listener failed: %s"
         (Printexc.to_string exn))
;;

(* --- Strict JSON codecs --- *)

let pair_to_json (text, turn_id) =
  `Assoc [ "text", `String text; "turn_id", Turn_id.to_yojson turn_id ]
;;

let pair_of_json = function
  | `Assoc fields ->
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) fields in
    (match sorted with
     | [ "text", `String text; "turn_id", tid_json ] ->
       let* tid = Turn_id.of_yojson tid_json in
       Ok (text, tid)
     | _ -> Error "expected exact pair fields text and turn_id")
  | _ -> Error "expected JSON object for anchored entry"
;;

let anchor_to_json (a : compaction_anchor) =
  `Assoc
    [ "epoch_id", `Int a.epoch_id
    ; "covers_through_turn", Turn_id.to_yojson a.covers_through_turn
    ; ( "archived_epochs_through"
      , match a.archived_epochs_through with
        | None -> `Null
        | Some n -> `Int n )
    ; "active_intent", `String a.active_intent
    ; "verified_facts_and_files", `List (List.map pair_to_json a.verified_facts_and_files)
    ; "decisions_made", `List (List.map pair_to_json a.decisions_made)
    ; "open_threads", `List (List.map (fun s -> `String s) a.open_threads)
    ]
;;

let decode_list f items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
      let* decoded = f item in
      loop (decoded :: acc) rest
  in
  loop [] items
;;

let anchor_of_json = function
  | `Assoc fields ->
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) fields in
    (match sorted with
     | [ "active_intent", `String active_intent
       ; "archived_epochs_through", archived_json
       ; "covers_through_turn", covers_json
       ; "decisions_made", `List decisions_json
       ; "epoch_id", `Int epoch_id
       ; "open_threads", `List threads_json
       ; "verified_facts_and_files", `List facts_json
       ] ->
       if epoch_id < 1
       then Error "epoch_id must be positive"
       else
         let* archived_epochs_through =
           match archived_json with
           | `Null -> Ok None
           | `Int n when n >= 1 && n <= epoch_id -> Ok (Some n)
           | `Int _ -> Error "archived_epochs_through out of range"
           | _ -> Error "archived_epochs_through must be integer or null"
         in
         let* covers_through_turn = Turn_id.of_yojson covers_json in
         let* verified_facts_and_files = decode_list pair_of_json facts_json in
         let* decisions_made = decode_list pair_of_json decisions_json in
         let* open_threads =
           decode_list
             (function
               | `String s -> Ok s
               | _ -> Error "open_threads elements must be strings")
             threads_json
         in
         Ok
           { epoch_id
           ; covers_through_turn
           ; archived_epochs_through
           ; active_intent
           ; verified_facts_and_files
           ; decisions_made
           ; open_threads
           }
     | _ -> Error "compaction_anchor field set mismatch")
  | _ -> Error "expected JSON object for compaction_anchor"
;;

let trigger_to_json = function
  | Provider_context_overflow { provider_limit_tokens } ->
    `Assoc
      [ "kind", `String "provider_context_overflow"
      ; ( "provider_limit_tokens"
        , match provider_limit_tokens with
          | None -> `Null
          | Some n -> `Int n )
      ]
  | Explicit_hard_limit { capacity_bytes; observed_bytes } ->
    `Assoc
      [ "kind", `String "explicit_hard_limit"
      ; "capacity_bytes", `Int capacity_bytes
      ; "observed_bytes", `Int observed_bytes
      ]
;;

let trigger_of_json = function
  | `Assoc fields ->
    let sorted = List.sort (fun (a, _) (b, _) -> String.compare a b) fields in
    (match sorted with
     | [ "kind", `String "provider_context_overflow"; "provider_limit_tokens", `Null ] ->
       Ok (Provider_context_overflow { provider_limit_tokens = None })
     | [ "kind", `String "provider_context_overflow"; "provider_limit_tokens", `Int n ] ->
       Ok (Provider_context_overflow { provider_limit_tokens = Some n })
     | [ "capacity_bytes", `Int capacity_bytes
       ; "kind", `String "explicit_hard_limit"
       ; "observed_bytes", `Int observed_bytes
       ] ->
       Ok (Explicit_hard_limit { capacity_bytes; observed_bytes })
     | _ -> Error "unknown or malformed compaction_trigger")
  | _ -> Error "expected JSON object for compaction_trigger"
;;

(* --- Anchor rendering as pinned Agent_core message --- *)

let render_anchor_text (a : compaction_anchor) =
  let buf = Buffer.create 512 in
  (match a.archived_epochs_through with
   | None ->
     Printf.bprintf
       buf
       "[compaction anchor epoch=%d covers_through=%s]\n"
       a.epoch_id
       (Turn_id.to_string a.covers_through_turn)
   | Some through_ep ->
     Printf.bprintf
       buf
       "[compaction anchor epoch=%d covers_through=%s archived_epochs=1..%d]\n"
       a.epoch_id
       (Turn_id.to_string a.covers_through_turn)
       through_ep);
  Printf.bprintf buf "Active Intent: %s\n" a.active_intent;
  (match a.verified_facts_and_files with
   | [] -> ()
   | facts ->
     Buffer.add_string buf "Verified Facts & Files:\n";
     List.iter
       (fun (text, tid) ->
          Printf.bprintf buf "- %s [turn:%s]\n" text (Turn_id.to_string tid))
       facts);
  (match a.decisions_made with
   | [] -> ()
   | decisions ->
     Buffer.add_string buf "Decisions Made:\n";
     List.iter
       (fun (text, tid) ->
          Printf.bprintf buf "- %s [turn:%s]\n" text (Turn_id.to_string tid))
       decisions);
  (match a.open_threads with
   | [] -> ()
   | threads ->
     Buffer.add_string buf "Open Threads:\n";
     List.iter (fun thread -> Printf.bprintf buf "- %s\n" thread) threads);
  Buffer.contents buf
;;

let anchor_to_message (a : compaction_anchor) : Agent_core.Types.message =
  { origin = Llm_provider.Types.Agent_instruction
  ; role = Agent_core.Types.User
  ; content = [ Agent_core.Types.Text (render_anchor_text a) ]
  ; name = None
  ; tool_call_id = None
  ; metadata = Runtime_model_input_tail_window.compaction_anchor_metadata
  }
;;

(* --- Pure Incremental Anchored Fold --- *)

let dedup_pairs pairs =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun (text, tid) ->
       let key = text ^ "\x00" ^ Turn_id.to_string tid in
       if Hashtbl.mem seen key
       then false
       else (
         Hashtbl.add seen key ();
         true))
    pairs
;;

let dedup_strings items =
  let seen = Hashtbl.create 16 in
  List.filter
    (fun s ->
       if Hashtbl.mem seen s
       then false
       else (
         Hashtbl.add seen s ();
         true))
    items
;;

let last_turn_id = function
  | [] -> None
  | first :: rest ->
    let rec loop last = function
      | [] -> Some last.turn_id
      | x :: xs -> loop x xs
    in
    loop first rest
;;

let fold_evicted_span ?previous_anchor ~evicted_turns ~summarize () =
  match last_turn_id evicted_turns with
  | None -> Error "cannot compact an empty evicted turn span"
  | Some covers_through_turn ->
    let next_epoch =
      match previous_anchor with
      | None -> 1
      | Some prev -> prev.epoch_id + 1
    in
    let* folded = summarize ~previous:previous_anchor ~evicted:evicted_turns in
    let merged_facts =
      match previous_anchor with
      | None -> dedup_pairs folded.verified_facts_and_files
      | Some prev ->
        dedup_pairs (prev.verified_facts_and_files @ folded.verified_facts_and_files)
    in
    let merged_decisions =
      match previous_anchor with
      | None -> dedup_pairs folded.decisions_made
      | Some prev -> dedup_pairs (prev.decisions_made @ folded.decisions_made)
    in
    let merged_archived_through =
      match previous_anchor, folded.archived_epochs_through with
      | None, x -> x
      | Some prev, None -> prev.archived_epochs_through
      | Some prev, Some f ->
        (match prev.archived_epochs_through with
         | None -> Some f
         | Some p -> Some (max p f))
    in
    Ok
      { epoch_id = next_epoch
      ; covers_through_turn
      ; archived_epochs_through = merged_archived_through
      ; active_intent = folded.active_intent
      ; verified_facts_and_files = merged_facts
      ; decisions_made = merged_decisions
      ; open_threads = dedup_strings folded.open_threads
      }
;;

let first_nonblank_text (blocks : Agent_core.Types.content_block list) =
  List.find_map
    (function
      | Agent_core.Types.Text s ->
        let trimmed = String.trim s in
        if String.equal trimmed "" then None else Some trimmed
      | ToolUse _ | ToolResult _ | ToolReference _ | Thinking _
      | ReasoningDetails _ | RedactedThinking _ | Image _ | Document _ | Audio _ -> None)
    blocks
;;

let summarize_tool_use_path (input : Yojson.Safe.t) =
  match input with
  | `Assoc fields ->
    List.find_map
      (fun (k, v) ->
         match k, v with
         | ("path" | "file_path" | "target_path" | "uri"), `String s
           when not (String.equal (String.trim s) "") -> Some s
         | _ -> None)
      fields
  | _ -> None
;;

let deterministic_fold ~previous ~evicted =
  match last_turn_id evicted with
  | None -> Error "cannot compact an empty evicted turn span"
  | Some covers_through_turn ->
    let next_epoch =
      match previous with
      | None -> 1
      | Some prev -> prev.epoch_id + 1
    in
    let latest_intent =
      ref
        (match previous with
         | Some prev -> prev.active_intent
         | None -> "")
    in
    let facts_rev = ref [] in
    let decisions_rev = ref [] in
    let open_threads_rev = ref [] in
    List.iter
      (fun (turn : canonical_turn) ->
         let tid = turn.turn_id in
         List.iter
           (fun (msg : Agent_core.Types.message) ->
              match msg.role, msg.origin with
              | Agent_core.Types.User, Llm_provider.Types.Conversation ->
                (match first_nonblank_text msg.content with
                 | Some text -> latest_intent := text
                 | None -> ())
              | ( Agent_core.Types.User
                , ( Llm_provider.Types.System_context
                  | Llm_provider.Types.Historical_system_context
                  | Llm_provider.Types.Recovery_instruction
                  | Llm_provider.Types.Tool_result_followup
                  | Llm_provider.Types.Agent_instruction
                  | Llm_provider.Types.Outside_context ) )
              | Agent_core.Types.System, _ -> ()
              | Agent_core.Types.Assistant, _ ->
                List.iter
                  (function
                    | Agent_core.Types.ToolUse { name; input; _ } ->
                      let fact =
                        match summarize_tool_use_path input with
                        | Some path -> Printf.sprintf "tool:%s path=%s" name path
                        | None -> Printf.sprintf "tool:%s" name
                      in
                      facts_rev := (fact, tid) :: !facts_rev
                    | Agent_core.Types.Text s ->
                      let trimmed = String.trim s in
                      if not (String.equal trimmed "")
                      then decisions_rev := (trimmed, tid) :: !decisions_rev
                    | ToolResult _ | ToolReference _ | Thinking _
                    | ReasoningDetails _ | RedactedThinking _ | Image _
                    | Document _ | Audio _ -> ())
                  msg.content
              | Agent_core.Types.Tool, _ ->
                List.iter
                  (function
                    | Agent_core.Types.ToolResult { outcome = Agent_core.Types.Tool_failed _; tool_use_id; _ } ->
                      open_threads_rev :=
                        Printf.sprintf
                          "unresolved tool error (tool_use_id=%s, turn=%s)"
                          tool_use_id
                          (Turn_id.to_string tid)
                        :: !open_threads_rev
                    | ToolResult { outcome = Agent_core.Types.Tool_succeeded; _ }
                    | Text _ | ToolUse _ | ToolReference _ | Thinking _
                    | ReasoningDetails _ | RedactedThinking _ | Image _
                    | Document _ | Audio _ -> ())
                  msg.content)
           turn.messages)
      evicted;
    let prev_facts =
      match previous with
      | None -> []
      | Some prev -> prev.verified_facts_and_files
    in
    let prev_decisions =
      match previous with
      | None -> []
      | Some prev -> prev.decisions_made
    in
    let prev_threads =
      match previous with
      | None -> []
      | Some prev -> prev.open_threads
    in
    let prev_archived_through =
      match previous with
      | None -> None
      | Some prev -> prev.archived_epochs_through
    in
    Ok
      { epoch_id = next_epoch
      ; covers_through_turn
      ; archived_epochs_through = prev_archived_through
      ; active_intent = !latest_intent
      ; verified_facts_and_files = dedup_pairs (prev_facts @ List.rev !facts_rev)
      ; decisions_made = dedup_pairs (prev_decisions @ List.rev !decisions_rev)
      ; open_threads = dedup_strings (prev_threads @ List.rev !open_threads_rev)
      }
;;

(* --- Structural Anchor Budget & Lossless Roll-Off --- *)

let default_anchor_max_bytes = 32_768

let saturating_mul a b =
  if a <= 0 || b <= 0
  then 0
  else if a > max_int / b
  then max_int
  else a * b
;;

let anchor_budget_for_window ~capacity_bytes ~reserved_bytes =
  max 0 ((capacity_bytes - reserved_bytes) / 4)
;;

let utf8_safe_prefix s max_bytes =
  let len = String.length s in
  if max_bytes <= 0
  then ""
  else if len <= max_bytes
  then s
  else (
    let rec advance pos =
      if pos >= max_bytes
      then pos
      else (
        let d = String.get_utf_8_uchar s pos in
        let next = pos + Uchar.utf_decode_length d in
        if next > max_bytes then pos else advance next)
    in
    String.sub s 0 (advance 0))
;;

let truncate_intent_to_budget s budget =
  if String.length s <= budget
  then s
  else if budget <= 3
  then utf8_safe_prefix s budget
  else utf8_safe_prefix s (budget - 3) ^ "..."
;;

let pair_weight (text, tid) =
  String.length text + String.length (Turn_id.to_string tid) + 12
;;

let string_weight s = String.length s + 4

let mark_rolled_off (a : compaction_anchor) =
  let rolled_epoch = if a.epoch_id > 1 then a.epoch_id - 1 else max 1 a.epoch_id in
  let archived_epochs_through =
    match a.archived_epochs_through with
    | None -> Some rolled_epoch
    | Some prev -> Some (max prev rolled_epoch)
  in
  { a with archived_epochs_through }
;;

let truncate_empty_anchor_intent ~measure_message_bytes ~ceiling (a : compaction_anchor) =
  if String.equal a.active_intent ""
  then a
  else (
    let empty_intent = { a with active_intent = "" } in
    let header_bytes = measure_message_bytes (anchor_to_message empty_intent) in
    let intent_budget = max 0 (ceiling - header_bytes) in
    let truncated = truncate_intent_to_budget a.active_intent intent_budget in
    if String.equal truncated a.active_intent then a else { a with active_intent = truncated })
;;

(* O(N) precomputed drop schedule + O(log N) binary search over
   [measure_message_bytes], preserving the exact heaviest-section oldest-first
   eviction order without O(N^2) weight rescans or full buffer re-renders. *)
let bound_anchor_to_budget ~measure_message_bytes ~max_anchor_bytes (anchor : compaction_anchor) =
  let ceiling = max 0 max_anchor_bytes in
  let fits a = measure_message_bytes (anchor_to_message a) <= ceiling in
  if fits anchor
  then anchor
  else (
    let rolled = mark_rolled_off anchor in
    if fits rolled
    then rolled
    else (
      let facts_arr = Array.of_list rolled.verified_facts_and_files in
      let decisions_arr = Array.of_list rolled.decisions_made in
      let threads_arr = Array.of_list rolled.open_threads in
      let nf = Array.length facts_arr in
      let nd = Array.length decisions_arr in
      let nt = Array.length threads_arr in
      let total = nf + nd + nt in
      if total = 0
      then truncate_empty_anchor_intent ~measure_message_bytes ~ceiling rolled
      else (
        let fw = ref 0 in
        for i = 0 to nf - 1 do
          fw := !fw + pair_weight facts_arr.(i)
        done;
        let dw = ref 0 in
        for i = 0 to nd - 1 do
          dw := !dw + pair_weight decisions_arr.(i)
        done;
        let tw = ref 0 in
        for i = 0 to nt - 1 do
          tw := !tw + string_weight threads_arr.(i)
        done;
        let drop_f = Array.make (total + 1) 0 in
        let drop_d = Array.make (total + 1) 0 in
        let drop_t = Array.make (total + 1) 0 in
        let fi = ref 0 in
        let di = ref 0 in
        let ti = ref 0 in
        for step = 1 to total do
          let has_f = !fi < nf in
          let has_d = !di < nd in
          let has_t = !ti < nt in
          if has_d && !dw >= !fw && !dw >= !tw
          then (
            dw := !dw - pair_weight decisions_arr.(!di);
            incr di)
          else if has_f && !fw >= !dw && !fw >= !tw
          then (
            fw := !fw - pair_weight facts_arr.(!fi);
            incr fi)
          else if has_t
          then (
            tw := !tw - string_weight threads_arr.(!ti);
            incr ti)
          else if has_f
          then (
            fw := !fw - pair_weight facts_arr.(!fi);
            incr fi)
          else if has_d
          then (
            dw := !dw - pair_weight decisions_arr.(!di);
            incr di);
          drop_f.(step) <- !fi;
          drop_d.(step) <- !di;
          drop_t.(step) <- !ti
        done;
        let slice_list arr start len =
          if start >= len then [] else Array.to_list (Array.sub arr start (len - start))
        in
        let anchor_at step =
          { rolled with
            verified_facts_and_files = slice_list facts_arr drop_f.(step) nf
          ; decisions_made = slice_list decisions_arr drop_d.(step) nd
          ; open_threads = slice_list threads_arr drop_t.(step) nt
          }
        in
        let rec bsearch lo hi =
          if lo >= hi
          then lo
          else (
            let mid = lo + ((hi - lo) / 2) in
            if fits (anchor_at mid) then bsearch lo mid else bsearch (mid + 1) hi)
        in
        let best_step = bsearch 1 total in
        let candidate = anchor_at best_step in
        if fits candidate
        then candidate
        else truncate_empty_anchor_intent ~measure_message_bytes ~ceiling candidate)))
;;

(* --- Secret Redaction at Compaction & Microcompaction Storage Boundaries --- *)

let strip_trailing_slashes path =
  let rec loop len =
    if len > 1 && path.[len - 1] = '/' then loop (len - 1) else len
  in
  let len = loop (String.length path) in
  if len = String.length path then path else String.sub path 0 len
;;

let base_path_of_masc_subdir dir =
  let rec walk current =
    let cleaned = strip_trailing_slashes current in
    if String.equal (Filename.basename cleaned) ".masc"
    then Some (Filename.dirname cleaned)
    else (
      let parent = Filename.dirname cleaned in
      if String.equal parent cleaned then None else walk parent)
  in
  walk dir
;;

let default_redact_for_keepers_dir ~keepers_dir ~keeper_id =
  match base_path_of_masc_subdir keepers_dir with
  | Some base_path ->
    Keeper_secret_redaction.snapshot ~base_path ~keeper_name:keeper_id
  | None -> Keeper_secret_redaction.empty
;;

let resolve_redact ?redact ~keepers_dir ~keeper_id () =
  match redact with
  | Some r -> Keeper_secret_redaction.copy_for_current_domain r
  | None -> default_redact_for_keepers_dir ~keepers_dir ~keeper_id
;;

let rec redact_content_block redact (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.Text s ->
    Agent_core.Types.Text (Keeper_secret_redaction.redact_text redact s)
  | Thinking t ->
    Thinking { t with content = Keeper_secret_redaction.redact_text redact t.content }
  | RedactedThinking s ->
    RedactedThinking (Keeper_secret_redaction.redact_text redact s)
  | ToolUse tu ->
    ToolUse { tu with input = Keeper_secret_redaction.redact_json redact tu.input }
  | ToolResult tr ->
    ToolResult
      { tr with
        content = Keeper_secret_redaction.redact_text redact tr.content
      ; json = Option.map (Keeper_secret_redaction.redact_json redact) tr.json
      ; content_blocks = Option.map (List.map (redact_content_block redact)) tr.content_blocks
      }
  | (ToolReference _ | ReasoningDetails _ | Image _ | Document _ | Audio _) as unchanged ->
    unchanged
;;

let redact_message redact (msg : Agent_core.Types.message) =
  { msg with content = List.map (redact_content_block redact) msg.content }
;;

let redact_turn redact (turn : canonical_turn) =
  { turn with messages = List.map (redact_message redact) turn.messages }
;;

let redact_anchor redact (a : compaction_anchor) =
  { a with
    active_intent = Keeper_secret_redaction.redact_text redact a.active_intent
  ; verified_facts_and_files =
      List.map
        (fun (text, tid) -> Keeper_secret_redaction.redact_text redact text, tid)
        a.verified_facts_and_files
  ; decisions_made =
      List.map
        (fun (text, tid) -> Keeper_secret_redaction.redact_text redact text, tid)
        a.decisions_made
  ; open_threads = List.map (Keeper_secret_redaction.redact_text redact) a.open_threads
  }
;;

(* --- Deterministic Microcompaction --- *)

let externalize_body ?redact ~blob_store body =
  match Tool_output.decode_any_handle body with
  | Tool_output.Decoded _ | Tool_output.Invalid_marker _ -> None
  | Tool_output.Not_marker ->
    let body =
      match redact with
      | None -> body
      | Some r -> Keeper_secret_redaction.redact_text r body
    in
    let preview = Tool_blob_store.make_preview body in
    let digest = Agent_core_sha256.(digest_string body |> to_hex) in
    (match
       Tool_output.make_artifact_ref
         ~sha256:digest
         ~bytes:(String.length body)
         ~preview
         ~mime:"text/plain"
     with
     | Error _ -> None
     | Ok candidate_ref ->
       let candidate_handle =
         Tool_output.encode_structured_handle (Tool_output.Stored candidate_ref)
       in
       if String.length candidate_handle >= String.length body
       then None
       else (
         match Tool_blob_store.put_durable blob_store ~bytes:body ~mime:"text/plain" with
         | stored_ref ->
           let handle =
             Tool_output.encode_structured_handle (Tool_output.Stored stored_ref)
           in
           let saved = String.length body - String.length handle in
           if saved > 0 then Some (handle, stored_ref, saved) else None
         | exception Sys_error _ -> None))
;;

let microcompact_block ?redact ~blob_store (block : Agent_core.Types.content_block) =
  match block with
  | Agent_core.Types.ToolResult tr ->
    let content, c_refs, c_saved =
      match externalize_body ?redact ~blob_store tr.content with
      | Some (handle, ref_, saved) -> handle, [ ref_ ], saved
      | None -> tr.content, [], 0
    in
    let content_blocks, b_refs, b_saved =
      match tr.content_blocks with
      | None -> None, [], 0
      | Some blocks ->
        let rev_blocks, refs, saved =
          List.fold_left
            (fun (acc_b, acc_r, acc_s) blk ->
               match blk with
               | Agent_core.Types.Text s ->
                 (match externalize_body ?redact ~blob_store s with
                  | Some (handle, ref_, ds) ->
                    Agent_core.Types.Text handle :: acc_b, ref_ :: acc_r, acc_s + ds
                  | None -> blk :: acc_b, acc_r, acc_s)
               | ToolUse _ | ToolResult _ | ToolReference _ | Thinking _
               | ReasoningDetails _ | RedactedThinking _ | Image _
               | Document _ | Audio _ -> blk :: acc_b, acc_r, acc_s)
            ([], [], 0)
            blocks
        in
        Some (List.rev rev_blocks), List.rev refs, saved
    in
    let all_refs = c_refs @ b_refs in
    let total_saved = c_saved + b_saved in
    if all_refs = []
    then block, [], 0
    else Agent_core.Types.ToolResult { tr with content; content_blocks }, all_refs, total_saved
  | Text _ | ToolUse _ | ToolReference _ | Thinking _
  | ReasoningDetails _ | RedactedThinking _ | Image _ | Document _ | Audio _ ->
    block, [], 0
;;

let microcompact_message ?redact ~blob_store (msg : Agent_core.Types.message) =
  let rev_content, rev_refs, saved =
    List.fold_left
      (fun (acc_c, acc_r, acc_s) blk ->
         let blk', refs, ds = microcompact_block ?redact ~blob_store blk in
         blk' :: acc_c, List.rev_append refs acc_r, acc_s + ds)
      ([], [], 0)
      msg.content
  in
  if rev_refs = []
  then msg, [], 0
  else { msg with content = List.rev rev_content }, List.rev rev_refs, saved
;;

let microcompact_turns ?redact ~blob_store ~keep_recent_turns turns =
  let total = List.length turns in
  let eligible_count = max 0 (total - max 0 keep_recent_turns) in
  let rec loop idx acc_turns acc_refs acc_saved = function
    | [] ->
      let handles = List.rev acc_refs in
      { turns = List.rev acc_turns
      ; externalized_count = List.length handles
      ; bytes_saved = acc_saved
      ; handles
      }
    | turn :: rest ->
      if idx >= eligible_count
      then loop (idx + 1) (turn :: acc_turns) acc_refs acc_saved rest
      else
        let rev_msgs, refs, saved =
          List.fold_left
            (fun (m_acc, r_acc, s_acc) msg ->
               let msg', r, ds = microcompact_message ?redact ~blob_store msg in
               msg' :: m_acc, List.rev_append r r_acc, s_acc + ds)
            ([], [], 0)
            turn.messages
        in
        let turn' =
          if refs = [] then turn else { turn with messages = List.rev rev_msgs }
        in
        loop (idx + 1) (turn' :: acc_turns) (List.rev_append refs acc_refs) (acc_saved + saved) rest
  in
  loop 0 [] [] 0 turns
;;

(* --- Provider-Neutral Projection --- *)

let flatten_messages ~anchor turns =
  let body = List.concat_map (fun (t : canonical_turn) -> t.messages) turns in
  match anchor with
  | None -> body
  | Some a -> anchor_to_message a :: body
;;

let measure_turn ~measure_message_bytes (turn : canonical_turn) =
  List.fold_left (fun acc msg -> acc + measure_message_bytes msg) 0 turn.messages
;;

let split_to_fit ~measure_message_bytes ~available_bytes turns =
  let arr = Array.of_list turns in
  let n = Array.length arr in
  let sizes = Array.map (measure_turn ~measure_message_bytes) arr in
  let suffix = Array.make (n + 1) 0 in
  for i = n - 1 downto 0 do
    suffix.(i) <- suffix.(i + 1) + sizes.(i)
  done;
  let rec find_first_kept idx =
    if idx >= n then n
    else if suffix.(idx) <= available_bytes then idx
    else find_first_kept (idx + 1)
  in
  let split_idx = find_first_kept 0 in
  let evicted = Array.to_list (Array.sub arr 0 split_idx) in
  let retained = Array.to_list (Array.sub arr split_idx (n - split_idx)) in
  evicted, retained, suffix.(0), (if n > 0 then sizes.(n - 1) else 0)
;;

let project_for_provider
      ?redact
      ?blob_store
      ?(keep_recent_turns = 2)
      ~anchor
      ~measure_message_bytes
      ~capacity_bytes
      ~reserved_bytes
      turns
  =
  let window_anchor_budget = anchor_budget_for_window ~capacity_bytes ~reserved_bytes in
  let projected_anchor =
    Option.map
      (bound_anchor_to_budget ~measure_message_bytes ~max_anchor_bytes:window_anchor_budget)
      anchor
  in
  let anchor_bytes =
    match projected_anchor with
    | None -> 0
    | Some a -> measure_message_bytes (anchor_to_message a)
  in
  let available_bytes = capacity_bytes - reserved_bytes - anchor_bytes in
  let verbatim_msgs = flatten_messages ~anchor:projected_anchor turns in
  let verbatim_turn_bytes =
    List.fold_left (fun acc t -> acc + measure_turn ~measure_message_bytes t) 0 turns
  in
  if available_bytes >= verbatim_turn_bytes
  then Fits_verbatim { anchor = projected_anchor; retained_turns = turns; messages = verbatim_msgs }
  else
    let working_turns, microcompacted =
      match blob_store with
      | None -> turns, None
      | Some store ->
        let outcome = microcompact_turns ?redact ~blob_store:store ~keep_recent_turns turns in
        outcome.turns, Some outcome
    in
    let working_turn_bytes =
      List.fold_left (fun acc t -> acc + measure_turn ~measure_message_bytes t) 0 working_turns
    in
    if available_bytes >= working_turn_bytes
    then
      match microcompacted with
      | Some mc ->
        Fits_after_microcompaction
          { anchor = projected_anchor
          ; retained_turns = working_turns
          ; messages = flatten_messages ~anchor:projected_anchor working_turns
          ; microcompacted = mc
          }
      | None ->
        Fits_verbatim
          { anchor = projected_anchor
          ; retained_turns = working_turns
          ; messages = flatten_messages ~anchor:projected_anchor working_turns
          }
    else
      let evicted, retained, observed_turn_bytes, newest_bytes =
        split_to_fit ~measure_message_bytes ~available_bytes working_turns
      in
      let observed_bytes = reserved_bytes + anchor_bytes + observed_turn_bytes in
      match retained with
      | [] when working_turns <> [] ->
        (* Even the newest turn alone exceeds capacity; if multiple turns exist,
           compact all older turns so the newest turn can be retried cleanly,
           otherwise surface the explicit structural error. *)
        (match List.rev working_turns with
         | newest :: (_ :: _ as older_rev) ->
           Needs_compaction
             { trigger = Explicit_hard_limit { capacity_bytes; observed_bytes }
             ; previous_anchor = anchor
             ; evicted_turns = List.rev older_rev
             ; retained_turns = [ newest ]
             ; microcompacted
             }
         | _ ->
           Single_turn_exceeds_capacity
             { capacity_bytes; reserved_bytes; smallest_turn_bytes = newest_bytes })
      | _ ->
        Needs_compaction
          { trigger = Explicit_hard_limit { capacity_bytes; observed_bytes }
          ; previous_anchor = anchor
          ; evicted_turns = evicted
          ; retained_turns = retained
          ; microcompacted
          }
;;

(* --- Per-Keeper SQLite WAL Store (strictly off-domain via Domain_pool_ref) --- *)

let db_suffix = ".compaction.db"

let db_path ~keepers_dir ~keeper_id =
  Filename.concat keepers_dir (keeper_id ^ db_suffix)
;;

let sqlite_err db operation rc =
  Sqlite_error
    { operation
    ; detail = Printf.sprintf "%s: %s" (Sqlite3.Rc.to_string rc) (Sqlite3.errmsg db)
    }
;;

let exec_sql db operation sql =
  match Sqlite3.exec db sql with
  | rc when Sqlite3.Rc.is_success rc -> Ok ()
  | rc -> Error (sqlite_err db operation rc)
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (Sqlite_error { operation; detail })
;;

let with_stmt db operation sql f =
  match Sqlite3.prepare db sql with
  | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
    Error (Sqlite_error { operation; detail })
  | stmt ->
    Fun.protect
      ~finally:(fun () ->
        try ignore (Sqlite3.finalize stmt : Sqlite3.Rc.t) with
        | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
      (fun () ->
         try f stmt with
         | Sqlite3.Error detail | Sqlite3.SqliteError detail ->
           Error (Sqlite_error { operation; detail }))
;;

let bind_values db operation stmt values =
  let rec loop idx = function
    | [] -> Ok ()
    | v :: rest ->
      let rc = Sqlite3.bind stmt idx v in
      if Sqlite3.Rc.is_success rc then loop (idx + 1) rest
      else Error (sqlite_err db operation rc)
  in
  loop 1 values
;;

let table_exists db table_name =
  with_stmt db "check_table"
    "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1 LIMIT 1"
    (fun stmt ->
       let* () = bind_values db "bind_table_name" stmt [ Sqlite3.Data.TEXT table_name ] in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then Ok true
       else if rc = Sqlite3.Rc.DONE
       then Ok false
       else Error (sqlite_err db "check_table" rc))
;;

let schema_initialized db =
  let* has_archived = table_exists db "archived_turns" in
  if not has_archived
  then Ok false
  else table_exists db "active_microcompacted_handles"
;;

let init_schema db =
  let* () = exec_sql db "pragma_busy" "PRAGMA busy_timeout=5000;" in
  let* () = exec_sql db "pragma_fk" "PRAGMA foreign_keys=ON;" in
  let* () = exec_sql db "pragma_sync" "PRAGMA synchronous=NORMAL;" in
  let* ready = schema_initialized db in
  if ready
  then Ok ()
  else (
    let* () = exec_sql db "pragma_wal" "PRAGMA journal_mode=WAL;" in
    let* () =
      exec_sql
        db
        "create_epochs"
        "CREATE TABLE IF NOT EXISTS compaction_epochs (\
         epoch_id INTEGER PRIMARY KEY, \
         covers_through_turn TEXT NOT NULL, \
         anchor_json TEXT NOT NULL, \
         trigger_json TEXT NOT NULL, \
         evicted_turn_ids_json TEXT NOT NULL, \
         previous_epoch_id INTEGER)"
    in
    let* () =
      exec_sql
        db
        "create_archived_turns"
        "CREATE TABLE IF NOT EXISTS archived_turns (\
         turn_id TEXT PRIMARY KEY, \
         epoch_id INTEGER NOT NULL, \
         sequence_ord INTEGER NOT NULL, \
         messages_json TEXT NOT NULL, \
         FOREIGN KEY(epoch_id) REFERENCES compaction_epochs(epoch_id))"
    in
    exec_sql
      db
      "create_active_microcompacted_handles"
      "CREATE TABLE IF NOT EXISTS active_microcompacted_handles (\
       sha256 TEXT PRIMARY KEY, \
       ref_json TEXT NOT NULL)")
;;

let sqlite_companions_absent path =
  let rec check = function
    | [] -> Ok true
    | suffix :: rest ->
      (match Unix.lstat (path ^ suffix) with
       | _ -> Ok false
       | exception Unix.Unix_error (Unix.ENOENT, _, _) -> check rest
       | exception Unix.Unix_error (code, fn, arg) ->
         Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)))
  in
  check
    [ Common.sqlite_journal_suffix
    ; Common.sqlite_wal_suffix
    ; Common.sqlite_shm_suffix
    ]
;;

let ensure_dir_result dir =
  try
    Fs_compat.mkdir_p dir;
    Ok ()
  with
  | Eio.Cancel.Cancelled _ as exn -> raise exn
  | Sys_error detail -> Error (Sqlite_error { operation = "mkdir_p"; detail })
  | Unix.Unix_error (code, fn, arg) ->
    Error
      (Sqlite_error
         { operation = "mkdir_p"
         ; detail = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
         })
;;

let with_db ~create ~keepers_dir ~keeper_id f =
  let path = db_path ~keepers_dir ~keeper_id in
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    let should_open =
      if create
      then
        let* () = ensure_dir_result keepers_dir in
        Ok true
      else (
        match Unix.lstat path with
        | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
        | exception Unix.Unix_error (code, fn, arg) ->
          Error
            (Sqlite_error
               { operation = "lstat"
               ; detail = Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code)
               })
        | { Unix.st_size = 0; _ } ->
          (match sqlite_companions_absent path with
           | Ok true -> Ok false
           | Ok false ->
             Error
               (Sqlite_error
                  { operation = "db_open"
                  ; detail = "empty compaction database with present sqlite companions"
                  })
           | Error detail -> Error (Sqlite_error { operation = "lstat_companion"; detail }))
        | _ -> Ok true)
    in
    let* open_now = should_open in
    if not open_now
    then Ok None
    else (
      match
        if create
        then Sqlite3.db_open path
        else Sqlite3.db_open ~mode:`READONLY path
      with
      | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
        Error (Sqlite_error { operation = "db_open"; detail })
      | db ->
        Fun.protect
          ~finally:(fun () ->
            try ignore (Sqlite3.db_close db : bool) with
            | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
          (fun () ->
             let* () =
               if create
               then init_schema db
               else exec_sql db "pragma_busy_ro" "PRAGMA busy_timeout=5000;"
             in
             f db)))
;;

let decode_anchor_string ~context raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error (Corrupt_record { context; detail })
  | json ->
    anchor_of_json json
    |> Result.map_error (fun detail -> Corrupt_record { context; detail })
;;

let encode_messages (msgs : Agent_core.Types.message list) =
  Yojson.Safe.to_string (`List (List.map Agent_core.Checkpoint.message_to_json msgs))
;;

let decode_messages ~context raw =
  match Yojson.Safe.from_string raw with
  | exception Yojson.Json_error detail -> Error (Corrupt_record { context; detail })
  | `List items ->
    decode_list
      (fun j ->
         Agent_core.Checkpoint.message_of_json j
         |> Result.map_error (fun err ->
           Corrupt_record { context; detail = Agent_core.Error.to_string err }))
      items
  | _ -> Error (Corrupt_record { context; detail = "expected JSON array of messages" })
;;

let latest_anchor ~keepers_dir ~keeper_id =
  with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
    with_stmt
      db
      "select_latest_anchor"
      "SELECT anchor_json FROM compaction_epochs ORDER BY epoch_id DESC LIMIT 1"
      (fun stmt ->
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.ROW
         then (
           let raw = Sqlite3.column_text stmt 0 in
           let* anchor = decode_anchor_string ~context:"latest_anchor" raw in
           Ok (Some anchor))
         else if rc = Sqlite3.Rc.DONE
         then Ok None
         else Error (sqlite_err db "select_latest_anchor" rc)))
;;

let list_epochs ~keepers_dir ~keeper_id =
  let* res =
    with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
      with_stmt
        db
        "list_epochs"
        "SELECT anchor_json FROM compaction_epochs ORDER BY epoch_id ASC"
        (fun stmt ->
           let rec loop acc =
             let rc = Sqlite3.step stmt in
             if rc = Sqlite3.Rc.ROW
             then (
               let raw = Sqlite3.column_text stmt 0 in
               let* anchor = decode_anchor_string ~context:"list_epochs" raw in
               loop (anchor :: acc))
             else if rc = Sqlite3.Rc.DONE
             then Ok (Some (List.rev acc))
             else Error (sqlite_err db "list_epochs" rc)
           in
           loop []))
  in
  Ok (Option.value ~default:[] res)
;;

let load_archived_turn ~keepers_dir ~keeper_id ~turn_id =
  with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
    with_stmt
      db
      "load_archived_turn"
      "SELECT messages_json FROM archived_turns WHERE turn_id = ?1"
      (fun stmt ->
         let* () =
           bind_values db "bind_turn_id" stmt [ Sqlite3.Data.TEXT (Turn_id.to_string turn_id) ]
         in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.ROW
         then (
           let raw = Sqlite3.column_text stmt 0 in
           let* messages =
             decode_messages ~context:(Turn_id.to_string turn_id) raw
           in
           Ok (Some { turn_id; messages }))
         else if rc = Sqlite3.Rc.DONE
         then Ok None
         else Error (sqlite_err db "load_archived_turn" rc)))
;;

let load_archived_turns_for_epoch ~keepers_dir ~keeper_id ~epoch_id =
  let* res =
    with_db ~create:false ~keepers_dir ~keeper_id (fun db ->
      with_stmt
        db
        "load_archived_turns_for_epoch"
        "SELECT turn_id, messages_json FROM archived_turns WHERE epoch_id = ?1 ORDER BY sequence_ord ASC"
        (fun stmt ->
           let* () =
             bind_values db "bind_epoch_id" stmt [ Sqlite3.Data.INT (Int64.of_int epoch_id) ]
           in
           let rec loop acc =
             let rc = Sqlite3.step stmt in
             if rc = Sqlite3.Rc.ROW
             then (
               let tid = Turn_id.of_string (Sqlite3.column_text stmt 0) in
               let raw = Sqlite3.column_text stmt 1 in
               let* messages = decode_messages ~context:(Turn_id.to_string tid) raw in
               loop ({ turn_id = tid; messages } :: acc))
             else if rc = Sqlite3.Rc.DONE
             then Ok (Some (List.rev acc))
             else Error (sqlite_err db "load_archived_turns_for_epoch" rc)
           in
           loop []))
  in
  Ok (Option.value ~default:[] res)
;;

let replace_active_microcompacted_handles_in_tx db (handles : Tool_output.artifact_ref list) =
  let* () = exec_sql db "clear_active_handles" "DELETE FROM active_microcompacted_handles;" in
  match handles with
  | [] -> Ok ()
  | _ :: _ ->
    with_stmt
      db
      "insert_active_handle"
      "INSERT OR REPLACE INTO active_microcompacted_handles (sha256, ref_json) VALUES (?1, ?2)"
      (fun stmt ->
         let rec insert_all = function
           | [] -> Ok ()
           | (ref_ : Tool_output.artifact_ref) :: rest ->
             let ref_json =
               Yojson.Safe.to_string (Tool_output.normalized_artifact_ref_to_json ref_)
             in
             let* () =
               bind_values
                 db
                 "bind_active_handle"
                 stmt
                 [ Sqlite3.Data.TEXT ref_.sha256; Sqlite3.Data.TEXT ref_json ]
             in
             let rc = Sqlite3.step stmt in
             if rc = Sqlite3.Rc.DONE
             then (
               let rc = Sqlite3.reset stmt in
               if Sqlite3.Rc.is_success rc
               then insert_all rest
               else Error (sqlite_err db "reset_active_handle" rc))
             else Error (sqlite_err db "insert_active_handle" rc)
         in
         insert_all handles)
;;

let sync_active_microcompacted_handles ~keepers_dir ~keeper_id handles =
  let path = db_path ~keepers_dir ~keeper_id in
  if handles = [] && not (Sys.file_exists path)
  then Ok ()
  else
    let* _ =
      with_db ~create:true ~keepers_dir ~keeper_id (fun db ->
        let* () = exec_sql db "begin_tx" "BEGIN IMMEDIATE;" in
        let rollback () =
          ignore (exec_sql db "rollback_tx" "ROLLBACK;" : (unit, store_error) result)
        in
        let work () =
          let* () = replace_active_microcompacted_handles_in_tx db handles in
          let* () = exec_sql db "commit_tx" "COMMIT;" in
          Ok (Some ())
        in
        match work () with
        | Ok _ as ok -> ok
        | Error _ as err ->
          rollback ();
          err
        | exception exn ->
          rollback ();
          raise exn)
    in
    Ok ()
;;

(* Stream-extract ONLY live blob/media references (plus any malformed refs so
   sweep fails closed) from each SQLite JSON row and discard the full row AST
   immediately, avoiding O(entire-archive) RAM allocation. *)
let history_tool_payload_key fields =
  match List.assoc_opt "type" fields with
  | Some (`String "tool_use") -> Some "input"
  | Some (`String "tool_result") -> Some "tool_result_json"
  | _ -> None
;;

let rec extract_blob_refs_from_json ~history_media ~seen ~acc_rev (json : Yojson.Safe.t) =
  match json with
  | `String text ->
    (match Tool_output.decode_any_handle text with
     | Tool_output.Not_marker -> ()
     | Tool_output.Decoded ref_ ->
       let key = "s:" ^ ref_.sha256 ^ ":" ^ ref_.mime ^ ":" ^ text in
       if not (Hashtbl.mem seen key)
       then (
         Hashtbl.add seen key ();
         acc_rev := `String text :: !acc_rev)
     | Tool_output.Invalid_marker _ ->
       (* Preserve invalid markers so Tool_blob_maintenance still fails closed. *)
       acc_rev := `String text :: !acc_rev)
  | `Assoc fields ->
    (match Tool_output.normalized_artifact_ref_of_json json with
     | Tool_output.Decoded_normalized_artifact_ref ref_ ->
       let key = "a:" ^ ref_.sha256 ^ ":" ^ ref_.mime in
       if not (Hashtbl.mem seen key)
       then (
         Hashtbl.add seen key ();
         acc_rev := json :: !acc_rev)
     | Tool_output.Invalid_normalized_artifact_ref _ -> acc_rev := json :: !acc_rev
     | Tool_output.Not_normalized_artifact_ref ->
       let media_decoded =
         if history_media
         then Agent_core_base.History.stored_source_of_json json
         else Agent_core_base.History.Not_stored_source
       in
       (match media_decoded with
        | Agent_core_base.History.Decoded_stored_source { stored; media_type = _ } ->
          let key = "m:" ^ stored.sha256 in
          if not (Hashtbl.mem seen key)
          then (
            Hashtbl.add seen key ();
            acc_rev := json :: !acc_rev)
        | Agent_core_base.History.Invalid_stored_source _ -> acc_rev := json :: !acc_rev
        | Agent_core_base.History.Not_stored_source ->
          let skipped_media_key = if history_media then history_tool_payload_key fields else None in
          List.iter
            (fun (k, v) ->
               let child_media =
                 history_media
                 &&
                 match skipped_media_key with
                 | Some skip -> not (String.equal k skip)
                 | None -> true
               in
               extract_blob_refs_from_json ~history_media:child_media ~seen ~acc_rev v)
            fields))
  | `List items ->
    List.iter (extract_blob_refs_from_json ~history_media ~seen ~acc_rev) items
  | `Null | `Bool _ | `Int _ | `Intlit _ | `Float _ -> ()
;;

let stream_blob_refs_from_column db ~operation ~table ~sql ~seen ~acc_rev =
  let* present = table_exists db table in
  if not present
  then Ok ()
  else
    with_stmt db operation sql (fun stmt ->
      let rec loop () =
        let rc = Sqlite3.step stmt in
        if rc = Sqlite3.Rc.ROW
        then (
          let raw = Sqlite3.column_text stmt 0 in
          match Yojson.Safe.from_string raw with
          | json ->
            extract_blob_refs_from_json ~history_media:true ~seen ~acc_rev json;
            loop ()
          | exception Yojson.Json_error detail ->
            Error (Corrupt_record { context = operation; detail }))
        else if rc = Sqlite3.Rc.DONE
        then Ok ()
        else Error (sqlite_err db operation rc)
      in
      loop ())
;;

let decode_live_blob_references_json path =
  Domain_pool_ref.submit_io_or_inline ~name:__FUNCTION__ (fun () ->
    match Unix.lstat path with
    | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Ok None
    | exception Unix.Unix_error (code, fn, arg) ->
      Error (Printf.sprintf "%s(%s): %s" fn arg (Unix.error_message code))
    | { Unix.st_size = 0; _ } ->
      (match sqlite_companions_absent path with
       | Ok true -> Ok None
       | Error reason -> Error reason
       | Ok false -> Error "empty compaction database with present sqlite companions")
    | _ ->
      (match Sqlite3.db_open ~mode:`READONLY path with
       | exception (Sqlite3.Error detail | Sqlite3.SqliteError detail) ->
         Error (Printf.sprintf "compaction sqlite db_open failed: %s" detail)
       | db ->
         Fun.protect
           ~finally:(fun () ->
             try ignore (Sqlite3.db_close db : bool) with
             | Sqlite3.Error _ | Sqlite3.SqliteError _ -> ())
           (fun () ->
              let res =
                let* () = exec_sql db "pragma_busy_ro" "PRAGMA busy_timeout=5000;" in
                let* () = exec_sql db "begin_read_tx" "BEGIN DEFERRED;" in
                let rollback () =
                  ignore (exec_sql db "rollback_read_tx" "ROLLBACK;" : (unit, store_error) result)
                in
                let work () =
                  let seen = Hashtbl.create 32 in
                  let acc_rev = ref [] in
                  let* () =
                    stream_blob_refs_from_column
                      db
                      ~operation:"scan_active_handles"
                      ~table:"active_microcompacted_handles"
                      ~sql:"SELECT ref_json FROM active_microcompacted_handles ORDER BY sha256 ASC"
                      ~seen
                      ~acc_rev
                  in
                  let* () =
                    stream_blob_refs_from_column
                      db
                      ~operation:"scan_epochs"
                      ~table:"compaction_epochs"
                      ~sql:"SELECT anchor_json FROM compaction_epochs ORDER BY epoch_id ASC"
                      ~seen
                      ~acc_rev
                  in
                  let* () =
                    stream_blob_refs_from_column
                      db
                      ~operation:"scan_archived_turns"
                      ~table:"archived_turns"
                      ~sql:"SELECT messages_json FROM archived_turns ORDER BY epoch_id ASC, sequence_ord ASC"
                      ~seen
                      ~acc_rev
                  in
                  let* () = exec_sql db "commit_read_tx" "COMMIT;" in
                  match List.rev !acc_rev with
                  | [] -> Ok None
                  | non_empty -> Ok (Some (`List non_empty))
                in
                match work () with
                | Ok _ as ok -> ok
                | Error _ as err ->
                  rollback ();
                  err
                | exception exn ->
                  rollback ();
                  raise exn
              in
              Result.map_error store_error_to_string res)))
;;

let latest_anchor_in_tx db =
  with_stmt
    db
    "select_latest_anchor_tx"
    "SELECT anchor_json FROM compaction_epochs ORDER BY epoch_id DESC LIMIT 1"
    (fun stmt ->
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then (
         let raw = Sqlite3.column_text stmt 0 in
         let* anchor = decode_anchor_string ~context:"latest_anchor" raw in
         Ok (Some anchor))
       else if rc = Sqlite3.Rc.DONE
       then Ok None
       else Error (sqlite_err db "select_latest_anchor_tx" rc))
;;

let archived_turn_exists_in_tx db turn_id_str =
  with_stmt
    db
    "check_archived_turn_exists"
    "SELECT 1 FROM archived_turns WHERE turn_id = ?1 LIMIT 1"
    (fun stmt ->
       let* () = bind_values db "bind_check_turn_id" stmt [ Sqlite3.Data.TEXT turn_id_str ] in
       let rc = Sqlite3.step stmt in
       if rc = Sqlite3.Rc.ROW
       then Ok true
       else if rc = Sqlite3.Rc.DONE
       then Ok false
       else Error (sqlite_err db "check_archived_turn_exists" rc))
;;

let disambiguate_turns_in_tx db ~next_epoch turns =
  let used_in_batch = Hashtbl.create (max 4 (List.length turns)) in
  let rec find_unique_id base idx attempt =
    let candidate =
      if attempt = 0
      then base
      else if attempt = 1
      then Printf.sprintf "%s-ep%d-%d" base next_epoch idx
      else Printf.sprintf "%s-ep%d-%d-%d" base next_epoch idx attempt
    in
    if Hashtbl.mem used_in_batch candidate
    then find_unique_id base idx (attempt + 1)
    else
      let* exists = archived_turn_exists_in_tx db candidate in
      if exists
      then find_unique_id base idx (attempt + 1)
      else (
        Hashtbl.add used_in_batch candidate ();
        Ok (Turn_id.of_string candidate))
  in
  let rec loop idx acc = function
    | [] -> Ok (List.rev acc)
    | (turn : canonical_turn) :: rest ->
      let* unique_id = find_unique_id (Turn_id.to_string turn.turn_id) idx 0 in
      loop (idx + 1) ({ turn with turn_id = unique_id } :: acc) rest
  in
  loop 0 [] turns
;;

let insert_epoch_and_turns_in_tx db ~active_handles ~trigger ~anchor ~evicted_turns =
  let evicted_ids_json =
    Yojson.Safe.to_string
      (`List (List.map (fun t -> Turn_id.to_yojson t.turn_id) evicted_turns))
  in
  let prev_epoch_data =
    if anchor.epoch_id > 1
    then Sqlite3.Data.INT (Int64.of_int (anchor.epoch_id - 1))
    else Sqlite3.Data.NULL
  in
  let* () =
    with_stmt
      db
      "insert_epoch"
      "INSERT INTO compaction_epochs \
       (epoch_id, covers_through_turn, anchor_json, trigger_json, evicted_turn_ids_json, previous_epoch_id) \
       VALUES (?1, ?2, ?3, ?4, ?5, ?6)"
      (fun stmt ->
         let* () =
           bind_values
             db
             "bind_epoch"
             stmt
             [ Sqlite3.Data.INT (Int64.of_int anchor.epoch_id)
             ; Sqlite3.Data.TEXT (Turn_id.to_string anchor.covers_through_turn)
             ; Sqlite3.Data.TEXT (Yojson.Safe.to_string (anchor_to_json anchor))
             ; Sqlite3.Data.TEXT (Yojson.Safe.to_string (trigger_to_json trigger))
             ; Sqlite3.Data.TEXT evicted_ids_json
             ; prev_epoch_data
             ]
         in
         let rc = Sqlite3.step stmt in
         if rc = Sqlite3.Rc.DONE
         then Ok ()
         else Error (sqlite_err db "insert_epoch" rc))
  in
  let* () =
    with_stmt
      db
      "insert_archived_turn"
      "INSERT INTO archived_turns (turn_id, epoch_id, sequence_ord, messages_json) \
       VALUES (?1, ?2, ?3, ?4)"
      (fun stmt ->
         let rec insert_all idx = function
           | [] -> Ok ()
           | (turn : canonical_turn) :: rest ->
             let* () =
               bind_values
                 db
                 "bind_archived_turn"
                 stmt
                 [ Sqlite3.Data.TEXT (Turn_id.to_string turn.turn_id)
                 ; Sqlite3.Data.INT (Int64.of_int anchor.epoch_id)
                 ; Sqlite3.Data.INT (Int64.of_int idx)
                 ; Sqlite3.Data.TEXT (encode_messages turn.messages)
                 ]
             in
             let rc = Sqlite3.step stmt in
             if rc = Sqlite3.Rc.DONE
             then (
               let rc = Sqlite3.reset stmt in
               if Sqlite3.Rc.is_success rc
               then insert_all (idx + 1) rest
               else Error (sqlite_err db "reset_archived_turn" rc))
             else Error (sqlite_err db "insert_archived_turn" rc)
         in
         insert_all 0 evicted_turns)
  in
  match active_handles with
  | None -> Ok ()
  | Some handles -> replace_active_microcompacted_handles_in_tx db handles
;;

let remap_anchor_for_disambiguated_turns
      ~(original_evicted : canonical_turn list)
      ~(disambiguated_evicted : canonical_turn list)
      (anchor : compaction_anchor)
  =
  let remap : (string, Turn_id.t) Hashtbl.t = Hashtbl.create 4 in
  List.iter2
    (fun (orig : canonical_turn) (disamb : canonical_turn) ->
       let old_s = Turn_id.to_string orig.turn_id in
       let new_s = Turn_id.to_string disamb.turn_id in
       if not (String.equal old_s new_s)
       then Hashtbl.replace remap old_s disamb.turn_id)
    original_evicted
    disambiguated_evicted;
  if Hashtbl.length remap = 0
  then anchor
  else (
    let map_id tid =
      match Hashtbl.find_opt remap (Turn_id.to_string tid) with
      | Some mapped -> mapped
      | None -> tid
    in
    { anchor with
      covers_through_turn = map_id anchor.covers_through_turn
    ; verified_facts_and_files =
        List.map (fun (text, tid) -> text, map_id tid) anchor.verified_facts_and_files
    ; decisions_made =
        List.map (fun (text, tid) -> text, map_id tid) anchor.decisions_made
    })
;;

let commit_epoch_with_handles_full
      ~rebound
      ~redact
      ~active_handles
      ~keepers_dir
      ~keeper_id
      ~trigger
      ~anchor
      ~evicted_turns
  =
  let* res =
    with_db ~create:true ~keepers_dir ~keeper_id (fun db ->
      let effective_redact = resolve_redact ?redact ~keepers_dir ~keeper_id () in
      let redacted_anchor = redact_anchor effective_redact anchor in
      let redacted_evicted = List.map (redact_turn effective_redact) evicted_turns in
      let* () = exec_sql db "begin_tx" "BEGIN IMMEDIATE;" in
      let rollback () = ignore (exec_sql db "rollback_tx" "ROLLBACK;" : (unit, store_error) result) in
      let work () =
        let* disambiguated_evicted =
          disambiguate_turns_in_tx db ~next_epoch:redacted_anchor.epoch_id redacted_evicted
        in
        let remapped_anchor =
          remap_anchor_for_disambiguated_turns
            ~original_evicted:redacted_evicted
            ~disambiguated_evicted
            redacted_anchor
        in
        let final_anchor =
          match rebound with
          | None -> remapped_anchor
          | Some bound_fn -> bound_fn remapped_anchor
        in
        let* () =
          insert_epoch_and_turns_in_tx
            db
            ~active_handles
            ~trigger
            ~anchor:final_anchor
            ~evicted_turns:disambiguated_evicted
        in
        let* () = exec_sql db "commit_tx" "COMMIT;" in
        Ok (Some (final_anchor, disambiguated_evicted))
      in
      match work () with
      | Ok _ as ok -> ok
      | Error _ as err ->
        rollback ();
        err
      | exception exn ->
        rollback ();
        raise exn)
  in
  match res with
  | Some (committed, committed_evicted) ->
    notify_global_epoch_committed ~keepers_dir ~keeper_id ~evicted_turns:committed_evicted committed;
    Ok (committed, committed_evicted)
  | None ->
    Error
      (Sqlite_error
         { operation = "commit_epoch"; detail = "unexpected empty database result" })
;;

let commit_epoch_with_handles
      ~redact
      ~active_handles
      ~keepers_dir
      ~keeper_id
      ~trigger
      ~anchor
      ~evicted_turns
  =
  let* committed, (_ : canonical_turn list) =
    commit_epoch_with_handles_full
      ~rebound:None
      ~redact
      ~active_handles
      ~keepers_dir
      ~keeper_id
      ~trigger
      ~anchor
      ~evicted_turns
  in
  Ok committed
;;

let commit_epoch ~keepers_dir ~keeper_id ~trigger ~anchor ~evicted_turns =
  commit_epoch_with_handles
    ~redact:None
    ~active_handles:None
    ~keepers_dir
    ~keeper_id
    ~trigger
    ~anchor
    ~evicted_turns
;;

let structured_handles_in_turns (turns : canonical_turn list) =
  let seen = Hashtbl.create 16 in
  let acc = ref [] in
  let add_if_structured text =
    match Tool_output.decode_structured_handle text with
    | Tool_output.Decoded ref_ ->
      if not (Hashtbl.mem seen ref_.sha256)
      then (
        Hashtbl.add seen ref_.sha256 ();
        acc := ref_ :: !acc)
    | Tool_output.Not_marker | Tool_output.Invalid_marker _ -> ()
  in
  List.iter
    (fun (turn : canonical_turn) ->
       List.iter
         (fun (msg : Agent_core.Types.message) ->
            List.iter
              (function
                | Agent_core.Types.ToolResult { content; content_blocks; _ } ->
                  add_if_structured content;
                  Option.iter
                    (List.iter (function
                       | Agent_core.Types.Text s -> add_if_structured s
                       | ToolUse _ | ToolResult _ | ToolReference _ | Thinking _
                       | ReasoningDetails _ | RedactedThinking _ | Image _
                       | Document _ | Audio _ -> ()))
                    content_blocks
                | Text _ | ToolUse _ | ToolReference _ | Thinking _
                | ReasoningDetails _ | RedactedThinking _ | Image _
                | Document _ | Audio _ -> ())
              msg.content)
         turn.messages)
    turns;
  List.rev !acc
;;

(* --- End-to-End Compaction + Projection --- *)

let compact_and_project
      ?redact
      ?blob_store
      ?(keep_recent_turns = 2)
      ?force_trigger
      ?(summarize = deterministic_fold)
      ?on_epoch_committed
      ~keepers_dir
      ~keeper_id
      ~measure_message_bytes
      ~capacity_bytes
      ~reserved_bytes
      turns
  =
  let effective_redact = resolve_redact ?redact ~keepers_dir ~keeper_id () in
  let* existing_anchor = latest_anchor ~keepers_dir ~keeper_id in
  let step =
    project_for_provider
      ~redact:effective_redact
      ?blob_store
      ~keep_recent_turns
      ~anchor:existing_anchor
      ~measure_message_bytes
      ~capacity_bytes
      ~reserved_bytes
      turns
  in
  let raw_turn_by_id =
    let tbl = Hashtbl.create (max 4 (List.length turns)) in
    List.iter
      (fun (t : canonical_turn) -> Hashtbl.replace tbl (Turn_id.to_string t.turn_id) t)
      turns;
    tbl
  in
  let raw_evicted_of evicted_turns =
    List.map
      (fun (t : canonical_turn) ->
         Option.value ~default:t (Hashtbl.find_opt raw_turn_by_id (Turn_id.to_string t.turn_id)))
      evicted_turns
  in
  let run_compaction
        ~enforce_capacity
        ~trigger
        ~previous_anchor
        ~evicted_turns
        ~retained_turns
        ~microcompacted
    =
    (* Always archive and fold the raw pre-microcompaction turns so archived
       history is 100% self-contained verbatim content and can never dangle on
       externalized Tool_blob_store files if a blob sweep deletes them later. *)
    let raw_evicted_turns = raw_evicted_of evicted_turns in
    let redacted_evicted = List.map (redact_turn effective_redact) raw_evicted_turns in
    let* raw_anchor =
      fold_evicted_span ?previous_anchor ~evicted_turns:redacted_evicted ~summarize ()
      |> Result.map_error (fun detail ->
        Corrupt_record { context = "fold_evicted_span"; detail })
    in
    let redacted_anchor = redact_anchor effective_redact raw_anchor in
    let retained_bytes =
      List.fold_left (fun acc t -> acc + measure_turn ~measure_message_bytes t) 0 retained_turns
    in
    let window_budget = anchor_budget_for_window ~capacity_bytes ~reserved_bytes in
    let max_anchor_bytes =
      if enforce_capacity
      then min window_budget (max 0 (capacity_bytes - reserved_bytes - retained_bytes))
      else window_budget
    in
    let new_anchor =
      bound_anchor_to_budget ~measure_message_bytes ~max_anchor_bytes redacted_anchor
    in
    let projected_messages = flatten_messages ~anchor:(Some new_anchor) retained_turns in
    let projected_bytes =
      List.fold_left (fun acc msg -> acc + measure_message_bytes msg) 0 projected_messages
    in
    if enforce_capacity && reserved_bytes + projected_bytes > capacity_bytes
    then
      Error
        (Capacity_exceeded
           { capacity_bytes
           ; reserved_bytes
           ; smallest_turn_bytes = projected_bytes
           })
    else (
      let retained_handles = structured_handles_in_turns retained_turns in
      let* committed, committed_evicted =
        commit_epoch_with_handles_full
          ~rebound:(Some (bound_anchor_to_budget ~measure_message_bytes ~max_anchor_bytes))
          ~redact:(Some effective_redact)
          ~active_handles:(Some retained_handles)
          ~keepers_dir
          ~keeper_id
          ~trigger
          ~anchor:new_anchor
          ~evicted_turns:redacted_evicted
      in
      let final_messages = flatten_messages ~anchor:(Some committed) retained_turns in
      Option.iter (fun cb -> cb committed) on_epoch_committed;
      let mc_count =
        match microcompacted with
        | None -> 0
        | Some mc -> mc.externalized_count
      in
      Ok
        { anchor = Some committed
        ; compacted_new_epoch = true
        ; retained_turns
        ; evicted_turns = committed_evicted
        ; messages = final_messages
        ; microcompacted_results = mc_count
        })
  in
  match force_trigger, step with
  | None, Fits_verbatim { anchor; retained_turns; messages } ->
    let* () = sync_active_microcompacted_handles ~keepers_dir ~keeper_id [] in
    Ok
      { anchor
      ; compacted_new_epoch = false
      ; retained_turns
      ; evicted_turns = []
      ; messages
      ; microcompacted_results = 0
      }
  | None, Fits_after_microcompaction { anchor; retained_turns; messages; microcompacted } ->
    let* () = sync_active_microcompacted_handles ~keepers_dir ~keeper_id microcompacted.handles in
    Ok
      { anchor
      ; compacted_new_epoch = false
      ; retained_turns
      ; evicted_turns = []
      ; messages
      ; microcompacted_results = microcompacted.externalized_count
      }
  | ( Some trigger
    , ( Fits_verbatim { anchor; retained_turns; _ }
      | Fits_after_microcompaction { anchor; retained_turns; _ } ) ) ->
    (* Explicit Provider_context_overflow when local estimate still fit:
       fold the oldest half of retained turns while keeping at least the newest
       turn verbatim. *)
    let n = List.length retained_turns in
    if n <= 1
    then
      Ok
        { anchor
        ; compacted_new_epoch = false
        ; retained_turns
        ; evicted_turns = []
        ; messages = flatten_messages ~anchor retained_turns
        ; microcompacted_results = 0
        }
    else
      let evict_count = max 1 (n / 2) in
      let evicted_turns = List.take evict_count retained_turns in
      let kept_turns = List.drop evict_count retained_turns in
      run_compaction
        ~enforce_capacity:false
        ~trigger
        ~previous_anchor:anchor
        ~evicted_turns
        ~retained_turns:kept_turns
        ~microcompacted:None
  | ( _
    , Needs_compaction
        { trigger; previous_anchor; evicted_turns; retained_turns; microcompacted } ) ->
    let effective_trigger = Option.value ~default:trigger force_trigger in
    run_compaction
      ~enforce_capacity:(Option.is_none force_trigger)
      ~trigger:effective_trigger
      ~previous_anchor
      ~evicted_turns
      ~retained_turns
      ~microcompacted
  | _, Single_turn_exceeds_capacity { capacity_bytes; reserved_bytes; smallest_turn_bytes } ->
    Error
      (Capacity_exceeded
         { capacity_bytes
         ; reserved_bytes
         ; smallest_turn_bytes
         })
;;

let canonical_turns_of_evicted_messages (messages : Agent_core.Types.message list) =
  let labelled, _ = Runtime_model_input_tail_window.annotate messages in
  let tbl : (int, Agent_core.Types.message list) Hashtbl.t = Hashtbl.create 16 in
  let order = ref [] in
  List.iter
    (fun (msg, label) ->
       match label with
       | Runtime_model_input_tail_window.Pinned -> ()
       | Runtime_model_input_tail_window.Atom idx ->
         if not (Hashtbl.mem tbl idx) then order := idx :: !order;
         let prev = Option.value ~default:[] (Hashtbl.find_opt tbl idx) in
         Hashtbl.replace tbl idx (msg :: prev))
    labelled;
  List.rev !order
  |> List.map (fun idx ->
    let msgs = Option.value ~default:[] (Hashtbl.find_opt tbl idx) |> List.rev in
    (* Hash the FULL atom messages rather than only the opener so distinct turns
       that share an identical opener like "Continue." never collide on the same
       [turn_id] in [archived_turns]. *)
    let full_hex = Agent_core_sha256.(digest_string (encode_messages msgs) |> to_hex) in
    let turn_id =
      if String.length full_hex >= 16
      then Turn_id.of_string (Printf.sprintf "atom-%d-%s" idx (String.sub full_hex 0 16))
      else Turn_id.of_string (Printf.sprintf "atom-%d-%s" idx full_hex)
    in
    { turn_id; messages = msgs })
;;

let drop_covered_turns ~(previous_anchor : compaction_anchor option) turns =
  match previous_anchor with
  | None -> turns
  | Some prev ->
    let target = Turn_id.to_string prev.covers_through_turn in
    let rec find_after = function
      | [] -> None
      | (t : canonical_turn) :: rest ->
        if String.equal (Turn_id.to_string t.turn_id) target
        then Some rest
        else find_after rest
    in
    (match find_after turns with
     | Some remaining -> remaining
     | None -> turns)
;;

let default_anchor_message_bytes (msg : Agent_core.Types.message) =
  List.fold_left
    (fun acc -> function
      | Agent_core.Types.Text s -> acc + String.length s
      | Thinking { content; _ } -> acc + String.length content
      | RedactedThinking s -> acc + String.length s
      | ToolResult { content; _ } -> acc + String.length content
      | ToolUse { name; input; _ } ->
        acc + String.length name + String.length (Yojson.Safe.to_string input)
      | ToolReference { tool_name; _ } -> acc + String.length tool_name
      | ReasoningDetails _ | Image _ | Document _ | Audio _ -> acc)
    0
    msg.content
;;

let compact_evicted_messages
      ?redact
      ?blob_store:_
      ?max_anchor_bytes
      ?(measure_message_bytes = default_anchor_message_bytes)
      ?on_epoch_committed
      ~keepers_dir
      ~keeper_id
      ~trigger
      ~evicted_messages
      ()
  =
  let all_turns = canonical_turns_of_evicted_messages evicted_messages in
  match all_turns with
  | [] -> Ok None
  | _ :: _ ->
    (* Always bound the committed anchor even when the provider omits a token
       limit; convert provider token limits to bytes (tok * 4) before applying
       the structural 1/4 anchor window ratio. *)
    let effective_budget =
      match max_anchor_bytes with
      | Some n -> max 0 n
      | None ->
        (match trigger with
         | Explicit_hard_limit { capacity_bytes; _ } ->
           anchor_budget_for_window ~capacity_bytes ~reserved_bytes:0
         | Provider_context_overflow { provider_limit_tokens = Some tok } ->
           let capacity_bytes = saturating_mul (max 0 tok) 4 in
           anchor_budget_for_window ~capacity_bytes ~reserved_bytes:0
         | Provider_context_overflow { provider_limit_tokens = None } ->
           default_anchor_max_bytes)
    in
    (* Perform latest_anchor read, idempotency check, collision disambiguation,
       secret redaction, incremental fold, budget roll-off, and SQLite commit
       atomically inside ONE [BEGIN IMMEDIATE] transaction off-domain so
       concurrent callers serialize without [PRIMARY KEY] races or main-domain
       CPU stalls. *)
    let* committed_opt =
      with_db ~create:true ~keepers_dir ~keeper_id (fun db ->
        let effective_redact = resolve_redact ?redact ~keepers_dir ~keeper_id () in
        let* () = exec_sql db "begin_tx" "BEGIN IMMEDIATE;" in
        let rollback () =
          ignore (exec_sql db "rollback_tx" "ROLLBACK;" : (unit, store_error) result)
        in
        let work () =
          let* existing_anchor = latest_anchor_in_tx db in
          let newly_evicted = drop_covered_turns ~previous_anchor:existing_anchor all_turns in
          match newly_evicted with
          | [] ->
            let* () = exec_sql db "commit_noop_tx" "COMMIT;" in
            Ok None
          | _ :: _ ->
            let next_epoch =
              match existing_anchor with
              | None -> 1
              | Some prev -> prev.epoch_id + 1
            in
            let* disambiguated = disambiguate_turns_in_tx db ~next_epoch newly_evicted in
            let redacted_evicted = List.map (redact_turn effective_redact) disambiguated in
            let* raw_anchor =
              fold_evicted_span
                ?previous_anchor:existing_anchor
                ~evicted_turns:redacted_evicted
                ~summarize:deterministic_fold
                ()
              |> Result.map_error (fun detail ->
                Corrupt_record { context = "compact_evicted_messages"; detail })
            in
            let redacted_anchor = redact_anchor effective_redact raw_anchor in
            let new_anchor =
              bound_anchor_to_budget
                ~measure_message_bytes
                ~max_anchor_bytes:effective_budget
                redacted_anchor
            in
            let* () =
              insert_epoch_and_turns_in_tx
                db
                ~active_handles:None
                ~trigger
                ~anchor:new_anchor
                ~evicted_turns:redacted_evicted
            in
            let* () = exec_sql db "commit_tx" "COMMIT;" in
            Ok (Some (new_anchor, redacted_evicted))
        in
        match work () with
        | Ok _ as ok -> ok
        | Error _ as err ->
          rollback ();
          err
        | exception exn ->
          rollback ();
          raise exn)
    in
    (match committed_opt with
     | None -> Ok None
     | Some (committed, committed_evicted) ->
       notify_global_epoch_committed
         ~keepers_dir
         ~keeper_id
         ~evicted_turns:committed_evicted
         committed;
       Option.iter (fun cb -> cb committed) on_epoch_committed;
       Ok (Some committed))
;;

let turn_id_matches_target ~target (candidate : string) =
  if String.equal candidate target
  then true
  else (
    let prefix = candidate ^ "-ep" in
    let plen = String.length prefix in
    String.length target > plen
    && String.starts_with ~prefix target
    &&
    match target.[plen] with
    | '0' .. '9' -> true
    | _ -> false)
;;

let parse_atom_turn_id (turn_id : string) : (int * string) option =
  (* Strip optional [-ep<epoch>-<idx>...] disambiguation suffix before parsing
     [atom-<idx>-<hash16>]. *)
  let base =
    match String.index_opt turn_id '-' with
    | None -> turn_id
    | Some _ ->
      let len = String.length turn_id in
      let rec find_ep i =
        if i + 3 >= len
        then None
        else if
          turn_id.[i] = '-'
          && turn_id.[i + 1] = 'e'
          && turn_id.[i + 2] = 'p'
          && (match turn_id.[i + 3] with '0' .. '9' -> true | _ -> false)
        then Some i
        else find_ep (i + 1)
      in
      (match find_ep 0 with
       | Some cut -> String.sub turn_id 0 cut
       | None -> turn_id)
  in
  if not (String.starts_with ~prefix:"atom-" base)
  then None
  else (
    let rest = String.sub base 5 (String.length base - 5) in
    match String.index_opt rest '-' with
    | None -> None
    | Some dash ->
      let idx_str = String.sub rest 0 dash in
      let hash = String.sub rest (dash + 1) (String.length rest - dash - 1) in
      (match int_of_string_opt idx_str with
       | Some idx when idx >= 0 && String.length hash > 0 -> Some (idx, hash)
       | Some _ | None -> None))
;;

let messages_after_anchor ~(anchor : compaction_anchor) (messages : Agent_core.Types.message list) =
  let rec inline_tail last_after = function
    | [] -> last_after
    | msg :: rest ->
      let next_after =
        if Runtime_model_input_tail_window.is_compaction_anchor msg
        then Some rest
        else last_after
      in
      inline_tail next_after rest
  in
  match inline_tail None messages with
  | Some tail -> tail
  | None ->
    let target = Turn_id.to_string anchor.covers_through_turn in
    let labelled, _ = Runtime_model_input_tail_window.annotate messages in
    let atom_tbl : (int, Agent_core.Types.message list) Hashtbl.t = Hashtbl.create 16 in
    let atom_order = ref [] in
    List.iter
      (fun (msg, label) ->
         match label with
         | Runtime_model_input_tail_window.Pinned -> ()
         | Runtime_model_input_tail_window.Atom idx ->
           if not (Hashtbl.mem atom_tbl idx) then atom_order := idx :: !atom_order;
           let prev = Option.value ~default:[] (Hashtbl.find_opt atom_tbl idx) in
           Hashtbl.replace atom_tbl idx (msg :: prev))
      labelled;
    let atom_hash idx =
      let msgs = Option.value ~default:[] (Hashtbl.find_opt atom_tbl idx) |> List.rev in
      let full_hex = Agent_core_sha256.(digest_string (encode_messages msgs) |> to_hex) in
      let hash16 =
        if String.length full_hex >= 16 then String.sub full_hex 0 16 else full_hex
      in
      msgs, hash16
    in
    let atom_matches_exact idx =
      let msgs, hash16 = atom_hash idx in
      let atom_turn_id = Printf.sprintf "atom-%d-%s" idx hash16 in
      if turn_id_matches_target ~target atom_turn_id
      then true
      else
        List.exists
          (fun (msg : Agent_core.Types.message) ->
             match List.assoc_opt "canonical_turn_id" msg.metadata with
             | Some (`String canonical_id) -> turn_id_matches_target ~target canonical_id
             | Some _ | None -> false)
          msgs
    in
    let ordered_atoms = List.rev !atom_order in
    let exact_covered =
      List.fold_left
        (fun matched idx -> if atom_matches_exact idx then Some idx else matched)
        None
        ordered_atoms
    in
    let covered_atom =
      match exact_covered with
      | Some _ as hit -> hit
      | None ->
        (* Fallback when [compact_evicted_messages] compacted a non-prefix subset
           (so atom [idx] was re-indexed to a smaller [target_idx] inside
           [evicted_messages]): match by full-atom content hash for atoms at or
           after [target_idx]. *)
        (match parse_atom_turn_id target with
         | None -> None
         | Some (target_idx, target_hash) ->
           List.fold_left
             (fun matched idx ->
                if idx >= target_idx && String.equal (snd (atom_hash idx)) target_hash
                then Some idx
                else matched)
             None
             ordered_atoms)
    in
    (match covered_atom with
     | None -> messages
     | Some covered_idx ->
       let last_covered_pos = ref (-1) in
       List.iteri
         (fun pos (_msg, label) ->
            match label with
            | Runtime_model_input_tail_window.Atom idx when idx = covered_idx ->
              last_covered_pos := pos
            | Runtime_model_input_tail_window.Atom _
            | Runtime_model_input_tail_window.Pinned -> ())
         labelled;
       if !last_covered_pos < 0
       then messages
       else
         List.filteri (fun pos _ -> pos > !last_covered_pos) messages)
;;

let live_history_after_latest_anchor ~keepers_dir ~keeper_id messages =
  match latest_anchor ~keepers_dir ~keeper_id with
  | Ok (Some anchor) -> messages_after_anchor ~anchor messages
  | Ok None | Error _ -> messages
;;
