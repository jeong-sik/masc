(* Whole-turn wall-clock ceiling shared by the official-client CLI runtimes
   (antigravity, claude_code, codex_app_server).

   Their per-operation idle timeouts reset on every emitted line, so a CLI
   that keeps emitting inside each window holds the turn indefinitely —
   observed 2026-08-21 as a 7.2h keeper turn that no deadline ended
   (provider_attempt_effect_fenced eventually did).

   The ceiling is hours-scale on purpose so it never competes with the
   progress-axis deadlines (#28417/#28419): a healthy turn's progress gaps
   top out around 120s and the model rows budget 600s per phase. A turn that
   hits the ceiling terminates through the runtime's existing typed
   [Timeout] error — this module adds no new disposition. *)

let default_ceiling_s = 14400.

type t =
  { now : unit -> float
  ; started_at : float
  ; ceiling_s : float
  }

let make ?(ceiling_s = default_ceiling_s) ~(now : unit -> float) () =
  { now; started_at = now (); ceiling_s }
;;

let remaining t = t.ceiling_s -. (t.now () -. t.started_at)

let expired t = remaining t <= 0.0

(** Cap a per-operation idle window so an in-flight read or write cannot
    outlive the ceiling by up to one idle window. [None] (no idle deadline
    requested) still yields the remaining budget: the ceiling is always a
    deadline, never a request. *)
let cap_window t (window_s : float option) : float option =
  match window_s with
  | Some window_s -> Some (Float.min window_s (remaining t))
  | None -> Some (remaining t)
;;
