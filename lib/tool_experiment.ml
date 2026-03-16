(** Social Experiment tools - Hypothesis-driven A/B testing for agent behaviors.

    Implements the Social Experiment model from the Cross-Session Protocol:
    experiment_created, experiment_assignment, experiment_observation,
    experiment_checkpoint, experiment_concluded.

    Storage: file-based under .masc/experiments/ (one JSON per experiment). *)

open Tool_args

(* {1 Types} *)

type context = {
  config : Room.config;
  agent_name : string;
}

type result = bool * string

type group = Treatment | Control

type experiment_status = Running | Concluded

type observation = {
  subject_id : string;
  metric_name : string;
  value : float;
  timestamp : float;
}

type assignment = {
  subject_id : string;
  group : group;
  timestamp : float;
}

type experiment = {
  id : string;
  hypothesis : string;
  treatment_desc : string;
  control_desc : string;
  metrics : string list;
  window_seconds : float;
  status : experiment_status;
  assignments : assignment list;
  observations : observation list;
  created_at : float;
}

(* {1 Serialization} *)

let group_to_string = function Treatment -> "treatment" | Control -> "control"

let group_of_string = function
  | "treatment" -> Treatment
  | "control" -> Control
  | s -> invalid_arg (Printf.sprintf "Unknown group: %s" s)

let status_to_string = function Running -> "running" | Concluded -> "concluded"

let status_of_string = function
  | "running" -> Running
  | "concluded" -> Concluded
  | s -> invalid_arg (Printf.sprintf "Unknown status: %s" s)

let assignment_to_yojson (a : assignment) : Yojson.Safe.t =
  `Assoc [
    ("subject_id", `String a.subject_id);
    ("group", `String (group_to_string a.group));
    ("timestamp", `Float a.timestamp);
  ]

let assignment_of_yojson (json : Yojson.Safe.t) : assignment =
  let open Yojson.Safe.Util in
  let subject_id = json |> member "subject_id" |> to_string in
  let group = json |> member "group" |> to_string |> group_of_string in
  let timestamp = json |> member "timestamp" |> to_float in
  { subject_id; group; timestamp }

let observation_to_yojson (o : observation) : Yojson.Safe.t =
  `Assoc [
    ("subject_id", `String o.subject_id);
    ("metric_name", `String o.metric_name);
    ("value", `Float o.value);
    ("timestamp", `Float o.timestamp);
  ]

let observation_of_yojson (json : Yojson.Safe.t) : observation =
  let open Yojson.Safe.Util in
  let subject_id = json |> member "subject_id" |> to_string in
  let metric_name = json |> member "metric_name" |> to_string in
  let value = json |> member "value" |> to_float in
  let timestamp = json |> member "timestamp" |> to_float in
  { subject_id; metric_name; value; timestamp }

let experiment_to_yojson (e : experiment) : Yojson.Safe.t =
  `Assoc [
    ("id", `String e.id);
    ("hypothesis", `String e.hypothesis);
    ("treatment_description", `String e.treatment_desc);
    ("control_description", `String e.control_desc);
    ("metrics", `List (List.map (fun m -> `String m) e.metrics));
    ("window_seconds", `Float e.window_seconds);
    ("status", `String (status_to_string e.status));
    ("assignments", `List (List.map assignment_to_yojson e.assignments));
    ("observations", `List (List.map observation_to_yojson e.observations));
    ("created_at", `Float e.created_at);
  ]

let experiment_of_yojson (json : Yojson.Safe.t) : experiment =
  let open Yojson.Safe.Util in
  let id = json |> member "id" |> to_string in
  let hypothesis = json |> member "hypothesis" |> to_string in
  let treatment_desc = json |> member "treatment_description" |> to_string in
  let control_desc = json |> member "control_description" |> to_string in
  let metrics = json |> member "metrics" |> to_list |> List.map to_string in
  let window_seconds = json |> member "window_seconds" |> to_float in
  let status = json |> member "status" |> to_string |> status_of_string in
  let assignments =
    json |> member "assignments" |> to_list |> List.map assignment_of_yojson
  in
  let observations =
    json |> member "observations" |> to_list |> List.map observation_of_yojson
  in
  let created_at = json |> member "created_at" |> to_float in
  { id; hypothesis; treatment_desc; control_desc; metrics;
    window_seconds; status; assignments; observations; created_at }

(* {1 Storage} *)

let experiments_dir config =
  Filename.concat (Room.masc_dir config) "experiments"

let rec ensure_dir path =
  if not (Sys.file_exists path) then begin
    let parent = Filename.dirname path in
    if parent <> path && not (Sys.file_exists parent) then
      ensure_dir parent;
    try Unix.mkdir path 0o755
    with Unix.Unix_error (Unix.EEXIST, _, _) -> ()
  end

let experiment_path config experiment_id =
  Filename.concat (experiments_dir config) (experiment_id ^ ".json")

let write_json path json =
  let content = Yojson.Safe.pretty_to_string json in
  let dir = Filename.dirname path in
  let tmp =
    Filename.concat dir
      (Printf.sprintf ".%s.tmp.%d" (Filename.basename path) (Unix.getpid ()))
  in
  let oc = open_out tmp in
  let closed = ref false in
  Fun.protect
    ~finally:(fun () ->
      if not !closed then (try close_out oc with exn -> let _ = exn in ());
      if Sys.file_exists tmp then (try Sys.remove tmp with Sys_error _ -> ()))
    (fun () ->
      output_string oc content;
      flush oc;
      close_out oc;
      closed := true;
      Sys.rename tmp path)

let read_json path =
  try
    let ic = open_in path in
    let content =
      Fun.protect ~finally:(fun () -> close_in_noerr ic) (fun () ->
        really_input_string ic (in_channel_length ic))
    in
    Some (Yojson.Safe.from_string content)
  with exn -> let _ = exn in None

let save_experiment config (exp : experiment) =
  ensure_dir (experiments_dir config);
  write_json (experiment_path config exp.id) (experiment_to_yojson exp)

let load_experiment config experiment_id : experiment option =
  let path = experiment_path config experiment_id in
  match read_json path with
  | Some json -> (try Some (experiment_of_yojson json) with Yojson.Safe.Util.Type_error _ | Invalid_argument _ -> None)
  | None -> None

let list_experiments config =
  let dir = experiments_dir config in
  ensure_dir dir;
  try
    Sys.readdir dir
    |> Array.to_list
    |> List.filter (fun f -> Filename.check_suffix f ".json")
    |> List.filter_map (fun f ->
         match read_json (Filename.concat dir f) with
         | Some json -> (try Some (experiment_of_yojson json) with Yojson.Safe.Util.Type_error _ | Invalid_argument _ -> None)
         | None -> None)
    |> List.sort (fun a b -> compare b.created_at a.created_at)
  with Sys_error _ -> []

(* {1 ID Generation} *)

let () = Random.self_init ()

let generate_id () =
  let ts = int_of_float (Time_compat.now () *. 1000.0) in
  let rand = Random.int 1_000_000 in
  Printf.sprintf "exp-%d-%06d" ts rand

(* {1 SSE Event Broadcasting}

   Emits experiment events to connected viewers via the SSE push pipeline.
   Wire format follows JSON-RPC 2.0 notification (no id field).

   Event types follow the Cross-Session Protocol:
   - experiment_created, experiment_assignment, experiment_observation
   - experiment_checkpoint, experiment_concluded *)

let broadcast_experiment_event ~event_type ~agent ?(data = `Null) () =
  let params =
    `Assoc
      [
        ("type", `String event_type);
        ("agent", `String agent);
        ("data", data);
        ("timestamp", `Float (Time_compat.now ()));
      ]
  in
  let notification =
    `Assoc
      [
        ("jsonrpc", `String "2.0");
        ("method", `String "masc/event");
        ("params", params);
      ]
  in
  Sse.broadcast notification

(* {1 Statistics Helpers} *)

let mean values =
  match values with
  | [] -> 0.0
  | _ ->
      let sum = List.fold_left ( +. ) 0.0 values in
      sum /. Float.of_int (List.length values)

let variance values =
  match values with
  | [] | [_] -> 0.0
  | _ ->
      let m = mean values in
      let sum_sq =
        List.fold_left (fun acc v -> acc +. ((v -. m) *. (v -. m))) 0.0 values
      in
      sum_sq /. Float.of_int (List.length values - 1)

(** Welch's t-test approximation for two independent samples.
    Returns (t_stat, approximate_p_value).
    p-value uses a rough normal approximation for large sample sizes. *)
let welch_t_test treatment_vals control_vals =
  let n1 = Float.of_int (List.length treatment_vals) in
  let n2 = Float.of_int (List.length control_vals) in
  if n1 < 2.0 || n2 < 2.0 then (0.0, 1.0)
  else
    let m1 = mean treatment_vals in
    let m2 = mean control_vals in
    let v1 = variance treatment_vals in
    let v2 = variance control_vals in
    let se = sqrt ((v1 /. n1) +. (v2 /. n2)) in
    if se < 1e-10 then (0.0, 1.0)
    else
      let t_stat = (m1 -. m2) /. se in
      (* Normal approximation for p-value (two-tailed) *)
      let abs_t = Float.abs t_stat in
      let p =
        if abs_t > 3.5 then 0.001
        else if abs_t > 2.576 then 0.01
        else if abs_t > 1.96 then 0.05
        else if abs_t > 1.645 then 0.10
        else 0.50
      in
      (t_stat, p)

(** Cohen's d effect size *)
let cohens_d treatment_vals control_vals =
  let m1 = mean treatment_vals in
  let m2 = mean control_vals in
  let v1 = variance treatment_vals in
  let v2 = variance control_vals in
  let n1 = Float.of_int (List.length treatment_vals) in
  let n2 = Float.of_int (List.length control_vals) in
  let pooled_var =
    ((n1 -. 1.0) *. v1 +. (n2 -. 1.0) *. v2) /. (n1 +. n2 -. 2.0)
  in
  let pooled_sd = sqrt pooled_var in
  if pooled_sd < 1e-10 then 0.0 else (m1 -. m2) /. pooled_sd

(* {1 Tool Handlers} *)

(** Create a new experiment. *)
let handle_experiment_start ctx args : result =
  let hypothesis = get_string args "hypothesis" "" in
  let treatment_desc = get_string args "treatment_description" "" in
  let control_desc = get_string args "control_description" "" in
  let metrics = get_string_list args "metrics" in
  let window_seconds = get_float args "window_seconds" 3600.0 in
  if hypothesis = "" then (false, "hypothesis is required")
  else if treatment_desc = "" then (false, "treatment_description is required")
  else if control_desc = "" then (false, "control_description is required")
  else
    let id = generate_id () in
    let exp =
      {
        id;
        hypothesis;
        treatment_desc;
        control_desc;
        metrics;
        window_seconds;
        status = Running;
        assignments = [];
        observations = [];
        created_at = Time_compat.now ();
      }
    in
    (try
       save_experiment ctx.config exp;
       broadcast_experiment_event ~event_type:"experiment_created"
         ~agent:ctx.agent_name
         ~data:
           (`Assoc
             [
               ("id", `String id);
               ("hypothesis", `String hypothesis);
               ("treatment_description", `String treatment_desc);
               ("control_description", `String control_desc);
               ("metrics", `List (List.map (fun m -> `String m) metrics));
               ("window_seconds", `Float window_seconds);
             ])
         ();
       Log.Misc.info "Created %s: %s" id hypothesis;
       ( true,
         Yojson.Safe.to_string
           (`Assoc
             [
               ("id", `String id);
               ("hypothesis", `String hypothesis);
               ("status", `String "running");
             ]) )
     with e ->
       (false, Printf.sprintf "Failed to create experiment: %s" (Printexc.to_string e)))

(** Assign a subject to treatment or control group. *)
let handle_experiment_assign ctx args : result =
  let experiment_id = get_string args "experiment_id" "" in
  let subject_id = get_string args "subject_id" "" in
  let group_str = get_string args "group" "" in
  if experiment_id = "" then (false, "experiment_id is required")
  else if subject_id = "" then (false, "subject_id is required")
  else
    (match (try Some (group_of_string group_str) with Invalid_argument _ -> None) with
    | None -> (false, Printf.sprintf "Invalid group: %s" group_str)
    | Some group -> (
        match load_experiment ctx.config experiment_id with
        | None -> (false, Printf.sprintf "Experiment not found: %s" experiment_id)
        | Some exp ->
            if exp.status <> Running then
              (false, Printf.sprintf "Experiment %s is not running" experiment_id)
            else
              let now = Time_compat.now () in
              let assignment = { subject_id; group; timestamp = now } in
              let updated =
                { exp with assignments = exp.assignments @ [ assignment ] }
              in
              (try
                 save_experiment ctx.config updated;
                 broadcast_experiment_event ~event_type:"experiment_assignment"
                   ~agent:ctx.agent_name
                   ~data:
                     (`Assoc
                       [
                         ("experiment_id", `String experiment_id);
                         ("subject_id", `String subject_id);
                         ("group", `String (group_to_string group));
                         ("timestamp", `Float now);
                       ])
                   ();
                 Log.Misc.info "Assigned %s to %s (%s)"
                   subject_id experiment_id (group_to_string group);
                 ( true,
                   Printf.sprintf "Assigned %s to %s group" subject_id
                     (group_to_string group) )
               with e ->
                 (false, Printf.sprintf "Failed: %s" (Printexc.to_string e)))))

(** Record a metric observation for a subject. *)
let handle_experiment_observe ctx args : result =
  let experiment_id = get_string args "experiment_id" "" in
  let subject_id = get_string args "subject_id" "" in
  let metric_name = get_string args "metric_name" "" in
  let value = get_float args "value" 0.0 in
  if experiment_id = "" then (false, "experiment_id is required")
  else if subject_id = "" then (false, "subject_id is required")
  else if metric_name = "" then (false, "metric_name is required")
  else
    match load_experiment ctx.config experiment_id with
    | None -> (false, Printf.sprintf "Experiment not found: %s" experiment_id)
    | Some exp ->
        if exp.status <> Running then
          (false, Printf.sprintf "Experiment %s is not running" experiment_id)
        else
          let now = Time_compat.now () in
          let obs = { subject_id; metric_name; value; timestamp = now } in
          let updated =
            { exp with observations = exp.observations @ [ obs ] }
          in
          (try
             save_experiment ctx.config updated;
             broadcast_experiment_event ~event_type:"experiment_observation"
               ~agent:ctx.agent_name
               ~data:
                 (`Assoc
                   [
                     ("experiment_id", `String experiment_id);
                     ("subject_id", `String subject_id);
                     ("metric_name", `String metric_name);
                     ("value", `Float value);
                     ("timestamp", `Float now);
                   ])
               ();
             ( true,
               Printf.sprintf "Recorded %s=%g for %s" metric_name value
                 subject_id )
           with e ->
             (false, Printf.sprintf "Failed: %s" (Printexc.to_string e)))

(** Generate a checkpoint with current statistics. *)
let handle_experiment_checkpoint ctx args : result =
  let experiment_id = get_string args "experiment_id" "" in
  let metric_name = get_string args "metric_name" "" in
  if experiment_id = "" then (false, "experiment_id is required")
  else
    match load_experiment ctx.config experiment_id with
    | None -> (false, Printf.sprintf "Experiment not found: %s" experiment_id)
    | Some exp ->
        let elapsed = Time_compat.now () -. exp.created_at in
        let elapsed_pct =
          if exp.window_seconds > 0.0 then
            Float.min 1.0 (elapsed /. exp.window_seconds)
          else 1.0
        in
        (* Filter observations by metric if specified, otherwise use first metric *)
        let target_metric =
          if metric_name <> "" then metric_name
          else match exp.metrics with m :: _ -> m | [] -> ""
        in
        (* Build subject→group map *)
        let group_of_subject =
          List.fold_left
            (fun tbl (a : assignment) ->
              Hashtbl.replace tbl a.subject_id a.group;
              tbl)
            (Hashtbl.create 16) exp.assignments
        in
        (* Partition observations by group *)
        let treatment_vals = ref [] in
        let control_vals = ref [] in
        List.iter
          (fun (o : observation) ->
            if target_metric = "" || o.metric_name = target_metric then
              match Hashtbl.find_opt group_of_subject o.subject_id with
              | Some Treatment -> treatment_vals := o.value :: !treatment_vals
              | Some Control -> control_vals := o.value :: !control_vals
              | None -> ())
          exp.observations;
        let t_mean = mean !treatment_vals in
        let c_mean = mean !control_vals in
        let _t_stat, p_value = welch_t_test !treatment_vals !control_vals in
        let effect_size = cohens_d !treatment_vals !control_vals in
        let data =
          `Assoc
            [
              ("experiment_id", `String experiment_id);
              ("elapsed_pct", `Float elapsed_pct);
              ("treatment_mean", `Float t_mean);
              ("control_mean", `Float c_mean);
              ("p_value", `Float p_value);
              ("effect_size", `Float effect_size);
            ]
        in
        broadcast_experiment_event ~event_type:"experiment_checkpoint"
          ~agent:ctx.agent_name ~data ();
        ( true,
          Yojson.Safe.to_string data )

(** Conclude an experiment with final statistical analysis. *)
let handle_experiment_conclude ctx args : result =
  let experiment_id = get_string args "experiment_id" "" in
  if experiment_id = "" then (false, "experiment_id is required")
  else
    match load_experiment ctx.config experiment_id with
    | None -> (false, Printf.sprintf "Experiment not found: %s" experiment_id)
    | Some exp ->
        if exp.status = Concluded then
          (false, Printf.sprintf "Experiment %s is already concluded" experiment_id)
        else
          (* Compute final stats across all metrics *)
          let group_of_subject =
            List.fold_left
              (fun tbl (a : assignment) ->
                Hashtbl.replace tbl a.subject_id a.group;
                tbl)
              (Hashtbl.create 16) exp.assignments
          in
          let treatment_vals = ref [] in
          let control_vals = ref [] in
          List.iter
            (fun (o : observation) ->
              match Hashtbl.find_opt group_of_subject o.subject_id with
              | Some Treatment -> treatment_vals := o.value :: !treatment_vals
              | Some Control -> control_vals := o.value :: !control_vals
              | None -> ())
            exp.observations;
          let _t_stat, p_value = welch_t_test !treatment_vals !control_vals in
          let effect_size = cohens_d !treatment_vals !control_vals in
          let result_str =
            if p_value < 0.05 then "significant"
            else if p_value > 0.20 then "not_significant"
            else "inconclusive"
          in
          (* Confidence interval (approximate: effect +/- 1.96 * SE) *)
          let n1 = Float.of_int (List.length !treatment_vals) in
          let n2 = Float.of_int (List.length !control_vals) in
          let se_d =
            if n1 > 1.0 && n2 > 1.0 then
              sqrt ((n1 +. n2) /. (n1 *. n2) +. (effect_size *. effect_size /. (2.0 *. (n1 +. n2))))
            else 1.0
          in
          let ci_low = effect_size -. 1.96 *. se_d in
          let ci_high = effect_size +. 1.96 *. se_d in
          let updated = { exp with status = Concluded } in
          (try
             save_experiment ctx.config updated;
             let data =
               `Assoc
                 [
                   ("experiment_id", `String experiment_id);
                   ("result", `String result_str);
                   ("effect_size", `Float effect_size);
                   ( "confidence_interval",
                     `List [ `Float ci_low; `Float ci_high ] );
                   ( "sample_sizes",
                     `Assoc
                       [
                         ("treatment", `Int (List.length !treatment_vals));
                         ("control", `Int (List.length !control_vals));
                       ] );
                 ]
             in
             broadcast_experiment_event ~event_type:"experiment_concluded"
               ~agent:ctx.agent_name ~data ();
             Log.Misc.info "Concluded %s: %s (d=%.3f, p=%.3f)"
               experiment_id result_str effect_size p_value;
             (true, Yojson.Safe.to_string data)
           with e ->
             (false, Printf.sprintf "Failed: %s" (Printexc.to_string e)))

(** List experiments, optionally filtered by status. *)
let handle_experiment_list ctx args : result =
  let status_filter = get_string args "status" "" in
  let limit = get_int args "limit" 20 in
  let all = list_experiments ctx.config in
  let filtered =
    if status_filter = "" then all
    else
      List.filter
        (fun e -> status_to_string e.status = status_filter)
        all
  in
  let limited =
    let rec take n = function
      | [] -> []
      | _ when n <= 0 -> []
      | x :: xs -> x :: take (n - 1) xs
    in
    take limit filtered
  in
  let json =
    `Assoc
      [
        ("total", `Int (List.length filtered));
        ( "experiments",
          `List
            (List.map
               (fun e ->
                 `Assoc
                   [
                     ("id", `String e.id);
                     ("hypothesis", `String e.hypothesis);
                     ("status", `String (status_to_string e.status));
                     ("assignments", `Int (List.length e.assignments));
                     ("observations", `Int (List.length e.observations));
                   ])
               limited) );
      ]
  in
  (true, Yojson.Safe.to_string json)

(** Get experiment details including current statistics. *)
let handle_experiment_status ctx args : result =
  let experiment_id = get_string args "experiment_id" "" in
  if experiment_id = "" then (false, "experiment_id is required")
  else
    match load_experiment ctx.config experiment_id with
    | None -> (false, Printf.sprintf "Experiment not found: %s" experiment_id)
    | Some exp ->
        let treatment_count =
          List.length
            (List.filter (fun (a : assignment) -> a.group = Treatment) exp.assignments)
        in
        let control_count =
          List.length
            (List.filter (fun (a : assignment) -> a.group = Control) exp.assignments)
        in
        let json =
          `Assoc
            [
              ("id", `String exp.id);
              ("hypothesis", `String exp.hypothesis);
              ("status", `String (status_to_string exp.status));
              ( "sample_sizes",
                `Assoc
                  [
                    ("treatment", `Int treatment_count);
                    ("control", `Int control_count);
                  ] );
              ("total_observations", `Int (List.length exp.observations));
              ("elapsed_seconds", `Float (Time_compat.now () -. exp.created_at));
              ("window_seconds", `Float exp.window_seconds);
            ]
        in
        (true, Yojson.Safe.to_string json)

(* {1 Dispatch} *)

let dispatch ctx ~name ~args : result option =
  match name with
  | "experiment_start" -> Some (handle_experiment_start ctx args)
  | "experiment_assign" -> Some (handle_experiment_assign ctx args)
  | "experiment_observe" -> Some (handle_experiment_observe ctx args)
  | "experiment_checkpoint" -> Some (handle_experiment_checkpoint ctx args)
  | "experiment_conclude" -> Some (handle_experiment_conclude ctx args)
  | "experiment_list" -> Some (handle_experiment_list ctx args)
  | "experiment_status" -> Some (handle_experiment_status ctx args)
  | _ -> None

(* {1 MCP Tool Schemas} *)

let schemas : Types.tool_schema list =
  [
    {
      name = "experiment_start";
      description =
        "Create a new social experiment with hypothesis, treatment/control \
         descriptions, and metric names. Returns experiment ID.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "hypothesis",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "The hypothesis to test");
                      ] );
                  ( "treatment_description",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Description of the treatment condition");
                      ] );
                  ( "control_description",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Description of the control condition");
                      ] );
                  ( "metrics",
                    `Assoc
                      [
                        ("type", `String "array");
                        ("items", `Assoc [ ("type", `String "string") ]);
                        ("description", `String "Metric names to track");
                      ] );
                  ( "window_seconds",
                    `Assoc
                      [
                        ("type", `String "number");
                        ("description", `String "Experiment duration in seconds (default: 3600)");
                      ] );
                ] );
            ( "required",
              `List
                [
                  `String "hypothesis";
                  `String "treatment_description";
                  `String "control_description";
                ] );
          ];
    };
    {
      name = "experiment_assign";
      description =
        "Assign a subject to treatment or control group in an experiment.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "experiment_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Experiment ID");
                      ] );
                  ( "subject_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Subject identifier (e.g. agent name)");
                      ] );
                  ( "group",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "treatment"; `String "control" ]);
                        ("description", `String "Group assignment");
                      ] );
                ] );
            ( "required",
              `List
                [
                  `String "experiment_id";
                  `String "subject_id";
                  `String "group";
                ] );
          ];
    };
    {
      name = "experiment_observe";
      description =
        "Record a metric observation for a subject in an experiment.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "experiment_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Experiment ID");
                      ] );
                  ( "subject_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Subject identifier");
                      ] );
                  ( "metric_name",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Name of the metric being observed");
                      ] );
                  ( "value",
                    `Assoc
                      [
                        ("type", `String "number");
                        ("description", `String "Observed metric value");
                      ] );
                ] );
            ( "required",
              `List
                [
                  `String "experiment_id";
                  `String "subject_id";
                  `String "metric_name";
                  `String "value";
                ] );
          ];
    };
    {
      name = "experiment_checkpoint";
      description =
        "Generate a statistical checkpoint for an experiment. Returns \
         treatment/control means, p-value, and effect size.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "experiment_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Experiment ID");
                      ] );
                  ( "metric_name",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Metric to analyze (default: first metric)");
                      ] );
                ] );
            ("required", `List [ `String "experiment_id" ]);
          ];
    };
    {
      name = "experiment_conclude";
      description =
        "Conclude an experiment with final statistical analysis. Returns \
         significance result, effect size, confidence interval, and sample sizes.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "experiment_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Experiment ID to conclude");
                      ] );
                ] );
            ("required", `List [ `String "experiment_id" ]);
          ];
    };
    {
      name = "experiment_list";
      description =
        "List experiments, optionally filtered by status (running/concluded).";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "status",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("enum", `List [ `String "running"; `String "concluded" ]);
                        ("description", `String "Filter by status");
                      ] );
                  ( "limit",
                    `Assoc
                      [
                        ("type", `String "integer");
                        ("description", `String "Max results (default: 20)");
                      ] );
                ] );
          ];
    };
    {
      name = "experiment_status";
      description =
        "Get detailed status of an experiment including sample sizes and elapsed time.";
      input_schema =
        `Assoc
          [
            ("type", `String "object");
            ( "properties",
              `Assoc
                [
                  ( "experiment_id",
                    `Assoc
                      [
                        ("type", `String "string");
                        ("description", `String "Experiment ID");
                      ] );
                ] );
            ("required", `List [ `String "experiment_id" ]);
          ];
    };
  ]
