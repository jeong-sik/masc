(** Process-local provider quota windows.  See the [.mli] for the contract.

    Implementation notes, mirroring {!Runtime_candidate_backpressure}:

    - State is a small [Hashtbl] guarded by [Stdlib.Mutex] (record/read may
      be called from outside Eio fibers, so [Eio.Mutex] is not required).
    - Expiry is lazy against the provider-stated [resets_at] or an
      observation's [rests_until]; reads prune passed entries.  [now] is a
      parameter of every read rather than a wall-clock read so the ordering
      decision is testable without stubbing time. *)

type scope =
  | Provider_row of string
  | Credential_env of string
  | Credential_file of string
  | Official_client_home of string * string

(* Two facts, not one duration. [Until] is the provider's own reset time.
   [Observed] is a spent quota that stated no reset. It rests the scope for
   the hard-quota fallback ([path_rest_sec] of [Hard_quota] without a hint,
   the operator's declared cap) from the moment it was noted, and the next
   success on the scope clears it sooner (RFC-provider-path-rest §3.3).
   Coarse 429 evidence does not establish this credential ownership and uses
   candidate backpressure. Who set the entry is kept with it: a refusal
   without a reset leaves a question a usage read may still answer with a
   date, and a read that found no reset has answered it. The refusal keeps
   the typed constructor that refused, so a 402 and a spent usage window stay
   two facts for whoever shows the scope. *)
type refusal = Keeper_runtime_failure_route.hard_quota_source =
  | Payment_refused
  | Provider_quota_refused

type cause =
  | Refused of refusal
  | Usage_read

type window =
  | Until of
      { resets_at : float
      ; cause : cause
      }
  | Observed of
      { cause : cause
      ; rests_until : float
      }

(* A usage read reports the provider's own quota window, so its rest is the
   one a quota refusal without a reset takes. *)
let observed_rest_sec cause =
  let source =
    match cause with
    | Refused source -> source
    | Usage_read -> Provider_quota_refused
  in
  Keeper_runtime_failure_route.path_rest_sec
    ~cap_sec:Env_config_keeper.KeeperKeepalive.rate_limit_backoff_cap_sec
    ~retry_class:(Keeper_runtime_failure_route.Hard_quota source)
    ~retry_after_hint:None

let windows : (scope, window) Hashtbl.t = Hashtbl.create 4
let mu = Stdlib.Mutex.create ()

let note_until ~scope ~cause ~resets_at =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    | Some (Until { resets_at = existing; cause = _ })
      when Float.compare existing resets_at >= 0 -> ()
    (* A stated reset is more than an observation, so it replaces one. *)
    | Some (Until _) | Some (Observed _) | None ->
      Hashtbl.replace windows scope (Until { resets_at; cause }));
  Runtime_path_rest_signal.recorded ()

let note_exhausted ~scope ~source ~resets_at =
  note_until ~scope ~cause:(Refused source) ~resets_at

let note_read_spent_until ~scope ~resets_at =
  note_until ~scope ~cause:Usage_read ~resets_at

let note_observed_at ~now ~scope cause =
  (* NDT-OK: the wall clock is the default moment an observation is noted,
     not the only admissible one. It dates the rest, and tells whether a
     held entry has passed. A caller that already holds the moment passes it
     in, so a fixture is dated deterministically instead of against the
     instant the test happens to run. A passed entry that no read has pruned
     yet names no rest, and keeping it over this observation would leave the
     scope looking available. *)
  let observed = Observed { cause; rests_until = now +. observed_rest_sec cause } in
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope, cause with
    (* A stated window still ahead says more; do not weaken it. *)
    | Some (Until { resets_at; cause = _ }), (Refused _ | Usage_read)
      when Float.compare now resets_at < 0 -> ()
    (* A read already answered the question a refusal asks, until its rest
       ends. *)
    | Some (Observed { cause = Usage_read; rests_until }), Refused _
      when Float.compare now rests_until < 0 -> ()
    | (Some (Until _) | Some (Observed _) | None), (Refused _ | Usage_read) ->
      Hashtbl.replace windows scope observed);
  Runtime_path_rest_signal.recorded ()

(* Real provider paths keep the wall clock; a caller that already holds the
   moment (a fixture, a replay) passes it in through the [_at] entry points. *)
let note_observed ~scope cause =
  note_observed_at ~now:(Unix.gettimeofday ()) ~scope cause

let note_observed_exhausted ~scope ~source = note_observed ~scope (Refused source)
let note_read_without_reset ~scope = note_observed ~scope Usage_read

let note_observed_exhausted_at ~now ~scope ~source =
  note_observed_at ~now ~scope (Refused source)

let note_read_without_reset_at ~now ~scope =
  note_observed_at ~now ~scope Usage_read

let note_succeeded ~scope =
  Stdlib.Mutex.protect mu (fun () ->
    match Hashtbl.find_opt windows scope with
    (* Only an observation is cleared by a call getting through. A stated
       window is the provider's own answer about a time, and one success
       inside it does not make it untrue. *)
    | Some (Observed _) -> Hashtbl.remove windows scope
    | Some (Until _) | None -> ());
  Runtime_path_rest_signal.recorded ()

(* The entry that still rests [scope] at [now], pruning one that has passed.
   Callers hold [mu]. *)
let live_entry ~scope ~now =
  match Hashtbl.find_opt windows scope with
  | None -> None
  | Some (Until { resets_at; cause = _ } as window)
  | Some (Observed { rests_until = resets_at; cause = _ } as window) ->
    if Float.compare now resets_at < 0
    then Some window
    else begin
      Hashtbl.remove windows scope;
      None
    end

let active_until ~scope ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match live_entry ~scope ~now with
    | None | Some (Observed _) -> None
    | Some (Until { resets_at; cause = _ }) -> Some resets_at)

type rest =
  | Reset_stated of float
  | Observed_until of float

let rest ~scope ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match live_entry ~scope ~now with
    | None -> None
    | Some (Until { resets_at; cause = _ }) -> Some (Reset_stated resets_at)
    | Some (Observed { rests_until; cause = _ }) -> Some (Observed_until rests_until))

type spent =
  { cause : cause
  ; rest : rest
  }

let spent ~scope ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match live_entry ~scope ~now with
    | None -> None
    | Some (Until { resets_at; cause }) -> Some { cause; rest = Reset_stated resets_at }
    | Some (Observed { rests_until; cause }) -> Some { cause; rest = Observed_until rests_until })

(* Whether ordering should hold this scope back at [now]: a stated window or
   an observation whose rest has not passed. Prunes a passed entry the way
   [active_until] does. *)
let is_exhausted ~scope ~now =
  Stdlib.Mutex.protect mu (fun () -> Option.is_some (live_entry ~scope ~now))

let cause_to_wire_name = function
  | Refused Payment_refused -> "payment_refused"
  | Refused Provider_quota_refused -> "provider_quota_refused"
  | Usage_read -> "usage_read"

let cause_of_wire_name name =
  List.find_map
    (fun cause -> if String.equal (cause_to_wire_name cause) name then Some cause else None)
    [ Refused Payment_refused; Refused Provider_quota_refused; Usage_read ]

type answered_rest =
  | Stated_reset_ahead
  | Read_found_no_reset

(* What a provider answer already says about [scope]'s rest, as a usage read
   asks it: a stated reset still ahead, or a read that found the window spent
   with no reset. A refusal's own observation is no answer. Prunes a passed
   window the way [active_until] does. *)
let answered_rest ~scope ~now =
  Stdlib.Mutex.protect mu (fun () ->
    match live_entry ~scope ~now with
    | None | Some (Observed { cause = Refused _; rests_until = _ }) -> None
    | Some (Observed { cause = Usage_read; rests_until = _ }) -> Some Read_found_no_reset
    | Some (Until _) -> Some Stated_reset_ahead)

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

let scope_to_string = function
  | Provider_row row -> "provider:" ^ row
  | Credential_env name -> "env:" ^ name
  | Credential_file path -> "file:" ^ path
  | Official_client_home (client, home) -> "official:" ^ client ^ ":home:" ^ home

(* Preserve the IDs already persisted by provider Usage history. These name
   credential locations, not the provider accounts whose secrets occupy them. *)
let scope_id scope = Digest.to_hex (Digest.string (scope_to_string scope))

let scope_equal left right =
  match left, right with
  | Provider_row a, Provider_row b
  | Credential_env a, Credential_env b
  | Credential_file a, Credential_file b -> String.equal a b
  | Official_client_home (a_client, a_home), Official_client_home (b_client, b_home) ->
    String.equal a_client b_client && String.equal a_home b_home
  | (Provider_row _ | Credential_env _ | Credential_file _
    | Official_client_home _), _ -> false
;;

let official_client_scope ~client ~env_name ~default_subdir account_home =
  let selected =
    match account_home with
    | Some path -> Runtime_account_home.of_string path
    | None ->
      (match Env_config_core.raw_value_opt env_name with
       | Some path when path <> "" -> Runtime_account_home.of_inherited path
       | Some _ | None ->
         (match Env_config_core.raw_value_opt "HOME" with
          | Some path -> Runtime_account_home.of_string (Filename.concat path default_subdir)
          | None -> Error "HOME is absent"))
  in
  match selected with
  | Ok path -> Official_client_home (client, path)
  | Error _ ->
    invalid_arg ("official client " ^ client ^ " has no absolute account home")
;;

let scope_of_claude_code_home =
  official_client_scope ~client:"claude-code" ~env_name:"CLAUDE_CONFIG_DIR"
    ~default_subdir:(Runtime_official_account.default_directory Claude_code)
;;

let scope_of_codex_home =
  official_client_scope ~client:"codex-app-server" ~env_name:"CODEX_HOME"
    ~default_subdir:(Runtime_official_account.default_directory Codex)
;;

let scope_of_muse_home home =
  Official_client_home ("muse-serve", home)
;;

let scope_of_credential ~provider_id (credential : Runtime_schema.credential option) =
  match credential with
  | Some (Runtime_schema.Env key) -> Credential_env key
  | Some (Runtime_schema.File path) -> Credential_file path
  (* The inline carrier is the secret itself, so it cannot name a shared
     account without leaking; the row id is the narrowest honest scope. *)
  | Some (Runtime_schema.Inline _) | None -> Provider_row provider_id

let reset_for_testing () =
  Stdlib.Mutex.protect mu (fun () -> Hashtbl.reset windows)
