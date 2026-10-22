(** Tool execution helpers — lookup, hooks, event_bus, parallel Eio fibers.

    These functions are parameterized by explicit fields rather than Agent.t
    to avoid circular module dependencies (Agent_tools is compiled before Agent). *)

open Types

let _log = Log.create ~module_name:"agent_tools" ()

type tool_failure_kind = Types.tool_failure_kind =
  | Validation_error
  | Recoverable_tool_error
  | Non_retryable_tool_error
  | Reported_tool_error
  | Unattributed_tool_error

include Agent_tool_execution_types

let observer_failure ~invocation exception_ backtrace =
  Llm_provider.Reserved_exn.reraise_if_reserved exception_;
  Log.error
    _log
    "tool observer failed"
    [ Log.S ("tool_use_id", Tool_contract.Invocation.tool_use_id invocation)
    ; Log.I ("turn", Tool_contract.Invocation.turn invocation)
    ; Log.I ("planned_index", Tool_contract.Invocation.planned_index invocation)
    ];
  Observer_failure { invocation; exception_; backtrace }
;;

let failure_summary = function
  | Hook_failure (Hook_execution_failed { hook_name; detail; _ }) ->
    Printf.sprintf "hook %s failed: %s" hook_name detail
  | Durability_failure { detail; _ } -> "durable execution failed: " ^ detail
  | Observer_failure { exception_; _ } -> Printexc.to_string exception_
;;

type restored_invocation =
  | Unattempted_invocation of Tool_contract.Invocation.t
  | Attempted_or_settled_invocation of Tool_contract.Invocation.t

type scheduled_tool_use =
  { index : int
  ; id : string
  ; name : string
  ; input : Yojson.Safe.t
  ; execution_mode : Tool_contract.execution_mode
  ; completion : Tool_contract.completion
  ; prepared_call : Tool.prepared_call option
  ; preparation_exception : (exn * Printexc.raw_backtrace) option
  ; restored_invocation : restored_invocation option
  }

type scoped_settlement =
  | Scoped_settled of scheduled_tool_outcome
  | Scoped_not_started

type tool_index = (string, Tool.t) Hashtbl.t

let add_first tbl key value = if not (Hashtbl.mem tbl key) then Hashtbl.add tbl key value

let build_index tools =
  let by_name = Hashtbl.create (List.length tools) in
  List.iter
    (fun (tool : Tool.t) ->
       let name = tool.schema.name in
       add_first by_name name tool)
    tools;
  by_name
;;

let find_in_index (index : tool_index) name : Tool.t option = Hashtbl.find_opt index name

let tool_names_of_index index =
  Hashtbl.fold (fun name _ acc -> name :: acc) index [] |> List.sort_uniq String.compare
;;

let render_tool_names names =
  match names with
  | [] -> "(none)"
  | _ -> String.concat "," names
;;

(* A registered tool name is a bare identifier, so lookup is exact and
   stays exact. What follows only enriches the reject MESSAGE: when the
   model fuses arguments into the name slot (masc#29008 live shape:
   [Execute["argv"]]) or typos a name, echoing the string back gives it
   nothing to repair with, and the same broken call comes back on the
   next turn. *)
let is_tool_name_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false
;;

(* [Some prefix] when [requested] starts as an identifier but carries
   trailing non-identifier characters; [None] when it already is a bare
   identifier. *)
let identifier_prefix requested =
  let length = String.length requested in
  let rec scan i =
    if i < length && is_tool_name_char requested.[i] then scan (i + 1) else i
  in
  let stop = scan 0 in
  if stop = length then None else Some (String.sub requested 0 stop)
;;

(* The exact-match-then-reject contract above assumes the model can repair a
   wrong name from the reject message. GLM-family providers break that
   assumption from the server side: they fuse a per-call sequence number onto
   the tool name (live shape 2026-08-24, keeper/polisher turns 3042-3044:
   [Execute1139645993.1], [Execute1248182267.1], [Execute1349427591.2] — a
   fresh number every turn, so every retry misses again and the model never
   chose the digits). Recovery belongs where the registered names are known:
   [Some registered] when [requested] is exactly one registered name extended
   by [0-9.] characters alone — every observed shape was digits and dots, and
   admitting [_] would let an underscore registered name such as masc_board_*
   recover a different stem's underscore tail, so an underscore tail stays a
   reject until a live shape asks for it. Alphabetic tails, unknown stems,
   and names matching more than one registered prefix all stay [None] — the
   exact-match answer below is unchanged for them. *)
let is_call_suffix_char = function
  | '0' .. '9' | '.' -> true
  | _ -> false
;;

let strip_registered_suffix ~available requested =
  let matches =
    List.filter_map
      (fun registered ->
         let rlen = String.length registered in
         let tlen = String.length requested in
         if
           tlen > rlen
           && String.starts_with ~prefix:registered requested
           && String.for_all
                is_call_suffix_char
                (String.sub requested rlen (tlen - rlen))
         then Some registered
         else None)
      available
  in
  match matches with
  | [ sole ] -> Some sole
  | [] | _ :: _ :: _ -> None
;;

let levenshtein a b =
  let la = String.length a
  and lb = String.length b in
  let prev = Array.init (lb + 1) Fun.id in
  let curr = Array.make (lb + 1) 0 in
  for i = 1 to la do
    curr.(0) <- i;
    for j = 1 to lb do
      let cost = if Char.equal a.[i - 1] b.[j - 1] then 0 else 1 in
      curr.(j) <- min (min (prev.(j) + 1) (curr.(j - 1) + 1)) (prev.(j - 1) + cost)
    done;
    Array.blit curr 0 prev 0 (lb + 1)
  done;
  prev.(lb)
;;

(* Two edits covers the observed miss shapes (transposed or dropped
   letters) without ever suggesting an unrelated tool for a genuinely
   unknown name. *)
let max_suggestion_distance = 2

let closest_registered ~requested ~available =
  List.fold_left
    (fun best name ->
       let distance = levenshtein requested name in
       if distance > max_suggestion_distance
       then best
       else (
         match best with
         | Some (best_distance, _) when best_distance <= distance -> best
         | Some _ | None -> Some (distance, name)))
    None
    available
  |> Option.map snd
;;

let unknown_tool_failure ~requested ~available =
  (* The catalog does not belong in the result the model reads back. Every
     request already carries the tool schemas, and the operator copy is logged
     beside this call, so listing the names here only sends the surface back
     into the conversation on each miss. Measured 2026-08-21 with 101 tools
     registered: 1,915 of the message's 1,975 bytes were the list, and one turn
     missed 88 times in a row, so a model already failing under tool-surface
     pressure was handed 170 KB more of it. What it cannot derive is which name
     failed and how that name was malformed; those stay. The sentences
     themselves are host-installed text ([Tool_guidance_text]): the host
     installs render callbacks for config/prompts/agent_core.md at prompt-init
     time, and each refusal resolves the current registry value. The defaults
     here are the last-resort copy. *)
  let text = Tool_guidance_text.current () in
  let base =
    match available with
    | [] -> text.unknown_tool_not_found_no_tools ~requested
    | _ :: _ -> text.unknown_tool_not_found ~requested
  in
  let extras =
    match identifier_prefix requested with
    | None ->
      (match closest_registered ~requested ~available with
       | None -> []
       | Some name -> [ text.unknown_tool_closest_registered ~name ])
    | Some prefix when List.exists (String.equal prefix) available ->
      [ text.unknown_tool_extra_characters ~prefix ]
    | Some prefix ->
      (match closest_registered ~requested:prefix ~available with
       | Some name -> [ text.unknown_tool_not_bare_with_closest ~name ]
       | None -> [ text.unknown_tool_not_bare () ])
  in
  (* [base] carries no trailing period, so the sentence join supplies
     it; with no extras the legacy message stays byte-identical. *)
  String.concat ". " (base :: extras), Validation_error
;;

let resolve_tool_call tool_index name input =
  match find_in_index tool_index name with
  | Some _ as found -> name, input, found
  | None -> (
    (* GLM fuses a call sequence number onto the name; strip it before the
       miss becomes a tool-not-found turn. [strip_registered_suffix] only
       accepts a sole registered stem with a [0-9.] tail, so a genuine
       unknown name still reaches the reject path unchanged. *)
    match strip_registered_suffix ~available:(tool_names_of_index tool_index) name with
    | Some corrected -> corrected, input, find_in_index tool_index corrected
    | None -> name, input, None)
;;

(* The transcript is what the next request replays to the model, so a tool name
   that never routed must not survive in it. Live shape 2026-08-24 (masc#29337):
   a keeper emitted [Execute-1.1111e1111111] once, the block stayed in history,
   and the same byte string came back 115 times over 2h17m. The same string also
   survived a lane switch from glm-5-turbo to deepseek-v4-flash, which is only
   possible if the source is the transcript rather than either model.

   History therefore carries what dispatch resolved, not what the wire carried:
   a recovered name is stored under its registered spelling (so the call-number
   recovery above stops teaching the fused shape), and an unroutable call is
   stored not at all. The wire text stays intact in the raw trace, which is the
   evidence authority for what the provider actually sent. *)
type tool_use_admission =
  { admitted : Types.content_block list
  ; retained_content_indices : int list
  ; rejected_names : string list
  ; tool_source_map : Hooks.admitted_tool_source_map
  }

let admit_tool_use_names tool_index blocks =
  let rejected_names = ref [] in
  let retained_content_indices = ref [] in
  let next_planned_index = ref 0 in
  let next_source_tool_use_ordinal = ref 0 in
  let admitted_tool_sources = ref [] in
  let admitted =
    List.filter_map
      (fun (content_index, (block : Types.content_block)) ->
         let retain block =
           retained_content_indices := content_index :: !retained_content_indices;
           Some block in
         match block with
         | Types.ToolUse { id; name; input } ->
           let source_tool_use_ordinal = !next_source_tool_use_ordinal in
           incr next_source_tool_use_ordinal;
           (match resolve_tool_call tool_index name input with
            | resolved, resolved_input, Some _ ->
              let planned_index = !next_planned_index in
              incr next_planned_index;
              let name_resolution =
                if String.equal name resolved then Hooks.Registered_name
                else Hooks.Recovered_name
                  { tool_call_id = id; provider_name = name; registered_name = resolved }
              in
              admitted_tool_sources :=
                { Hooks.planned_index; source_tool_use_ordinal; name_resolution }
                :: !admitted_tool_sources;
              retain (Types.ToolUse { id; name = resolved; input = resolved_input })
            | _, _, None ->
              rejected_names := name :: !rejected_names;
              None)
         | Types.Text _
         | Types.Thinking _
         | Types.ReasoningDetails _
         | Types.RedactedThinking _
         | Types.ToolResult _
         | Types.Image _
         | Types.Document _
         | Types.Audio _ -> retain block)
      (List.mapi (fun index block -> index, block) blocks)
  in
  { admitted
  ; retained_content_indices = List.rev !retained_content_indices
  ; rejected_names = List.rev !rejected_names
  ; tool_source_map =
      { Hooks.admitted_tool_sources = List.rev !admitted_tool_sources
      ; source_tool_use_count = !next_source_tool_use_ordinal
      }
  }
;;

(* The note built from these names is a User message, so the transcript
   replays it on every later request for the life of the conversation. A name
   is provider text of unbounded length and one turn can carry many, so the
   rendering is bounded on both axes. *)
let rejected_name_display_limit = 8
let rejected_name_char_limit = 64

let describe_rejected_names names =
  let distinct =
    List.rev
      (List.fold_left
         (fun acc name -> if List.mem name acc then acc else name :: acc)
         []
         names)
  in
  let rec take index shown = function
    | [] -> List.rev shown, 0
    | rest when index >= rejected_name_display_limit -> List.rev shown, List.length rest
    | name :: rest -> take (index + 1) (name :: shown) rest
  in
  let shown, hidden = take 0 [] distinct in
  (* [Util.clip] never cuts inside a UTF-8 sequence. The clipped name is
     carried in the prompt for the rest of the conversation, and an invalid
     byte there would be replayed on every request. *)
  let clip name = Util.clip name rejected_name_char_limit in
  let listed = String.concat ", " (List.map (fun name -> "\"" ^ clip name ^ "\"") shown) in
  if hidden = 0 then listed else Printf.sprintf "%s and %d more" listed hidden
;;

let schedule_tool_use ~tool_index index (id, name, input) =
  (* Resolving through [resolve_tool_call] (not a bare [find_in_index]) keeps
     the scheduled name, execution_mode, and completion consistent with what
     execution will look up: without the strip here, a suffixed name would
     schedule as the Serial fallback and silently serialize tools whose
     contract is Concurrent. *)
  let resolved, _, tool_opt = resolve_tool_call tool_index name input in
  let execution_mode, completion =
    match tool_opt with
    | Some tool -> Tool.execution_mode tool ~input, Tool.completion tool
    | None -> Tool_contract.Serial, Tool_contract.Continue_after_success
  in
  (match tool_opt with
   | Some _ when not (String.equal resolved name) ->
     Log.warn
       _log
       "tool name suffix normalized"
       [ Log.S ("requested", name); Log.S ("resolved", resolved) ]
   | _ -> ());
  { index; id; name = resolved; input; execution_mode; completion
  ; prepared_call = None; preparation_exception = None; restored_invocation = None }
;;

let restore_durable_tool ~turn_count ~durable (call : scheduled_tool_use) =
  match durable with
  | None | Some (_, Error _) -> call
  | Some (provider, Ok authorities) ->
    let matching = List.filter (fun (authority : Execution_agent_scope.invocation_authority) ->
      Tool_contract.Invocation.planned_index authority.invocation = call.index) authorities in
    (match matching with
     | [ authority ] ->
       (match Execution_agent_scope.validate_invocation_authority authority
                ~turn:turn_count ~planned_index:call.index ~tool_use_id:call.id
                ~tool_name:call.name ~input:call.input with
        | Error _ -> call
        | Ok () ->
          (match Execution_agent_scope.find_invocation provider ~invocation:authority.invocation
                   ~tool_name:call.name ~input:call.input with
           | Error _ | Ok None -> call
           | Ok (Some original) ->
             (match Execution_agent_scope.invocation_progress original with
              | Error _ -> call
              | Ok Execution_agent_scope.Invocation_unattempted ->
                (* An open sibling already owns its original wave identity,
                   even when a settled sibling now forms a replay barrier.
                   This restores identity, not attempt or execution authority:
                   current preparation and Gate still run. Current completion
                   must agree before restoring an unattempted occurrence. *)
                if call.completion = Tool_contract.Invocation.completion authority.invocation
                then { call with restored_invocation = Some (Unattempted_invocation authority.invocation)
                               ; execution_mode = Tool_contract.Serial }
                else call
              | Ok Execution_agent_scope.Invocation_attempted_or_settled ->
                (* Only canonical settlement decides replay or unknown-effect
                   refusal. Current resource preparation cannot mask either.
                   No new effect is admitted by this conservative batch barrier. *)
                { call with restored_invocation = Some (Attempted_or_settled_invocation authority.invocation)
                          ; execution_mode = Tool_contract.Serial
                          ; completion = Tool_contract.Invocation.completion authority.invocation })))
     | [] | _ :: _ :: _ -> call)
;;

let prepare_scheduled_tool ~sw ~tool_index (call : scheduled_tool_use) =
  match call.restored_invocation, Hashtbl.find_opt tool_index call.name with
  | Some (Attempted_or_settled_invocation _), (Some _ | None)
  | (None | Some (Unattempted_invocation _)), None -> call
  | (None | Some (Unattempted_invocation _)), Some tool when not (Tool.has_scoped_admission tool) -> call
  | (None | Some (Unattempted_invocation _)), Some tool ->
    (* Invalid public input never reaches a producer's resource resolver. The
       existing dispatch boundary still owns the canonical validation result. *)
    (match Tool_input_validation.validate tool.Tool.schema call.input with
     | Tool_input_validation.Invalid _ -> call
     | Tool_input_validation.Valid _ ->
       try
         let prepared_call = Tool.prepare_call ~sw tool ~input:call.input in
         let execution_mode =
           match call.restored_invocation, Tool.prepared_call_scopes prepared_call with
           | None, Some _ -> Tool_contract.Concurrent
           | (None | Some (Unattempted_invocation _ | Attempted_or_settled_invocation _)), None
           | Some (Unattempted_invocation _ | Attempted_or_settled_invocation _), Some _ -> call.execution_mode
         in
         { call with prepared_call = Some prepared_call; execution_mode }
       with
       | exception_ ->
         let backtrace = Printexc.get_raw_backtrace () in
         Llm_provider.Reserved_exn.reraise_if_reserved exception_;
         { call with preparation_exception = Some (exception_, backtrace) })
;;

let hook_schedule_of_tool_use ~batch_index ~batch_size (tool_use : scheduled_tool_use)
  : Tool_contract.schedule
  =
  { planned_index = tool_use.index
  ; batch_index
  ; batch_size
  ; execution_mode = tool_use.execution_mode
  }
;;

exception Hook_observer_raised of exn * Printexc.raw_backtrace

let raise_hook_observer exn =
  let backtrace = Printexc.get_raw_backtrace () in
  raise (Hook_observer_raised (exn, backtrace))
;;

let reraise_hook_observer exn backtrace = Printexc.raise_with_backtrace exn backtrace

let invoke_hook ?on_hook_invoked ~tracer ~agent_name ~turn_count ~hook_name hook_opt event
  =
  try
    Tracing.with_span
      tracer
      { kind = Hook_invoke
      ; name = hook_name
      ; agent_name
      ; turn = turn_count
      ; extra = []
      ; links = []
      }
      (fun _ ->
         let decision = Hooks.invoke_validated ~hook_name hook_opt event in
         (match on_hook_invoked with
          | Some callback ->
            (try
               callback
                 ~invocation:(Hooks.invocation_of_event event)
                 ~hook_name
                 ~decision
                 ~detail:
                   (match event with
                    | Hooks.PreToolUse { tool_name; _ }
                    | Hooks.PostToolUse { tool_name; _ }
                    | Hooks.PostToolUseFailure { tool_name; _ } -> Some tool_name
                    | Hooks.BeforeTurn _
                    | Hooks.BeforeTurnParams _
                    | Hooks.AfterTurn _
                    | Hooks.OnStop _
                    | Hooks.OnError _
                    | Hooks.OnToolError _ -> None)
             with
             | exn -> raise_hook_observer exn)
          | None -> ());
         decision)
  with
  | Hook_observer_raised _ as exn -> raise exn
  | exn ->
    Llm_provider.Reserved_exn.reraise_if_reserved exn;
    (* A user-hook exception is converted to [HookFailed] inside
       [Hooks.invoke_validated]. Anything escaping the tracing envelope is
       therefore an observer/tracer failure and must reach the caller. *)
    raise_hook_observer exn
;;

let execution_failure_of_deferred = function
  | Deferred_hook_failure error -> Hook_failure error
  | Deferred_observer_failure { invocation; exception_; backtrace } ->
    Observer_failure { invocation; exception_; backtrace }
;;

let deferred_failure_summary deferred =
  failure_summary (execution_failure_of_deferred deferred)
;;

let hook_execution_error ~hook_name ~stage ~tool_name ~invocation ~detail =
  Hook_execution_failed { hook_name; stage; tool_name; invocation; detail }
;;

let invoke_post_hook
      ?on_hook_invoked
      ~tracer
      ~agent_name
      ~invocation
      ~hook_name
      ~tool_name
      hook_opt
      event
  =
  let turn_count = Tool_contract.Invocation.turn invocation in
  try
    match
      invoke_hook
        ?on_hook_invoked
        ~tracer
        ~agent_name
        ~turn_count
        ~hook_name
        hook_opt
        event
    with
    | Hooks.Continue -> None
    | Hooks.HookFailed { stage; detail } ->
      Some
        (Deferred_hook_failure
           (hook_execution_error ~hook_name ~stage ~tool_name ~invocation ~detail))
    | (Hooks.AdjustParams _ | Hooks.ElicitInput _ | Hooks.ElicitToolApproval _ | Hooks.Nudge _ | Hooks.Block _) as decision -> let stage = Hooks.stage_of_event event in
      Some
        (Deferred_hook_failure
           (hook_execution_error
              ~hook_name
              ~stage
              ~tool_name
              ~invocation
              ~detail:
                (Printf.sprintf
                   "illegal decision %s escaped hook validation"
                   (Hooks.decision_kind_to_string (Hooks.classify_decision decision)))))
  with
  | Hook_observer_raised (exception_, backtrace) ->
    Llm_provider.Reserved_exn.reraise_if_reserved exception_;
    Some (Deferred_observer_failure { invocation; exception_; backtrace })
;;

let resolve_dispatch dispatch =
  match dispatch.deferred_failure with
  | None -> Ok dispatch.result
  | Some (Deferred_hook_failure error) -> Error error
  | Some (Deferred_observer_failure { exception_; backtrace; _ }) ->
    reraise_hook_observer exception_ backtrace
;;

(** Find and execute a single tool, invoking PostToolUse hook.
    Returns a structured execution result. *)
let find_and_execute_tool_with_index
      ~context
      ~tool_index
      ~(hooks : Hooks.hooks)
      ~event_bus
      ~tracer
      ~agent_name
      ?correlation_id
      ?run_id
      ?on_hook_invoked
      ~publish_event_bus
      ~invocation
      ?prepared_call
      name
      input
  =
  let id = Tool_contract.Invocation.tool_use_id invocation in
  let requested_name = name in
  let name, input, tool_opt = resolve_tool_call tool_index name input in
  (* Callers that reach execution without going through [schedule_tool_use]
     (keeper official-client host passes the registered name verbatim, so it
     never trips this) still normalize here; a suffixed name that resolves
     must be visible in the log, not silently recovered. *)
  (match tool_opt with
   | Some _ when not (String.equal requested_name name) ->
     Log.warn
       _log
       "tool name suffix normalized"
       [ Log.S ("requested", requested_name); Log.S ("resolved", name) ]
   | _ -> ());
  let first_deferred_failure = ref None in
  let post_effect_observers = ref [] in
  let defer_observer observer =
    post_effect_observers := observer :: !post_effect_observers
  in
  let record_deferred_failure failure =
    match !first_deferred_failure with
    | None -> first_deferred_failure := Some failure
    | Some primary ->
      let retained, suppressed =
        match primary, failure with
        | Deferred_hook_failure _, Deferred_observer_failure _ ->
          first_deferred_failure := Some failure;
          failure, primary
        | (Deferred_hook_failure _, Deferred_hook_failure _) | (Deferred_observer_failure _, _) -> primary, failure
      in
      Log.error
        _log
        "additional tool dispatch failure"
        [ Log.S ("tool", name)
        ; Log.S ("tool_use_id", id)
        ; Log.S ("retained", deferred_failure_summary retained)
        ; Log.S ("suppressed", deferred_failure_summary suppressed)
        ]
  in
  let record_deferred_exception exception_ backtrace =
    Llm_provider.Reserved_exn.reraise_if_reserved exception_;
    record_deferred_failure
      (Deferred_observer_failure { invocation; exception_; backtrace })
  in
  (* ToolCalled event — capture the published envelope's run_id so the
     matching ToolCompleted records it as caused_by, preserving the
     call -> completion causation chain per tool invocation (#877).
     Using [ev.meta.run_id] works whether the caller supplies
     [~run_id] explicitly or we fall back to the fresh id minted by
     [mk_event]. *)
  let tool_called_run_id =
    match publish_event_bus, event_bus with
    | false, _ -> None
    | true, Some bus ->
      let ev =
        Event_bus.mk_event
          ?correlation_id
          ?run_id
          (ToolCalled { invocation; agent_name; tool_name = name; input })
      in
      (try
         Event_bus.publish bus ev;
         Some ev.meta.run_id
       with
       | exception_ ->
         let backtrace = Printexc.get_raw_backtrace () in
         record_deferred_exception exception_ backtrace;
         None)
    | true, None -> None
  in
  let dispatch =
    match tool_opt with
    | Some tool ->
      let validation_error_result ~input message =
        { invocation
        ; tool_name = name
        ; input
        ; content = message
        ; content_blocks = None
        ; outcome =
            Tool_failed
              { failure_kind = Validation_error; error_class = Some Types.Deterministic }
        }
      in
      let emit_post_tool_use_failure ~input ~stage ~duration_ms message =
        invoke_post_hook
          ?on_hook_invoked
          ~tracer
          ~agent_name
          ~invocation
          ~hook_name:"post_tool_use_failure"
          ~tool_name:name
          hooks.post_tool_use_failure
          (Hooks.PostToolUseFailure
             { invocation
             ; tool_name = name
             ; input
             ; stage
             ; duration_ms
             ; error = message
             })
      in
      (* Tool inputs cross this boundary unchanged. The schema either accepts
           the exact JSON value or produces a typed validation failure for the
           model to correct in a later native ToolUse block. *)
      let validation_started_at = Unix.gettimeofday () in
      let validated_input =
        match Tool_input_validation.validate tool.schema input with
        | Tool_input_validation.Valid exact_input -> Ok exact_input
        | Tool_input_validation.Invalid errors ->
          let message =
            Tool_input_validation.format_errors_inline ~tool_name:name ~args:input errors
          in
          let duration_ms =
            max 0.0 ((Unix.gettimeofday () -. validation_started_at) *. 1000.0)
          in
          defer_observer (fun () ->
            emit_post_tool_use_failure
              ~input
              ~stage:Hooks.Validation_before_execution
              ~duration_ms
              message
            |> Option.iter record_deferred_failure);
          Error message
      in
      (match validated_input with
       | Error message ->
         { result = validation_error_result ~input message; deferred_failure = None }
       | Ok exact_input ->
         let t0 = Unix.gettimeofday () in
         let result =
           Agent_tool_terminal_boundary.execute_handler ~tool ~name (fun () ->
             match prepared_call with
             | Some prepared -> Tool.execute_prepared ~context ~invocation prepared
             | None -> Tool.execute ~context ~invocation tool exact_input)
         in
         let duration_ms = (Unix.gettimeofday () -. t0) *. 1000.0 in
         let result_bytes =
           match result with
           | Ok { content; _ } -> String.length content
           | Error { message; _ } -> String.length message
         in
         defer_observer (fun () ->
           invoke_post_hook
             ?on_hook_invoked
             ~tracer
             ~agent_name
             ~invocation
             ~hook_name:"post_tool_use"
             ~tool_name:name
             hooks.post_tool_use
             (Hooks.PostToolUse
                { invocation
                ; tool_name = name
                ; input = exact_input
                ; output = result
                ; result_bytes
                ; duration_ms
                })
           |> Option.iter record_deferred_failure);
         (match result with
          | Ok _ -> ()
          | Error { message; _ } ->
            defer_observer (fun () ->
              invoke_post_hook
                ?on_hook_invoked
                ~tracer
                ~agent_name
                ~invocation
                ~hook_name:"post_tool_use_failure"
                ~tool_name:name
                hooks.post_tool_use_failure
                (Hooks.PostToolUseFailure
                   { invocation
                   ; tool_name = name
                   ; input = exact_input
                   ; stage = Hooks.Execution
                   ; duration_ms
                   ; error = message
                   })
              |> Option.iter record_deferred_failure);
            (* [OnToolError] is the compact error projection. The exact
               invocation remains shared with the richer failure hook. *)
            defer_observer (fun () ->
              invoke_post_hook
                ?on_hook_invoked
                ~tracer
                ~agent_name
                ~invocation
                ~hook_name:"on_tool_error"
                ~tool_name:name
                hooks.on_tool_error
                (Hooks.OnToolError { invocation; tool_name = name; error = message })
              |> Option.iter record_deferred_failure));
         let content, content_blocks, outcome =
           match result with
           | Ok { content; content_blocks; _ } -> content, content_blocks, Tool_succeeded
           | Error { message; recoverable; error_class } ->
             let failure_kind =
               if recoverable then Recoverable_tool_error else Non_retryable_tool_error
             in
             message, None, Tool_failed { failure_kind; error_class }
         in
         { result =
             { invocation; tool_name = name; input = exact_input; content; content_blocks; outcome }
         ; deferred_failure = None
         })
    | None ->
      (* Tool dispatch failure (the LLM asked for a tool that isn't
         registered). Distinct from OnToolError — that fires when a
         tool actually ran and returned Error. This is a configuration
         / routing mistake, so it belongs on the general OnError
         channel. Unknown names are always typed as validation errors; the
         available names remain diagnostic data only. *)
      let available = tool_names_of_index tool_index in
      let message, failure_kind =
        unknown_tool_failure ~requested:requested_name ~available
      in
      Log.warn
        _log
        "tool not found"
        [ Log.S ("tool", requested_name)
        ; Log.S ("available_tools", render_tool_names available)
        ];
      defer_observer (fun () ->
        invoke_post_hook
          ?on_hook_invoked
          ~tracer
          ~agent_name
          ~invocation
          ~hook_name:"on_error"
          ~tool_name:requested_name
          hooks.on_error
          (Hooks.OnError
             { invocation = Some invocation
             ; detail = message
             ; context = "agent_tools.find_and_execute_tool"
             })
        |> Option.iter record_deferred_failure);
      { result =
          { invocation
          ; tool_name = requested_name
          ; input
          ; content = message
        ; content_blocks = None
          ; outcome = Tool_failed { failure_kind; error_class = Some Types.Deterministic }
          }
      ; deferred_failure = None
      }
  in
  (* ToolCompleted event *)
  defer_observer (fun () ->
    match publish_event_bus, event_bus with
    | false, _ -> ()
    | true, Some bus ->
      let output_content = dispatch.result.content in
      let output =
        Types.tool_result_of_outcome ?content_blocks:dispatch.result.content_blocks ~content:output_content dispatch.result.outcome
      in
      (try
         Event_bus.publish
           bus
           (Event_bus.mk_event
              ?correlation_id
              ?run_id
              ?caused_by:tool_called_run_id
              (ToolCompleted { invocation; agent_name; tool_name = name; output }))
       with
       | exception_ ->
         let backtrace = Printexc.get_raw_backtrace () in
         record_deferred_exception exception_ backtrace)
    | true, None -> ());
  { result = dispatch.result
  ; finish_observers =
      (fun () ->
        List.rev !post_effect_observers |> List.iter (fun observe -> observe ());
        { dispatch with deferred_failure = !first_deferred_failure })
  }
;;

let find_and_execute_tool
      ~context
      ~tools
      ~(hooks : Hooks.hooks)
      ~event_bus
      ~tracer
      ~agent_name
      ?correlation_id
      ?run_id
      ?on_hook_invoked
      ~invocation
      name
      input
  =
  let tool_index = build_index tools in
  try
    let pending =
      find_and_execute_tool_with_index
        ~context
        ~tool_index
        ~hooks
        ~event_bus
        ~tracer
        ~agent_name
        ?correlation_id
        ?run_id
        ?on_hook_invoked
        ~publish_event_bus:true
        ~invocation
        name
        input
    in
    pending.finish_observers () |> resolve_dispatch
  with
  | Hook_observer_raised (exn, backtrace) -> reraise_hook_observer exn backtrace
;;

exception Abort_tool_dispatch

let execute_scheduled_tool
      ~context
      ~tools:_
      ~tool_index
      ~(hooks : Hooks.hooks)
      ~event_bus
      ?tool_approval
      ?journal
      ~tracer
      ~agent_name
      ~turn_count
      ~(usage : Types.usage_stats)
      ?correlation_id
      ?run_id
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      ~(schedule : Tool_contract.schedule)
      (tool_use : scheduled_tool_use)
  =
  let { index; id; name; input; _ } = tool_use in
  let invocation =
    match tool_use.restored_invocation with
    | Some (Unattempted_invocation original | Attempted_or_settled_invocation original) -> original
    | None ->
      Tool_contract.Invocation.create
        ~tool_use_id:id
        ~turn:turn_count
        ~schedule
        ~completion:tool_use.completion
  in
  let id = Tool_contract.Invocation.tool_use_id invocation in
  let turn_count = Tool_contract.Invocation.turn invocation in
  let completed_dispatch : tool_dispatch option ref = ref None in
  let first_failure = ref None in
  let record_failure failure =
    match !first_failure with
    | None -> first_failure := Some failure
    | Some primary ->
      let retained, suppressed =
        if failure_priority failure > failure_priority primary
        then (
          first_failure := Some failure;
          failure, primary)
        else primary, failure
      in
      Log.error
        _log
        "additional tool execution failure"
        [ Log.S ("tool", name)
        ; Log.S ("tool_use_id", id)
        ; Log.S ("retained", failure_summary retained)
        ; Log.S ("suppressed", failure_summary suppressed)
        ]
  in
  let record_caught_exception exception_ backtrace =
    Llm_provider.Reserved_exn.reraise_if_reserved exception_;
    record_failure (observer_failure ~invocation exception_ backtrace)
  in
  let observe_before_completion callback =
    try callback () with
    | Hook_observer_raised (exception_, backtrace) ->
      record_caught_exception exception_ backtrace;
      raise Abort_tool_dispatch
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      record_caught_exception exception_ backtrace;
      raise Abort_tool_dispatch
  in
  let observe_after_completion callback =
    try callback () with
    | Hook_observer_raised (exception_, backtrace) ->
      record_caught_exception exception_ backtrace
    | exception_ ->
      let backtrace = Printexc.get_raw_backtrace () in
      record_caught_exception exception_ backtrace
  in
  let outcome () =
    { index
    ; completed_result =
        Option.map (fun (dispatch : tool_dispatch) -> dispatch.result) !completed_dispatch
    ; completion =
        Agent_tool_terminal_boundary.completed_dispatch
          tool_use.completion
          !completed_dispatch
    ; failure = !first_failure
    }
  in
  let observe_started ~tool_name ~input =
    match on_tool_execution_started with
    | Some callback -> callback ~invocation ~tool_name ~input
    | None -> ()
  in
  let begin_effect ~tool_name ~input =
    let t0_tool = Unix.gettimeofday () in
    let pending =
      find_and_execute_tool_with_index
        ~context
        ~tool_index
        ~hooks
        ~event_bus
        ~tracer
        ~agent_name
        ?correlation_id
        ?run_id
        ?on_hook_invoked
        ~publish_event_bus:true
        ~invocation
        ?prepared_call:tool_use.prepared_call
        tool_name
        input
    in
    completed_dispatch
    := Some ({ result = pending.result; deferred_failure = None } : tool_dispatch);
    pending, (Unix.gettimeofday () -. t0_tool) *. 1000.0
  in
  let finish_effect pending ~tool_name =
    let dispatch = pending.finish_observers () in
    completed_dispatch := Some dispatch;
    Option.iter
      (fun deferred -> record_failure (execution_failure_of_deferred deferred))
      dispatch.deferred_failure;
    observe_after_completion (fun () ->
      match on_tool_execution_finished with
      | Some callback ->
        callback
          ~invocation
          ~tool_name
          ~content:dispatch.result.content
          ~is_error:(Types.tool_result_outcome_is_error dispatch.result.outcome)
      | None -> ());
    dispatch
  in
  let execute_durable durable_invocation =
    match
      Execution_agent_scope.execute_phased
        durable_invocation
        ~invoke:(fun ~start_child ~tool_name ~input ->
          observe_before_completion (fun () -> observe_started ~tool_name ~input);
          Execution_context.with_child_scope_factory start_child (fun () ->
            let pending, _duration_ms = begin_effect ~tool_name ~input in
            ( (pending.result.content, pending.result.content_blocks, pending.result.outcome)
            , fun () ->
                let (_ : tool_dispatch) = finish_effect pending ~tool_name in
                () )))
    with
    | Error error ->
      (* The effect may already have returned, but without an atomic settlement
         there is no result authority to expose to the transcript. *)
      completed_dispatch := None;
      record_failure
        (Durability_failure
           { invocation; detail = Execution_agent_scope.error_to_string error });
      raise Abort_tool_dispatch
    | Ok (Execution_agent_scope.Executed (result, _, _))
    | Ok (Execution_agent_scope.Replayed result) ->
      let dispatch =
        match !completed_dispatch with
        | Some dispatch -> dispatch
        | None ->
          { result =
              { invocation = result.invocation
              ; tool_name = result.tool_name
              ; input = result.input
              ; content = result.content
              ; content_blocks = result.content_blocks
              ; outcome = result.outcome
              }
          ; deferred_failure = None
          }
      in
      completed_dispatch := Some dispatch;
      dispatch
  in
  let with_tool_span run =
    Tracing.with_span
      tracer
      { kind = Tool_exec; name; agent_name; turn = turn_count; extra = []; links = [] }
      (fun _tracer -> run ())
  in
  let durability_failure error =
    record_failure
      (Durability_failure
         { invocation; detail = Execution_agent_scope.error_to_string error });
    raise Abort_tool_dispatch
  in
  let settle_existing_block durable result =
    match Agent_tool_pre_execution_gate.settle_existing_block durable result with
    | Ok result -> result
    | Error error -> durability_failure error
  in
  let settle_gate ?settle_blocked execute_admitted =
    let decision =
      invoke_hook
        ?on_hook_invoked
        ~tracer
        ~agent_name
        ~turn_count
        ~hook_name:"pre_tool_use"
        hooks.pre_tool_use
        (Hooks.PreToolUse
           { invocation
           ; tool_name = name
           ; input
           ; usage = Some usage
           })
    in
    let settlement =
      Agent_tool_pre_execution_gate.settle
        ?tool_approval
        ?correlation_id
        ?run_id
        ~event_bus
        ~agent_name
        ~invocation
        ~tool_name:name
        ~input
        decision
    in
    match
      Agent_tool_pre_execution_gate.scheduled_settlement
        ?settle_blocked
        ~index
        ~invocation
        ~tool_name:name
        ~input
        settlement
    with
    | Agent_tool_pre_execution_gate.Run_admitted -> execute_admitted ()
    | Agent_tool_pre_execution_gate.Return_outcome outcome -> outcome
  in
  let require_preparation () =
    match tool_use.preparation_exception with
    | None -> ()
    | Some (exception_, backtrace) -> Printexc.raise_with_backtrace exception_ backtrace
  in
  try
    let execution_provider = Execution_context.provider_attempt () in
    let existing =
      match execution_provider with
      | None -> Ok None
      | Some provider ->
        Execution_agent_scope.find_invocation provider ~invocation ~tool_name:name ~input
    in
    match existing with
    | Error error -> durability_failure error
    | Ok (Some durable) ->
      let execute_existing () =
        let (_ : tool_dispatch) = with_tool_span (fun () -> execute_durable durable) in
        outcome ()
      in
      (match Execution_agent_scope.invocation_progress durable with
       | Error error -> durability_failure error
       | Ok Execution_agent_scope.Invocation_unattempted ->
         settle_gate ~settle_blocked:(settle_existing_block durable) (fun () ->
           require_preparation ();
           execute_existing ())
       | Ok Execution_agent_scope.Invocation_attempted_or_settled -> execute_existing ())
    | Ok None ->
      let execute_admitted () =
        require_preparation ();
        let idem_key = Durable_event.make_idempotency_key ~tool_name:name ~input in
        try
          let dispatch =
            with_tool_span (fun () ->
              match execution_provider with
              | Some provider ->
                (match
                   Execution_agent_scope.open_invocation
                     provider
                     ~invocation
                     ~tool_name:name
                     ~input
                 with
                 | Error error -> durability_failure error
                 | Ok durable_invocation -> execute_durable durable_invocation)
              | None ->
                observe_before_completion (fun () ->
                  observe_started ~tool_name:name ~input;
                  match journal with
                  | Some j ->
                    Agent_execution_event_writer.append
                      j
                      (Tool_called
                         { turn = Tool_contract.Invocation.turn invocation
                         ; tool_name = name
                         ; idempotency_key = idem_key
                         ; input_hash = Digest.string (Yojson.Safe.to_string input)
                         ; timestamp = Unix.gettimeofday ()
                         })
                  | None -> ());
                let pending, duration_ms_tool = begin_effect ~tool_name:name ~input in
                let dispatch = finish_effect pending ~tool_name:name in
                observe_after_completion (fun () ->
                  match journal with
                  | Some j ->
                    Agent_execution_event_writer.append
                      j
                      (Tool_completed
                         { turn = Tool_contract.Invocation.turn invocation
                         ; tool_name = name
                         ; idempotency_key = idem_key
                         ; output_json = `String dispatch.result.content
                         ; is_error =
                             Types.tool_result_outcome_is_error dispatch.result.outcome
                         ; duration_ms = duration_ms_tool
                         ; timestamp = Unix.gettimeofday ()
                         })
                  | None -> ());
                dispatch)
          in
          completed_dispatch := Some dispatch;
          outcome ()
        with
        | Abort_tool_dispatch -> outcome ()
        | Hook_observer_raised (exception_, backtrace) ->
          record_caught_exception exception_ backtrace;
          outcome ()
        | exception_ ->
          let backtrace = Printexc.get_raw_backtrace () in
          record_caught_exception exception_ backtrace;
          outcome ()
      in
      settle_gate execute_admitted
  with
  | Hook_observer_raised (exception_, backtrace) ->
    record_caught_exception exception_ backtrace;
    outcome ()
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    record_caught_exception exception_ backtrace;
    outcome ()
;;

let execute_tools
      ~context
      ~tools
      ~(hooks : Hooks.hooks)
      ?tool_approval
      ~event_bus
      ?journal
      ~tracer
      ~agent_name
      ~turn_count
      ~(usage : Types.usage_stats)
      ?correlation_id
      ?run_id
      ?before_tool_execution
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
      tool_uses
  =
  let tool_index = build_index tools in
  let tool_use_blocks = Agent_tool_terminal_boundary.tool_use_blocks tool_uses in
  let durable = Option.map (fun provider ->
    provider, Execution_agent_scope.provider_invocations provider)
      (Execution_context.provider_attempt ()) in
  let scheduled =
    List.mapi (schedule_tool_use ~tool_index) tool_use_blocks
    |> List.map (restore_durable_tool ~turn_count ~durable)
  in
  let plan =
    Agent_tool_batch_plan.create
      ~execution_mode:(fun tool_use -> tool_use.execution_mode)
      ~completion:(fun tool_use -> tool_use.completion)
      scheduled
  in
  let run_one =
    execute_scheduled_tool
      ~context
      ~tools
      ~tool_index
      ~hooks
      ~event_bus
      ?tool_approval
      ?journal
      ~tracer
      ~agent_name
      ~turn_count
      ~usage
      ?correlation_id
      ?run_id
      ?on_tool_execution_started
      ?on_tool_execution_finished
      ?on_hook_invoked
  in
  let collect_batch (outcomes : scheduled_tool_outcome list) =
    let completed =
      List.filter_map
        (fun (outcome : scheduled_tool_outcome) ->
           Option.map (fun result -> outcome.index, result) outcome.completed_result)
        outcomes
    in
    let failure =
      List.fold_left
        (fun selected (outcome : scheduled_tool_outcome) ->
           match outcome.failure with
           | None -> selected
           | Some candidate -> prefer_failure selected candidate)
        None
        outcomes
    in
    let completion =
      List.fold_left
        (fun selected (outcome : scheduled_tool_outcome) ->
           match selected, outcome.completion with
           | (Terminal_completed _ | Terminal_failed _), _ -> selected
           | Continue_after_batch, candidate -> candidate)
        Continue_after_batch
        outcomes
    in
    completed, completion, failure
  in
  let ordered_results completed =
    completed
    |> List.sort (fun (left_index, _) (right_index, _) ->
      Int.compare left_index right_index)
    |> List.map snd
  in
  let run_scoped ~batch_index (group : scheduled_tool_use Agent_tool_batch_plan.scoped_group) =
    let outcomes = Array.of_list (List.map (fun _ -> Eio.Promise.create ()) group.nodes) in
    let known_failure : execution_failure_cause option Atomic.t = Atomic.make None in
    let run_node (node : scheduled_tool_use Agent_tool_batch_plan.scoped_node) =
      let predecessors = List.map (fun index ->
          let outcome, _ = outcomes.(index) in
          Eio.Promise.await outcome) node.predecessors in
      let predecessor_stopped = List.exists (function
        | Scoped_not_started -> true
        | Scoped_settled outcome -> Option.is_some outcome.failure) predecessors in
      (* Roots are the same admitted concurrent cohort as before. Successors
         acquire admission only after their actual resource predecessors and
         complete observers settle. Never start a new successor after a known
         failure; an already-started effect still settles under the Eio scope. *)
      let admitted = match node.predecessors with
        | [] -> true
        | _ :: _ -> not predecessor_stopped && Option.is_none (Atomic.get known_failure) in
      let outcome =
        if admitted then
          let batch_size = Agent_tool_batch_plan.Index_map.find
              node.batch_offset group.batch_sizes in
          let schedule = hook_schedule_of_tool_use
              ~batch_index:(batch_index + node.batch_offset) ~batch_size node.value in
          let result = run_one ~schedule node.value in
          Option.iter (fun failure ->
            ignore (Atomic.compare_and_set known_failure None (Some failure) : bool)) result.failure;
          Scoped_settled result
        else Scoped_not_started
      in
      let _, resolve = outcomes.(node.local_index) in
      Eio.Promise.resolve resolve outcome;
      outcome
    in
    Eio.Fiber.List.map run_node group.nodes
    |> List.filter_map (function Scoped_settled outcome -> Some outcome | Scoped_not_started -> None)
  in
  let rec run_batches batch_index completed completion = function
    | [] -> Ok { completed_results = ordered_results completed; completion }
    | batch :: rest ->
      let batch_results, next_batch_index =
        match batch with
        | Agent_tool_batch_plan.Serial_batch tool_use ->
          let schedule = hook_schedule_of_tool_use ~batch_index ~batch_size:1 tool_use in
          [ run_one ~schedule tool_use ], batch_index + 1
        | Agent_tool_batch_plan.Concurrent_batch tool_uses ->
          let batch_size = List.length tool_uses in
          let outcomes = tool_uses
          |> List.map (fun tool_use ->
            let schedule = hook_schedule_of_tool_use ~batch_index ~batch_size tool_use in
            tool_use, schedule)
          |> Eio.Fiber.List.map (fun (tool_use, schedule) -> run_one ~schedule tool_use) in
          outcomes, batch_index + 1
        | Agent_tool_batch_plan.Scoped_batch group ->
          run_scoped ~batch_index group,
          batch_index + Agent_tool_batch_plan.Index_map.cardinal group.batch_sizes
      in
      let batch_completed, batch_completion, failure = collect_batch batch_results in
      let completed = List.rev_append batch_completed completed in
      let completion =
        match completion, batch_completion with
        | (Terminal_completed _ | Terminal_failed _), _ -> completion
        | Continue_after_batch, candidate -> candidate
      in
      (match failure with
       | Some cause ->
         Error { completed_results = ordered_results completed; completion; cause }
       | None -> run_batches next_batch_index completed completion rest)
  in
  match plan with
  | Agent_tool_batch_plan.Rejected_terminal_mix scheduled ->
    let batch_size = List.length scheduled in
    Ok
      (Agent_tool_terminal_boundary.rejected_report
         ~turn:turn_count
         ~schedule:(hook_schedule_of_tool_use ~batch_index:0 ~batch_size)
         ~completion:(fun tool_use -> tool_use.completion)
         ~id:(fun tool_use -> tool_use.id)
         ~name:(fun tool_use -> tool_use.name)
         ~input:(fun tool_use -> tool_use.input)
         scheduled)
  | Agent_tool_batch_plan.Admitted batches when not
      (List.exists (fun call ->
        match Hashtbl.find_opt tool_index call.name with
        | Some tool -> Tool.has_scoped_admission tool
        | None -> false) scheduled) ->
    if batches <> [] then Option.iter (fun callback -> callback ()) before_tool_execution;
    run_batches 0 [] Continue_after_batch batches
  | Agent_tool_batch_plan.Admitted _ ->
    Eio.Switch.run @@ fun sw ->
    let prepared = List.map (prepare_scheduled_tool ~sw ~tool_index) scheduled in
    let prepared_plan =
      Agent_tool_batch_plan.create
        ~resource_scopes:(fun call ->
          match call.restored_invocation with
          | Some (Unattempted_invocation _ | Attempted_or_settled_invocation _) -> None
          | None -> Option.bind call.prepared_call Tool.prepared_call_scopes)
        ~execution_mode:(fun call -> call.execution_mode)
        ~completion:(fun call -> call.completion)
        prepared
    in
    (match prepared_plan with
     | Agent_tool_batch_plan.Rejected_terminal_mix rejected ->
       Ok
         (Agent_tool_terminal_boundary.rejected_report
            ~turn:turn_count
            ~schedule:(hook_schedule_of_tool_use ~batch_index:0 ~batch_size:(List.length rejected))
            ~completion:(fun call -> call.completion)
            ~id:(fun call -> call.id)
            ~name:(fun call -> call.name)
            ~input:(fun call -> call.input)
            rejected)
     | Agent_tool_batch_plan.Admitted batches ->
       if batches <> [] then Option.iter (fun callback -> callback ()) before_tool_execution;
       run_batches 0 [] Continue_after_batch batches)
;;

let recovered_batch_completion = Agent_tool_terminal_boundary.recovered_batch_completion
