(** Supervisor recovery policy for auto-recoverable durable keeper pauses.

    Implements the recovery scan that runs on each supervisor tick to detect
    paused keepers whose pause reason has resolved and who can be safely
    resumed. See keeper_supervisor_pause_recovery.mli for the full design. *)

open Keeper_types

(* ── Types ─────────────────────────────────────────────────────────────── *)

type pause_reason =
  | Operator_pause
  | Supervisor_pause
  | Auto_recover_pause

type recovery_evaluation =
  | Not_paused
  | Paused_not_recoverable of pause_reason
  | Paused_recoverable of
      { reason : pause_reason
      ; cooldown_elapsed : bool
      ; health_ok : bool
      }

type recovery_outcome =
  | Recovery_not_needed
  | Recovery_skipped of string
  | Recovery_resumed of string
  | Recovery_failed of string

(* ── Constants ─────────────────────────────────────────────────────────── *)

let default_cooldown_sec = 300.0

(* ── Pause reason serialization ────────────────────────────────────────── *)

let pause_reason_to_label = function
  | Operator_pause -> "operator"
  | Supervisor_pause -> "supervisor"
  | Auto_recover_pause -> "auto_recover"

let pause_reason_of_state = function
  | Some "operator" -> Operator_pause
  | Some "supervisor" -> Supervisor_pause
  | Some "auto_recover" -> Auto_recover_pause
  | Some _ -> Supervisor_pause (* unknown pause states treated as supervisor *)
  | None -> Operator_pause (* missing state defaults to operator, safest choice *)

(* ── Evaluation ────────────────────────────────────────────────────────── *)

let evaluate_pause ~paused_at ~pause_state ~auto_recoverable ~now =
  match pause_state with
  | None | Some "" | Some "running" | Some "active" ->
    Not_paused
  | Some _ ->
    let reason = pause_reason_of_state pause_state in
    (* Only auto_recover pauses are candidates for automatic resume *)
    if not auto_recoverable then
      Paused_not_recoverable reason
    else
      (* Check cooldown: has enough time elapsed since pause? *)
      let cooldown_elapsed =
        match paused_at with
        | None -> true (* no timestamp means legacy pause, allow recovery *)
        | Some ts -> now -. ts >= default_cooldown_sec
      in
      (* For auto-recoverable pauses, health is assumed OK unless
         we have explicit evidence otherwise. The liveness scan
         handles dead-keeper detection separately. *)
      let health_ok = true in
      Paused_recoverable { reason; cooldown_elapsed; health_ok }

(* ── Lifecycle event helper ────────────────────────────────────────────── *)

let publish_resume_event ~publish_lifecycle keeper_name =
  let event =
    Keeper_lifecycle_events.Resume_from_pause
      { keeper = keeper_name
      ; trigger = "auto_recovery"
      }
  in
  publish_lifecycle ~event keeper_name "pause_recovery" ()

(* ── Scan ──────────────────────────────────────────────────────────────── *)

let scan ~resume_keeper ~publish_lifecycle keepers =
  let now = Unix.gettimeofday () in
  let evaluate_one (entry, keeper_name) =
    (* Extract pause state from registry entry metadata *)
    let paused = entry.Keeper_registry.paused in
    let pause_state = entry.Keeper_registry.pause_state in
    let paused_at = entry.Keeper_registry.paused_at in
    let auto_recoverable =
      match entry.Keeper_registry.pause_reason with
      | Some "auto_recover" -> true
      | Some "cascade_cooldown" -> true
      | Some "transient_error" -> true
      | _ -> false
    in
    if not paused then Recovery_not_needed
    else begin
      let eval =
        evaluate_pause
          ~paused_at
          ~pause_state
          ~auto_recoverable
          ~now
      in
      match eval with
      | Not_paused ->
        Recovery_not_needed
      | Paused_not_recoverable reason ->
        Recovery_skipped
          (Printf.sprintf "%s: %s pause, not auto-recoverable"
             keeper_name (pause_reason_to_label reason))
      | Paused_recoverable { cooldown_elapsed = false; _ } ->
        Recovery_skipped
          (Printf.sprintf "%s: cooldown not yet elapsed" keeper_name)
      | Paused_recoverable { health_ok = false; _ } ->
        Recovery_skipped
          (Printf.sprintf "%s: health check failed" keeper_name)
      | Paused_recoverable _ ->
        (* Conditions met: attempt resume *)
        begin try
          resume_keeper keeper_name;
          publish_resume_event ~publish_lifecycle keeper_name;
          Recovery_resumed keeper_name
        with exn ->
          Recovery_failed
            (Printf.sprintf "%s: resume failed: %s"
               keeper_name (Printexc.to_string exn))
        end
    end
  in
  List.filter_map
    (fun (entry, name) ->
      let outcome = evaluate_one (entry, name) in
      match outcome with
      | Recovery_not_needed -> None
      | other -> Some other)
    keepers