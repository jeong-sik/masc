(** Process-local provider quota windows.  See the [.mli] for the contract.

    Implementation notes, mirroring {!Runtime_lane_preference}:

    - State is a small [Hashtbl] guarded by [Stdlib.Mutex] (record/read may
      be called from outside Eio fibers, so [Eio.Mutex] is not required).
    - Expiry is lazy against the provider-stated [resets_at]; reads prune
      passed windows.  [now] is a parameter rather than a wall-clock read
      so the ordering decision is testable without stubbing time. *)

let windows : (string, float) Hashtbl.t = Hashtbl.create 4
let mu = Stdlib.Mutex.create ()

let note_exhausted ~provider_id ~resets_at =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows provider_id with
    | Some existing when Float.compare existing resets_at >= 0 -> ()
    | Some _ | None -> Hashtbl.replace windows provider_id resets_at)

let active_until ~provider_id ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows provider_id with
    | None -> None
    | Some resets_at ->
      if Float.compare now resets_at < 0
      then Some resets_at
      else begin
        Hashtbl.remove windows provider_id;
        None
      end)

let demote_order ~now ~quota_scope_of candidates =
  let demoted =
    List.filter
      (fun candidate ->
        match quota_scope_of candidate with
        | None -> false
        | Some provider_id ->
          Option.is_some (active_until ~provider_id ~now))
      candidates
  in
  match demoted with
  | [] -> candidates
  | _ ->
    let kept =
      List.filter
        (fun candidate ->
          not (List.exists (String.equal candidate) demoted))
        candidates
    in
    kept @ demoted

let scope_of_credential ~provider_id (credential : Runtime_schema.credential option) =
  match credential with
  | Some (Runtime_schema.Env key) -> "env:" ^ key
  | Some (Runtime_schema.File path) -> "file:" ^ path
  (* The inline carrier is the secret itself, so it cannot name a shared
     account without leaking; the row id is the narrowest honest scope. *)
  | Some (Runtime_schema.Inline _) | None -> provider_id

let reset_for_testing () =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.reset windows)
