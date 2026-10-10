open Keeper_approval_queue_rules_types

let summary_version = current_hitl_context_summary_version

(* The fields that identify a request - keeper, tool, complete input, and
   task/goal linkage - are present on every pending approval. Outer-turn
   context is an accuracy aid that a request raised outside a Keeper turn
   structurally cannot carry, so its absence is reported to the judge as
   [partial_context] instead of ending the attempt. *)
(* The judge is shown what the Keeper did, not what it told itself while
   deciding to. [thinking] blocks are the Keeper's own reasoning, and they are
   dropped here for two reasons.

   Size: measured 2026-08-27 on the live queue, they were 23.2 kB of an 85.6 kB
   bundle for one keeper -- 51% of the message blocks -- while the call actually
   being judged was 2.5 kB. Every pending approval carries its own copy, so one
   Keeper with five of them sent the same reasoning five times.

   Independence: a Keeper's reasoning is where it argues for what it is about
   to do. The live sample carried "I MUST STOP this immediately" as a
   self-instruction, and a judge reading that is being asked to weigh the
   Keeper's account of itself rather than the request. What the Keeper actually
   did is still there in [text], [tool_use] and [tool_result].

   Dropped at the bundle rather than at write time: the durable entry keeps
   what the turn carried, and only the prompt is narrowed. The count is
   reported so a judge reading a thin bundle can tell trimming from a turn that
   never reasoned. *)
let thinking_block = function
  | `Assoc fields -> (
    match List.assoc_opt "type" fields with
    | Some (`String "thinking") -> true
    | Some _ | None -> false)
  | `Bool _ | `Float _ | `Int _ | `Intlit _ | `List _ | `Null | `String _ -> false
;;

(* Newest first, because a constraint a Keeper set for itself is the one it
   just wrote down. The messages arrive oldest-first, so the budget is spent
   walking them backwards and the survivors are marked before the forward pass
   rewrites each message. Physical identity is the mark: two thinking blocks
   with the same text are still two blocks, and keeping "the newest one" has to
   mean the one that is newest. *)
let newest_thinking_blocks ~keep messages =
  if keep <= 0
  then []
  else
    List.fold_left
      (fun kept message ->
        if List.length kept >= keep
        then kept
        else
          match message with
          | `Assoc fields -> (
            match List.assoc_opt "content_blocks" fields with
            | Some (`List blocks) ->
              List.fold_left
                (fun kept block ->
                  if List.length kept >= keep || not (thinking_block block)
                  then kept
                  else block :: kept)
                kept (List.rev blocks)
            | Some _ | None -> kept)
          | _ -> kept)
      [] (List.rev messages)
;;

let drop_thinking_blocks ?(keep_newest = 0) context =
  let dropped = ref 0 in
  let survivors =
    match context with
    | `Assoc fields -> (
      match List.assoc_opt "initial" fields with
      | Some (`Assoc initial) -> (
        match List.assoc_opt "history_messages" initial with
        | Some (`List messages) -> newest_thinking_blocks ~keep:keep_newest messages
        | Some _ | None -> [])
      | Some _ | None -> [])
    | _ -> []
  in
  let survives block = List.exists (fun kept -> kept == block) survivors in
  let strip_message = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             match key, value with
             | "content_blocks", `List blocks ->
               let kept =
                 List.filter (fun b -> (not (thinking_block b)) || survives b) blocks
               in
               dropped := !dropped + (List.length blocks - List.length kept);
               key, `List kept
             | _ -> key, value)
           fields)
    | other -> other
  in
  let strip_initial = function
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             match key, value with
             | "history_messages", `List messages ->
               key, `List (List.map strip_message messages)
             | _ -> key, value)
           fields)
    | other -> other
  in
  let stripped =
    (* Only the one path this shape defines. A context that does not have it is
       carried through unchanged rather than walked for anything that looks
       like a block: guessing at the shape is how a field nobody meant to
       touch gets rewritten. *)
    match context with
    | `Assoc fields ->
      `Assoc
        (List.map
           (fun (key, value) ->
             if String.equal key "initial" then key, strip_initial value
             else key, value)
           fields)
    | other -> other
  in
  stripped, !dropped
;;

let project_context_bundle ~host_context ~keep_newest ~(entry : pending_approval) =
  let request_identity =
    [ "keeper_name", `String entry.keeper_name
    ; "tool_name", `String entry.tool_name
    ; "turn_id", Json_util.int_opt_to_json entry.turn_id
    ; "task_id", Json_util.string_opt_to_json entry.task_id
    ; "goal_id", Json_util.string_opt_to_json entry.goal_id
    ; "input", entry.input
    ]
    @
    (* RFC-0422 §3.3: when the Gate ran the request boxed first, the judge is
       shown what the box refused -- the status and the program's own stderr
       -- rather than left to infer what the request would do. Absent when no
       box ran, so a judge can tell "nothing was tried" from "it was tried
       and said nothing". *)
    match entry.observation with
    | Some refusal ->
      [ "observation", Keeper_approval_queue_rules_types.observed_refusal_to_yojson refusal ]
    | None -> []
  in
  match entry.request_context with
  | Some request_context ->
    let request_context, thinking_dropped =
      drop_thinking_blocks
        ~keep_newest
        request_context
    in
    `Assoc
      (request_identity
       @ [ "partial_context", `Bool false
         ; "thinking_blocks_omitted", `Int thinking_dropped
         ; "host_context", host_context
         ; "request_context", request_context
         ])
  | None ->
    `Assoc
      (request_identity
       @ [ "partial_context", `Bool true
         ; "host_context", host_context
         ])
;;

let capture_context_bundle ~(entry : pending_approval) =
  let host_context = Keeper_gate_host_context.for_approval entry in
  let keep_newest =
    match entry.request_context with
    | Some _ -> Keeper_config.keeper_hitl_thinking_blocks ()
    | None -> 0
  in
  project_context_bundle ~host_context ~keep_newest ~entry
;;

(* ── MASC domain validation ─────────────────────── *)

let parse_summary ~generated_at ~model_run_id json =
  match json with
  | `Assoc fields ->
    hitl_context_summary_of_yojson_with_error
      (`Assoc
         ([ "summary_version", `Int summary_version
          ; "generated_at", `Float generated_at
          ; "model_run_id", `String model_run_id
          ]
          @ fields))
  | _ -> Error "HITL summary model output must be a JSON object"
;;
