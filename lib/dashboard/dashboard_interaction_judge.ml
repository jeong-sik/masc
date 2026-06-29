open Eio.Std

let keeper_name = "interaction-judge"

type interaction = {
  source : string;
  target : string;
  strength : float;
  reasoning : string;
} [@@deriving yojson]

type judge_response = {
  stigmergy : (string * float) list; (* We will parse the assoc list manually if needed, or just let yojson do it if we use Yojson.Safe.Util *)
  interactions : interaction list;
} (* custom parser *)

let parse_judge_response (json : Yojson.Safe.t) : (judge_response, string) result =
  let open Yojson.Safe.Util in
  try
    let stigmergy_assoc = member "stigmergy" json |> to_assoc in
    let stigmergy = List.map (fun (k, v) -> (k, to_float v)) stigmergy_assoc in
    let interactions_json = member "interactions" json |> to_list in
    let interactions =
      List.map (fun j ->
        match interaction_of_yojson j with
        | Ok i -> i
        | Error e -> failwith e
      ) interactions_json
    in
    Ok { stigmergy; interactions }
  with
  | Type_error (msg, _) -> Error ("Type error: " ^ msg)
  | Failure msg -> Error ("Parse failure: " ^ msg)

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
  mu : Eio.Mutex.t;
  cond : Eio.Condition.t;
  mutable snapshot : runtime_snapshot;
  mutable last_json : Yojson.Safe.t;
  mutable pending_refresh : bool;
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
              mu = Eio.Mutex.create ();
              cond = Eio.Condition.create ();
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
              pending_refresh = false;
            }
          in
          Hashtbl.replace states base_path s;
          s)

let runtime_status base_path =
  let st = get_state base_path in
  Eio_guard.with_mutex st.mu (fun () -> st.snapshot)

let fresh_interactions_json ~base_path =
  let st = get_state base_path in
  Eio_guard.with_mutex st.mu (fun () ->
    `Assoc [
      ("judge_online", `Bool st.snapshot.judge_online);
      ("refreshing", `Bool st.snapshot.refreshing);
      ("last_error", match st.snapshot.last_error with Some e -> `String e | None -> `Null);
      ("data", st.last_json)
    ]
  )

let prompt_for_facts facts_json =
  let facts_str = Yojson.Safe.to_string facts_json in
  let template =
    In_channel.with_open_text "config/prompts/dashboard_interaction_judge.md" In_channel.input_all
  in
  Printf.sprintf "%s\n\nFacts:\n%s" template facts_str

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
  Eio_guard.with_mutex st.mu (fun () ->
    st.snapshot <- { st.snapshot with refreshing = true; last_error = None }
  );
  match compute_judgments ~build_facts with
  | Ok result ->
      let text = Agent_sdk_response.text_of_response result.Runtime_agent.response in
      (match Llm_provider.Lenient_json.parse text with
      | `Assoc _ as parsed ->
          (match parse_judge_response parsed with
          | Ok _ ->
              Eio_guard.with_mutex st.mu (fun () ->
                st.last_json <- parsed;
                st.snapshot <- { st.snapshot with 
                  judge_online = true; 
                  refreshing = false; 
                  generated_at = Some (Masc_domain.now_iso ());
                  model_used = Some result.Runtime_agent.response.model;
                  last_error = None;
                }
              )
          | Error e ->
              Eio_guard.with_mutex st.mu (fun () ->
                st.snapshot <- { st.snapshot with refreshing = false; last_error = Some ("invalid judge schema: " ^ e) }
              ))
      | _ ->
          Eio_guard.with_mutex st.mu (fun () ->
            st.snapshot <- { st.snapshot with refreshing = false; last_error = Some "invalid json schema from judge" }
          )
      | exception e ->
          Eio_guard.with_mutex st.mu (fun () ->
            st.snapshot <- { st.snapshot with refreshing = false; last_error = Some ("parse error: " ^ Printexc.to_string e) }
          ))
  | Error err ->
      Eio_guard.with_mutex st.mu (fun () ->
        st.snapshot <- { st.snapshot with refreshing = false; last_error = Some (Agent_sdk.Error.to_string err) }
      )

let notify_activity ~base_path =
  let st = get_state base_path in
  Eio_guard.with_mutex st.mu (fun () ->
    st.pending_refresh <- true;
    Eio.Condition.broadcast st.cond
  )

let start ~sw ~clock:_ ~base_path ~build_facts =
  let st = get_state base_path in
  Eio.Fiber.fork ~sw (fun () ->
    let rec loop () =
      Eio_guard.with_mutex st.mu (fun () ->
        while not st.pending_refresh do
          Eio.Condition.await st.cond st.mu
        done;
        st.pending_refresh <- false
      );
      Eio.Fiber.check ();
      refresh_once st build_facts;
      loop ()
    in
    refresh_once st build_facts;
    loop ()
  )
