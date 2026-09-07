(** Process-local provider quota windows.  See the [.mli] for the contract.

    Implementation notes, mirroring {!Runtime_lane_preference}:

    - State is a small [Hashtbl] guarded by [Stdlib.Mutex] (record/read may
      be called from outside Eio fibers, so [Eio.Mutex] is not required).
    - Expiry is lazy against the provider-stated [resets_at]; reads prune
      passed windows.  [now] is a parameter rather than a wall-clock read
      so the ordering decision is testable without stubbing time. *)

type scope =
  | Provider_row of string
  | Credential_env of string
  | Credential_file of string

(* Two facts, not one duration. [Until] is the provider's own reset time.
   [Observed] is a hard-quota rejection that stated no reset -- both metered
   providers this fleet reaches answer that way (2026-09-06: ollama.com and
   api.z.ai each return 429 with no Retry-After), so without it the window
   never records and every lane re-dispatches into an exhausted account all
   day. It claims no end time; the next success on the scope clears it. *)
type window =
  | Until of float
  | Observed

let windows : (scope, window) Hashtbl.t = Hashtbl.create 4
let mu = Stdlib.Mutex.create ()

let note_exhausted ~scope ~resets_at =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    | Some (Until existing) when Float.compare existing resets_at >= 0 -> ()
    (* A stated reset is more than an observation, so it replaces one. *)
    | Some (Until _) | Some Observed | None ->
      Hashtbl.replace windows scope (Until resets_at))

let note_observed_exhausted ~scope =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    (* A stated window already says more; do not weaken it. *)
    | Some (Until _) -> ()
    | Some Observed | None -> Hashtbl.replace windows scope Observed)

let note_succeeded ~scope =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    (* Only an observation is cleared by a call getting through. A stated
       window is the provider's own answer about a time, and one success
       inside it does not make it untrue. *)
    | Some Observed -> Hashtbl.remove windows scope
    | Some (Until _) | None -> ())

let active_until ~scope ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    | None | Some Observed -> None
    | Some (Until resets_at) ->
      if Float.compare now resets_at < 0
      then Some resets_at
      else begin
        Hashtbl.remove windows scope;
        None
      end)

(* Whether ordering should hold this scope back at [now]: a stated window that
   has not passed, or an observation that no success has cleared. Prunes a
   passed window the way [active_until] does. *)
let is_exhausted ~scope ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    | None -> false
    | Some Observed -> true
    | Some (Until resets_at) ->
      if Float.compare now resets_at < 0
      then true
      else begin
        Hashtbl.remove windows scope;
        false
      end)

let demote_order ~now ~quota_scope_of candidates =
  let kept, demoted =
    List.partition
      (fun candidate ->
        match quota_scope_of candidate with
        | None -> true
        | Some scope -> not (is_exhausted ~scope ~now))
      candidates
  in
  match demoted with [] -> candidates | _ -> kept @ demoted

let scope_of_credential ~provider_id (credential : Runtime_schema.credential option) =
  match credential with
  | Some (Runtime_schema.Env key) -> Credential_env key
  | Some (Runtime_schema.File path) -> Credential_file path
  (* The inline carrier is the secret itself, so it cannot name a shared
     account without leaking; the row id is the narrowest honest scope. *)
  | Some (Runtime_schema.Inline _) | None -> Provider_row provider_id

let reset_for_testing () =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.reset windows)
