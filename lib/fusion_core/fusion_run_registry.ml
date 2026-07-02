(* Fusion — in-memory run registry for in-progress + recent fusion visibility
   (RFC-0266 §7 Phase 2). The fusion tool registers a run [Running] at fork
   start and the sink/failure path marks it [Completed] on finish, so an
   operator surface (masc_fusion_status tool = Phase 3, dashboard = Phase 4) can
   show what is deliberating now and what just finished — instead of run_id only
   living in the caller's tool-result.

   Lock-free Atomic + CAS; no extra deps. Server-lifetime: a fork that dies on
   server shutdown takes its registry entry with it, so no orphan [Running]
   survives a restart (RFC-0266 §10 #4).

   This module never wakes a keeper (that is the WAKE half, Phase 1). Recording
   a run is the visibility half and is intentionally side-effect-free beyond the
   in-memory table. *)

type run_status =
  | Running
  | Completed of {
      ok : bool;
      (* ok=false일 때의 사람-가독 사유 + 안정 분류 태그. 2026-07-01 사고에서
         상태 표면(masc_fusion_status/SSE)이 status="failed"만 나르는 바람에
         키퍼가 원인을 얻을 tool-reachable 경로가 없었다 (mli 참조). *)
      failure : string option;
      failure_code : string option;
    }

type run = {
  run_id : string;
  keeper : string;
  preset : string;
  started_at : float;  (* unix seconds from the keeper clock at fork start *)
  status : run_status;
}

type t = run list Atomic.t

(* Recent-history retention for [Completed] runs. [Running] runs are never
   evicted (active state must stay accurate). NOTE: 이전 주석은 [Running]이
   "per-hour fusion budget (RFC-0252 §10)으로 bounded"라고 주장했으나 그 budget은
   PR #22051에서 제거되어 존재하지 않는다 — 현재 fusion 호출률 제한은 없다(설계
   미결정, 집계만 한다는 운영 원칙과 정합). This is a log-retention bound, not a
   symptom cap — it stops the table from growing without limit over a long
   server lifetime. *)
let max_completed_retained = 64

let create () : t = Atomic.make []

let is_running (r : run) =
  match r.status with
  | Running -> true
  | Completed _ -> false
;;

(* Keep every [Running] run plus the [max_completed_retained] most recent
   [Completed] runs (newest [started_at] first). *)
let prune (runs : run list) : run list =
  let running, completed = List.partition is_running runs in
  let recent_completed =
    completed
    |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
    |> List.filteri (fun i _ -> i < max_completed_retained)
  in
  running @ recent_completed
;;

let rec update (t : t) (f : run list -> run list) =
  let cur = Atomic.get t in
  let next = f cur in
  if not (Atomic.compare_and_set t cur next) then update t f
;;

let register_running (t : t) ~run_id ~keeper ~preset ~started_at =
  update t (fun runs ->
    let run = { run_id; keeper; preset; started_at; status = Running } in
    (* defensive: a re-registered run_id replaces its prior entry *)
    let without_dup = List.filter (fun r -> not (String.equal r.run_id run_id)) runs in
    prune (run :: without_dup))
;;

let mark_completed (t : t) ~run_id ?failure ?failure_code ~ok () =
  update t (fun runs ->
    runs
    |> List.map (fun r ->
         if String.equal r.run_id run_id
         then { r with status = Completed { ok; failure; failure_code } }
         else r)
    |> prune)
;;

let list_runs (t : t) : run list =
  Atomic.get t |> List.sort (fun a b -> Float.compare b.started_at a.started_at)
;;

let get (t : t) ~run_id : run option =
  List.find_opt (fun r -> String.equal r.run_id run_id) (Atomic.get t)
;;

(* Stable status vocabulary shared by every fusion-run surface (Phase 3 keeper
   tool, Phase 4 dashboard route, the [fusion_run_status] SSE event). Hand-
   written rather than [@@deriving] so the on-wire labels stay
   "running"/"completed"/"failed" regardless of the variant shape — a consumer
   never reconstructs run state from the variant, only reads these labels. *)
let status_label = function
  | Running -> "running"
  | Completed { ok = true; _ } -> "completed"
  | Completed { ok = false; _ } -> "failed"
;;

(* The single per-run JSON object. The HTTP list endpoint, the SSE delta, and the
   keeper status tool all serialize a run through here so the field set and the
   status label never drift between surfaces. *)
let run_to_yojson (r : run) : Yojson.Safe.t =
  let base =
    [ ("run_id", `String r.run_id)
    ; ("keeper", `String r.keeper)
    ; ("preset", `String r.preset)
    ; ("started_at", `Float r.started_at)
    ; ("status", `String (status_label r.status))
    ]
  in
  (* 실패 사유는 additive 필드로만 싣는다 — 기존 소비자(tool/HTTP/SSE/프론트)의
     필드 집합은 그대로 유지된다. *)
  let failure_fields =
    match r.status with
    | Running | Completed { ok = true; _ } -> []
    | Completed { ok = false; failure; failure_code } ->
      List.filter_map
        (fun (k, v) -> Option.map (fun s -> (k, `String s)) v)
        [ ("error", failure); ("failure_code", failure_code) ]
  in
  `Assoc (base @ failure_fields)
;;

(* Process-wide registry the fusion tool/sink write to (server-lifetime). Tests
   use a fresh [create ()] for state isolation, avoiding a reset backdoor. *)
let global : t = create ()
