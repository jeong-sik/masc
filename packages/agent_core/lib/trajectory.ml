(** Trajectory — structured agent execution trace.

    Bridges OAS {!Raw_trace} records into a higher-level execution model
    inspired by Deep Agents Harbor evaluation framework.

    A trajectory captures the full history of an agent run as a sequence
    of typed steps: Think, Act, Observe, Respond. This enables quantitative
    evaluation of agent behavior without replaying the run. *)

(* ── Tool call ──────────────────────────────────────────────── *)

type tool_call =
  { tool_use_id : string
  ; tool_name : string
  ; tool_input : Yojson.Safe.t
  ; tool_result : string option
  ; is_error : bool
  ; started_at : float
  ; finished_at : float option
  }

let show_tool_call tc =
  Printf.sprintf
    "tool_call(%s:%s started=%.3f error=%b)"
    tc.tool_use_id
    tc.tool_name
    tc.started_at
    tc.is_error
;;

let pp_tool_call fmt tc = Format.fprintf fmt "%s" (show_tool_call tc)

(* ── Step ───────────────────────────────────────────────────── *)

type step =
  | Think of
      { content : string
      ; ts : float
      }
  | Act of
      { tool_call : tool_call
      ; ts : float
      }
  | Observe of
      { content : string
      ; ts : float
      }
  | Respond of
      { content : string
      ; ts : float
      }

let show_step = function
  | Think { content; ts } ->
    Printf.sprintf "Think(%.3f, %d chars)" ts (String.length content)
  | Act { tool_call; ts } -> Printf.sprintf "Act(%.3f, %s)" ts tool_call.tool_name
  | Observe { content; ts } ->
    Printf.sprintf "Observe(%.3f, %d chars)" ts (String.length content)
  | Respond { content; ts } ->
    Printf.sprintf "Respond(%.3f, %d chars)" ts (String.length content)
;;

let pp_step fmt s = Format.fprintf fmt "%s" (show_step s)

let step_ts = function
  | Think { ts; _ } | Act { ts; _ } | Observe { ts; _ } | Respond { ts; _ } -> ts
;;

(* ── Trajectory ─────────────────────────────────────────────── *)

type trajectory =
  { agent_name : string
  ; model : string
  ; prompt : string
  ; steps : step list
  ; started_at : float
  ; finished_at : float option
  ; success : bool
  ; metrics : Eval.run_metrics option
  ; error : string option
  }

let show_trajectory t =
  let n_think, n_act, n_observe, n_respond =
    List.fold_left
      (fun (th, ac, ob, re) step ->
         match step with
         | Think _ -> th + 1, ac, ob, re
         | Act _ -> th, ac + 1, ob, re
         | Observe _ -> th, ac, ob + 1, re
         | Respond _ -> th, ac, ob, re + 1)
      (0, 0, 0, 0)
      t.steps
  in
  Printf.sprintf
    "trajectory(agent=%s model=%s steps=%d [T=%d A=%d O=%d R=%d] success=%b)"
    t.agent_name
    t.model
    (List.length t.steps)
    n_think
    n_act
    n_observe
    n_respond
    t.success
;;

let pp_trajectory fmt t = Format.fprintf fmt "%s" (show_trajectory t)

(* ── Build from Raw_trace records ───────────────────────────── *)

(** Accumulator for pairing tool-start with tool-finish records. *)
type tool_acc =
  { id : string
  ; name : string
  ; input : Yojson.Safe.t
  ; started_at : float
  }

module StringMap = Map.Make (String)

type parser_state =
  { p_agent_name : string
  ; p_model : string
  ; p_prompt : string
  ; p_started_at : float
  ; p_finished_at : float option
  ; p_success : bool
  ; p_error_msg : string option
  ; p_pending_tools : tool_acc StringMap.t
  ; p_steps : step list
  }

let initial_state =
  { p_agent_name = "unknown"
  ; p_model = "unknown"
  ; p_prompt = ""
  ; p_started_at = 0.0
  ; p_finished_at = None
  ; p_success = true
  ; p_error_msg = None
  ; p_pending_tools = StringMap.empty
  ; p_steps = []
  }
;;

let of_raw_trace_records (records : Raw_trace.record list) : trajectory =
  let final_state =
    List.fold_left
      (fun st (r : Raw_trace.record) ->
         match r.record_type with
         | Run_started ->
           let p_prompt =
             match r.prompt with
             | Some p -> p
             | None -> st.p_prompt
           in
           let p_model =
             match r.model with
             | Some model -> model
             | None -> st.p_model
           in
           { st with p_agent_name = r.agent_name; p_model; p_started_at = r.ts; p_prompt }
         | Assistant_block ->
           (match r.block_kind with
            | Some "thinking" ->
              let content =
                match r.assistant_block with
                | Some json ->
                  (try Yojson.Safe.Util.(json |> member "content" |> to_string) with
                   | Yojson.Safe.Util.Type_error _ | Not_found ->
                     (try Yojson.Safe.Util.(json |> member "thinking" |> to_string) with
                      | Yojson.Safe.Util.Type_error _ | Not_found ->
                        Yojson.Safe.to_string json))
                | None -> ""
              in
              { st with p_steps = Think { content; ts = r.ts } :: st.p_steps }
            | Some "text" ->
              let content =
                match r.assistant_block with
                | Some json ->
                  (try Yojson.Safe.Util.(json |> member "text" |> to_string) with
                   | Yojson.Safe.Util.Type_error _ | Not_found ->
                     Yojson.Safe.to_string json)
                | None -> ""
              in
              { st with p_steps = Respond { content; ts = r.ts } :: st.p_steps }
            | Some "tool_use" -> st
            | _ -> st)
         | Tool_execution_started ->
           let tool_use_id = Option.value ~default:"" r.tool_use_id in
           let tool_name = Option.value ~default:"unknown" r.tool_name in
           let tool_input = Option.value ~default:`Null r.tool_input in
           let acc =
             { id = tool_use_id; name = tool_name; input = tool_input; started_at = r.ts }
           in
           { st with p_pending_tools = StringMap.add tool_use_id acc st.p_pending_tools }
         | Tool_execution_finished ->
           let tool_use_id = Option.value ~default:"" r.tool_use_id in
           let is_error = Option.value ~default:false r.tool_error in
           let tool_result = r.tool_result in
           (match StringMap.find_opt tool_use_id st.p_pending_tools with
            | Some acc ->
              let tc =
                { tool_use_id
                ; tool_name = acc.name
                ; tool_input = acc.input
                ; tool_result
                ; is_error
                ; started_at = acc.started_at
                ; finished_at = Some r.ts
                }
              in
              let act_step = Act { tool_call = tc; ts = acc.started_at } in
              let obs_steps =
                match tool_result with
                | Some result when result <> "" ->
                  [ Observe { content = result; ts = r.ts } ]
                | _ -> []
              in
              { st with
                p_steps = obs_steps @ (act_step :: st.p_steps)
              ; p_pending_tools = StringMap.remove tool_use_id st.p_pending_tools
              }
            | None ->
              let tool_name = Option.value ~default:"unknown" r.tool_name in
              let tc =
                { tool_use_id
                ; tool_name
                ; tool_input = `Null
                ; tool_result
                ; is_error
                ; started_at = r.ts
                ; finished_at = Some r.ts
                }
              in
              { st with p_steps = Act { tool_call = tc; ts = r.ts } :: st.p_steps })
         | Run_finished ->
           let p_success, p_error_msg =
             match r.error with
             | Some e -> false, Some e
             | None -> st.p_success, st.p_error_msg
           in
           let st' = { st with p_finished_at = Some r.ts; p_success; p_error_msg } in
           (match r.final_text with
            | Some text when text <> "" ->
              let already_has_final =
                List.exists
                  (function
                    | Respond { content; _ } -> content = text
                    | _ -> false)
                  st.p_steps
              in
              if not already_has_final
              then
                { st' with
                  p_steps = Respond { content = text; ts = r.ts } :: st'.p_steps
                }
              else st'
            | _ -> st')
         | Hook_invoked -> st)
      initial_state
      records
  in
  let pending_steps =
    StringMap.fold
      (fun _id acc steps ->
         let tc =
           { tool_use_id = acc.id
           ; tool_name = acc.name
           ; tool_input = acc.input
           ; tool_result = None
           ; is_error = false
           ; started_at = acc.started_at
           ; finished_at = None
           }
         in
         Act { tool_call = tc; ts = acc.started_at } :: steps)
      final_state.p_pending_tools
      final_state.p_steps
  in
  let sorted_steps =
    List.sort (fun a b -> Float.compare (step_ts a) (step_ts b)) pending_steps
  in
  { agent_name = final_state.p_agent_name
  ; model = final_state.p_model
  ; prompt = final_state.p_prompt
  ; steps = sorted_steps
  ; started_at = final_state.p_started_at
  ; finished_at = final_state.p_finished_at
  ; success = final_state.p_success
  ; metrics = None
  ; error = final_state.p_error_msg
  }
;;

(* ── JSON serialization ─────────────────────────────────────── *)

let tool_call_to_json tc =
  `Assoc
    [ "tool_use_id", `String tc.tool_use_id
    ; "tool_name", `String tc.tool_name
    ; "tool_input", tc.tool_input
    ; ( "tool_result"
      , match tc.tool_result with
        | Some r -> `String r
        | None -> `Null )
    ; "is_error", `Bool tc.is_error
    ; "started_at", `Float tc.started_at
    ; ( "finished_at"
      , match tc.finished_at with
        | Some f -> `Float f
        | None -> `Null )
    ]
;;

let tool_call_of_json json =
  let open Yojson.Safe.Util in
  try
    Ok
      { tool_use_id = json |> member "tool_use_id" |> to_string
      ; tool_name = json |> member "tool_name" |> to_string
      ; tool_input = json |> member "tool_input"
      ; tool_result = json |> member "tool_result" |> to_string_option
      ; is_error = json |> member "is_error" |> to_bool
      ; started_at = json |> member "started_at" |> to_float
      ; finished_at =
          (match json |> member "finished_at" with
           | `Null -> None
           | j -> Some (to_float j))
      }
  with
  | Type_error (msg, _) -> Error msg
;;

let step_to_json = function
  | Think { content; ts } ->
    `Assoc [ "type", `String "think"; "content", `String content; "ts", `Float ts ]
  | Act { tool_call; ts } ->
    `Assoc
      [ "type", `String "act"; "tool_call", tool_call_to_json tool_call; "ts", `Float ts ]
  | Observe { content; ts } ->
    `Assoc [ "type", `String "observe"; "content", `String content; "ts", `Float ts ]
  | Respond { content; ts } ->
    `Assoc [ "type", `String "respond"; "content", `String content; "ts", `Float ts ]
;;

let step_of_json json =
  let open Yojson.Safe.Util in
  try
    let ts = json |> member "ts" |> to_float in
    match json |> member "type" |> to_string with
    | "think" ->
      let content = json |> member "content" |> to_string in
      Ok (Think { content; ts })
    | "act" ->
      let tc_json = json |> member "tool_call" in
      (match tool_call_of_json tc_json with
       | Ok tool_call -> Ok (Act { tool_call; ts })
       | Error e -> Error e)
    | "observe" ->
      let content = json |> member "content" |> to_string in
      Ok (Observe { content; ts })
    | "respond" ->
      let content = json |> member "content" |> to_string in
      Ok (Respond { content; ts })
    | other -> Error (Printf.sprintf "unknown step type: %s" other)
  with
  | Type_error (msg, _) -> Error msg
;;

let to_json t =
  `Assoc
    [ "agent_name", `String t.agent_name
    ; "model", `String t.model
    ; "prompt", `String t.prompt
    ; "steps", `List (List.map step_to_json t.steps)
    ; "started_at", `Float t.started_at
    ; ( "finished_at"
      , match t.finished_at with
        | Some f -> `Float f
        | None -> `Null )
    ; "success", `Bool t.success
    ; ( "metrics"
      , match t.metrics with
        | Some m -> Eval.run_metrics_to_yojson m
        | None -> `Null )
    ; ( "error"
      , match t.error with
        | Some e -> `String e
        | None -> `Null )
    ]
;;

let of_json json =
  let open Yojson.Safe.Util in
  try
    let steps_json = json |> member "steps" |> to_list in
    let steps_result =
      List.fold_left
        (fun acc j ->
           match acc with
           | Error _ as e -> e
           | Ok ss ->
             (match step_of_json j with
              | Ok s -> Ok (s :: ss)
              | Error e -> Error e))
        (Ok [])
        steps_json
    in
    match steps_result with
    | Error e -> Error e
    | Ok steps ->
      Ok
        { agent_name = json |> member "agent_name" |> to_string
        ; model = json |> member "model" |> to_string
        ; prompt = json |> member "prompt" |> to_string
        ; steps = List.rev steps
        ; started_at = json |> member "started_at" |> to_float
        ; finished_at =
            (match json |> member "finished_at" with
             | `Null -> None
             | j -> Some (to_float j))
        ; success = json |> member "success" |> to_bool
        ; metrics = None
        ; (* Metrics not round-tripped for simplicity *)
          error = json |> member "error" |> to_string_option
        }
  with
  | Type_error (msg, _) -> Error msg
;;

(* ── Step count ─────────────────────────────────────────────── *)

let count_steps t =
  List.fold_left
    (fun (th, ac, ob, re) step ->
       match step with
       | Think _ -> th + 1, ac, ob, re
       | Act _ -> th, ac + 1, ob, re
       | Observe _ -> th, ac, ob + 1, re
       | Respond _ -> th, ac, ob, re + 1)
    (0, 0, 0, 0)
    t.steps
;;

(* ── Derived metrics ────────────────────────────────────────── *)

let total_tool_calls t =
  List.length
    (List.filter
       (function
         | Act _ -> true
         | _ -> false)
       t.steps)
;;

let tool_error_count t =
  List.length
    (List.filter
       (function
         | Act { tool_call; _ } -> tool_call.is_error
         | _ -> false)
       t.steps)
;;

let elapsed_s t =
  match t.finished_at with
  | Some f -> Some (f -. t.started_at)
  | None -> None
;;
