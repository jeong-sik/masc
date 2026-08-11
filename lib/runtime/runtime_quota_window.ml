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

let windows : (scope, float) Hashtbl.t = Hashtbl.create 4
let mu = Stdlib.Mutex.create ()

let note_exhausted ~scope ~resets_at =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    | Some existing when Float.compare existing resets_at >= 0 -> ()
    | Some _ | None -> Hashtbl.replace windows scope resets_at)

let active_until ~scope ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    | None -> None
    | Some resets_at ->
      if Float.compare now resets_at < 0
      then Some resets_at
      else begin
        Hashtbl.remove windows scope;
        None
      end)

let demote_order ~now ~quota_scope_of candidates =
  let kept, demoted =
    List.partition
      (fun candidate ->
        match quota_scope_of candidate with
        | None -> true
        | Some scope -> Option.is_none (active_until ~scope ~now))
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
