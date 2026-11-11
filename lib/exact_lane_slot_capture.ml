module Observation = Exact_lane_slot_observation
module Cli = Keeper_lane_cli_oneshot
type t = { owner : Runtime_schema.exact_lane_owner option; mutable visits : Observation.t list option }
let create ?owner () = {owner;visits=None}
let key : t Eio.Fiber.key = Eio.Fiber.create_key ()
let with_capture capture run = Eio.Fiber.with_binding key capture run
let observations capture = Option.map (fun visits ->
  List.rev_map (fun visit -> match capture.owner with
    | None -> visit | Some owner -> Observation.with_owner owner visit) visits) capture.visits
let record observations = match Eio.Fiber.get key with
  | None -> ()
  | Some capture -> capture.visits <- Some
      (List.rev_append observations (Option.value capture.visits ~default:[]))
let flow attempt run = match run () with
  | result -> record (Observation.of_result result); result
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    record (Observation.of_evidence (Agent_core.Exact_output.flow_attempt_evidence attempt));
    Printexc.raise_with_backtrace exn backtrace
let slot_of_failure = function
  | Cli.Unknown_runtime {runtime_id} | Not_an_official_client {runtime_id}
  | Execution_failed {runtime_id;_} | Invalid_json_output {runtime_id;_}
  | Invalid_domain_output {runtime_id;_} | Held {runtime_id;_} -> runtime_id
let cli_outcome ~slot_id outcome = match Eio.Fiber.get key with
  | None -> ()
  | Some capture ->
    let rec update = function
      | [] -> []
      | (visit:Observation.t)::rest ->
        if visit.slot_id=slot_id then
          Observation.cli ~slot_id ~started_at:visit.started_at ~finished_at:visit.finished_at
            ~generation_dispatched:visit.generation_dispatched ~outcome :: rest
        else visit::update rest in
    capture.visits <- Option.map update capture.visits
let cli_capture ?observe () =
  let started=ref [] in
  let observe event =
    Option.iter (fun observe -> observe event) observe;
    match event with
    | Cli.Dispatching {runtime_id} -> started := (runtime_id,Time_compat.now ())::!started
    | Raw_response _ -> () in
  let finish ~slot_id ~outcome =
    let started_at=List.assoc_opt slot_id !started in
    started := List.remove_assoc slot_id !started;
    record [Observation.cli ~slot_id ~started_at
      ~finished_at:(Option.map (fun _ -> Time_compat.now ()) started_at)
      ~generation_dispatched:(Option.is_some started_at) ~outcome] in
  let failed failure = finish ~slot_id:(slot_of_failure failure)
    ~outcome:(Observation.Cli_failed (Keeper_exact_walk_failure.cli_observation failure)) in
  let interrupted () = List.iter (fun (slot_id,at) ->
    record [Observation.cli ~slot_id ~started_at:(Some at) ~finished_at:None
      ~generation_dispatched:true ~outcome:Unresolved]) !started in
  observe,finish,failed,interrupted
let walk_cli ?runner ?observe ~base_dir ~cli_slots ~system_prompt ~requirement ~prompt ~validate ~on_failure () =
  let observe,finish,failed,interrupted=cli_capture ?observe () in
  match Cli.walk ?runner ~observe ~base_dir ~cli_slots ~system_prompt ~requirement ~prompt ~validate
    ~on_failure:(fun failure -> failed failure; on_failure failure) () with
  | Ok (slot,value) -> finish ~slot_id:slot ~outcome:Accepted; Ok (slot,value)
  | Error failures -> Error failures
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    interrupted (); Printexc.raise_with_backtrace exn backtrace
let run_cli ?runner ?observe ~base_dir ~runtime_id ~system_prompt ~requirement ~prompt () =
  let observe,finish,failed,interrupted=cli_capture ?observe () in
  match Cli.run ?runner ~observe ~base_dir ~runtime_id ~system_prompt ~requirement ~prompt () with
  | Ok value -> finish ~slot_id:runtime_id ~outcome:Unresolved; Ok value
  | Error failure -> failed failure; Error failure
  | exception exn ->
    let backtrace=Printexc.get_raw_backtrace () in
    interrupted (); Printexc.raise_with_backtrace exn backtrace
