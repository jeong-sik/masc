(** Autonomy Adjuster — Feedback Closure for Lodge Agent Selection (Phase 4).

    Observes Thompson Sampling stats and agent health to auto-adjust
    per-agent autonomy levels. See {!Autonomy_adjuster} (.mli) for algorithm.

    @since 2.77.0 *)

(* ================================================================ *)
(* Types                                                            *)
(* ================================================================ *)

type action_class =
  | Autonomous
  | Supervised
  | Restricted
  | Suspended

type autonomy_record = {
  agent_name : string;
  level : float;
  action_class : action_class;
  quality_ratio : float;
  updated_at : float;
}

(* ================================================================ *)
(* Constants                                                        *)
(* ================================================================ *)

let default_level = 0.5
let high_quality_threshold = 0.7
let low_quality_threshold = 0.4
let bump_up = 0.05
let bump_down = -0.1
let recovering_cap = 0.5

(* ================================================================ *)
(* Action class                                                     *)
(* ================================================================ *)

let classify_action level =
  if level >= 0.8 then Autonomous
  else if level >= 0.5 then Supervised
  else if level >= 0.2 then Restricted
  else Suspended

let action_class_to_string = function
  | Autonomous -> "autonomous"
  | Supervised -> "supervised"
  | Restricted -> "restricted"
  | Suspended  -> "suspended"

let action_class_of_string = function
  | "autonomous" -> Autonomous
  | "supervised" -> Supervised
  | "restricted" -> Restricted
  | "suspended"  -> Suspended
  | s -> failwith (Printf.sprintf "Autonomy_adjuster: unknown action_class %S" s)

(* ================================================================ *)
(* Persistence path                                                 *)
(* ================================================================ *)

let base_path_ref : string option ref = ref None

let set_base_path p = base_path_ref := Some p

let autonomy_path () =
  let base =
    match !base_path_ref with
    | Some p -> p
    | None ->
        let p =
          match Sys.getenv_opt "MASC_BASE_PATH" with
          | Some bp -> bp
          | None -> ".masc"
        in
        (try Sys.mkdir p 0o755 with Sys_error _ -> ());
        p
  in
  Filename.concat base "lodge_autonomy.jsonl"

(* ================================================================ *)
(* In-memory state                                                  *)
(* ================================================================ *)

let table : (string, autonomy_record) Hashtbl.t = Hashtbl.create 16

let make_default ~agent_name ~now =
  let level = default_level in
  { agent_name; level; action_class = classify_action level;
    quality_ratio = 0.5; updated_at = now }

(* ================================================================ *)
(* JSON serialization                                               *)
(* ================================================================ *)

let autonomy_record_to_yojson r =
  `Assoc [
    ("agent_name", `String r.agent_name);
    ("level", `Float r.level);
    ("action_class", `String (action_class_to_string r.action_class));
    ("quality_ratio", `Float r.quality_ratio);
    ("updated_at", `Float r.updated_at);
  ]

let autonomy_record_of_yojson (json : Yojson.Safe.t) =
  try
    let open Yojson.Safe.Util in
    let agent_name = json |> member "agent_name" |> to_string in
    let level = json |> member "level" |> to_float in
    let action_class =
      json |> member "action_class" |> to_string |> action_class_of_string
    in
    let quality_ratio = json |> member "quality_ratio" |> to_float in
    let updated_at = json |> member "updated_at" |> to_float in
    Ok { agent_name; level; action_class; quality_ratio; updated_at }
  with exn ->
    Error (Printf.sprintf "autonomy_record_of_yojson: %s" (Printexc.to_string exn))

(* ================================================================ *)
(* Persistence — JSONL append + load                                *)
(* ================================================================ *)

let persist_record r =
  let line = Yojson.Safe.to_string (autonomy_record_to_yojson r) ^ "\n" in
  let path = autonomy_path () in
  Fs_compat.append_file path line

let load_all_from_disk () =
  let path = autonomy_path () in
  if not (Fs_compat.file_exists path) then ()
  else begin
    let lines = Fs_compat.load_jsonl path in
    List.iter (fun json ->
      match autonomy_record_of_yojson json with
      | Ok r -> Hashtbl.replace table r.agent_name r
      | Error _ -> ()  (* skip malformed lines *)
    ) lines
  end

let ensure_loaded =
  let loaded = ref false in
  fun () ->
    if not !loaded then begin
      load_all_from_disk ();
      loaded := true
    end

(* ================================================================ *)
(* Core API                                                         *)
(* ================================================================ *)

let get_autonomy ~agent_name =
  ensure_loaded ();
  match Hashtbl.find_opt table agent_name with
  | Some r -> r
  | None -> make_default ~agent_name ~now:(Time_compat.now ())

let clamp v = Float.min 1.0 (Float.max 0.0 v)

let adjust ~agent_name =
  ensure_loaded ();
  let stats = Lodge_selection.get_stats agent_name in
  let health = Agent_health.check_health ~agent_name in
  let alpha = stats.Lodge_selection.alpha in
  let beta_val = stats.Lodge_selection.beta in
  let quality_ratio =
    if alpha +. beta_val > 0.0 then alpha /. (alpha +. beta_val)
    else 0.5  (* no data — neutral *)
  in
  let current = get_autonomy ~agent_name in
  let now = Time_compat.now () in
  (* Compute delta based on quality band *)
  let delta =
    if quality_ratio > high_quality_threshold then bump_up
    else if quality_ratio < low_quality_threshold then bump_down
    else 0.0
  in
  let new_level = clamp (current.level +. delta) in
  (* Health gating *)
  let new_level =
    match health with
    | Agent_health.Unhealthy _ -> 0.0
    | Agent_health.Recovering -> Float.min recovering_cap new_level
    | Agent_health.Healthy -> new_level
  in
  let r = {
    agent_name;
    level = new_level;
    action_class = classify_action new_level;
    quality_ratio;
    updated_at = now;
  } in
  Hashtbl.replace table agent_name r;
  persist_record r;
  r

let check_autonomy ~agent_name =
  (get_autonomy ~agent_name).action_class

let get_all () =
  ensure_loaded ();
  Hashtbl.fold (fun _ v acc -> v :: acc) table []

let reset ~agent_name ?(level = default_level) () =
  ensure_loaded ();
  let now = Time_compat.now () in
  let lvl = clamp level in
  let r = {
    agent_name;
    level = lvl;
    action_class = classify_action lvl;
    quality_ratio = 0.5;
    updated_at = now;
  } in
  Hashtbl.replace table agent_name r;
  persist_record r;
  r
