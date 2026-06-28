open Eio.Std

let keeper_name = "interaction-judge"

type runtime_snapshot = {
  enabled : bool;
  judge_online : bool;
  refreshing : bool;
  generated_at : string option;
  expires_at : string option;
  model_used : string option;
  keeper_name : string;
  last_error : string option;
}

type state = {
  mutable snapshot : runtime_snapshot;
  mutable last_json : Yojson.Safe.t;
}

let states : (string, state) Hashtbl.t = Hashtbl.create 4
let outer_mu = Eio.Mutex.create ()

let get_state base_path =
  Eio_guard.with_mutex outer_mu (fun () ->
      match Hashtbl.find_opt states base_path with
      | Some s -> s
      | None ->
          let s =
            {
              snapshot = {
                enabled = true;
                judge_online = false;
                refreshing = false;
                generated_at = None;
                expires_at = None;
                model_used = None;
                keeper_name;
                last_error = None;
              };
              last_json = `Assoc [("stigmergy", `Assoc []); ("interactions", `List [])];
            }
          in
          Hashtbl.replace states base_path s;
          s)

let runtime_status base_path =
  let st = get_state base_path in
  st.snapshot

let fresh_interactions_json ~base_path =
  let st = get_state base_path in
  st.last_json

let prompt_for_facts facts_json =
  let facts_str = Yojson.Safe.to_string facts_json in
  Printf.sprintf 
    "You are the MASC Interaction Judge. Analyze the following workspace facts and logs:\n%s\n\n\
    Evaluate two things based on the facts:\n\
    1. Stigmergy Intensity (0.0 to 1.0): How much did each Keeper's actions alter the shared environment/tasks?\n\
    2. Interaction Strength (0.0 to 1.0): How deeply did Keepers collaborate on shared tasks or context?\n\n\
    Output MUST be valid JSON matching this schema:\n\
    {\n\
      \"stigmergy\": { \"keeperName\": 0.85, ... },\n\
      \"interactions\": [\n\
        { \"source\": \"keeperA\", \"target\": \"keeperB\", \"strength\": 0.9, \"reasoning\": \"...\" }\n\
      ]\n\
    }" facts_str

let compute_judgments ~build_facts =
  let runtime_id = Runtime.get_default_runtime_id () in
  Masc_oas_bridge.run_with_caller ~caller:Env_config_oas_bridge.Operator_judge (fun () ->
    let factual_json = build_facts () in
    let prompt = prompt_for_facts factual_json in
    Keeper_turn_driver_wrappers.run_named_with_masc_tools ~runtime_id
      ~goal:prompt ~masc_tools:[] ~dispatch:(fun ~name ~args:_ -> Tool_result.error ~tool_name:name ~start_time:0.0 "no tools")
      ~accept:Keeper_tool_response.response_has_text_or_tool_progress
      ~approval:Approval_callbacks.auto_approve
      ()
  )

let refresh_once st build_facts =
  st.snapshot <- { st.snapshot with refreshing = true; last_error = None };
  match compute_judgments ~build_facts with
  | Ok result ->
      let text = Agent_sdk_response.text_of_response result.Runtime_agent.response in
      (match Llm_provider.Lenient_json.parse text with
      | `Assoc _ as parsed ->
          st.last_json <- parsed;
          st.snapshot <- { st.snapshot with 
            judge_online = true; 
            refreshing = false; 
            generated_at = Some (Masc_domain.now_iso ());
            model_used = Some result.Runtime_agent.response.model;
          }
      | _ ->
          st.snapshot <- { st.snapshot with refreshing = false; last_error = Some "invalid json schema from judge" }
      | exception _ ->
          st.snapshot <- { st.snapshot with refreshing = false; last_error = Some "parse error from judge" })
  | Error err ->
      st.snapshot <- { st.snapshot with refreshing = false; last_error = Some (Agent_sdk.Error.to_string err) }

let start ~sw ~clock ~base_path ~build_facts =
  let st = get_state base_path in
  Eio.Fiber.fork ~sw (fun () ->
    while true do
      Eio.Time.sleep clock 600.0;
      refresh_once st build_facts
    done
  )
