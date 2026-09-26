(** Process-local provider quota windows.  See the [.mli] for the contract.

    Implementation notes, mirroring {!Runtime_candidate_backpressure}:

    - State is a small [Hashtbl] guarded by [Stdlib.Mutex] (record/read may
      be called from outside Eio fibers, so [Eio.Mutex] is not required).
    - Expiry is lazy against the provider-stated [resets_at]; reads prune
      passed windows.  [now] is a parameter rather than a wall-clock read
      so the ordering decision is testable without stubbing time. *)

type scope =
  | Provider_row of string
  | Credential_env of string
  | Credential_file of string
  | Official_client_home of string * string

(* Two facts, not one duration. [Until] is the provider's own reset time.
   [Observed] is a hard-quota rejection that stated no reset. It claims no end
   time; the next success on the scope clears it. Coarse 429 evidence does not
   establish this credential ownership and uses candidate backpressure. *)
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

let scope_to_string = function
  | Provider_row row -> "provider:" ^ row
  | Credential_env name -> "env:" ^ name
  | Credential_file path -> "file:" ^ path
  | Official_client_home (client, home) -> "official:" ^ client ^ ":home:" ^ home

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
    ~default_subdir:".claude"
;;

let scope_of_codex_home =
  official_client_scope ~client:"codex-app-server" ~env_name:"CODEX_HOME"
    ~default_subdir:".codex"
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
