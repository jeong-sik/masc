type init_error =
  | Already_initialized of { base_path : string }
  | Runtime_creation_failed of Agent_sdk.Error.sdk_error
  | Storage_root_failed of string

type prepare_error =
  | Runtime_not_initialized
  | Runtime_released of { base_path : string }
  | Invalid_recovery_key
  | Recovery_key_already_active
  | Recovery_state_failed of string

type finish_error = Recovery_cleanup_failed of string

type recovery_record =
  { recovery_key : string
  ; agent_name : string
  ; scope_leaf : string
  ; locator_json : Yojson.Safe.t
  }

type active =
  { token : unit ref
  ; base_path : string
  ; runtime : Agent_sdk.Agent.execution_runtime
  ; runs_root : Eio.Fs.dir_ty Eio.Path.t
  ; slots_root : Eio.Fs.dir_ty Eio.Path.t
  ; state_mu : Eio.Mutex.t
  ; active_keys : (string, unit) Hashtbl.t
  }

type lifecycle =
  | Never_initialized
  | Active of active
  | Released of { base_path : string }

type prepared =
  { owner : active
  ; recovery_key : string
  ; context : Agent_sdk.Context.t
  ; slot_path : Eio.Fs.dir_ty Eio.Path.t
  ; unused_fresh_scope : Eio.Fs.dir_ty Eio.Path.t option ref
  ; record : recovery_record option ref
  ; ready : bool ref
  ; finished : bool ref
  ; store : Agent_sdk.Agent.execution_store
  }

module Storage = Runtime_oas_execution_storage

exception Operation_failed of string

let require_ok = function
  | Ok value -> value
  | Error detail -> raise (Operation_failed detail)
;;

let lifecycle = Atomic.make Never_initialized
let context_key = "masc.oas_execution.v1"
let record_schema = "masc.oas-execution-recovery.v1"
let max_record_bytes = 1024 * 1024

let init_error_to_string = function
  | Already_initialized { base_path } ->
    Printf.sprintf "OAS execution runtime is already initialized for %s" base_path
  | Runtime_creation_failed error ->
    "OAS execution runtime creation failed: " ^ Agent_sdk.Error.to_string error
  | Storage_root_failed detail ->
    "OAS execution storage root preparation failed: " ^ detail
;;

let prepare_error_to_string = function
  | Runtime_not_initialized ->
    "OAS execution runtime is not initialized; refusing non-durable fallback"
  | Runtime_released { base_path } ->
    Printf.sprintf
      "OAS execution runtime for %s has been released; refusing non-durable fallback"
      base_path
  | Invalid_recovery_key -> "OAS execution recovery key must not be empty"
  | Recovery_key_already_active ->
    "OAS execution recovery key already has an active in-process call"
  | Recovery_state_failed detail -> "OAS execution recovery state failed: " ^ detail
;;

let finish_error_to_string (Recovery_cleanup_failed detail) =
  "OAS execution recovery cleanup failed: " ^ detail
;;

let release token base_path =
  let rec loop () =
    let observed = Atomic.get lifecycle in
    match observed with
    | Active current when current.token == token ->
      if not (Atomic.compare_and_set lifecycle observed (Released { base_path }))
      then loop ()
    | Never_initialized | Active _ | Released _ -> ()
  in
  loop ()
;;

let initialize ~sw ~domain_mgr ~fs ~base_path ~domain_count =
  let observed = Atomic.get lifecycle in
  match observed with
  | Active current -> Error (Already_initialized { base_path = current.base_path })
  | Never_initialized | Released _ ->
    (match Agent_sdk.Agent.create_execution_runtime ~sw ~domain_mgr ~domain_count with
     | Error error -> Error (Runtime_creation_failed error)
     | Ok runtime ->
       (try
          let base_dir = Eio.Path.open_dir ~sw Eio.Path.(fs / base_path) in
          let masc_dir =
            require_ok (Storage.ensure_private_child ~sw base_dir Common.masc_dirname)
          in
          let storage_root =
            require_ok (Storage.ensure_private_child ~sw masc_dir "oas-execution")
          in
          let runs_root =
            require_ok (Storage.ensure_private_child ~sw storage_root "runs")
          in
          let slots_root =
            require_ok (Storage.ensure_private_child ~sw storage_root "slots")
          in
          let token = ref () in
          let current =
            { token
            ; base_path
            ; runtime
            ; runs_root
            ; slots_root
            ; state_mu = Eio.Mutex.create ()
            ; active_keys = Hashtbl.create 17
            }
          in
          Eio.Switch.on_release sw (fun () -> release token base_path);
          if Atomic.compare_and_set lifecycle observed (Active current)
          then Ok ()
          else
            (match Atomic.get lifecycle with
             | Active existing ->
               Error (Already_initialized { base_path = existing.base_path })
             | Never_initialized | Released _ ->
               Error
                 (Storage_root_failed
                    "execution runtime lifecycle changed during initialization"))
        with
        | Eio.Cancel.Cancelled _ as exn -> raise exn
        | Operation_failed detail -> Error (Storage_root_failed detail)
        | exn -> Error (Storage_root_failed (Printexc.to_string exn))))
;;

let valid_scope_leaf value =
  let prefix = "run-" in
  let prefix_length = String.length prefix in
  String.length value = prefix_length + 32
  && String.sub value 0 prefix_length = prefix
  && String.for_all
       (function
         | '0' .. '9' | 'a' .. 'f' -> true
         | _ -> false)
       (String.sub value prefix_length 32)
;;

let record_json (record : recovery_record) =
  `Assoc
    [ "schema", `String record_schema
    ; "recovery_key", `String record.recovery_key
    ; "agent_name", `String record.agent_name
    ; "scope_leaf", `String record.scope_leaf
    ; "locator", record.locator_json
    ]
;;

let parse_record json =
  let fail detail = Error detail in
  match json with
  | `Assoc fields ->
    let keys = List.map fst fields in
    let expected = [ "agent_name"; "locator"; "recovery_key"; "schema"; "scope_leaf" ] in
    if List.sort_uniq String.compare keys <> expected || List.length keys <> List.length expected
    then fail "recovery record has missing, duplicate, or unknown fields"
    else
      let field name = List.assoc name fields in
      (match field "schema", field "recovery_key", field "agent_name", field "scope_leaf" with
       | `String schema, `String recovery_key, `String agent_name, `String scope_leaf ->
         if not (String.equal schema record_schema)
         then fail (Printf.sprintf "unsupported recovery record schema %S" schema)
         else if String.equal recovery_key ""
         then fail "recovery record has an empty recovery key"
         else if String.equal agent_name ""
         then fail "recovery record has an empty agent name"
         else if not (valid_scope_leaf scope_leaf)
         then fail (Printf.sprintf "invalid recovery scope leaf %S" scope_leaf)
         else
           let locator_json = field "locator" in
           (match Agent_sdk.Agent.execution_locator_of_yojson locator_json with
            | Error detail -> fail ("invalid OAS execution locator: " ^ detail)
            | Ok _ -> Ok { recovery_key; agent_name; scope_leaf; locator_json })
       | _ -> fail "recovery record fields have invalid JSON types")
  | _ -> fail "recovery record must be a JSON object"
;;

let same_record (left : recovery_record) (right : recovery_record) =
  String.equal left.recovery_key right.recovery_key
  && String.equal left.agent_name right.agent_name
  && String.equal left.scope_leaf right.scope_leaf
  && left.locator_json = right.locator_json
;;

let context_record context =
  match Agent_sdk.Context.get_scoped context Agent_sdk.Context.Session context_key with
  | None -> Ok None
  | Some json -> Result.map Option.some (parse_record json)
;;

let slot_leaf recovery_key =
  Digestif.SHA256.(digest_string (record_schema ^ "\000" ^ recovery_key) |> to_hex)
  ^ ".json"
;;

let load_slot slot_path =
  match Storage.load_json ~max_bytes:max_record_bytes slot_path with
  | Error _ as error -> error
  | Ok None -> Ok None
  | Ok (Some json) -> Result.map Option.some (parse_record json)
;;

let persist_slot slots_root slot_path record =
  let payload = Yojson.Safe.to_string (record_json record) ^ "\n" in
  Storage.persist_exclusive
    ~max_bytes:max_record_bytes
    ~parent:slots_root
    ~path:slot_path
    payload
;;

let remove_slot slots_root slot_path =
  Storage.remove_file ~parent:slots_root slot_path
;;

let release_key prepared =
  Eio.Mutex.use_rw ~protect:true prepared.owner.state_mu (fun () ->
    Hashtbl.remove prepared.owner.active_keys prepared.recovery_key)
;;

let prepare_active ~sw ~recovery_key agent owner =
  if String.equal recovery_key ""
  then Error Invalid_recovery_key
  else
    Eio.Mutex.use_rw ~protect:true owner.state_mu
    @@ fun () ->
    if Hashtbl.mem owner.active_keys recovery_key
    then Error Recovery_key_already_active
    else (
      Hashtbl.add owner.active_keys recovery_key ();
      try
        let context = Agent_sdk.Agent.context agent in
        let agent_name = (Agent_sdk.Agent.state agent).config.name in
        if String.equal agent_name ""
        then raise (Operation_failed "agent name must not be empty");
        let slot_path = Eio.Path.(owner.slots_root / slot_leaf recovery_key) in
        let context_state =
          match context_record context with
          | Ok value -> value
          | Error detail ->
            raise (Operation_failed ("invalid checkpoint recovery record: " ^ detail))
        in
        let slot_state =
          match load_slot slot_path with
          | Ok value -> value
          | Error detail ->
            raise (Operation_failed ("invalid durable recovery slot: " ^ detail))
        in
        let record, resume, scope_dir, unused_fresh_scope =
          match slot_state, context_state with
          | None, None ->
            let scope_leaf = Random_id.prefixed ~prefix:"run-" ~bytes:16 in
            let scope_dir =
              require_ok (Storage.create_private_child ~sw owner.runs_root scope_leaf)
            in
            None, None, scope_dir, Some scope_dir
          | Some slot_record, Some checkpoint_record ->
            if not (same_record slot_record checkpoint_record)
            then
              raise
                (Operation_failed
                   "durable slot and checkpoint recovery record differ");
            if not (String.equal slot_record.recovery_key recovery_key)
            then
              raise
                (Operation_failed
                   "durable slot recovery key does not match the requested key");
            if not (String.equal slot_record.agent_name agent_name)
            then
              raise
                (Operation_failed
                   "durable slot agent identity does not match the resumed agent");
            let scope_path = Eio.Path.(owner.runs_root / slot_record.scope_leaf) in
            (match Eio.Path.kind ~follow:false scope_path with
             | `Directory -> ()
             | kind ->
               raise
                 (Operation_failed
                    (Printf.sprintf
                       "recovery execution directory is %s"
                       (match kind with
                        | `Not_found -> "missing"
                        | `Symbolic_link -> "symbolic_link"
                        | _ -> "not_a_directory"))));
            let locator =
              match Agent_sdk.Agent.execution_locator_of_yojson slot_record.locator_json with
              | Ok locator -> locator
              | Error detail ->
                raise (Operation_failed ("invalid OAS execution locator: " ^ detail))
            in
            ( Some slot_record
            , Some locator
            , require_ok (Storage.open_verified_directory ~sw scope_path)
            , None )
          | Some _, None ->
            raise
              (Operation_failed
                 "durable recovery slot exists but the restored checkpoint has no matching record")
          | None, Some _ ->
            raise
              (Operation_failed
                 "restored checkpoint has a recovery record but its durable slot is missing")
        in
        let record_ref = ref record in
        let unused_fresh_scope = ref unused_fresh_scope in
        let ready = ref false in
        let on_scope_ready locator =
          unused_fresh_scope := None;
          let locator_json = Agent_sdk.Agent.execution_locator_to_yojson locator in
          match !record_ref with
          | Some expected ->
            if expected.locator_json <> locator_json
            then Error "resumed OAS execution locator differs from the durable record"
            else (
              ready := true;
              Ok ())
          | None ->
            let fresh =
              { recovery_key
              ; agent_name
              ; scope_leaf =
                  (match Eio.Path.native scope_dir with
                   | Some path -> Filename.basename path
                   | None ->
                     raise
                       (Operation_failed "execution directory has no native identity"))
              ; locator_json
              }
            in
            Agent_sdk.Context.set_scoped
              context
              Agent_sdk.Context.Session
              context_key
              (record_json fresh);
            (match persist_slot owner.slots_root slot_path fresh with
             | Ok () ->
               record_ref := Some fresh;
               ready := true;
               Ok ()
             | Error detail ->
               Agent_sdk.Context.delete_scoped
                 context
                 Agent_sdk.Context.Session
                 context_key;
               Error detail)
        in
        let store =
          Agent_sdk.Agent.execution_store
            ~runtime:owner.runtime
            ~dir:scope_dir
            ~on_scope_ready
            ?resume
            ()
        in
        Ok
          { owner
          ; recovery_key
          ; context
          ; slot_path
          ; unused_fresh_scope
          ; record = record_ref
          ; ready
          ; finished = ref false
          ; store
          }
      with
      | Eio.Cancel.Cancelled _ as exn ->
        Hashtbl.remove owner.active_keys recovery_key;
        raise exn
      | Operation_failed detail ->
        Hashtbl.remove owner.active_keys recovery_key;
        Error (Recovery_state_failed detail)
      | exn ->
        Hashtbl.remove owner.active_keys recovery_key;
        Error (Recovery_state_failed (Printexc.to_string exn)))
;;

let prepare ~sw ~recovery_key agent =
  match Atomic.get lifecycle with
  | Released { base_path } -> Error (Runtime_released { base_path })
  | Never_initialized -> Error Runtime_not_initialized
  | Active owner -> prepare_active ~sw ~recovery_key agent owner
;;

let execution_store prepared = prepared.store

let cleanup_unused_fresh_scope prepared =
  match !(prepared.unused_fresh_scope) with
  | None -> Ok ()
  | Some scope_dir ->
    (match Storage.remove_empty_directory ~parent:prepared.owner.runs_root scope_dir with
     | Error _ as error -> error
     | Ok () ->
       prepared.unused_fresh_scope := None;
       Ok ())
;;

let retain_failure prepared =
  if not !(prepared.finished)
  then (
    (match cleanup_unused_fresh_scope prepared with
     | Ok () -> ()
     | Error detail ->
       Log.Misc.warn
         "OAS unused fresh execution scope cleanup failed while retaining failure: %s"
         detail);
    prepared.finished := true;
    release_key prepared)
;;

let finish prepared =
  if !(prepared.finished)
  then Ok ()
  else if not !(prepared.ready)
  then
    let cleanup = cleanup_unused_fresh_scope prepared in
    prepared.finished := true;
    release_key prepared;
    Result.map_error (fun detail -> Recovery_cleanup_failed detail) cleanup
  else
    Eio.Mutex.use_rw ~protect:true prepared.owner.state_mu
    @@ fun () ->
    let fail detail =
      prepared.finished := true;
      Hashtbl.remove prepared.owner.active_keys prepared.recovery_key;
      Error (Recovery_cleanup_failed detail)
    in
    (match !(prepared.record) with
       | None -> fail "ready execution has no recovery record"
       | Some expected ->
         (match context_record prepared.context with
          | Error detail -> fail ("invalid checkpoint recovery record: " ^ detail)
          | Ok None -> fail "ready execution has no checkpoint recovery record"
          | Ok (Some context_record) when not (same_record expected context_record) ->
            fail "checkpoint recovery record changed before terminal cleanup"
          | Ok (Some _) ->
            (match load_slot prepared.slot_path with
             | Error detail -> fail ("invalid durable recovery slot: " ^ detail)
             | Ok None -> fail "durable recovery slot disappeared before terminal cleanup"
             | Ok (Some slot_record) when not (same_record expected slot_record) ->
               fail "durable recovery slot changed before terminal cleanup"
             | Ok (Some _) ->
               (match remove_slot prepared.owner.slots_root prepared.slot_path with
                | Error detail -> fail detail
                | Ok () ->
                  Agent_sdk.Context.delete_scoped
                    prepared.context
                    Agent_sdk.Context.Session
                    context_key;
                  prepared.finished := true;
                  Hashtbl.remove prepared.owner.active_keys prepared.recovery_key;
                  (* Reclaim the execution scope (its OAS effect journal) now
                     that the recovery slot and checkpoint record are gone.
                     Recovery correctness is already satisfied by the slot and
                     record removal above; failing to unlink the scope tree only
                     leaks one directory, so it is logged rather than turned into
                     a settlement failure that would strand the completed turn.
                     A crash between the slot removal and this cleanup leaves an
                     orphan directory referenced by no slot, which is never
                     resumed. *)
                  let scope_path =
                    Eio.Path.(prepared.owner.runs_root / expected.scope_leaf)
                  in
                  (match
                     Storage.remove_directory_tree
                       ~parent:prepared.owner.runs_root
                       scope_path
                   with
                   | Ok () -> ()
                   | Error detail ->
                     Log.Misc.warn
                       "OAS settled execution scope %s cleanup failed: %s"
                       expected.scope_leaf
                       detail);
                  Ok ()))))
;;

let finish_checkpoint prepared checkpoint =
  match finish prepared with
  | Error _ as error -> error
  | Ok () ->
    let context = Agent_sdk.Context.copy ~eio:true checkpoint.Agent_sdk.Checkpoint.context in
    Agent_sdk.Context.delete_scoped
      context
      Agent_sdk.Context.Session
      context_key;
    Ok { checkpoint with Agent_sdk.Checkpoint.context }
;;
