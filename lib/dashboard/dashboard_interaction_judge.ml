open Eio.Std

let keeper_name = "interaction-judge"
let prompt_dashboard_interaction_judge = "dashboard_interaction_judge"

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
  mutable started : bool;
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
              mu = Eio.Mutex.create ();
              started = false;
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
  Prompt_registry.render_prompt_template prompt_dashboard_interaction_judge
    [ ("facts_json", Yojson.Safe.to_string facts_json) ]
  |> Result.map_error (fun msg ->
         Agent_sdk.Error.Internal
           ("dashboard_interaction_judge prompt render failed: " ^ msg))

let compute_judgments ~base_path ~build_facts =
  let runtime_id = Runtime.get_default_runtime_id () in
  Masc_oas_bridge.run_with_caller
    ~caller:Env_config_oas_bridge.Operator_judge
    (fun () ->
      let factual_json = build_facts () in
      match prompt_for_facts factual_json with
      | Error err -> Error err
      | Ok prompt ->
          Keeper_turn_driver_wrappers.run_named_with_masc_tools ~runtime_id
            ~base_path ~goal:prompt ~masc_tools:[]
            ~dispatch:(fun ~name ~args:_ ->
              Tool_result.error ~tool_name:name ~start_time:0.0 "no tools")
            ~accept:Keeper_tool_response.response_has_text_or_tool_progress
            ~approval:Approval_callbacks.auto_approve ())

let refresh_once ~base_path st build_facts =
  Eio_guard.with_mutex st.mu (fun () ->
    st.snapshot <- { st.snapshot with refreshing = true; last_error = None }
  );
  match compute_judgments ~base_path ~build_facts with
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

let start ~sw ~clock ~base_path ~build_facts =
  let st = get_state base_path in
  (* Idempotency: 같은 base_path 에 start 가 두 번 호출되면 두 fiber 가 동시에
     폴링하며 LLM 을 중복 청구한다(operator_judge 의 started 플래그 패턴). st.mu
     안에서 started CAS 로 한 번만 fork_daemon 한다(crash 복구에 유리). *)
  let should_start =
    Eio_guard.with_mutex st.mu (fun () ->
      if st.started then false else (st.started <- true; true))
  in
  if should_start then begin
    (* switch 종료 시 state 를 정리해 module-level Hashtbl 이 무한 성장하지 않게.
       remove 도 outer_mu 안에서 get_state 와 직렬화한다. *)
    Eio.Switch.on_release sw (fun () ->
      Eio_guard.with_mutex outer_mu (fun () -> Hashtbl.remove states base_path));
    Eio.Fiber.fork_daemon ~sw (fun () ->
      let rec loop () =
        Eio.Fiber.check ();
        Eio.Time.sleep clock 60.0;
        refresh_once ~base_path st build_facts;
        loop ()
      in
      refresh_once ~base_path st build_facts;
      loop ())
  end
