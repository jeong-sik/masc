(** Durable lifecycle tests for the BasePath-scoped MCP HTTP session store.

    Every store is owned by an explicit Eio switch.  Tests that reopen a store
    use a new switch, so success is also proof that the preceding close or
    failed restore released both the file lock and the in-process reservation. *)

open Alcotest
module Store = Server_mcp_transport_session_store

let rec remove_tree path =
  match Unix.lstat path with
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
  | { Unix.st_kind = Unix.S_DIR; _ } ->
    Array.iter
      (fun entry -> remove_tree (Filename.concat path entry))
      (Sys.readdir path);
    Unix.rmdir path
  | _ -> Unix.unlink path

let with_temp_root f =
  let path, channel =
    Filename.open_temp_file "masc-mcp-session-store-" ".directory"
  in
  close_out channel;
  Unix.unlink path;
  Unix.mkdir path 0o700;
  Fun.protect ~finally:(fun () -> remove_tree path) (fun () -> f path)

let mkdir path = Unix.mkdir path 0o700

let with_switch f =
  Eio_main.run (fun _env -> Eio.Switch.run (fun sw -> f sw))

let require_open = function
  | Ok store -> store
  | Error error -> fail (Store.open_error_to_string error)

let require_initialize store session =
  match Store.initialize store session with
  | Ok () -> ()
  | Error error -> fail (Store.mutation_error_to_string error)

let require_delete store ~session_id ~deleted_at =
  match Store.delete store ~session_id ~deleted_at with
  | Ok result -> result
  | Error error -> fail (Store.mutation_error_to_string error)

let require_store_locked = function
  | Error (Store.Store_locked { lock_path }) -> lock_path
  | Error error ->
    failf "expected Store_locked, got %s" (Store.open_error_to_string error)
  | Ok _ -> fail "a second handle unexpectedly acquired the same store"

let require_store_directory_rejected ~expected_path = function
  | Error
      (Store.Open_filesystem_error
        { stage = Store.Validate_store_directory; path; _ }) ->
    check string "rejected store-directory path" expected_path path
  | Error error ->
    failf
      "expected Validate_store_directory rejection, got %s"
      (Store.open_error_to_string error)
  | Ok _ -> fail "a symlinked store directory was silently accepted"

let make_session ?(owner_name = "session-store-owner") session_id : Store.session =
  let owner : Server_transport_admission.identity =
    { agent_name = owner_name; role = Masc_domain.Worker }
  in
  { session_id
  ; protocol_version = Mcp_transport_protocol.default_protocol_version
  ; tool_profile = Server_mcp_transport_http_types.Full
  ; owner
  ; started_at = 10.0
  ; transport_context = None
  }

let check_session ~label expected actual =
  check string (label ^ " id") expected.Store.session_id actual.Store.session_id;
  check string
    (label ^ " protocol")
    expected.protocol_version
    actual.protocol_version;
  check bool
    (label ^ " profile")
    true
    (expected.tool_profile = actual.tool_profile);
  check string
    (label ^ " owner")
    expected.owner.agent_name
    actual.owner.agent_name;
  check bool (label ^ " role") true (expected.owner.role = actual.owner.role);
  check (float 0.0) (label ^ " started_at") expected.started_at actual.started_at;
  check bool
    (label ^ " transport context")
    true
    (expected.transport_context = actual.transport_context)

let store_and_lock ~sw ~base_path =
  let store = require_open (Store.open_ ~sw ~base_path) in
  let lock_path = require_store_locked (Store.open_ ~sw ~base_path) in
  store, lock_path

let canonical_entry_path ~store_dir session_id =
  let digest = Digestif.SHA256.(digest_string session_id |> to_hex) in
  Filename.concat store_dir (digest ^ ".json")

let write_file path contents =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out channel)
    (fun () -> output_string channel contents)

let expect_restore_failure ~base_path check_failure =
  with_switch (fun sw ->
    match Store.open_ ~sw ~base_path with
    | Error (Store.Restore_failed failure) -> check_failure failure
    | Error error ->
      failf
        "expected Restore_failed, got %s"
        (Store.open_error_to_string error)
    | Ok _ -> fail "invalid durable state was silently restored")

let test_empty_open_self_lock_and_reopen () =
  with_temp_root (fun base_path ->
    let first_lock_path =
      with_switch (fun sw ->
        (match Store.open_ ~sw ~base_path:"" with
         | Error Store.Invalid_base_path -> ()
         | Error error ->
           failf
             "empty BasePath returned the wrong error: %s"
             (Store.open_error_to_string error)
         | Ok _ -> fail "empty BasePath unexpectedly opened a store");
        let store, lock_path = store_and_lock ~sw ~base_path in
        check string "store retains explicit BasePath" base_path (Store.base_path store);
        check int "empty active snapshot" 0 (List.length (Store.active_sessions store));
        check int "empty pending snapshot" 0 (List.length (Store.pending_sessions store));
        check bool
          "unknown lookup in empty store"
          true
          (Option.is_none (Store.find store ~session_id:"not-issued"));
        let lock_stat = Unix.lstat lock_path in
        check bool
          "self-lock metadata names a regular file"
          true
          (lock_stat.Unix.st_kind = Unix.S_REG);
        check string
          "self-lock metadata is canonical"
          lock_path
          (Unix.realpath lock_path);
        lock_path)
    in
    with_switch (fun sw ->
      let store, reopened_lock_path = store_and_lock ~sw ~base_path in
      check string
        "release permits the same canonical lock to reopen"
        first_lock_path
        reopened_lock_path;
      check int
        "reopened store remains empty"
        0
        (List.length (Store.active_sessions store))))

let test_separate_base_paths_are_independent () =
  with_temp_root (fun root ->
    let base_a = Filename.concat root "workspace-a" in
    let base_b = Filename.concat root "workspace-b" in
    mkdir base_a;
    mkdir base_b;
    with_switch (fun sw ->
      let store_a, lock_a = store_and_lock ~sw ~base_path:base_a in
      let store_b, lock_b = store_and_lock ~sw ~base_path:base_b in
      check bool "different BasePaths have different locks" false (String.equal lock_a lock_b);
      let session_a = make_session ~owner_name:"owner-a" "same-issued-id" in
      let session_b = make_session ~owner_name:"owner-b" "same-issued-id" in
      require_initialize store_a session_a;
      check bool
        "BasePath B does not inherit BasePath A state"
        true
        (Option.is_none (Store.find store_b ~session_id:session_a.session_id));
      require_initialize store_b session_b;
      let restored_a =
        match Store.find_active store_a ~session_id:session_a.session_id with
        | Some session -> session
        | None -> fail "BasePath A lost its active session"
      in
      let restored_b =
        match Store.find_active store_b ~session_id:session_b.session_id with
        | Some session -> session
        | None -> fail "BasePath B lost its active session"
      in
      check string "BasePath A owner" "owner-a" restored_a.owner.agent_name;
      check string "BasePath B owner" "owner-b" restored_b.owner.agent_name))

let test_initialize_delete_tombstone_and_restart () =
  with_temp_root (fun base_path ->
    let session = make_session "deleted-session-id" in
    with_switch (fun sw ->
      let store = require_open (Store.open_ ~sw ~base_path) in
      require_initialize store session;
      let active =
        match Store.find store ~session_id:session.session_id with
        | Some (Store.Stable_state (Store.Active active)) -> active
        | Some (Store.Stable_state (Store.Deleted _)) ->
          fail "initialize published a tombstone"
        | Some (Store.Pending_state _) ->
          fail "durable initialize remained pending"
        | None -> fail "initialize did not publish active state"
      in
      check_session ~label:"active session" session active;
      (match
         require_delete store ~session_id:session.session_id ~deleted_at:20.0
       with
       | Store.Deleted_now -> ()
       | Store.Already_deleted _ -> fail "first delete was reported idempotent");
      check bool
        "deleted session is not active"
        true
        (Option.is_none (Store.find_active store ~session_id:session.session_id));
      let tombstone =
        match Store.find store ~session_id:session.session_id with
        | Some (Store.Stable_state (Store.Deleted tombstone)) -> tombstone
        | Some (Store.Stable_state (Store.Active _)) ->
          fail "delete retained active state"
        | Some (Store.Pending_state _) -> fail "durable delete remained pending"
        | None -> fail "delete removed its tombstone"
      in
      check (float 0.0) "delete timestamp" 20.0 tombstone.deleted_at;
      (match
         require_delete store ~session_id:session.session_id ~deleted_at:21.0
       with
       | Store.Already_deleted retained ->
         check
           (float 0.0)
           "idempotent delete retains original tombstone"
           20.0
           retained.deleted_at
       | Store.Deleted_now -> fail "second delete rewrote a stable tombstone"));
    with_switch (fun sw ->
      let store = require_open (Store.open_ ~sw ~base_path) in
      (match Store.find store ~session_id:session.session_id with
       | Some (Store.Stable_state (Store.Deleted tombstone)) ->
         check
           (float 0.0)
           "restart restores tombstone"
           20.0
           tombstone.deleted_at
       | Some (Store.Stable_state (Store.Active _)) ->
         fail "restart resurrected a deleted session"
       | Some (Store.Pending_state _) ->
         fail "restart converted a durable tombstone to pending"
       | None -> fail "restart lost the tombstone");
      match Store.initialize store session with
      | Error (Store.Session_already_deleted session_id) ->
        check string "rejected deleted id" session.session_id session_id
      | Error error ->
        failf
          "deleted id returned the wrong error: %s"
          (Store.mutation_error_to_string error)
      | Ok () -> fail "a deleted server-issued id was reused"))

let test_unknown_delete_is_explicit () =
  with_temp_root (fun base_path ->
    with_switch (fun sw ->
      let store = require_open (Store.open_ ~sw ~base_path) in
      match Store.delete store ~session_id:"never-issued" ~deleted_at:1.0 with
      | Error (Store.Session_unknown session_id) ->
        check string "unknown delete id" "never-issued" session_id
      | Error error ->
        failf
          "unknown delete returned the wrong error: %s"
          (Store.mutation_error_to_string error)
      | Ok _ -> fail "unknown delete was silently accepted"))

let test_restore_rejects_invalid_entries_and_releases_lock () =
  with_temp_root (fun base_path ->
    let valid_session = make_session "valid-sibling" in
    let store_dir =
      with_switch (fun sw ->
        let store, lock_path = store_and_lock ~sw ~base_path in
        require_initialize store valid_session;
        Filename.dirname lock_path)
    in
    let malformed_id = "malformed-entry" in
    let malformed_path = canonical_entry_path ~store_dir malformed_id in
    write_file malformed_path "{not-json";
    expect_restore_failure ~base_path (function
      | Store.Store_entry_json_invalid { path; _ } ->
        check string "malformed canonical path" malformed_path path
      | failure ->
        failf
          "malformed entry returned the wrong restore failure: %s"
          (Store.restore_failure_to_string failure));
    Unix.unlink malformed_path;

    let future_id = "future-state-entry" in
    let future_path = canonical_entry_path ~store_dir future_id in
    let future_json =
      `Assoc
        [ "schema_version", `Int 1
        ; "session_id", `String future_id
        ; "state", `Assoc [ "kind", `String "future_state" ]
        ]
      |> Yojson.Safe.to_string
    in
    write_file future_path future_json;
    expect_restore_failure ~base_path (function
      | Store.Store_entry_schema_invalid
          { path; error = Store.Unsupported_state_kind kind } ->
        check string "unsupported state path" future_path path;
        check string "unsupported state kind" "future_state" kind
      | failure ->
        failf
          "unsupported state returned the wrong restore failure: %s"
          (Store.restore_failure_to_string failure));
    Unix.unlink future_path;

    let unexpected_path = Filename.concat store_dir "unknown-entry" in
    write_file unexpected_path "not a canonical session entry";
    expect_restore_failure ~base_path (function
      | Store.Unexpected_store_entry { entry_name } ->
        check string "unexpected entry name" "unknown-entry" entry_name
      | failure ->
        failf
          "unknown entry returned the wrong restore failure: %s"
          (Store.restore_failure_to_string failure));
    Unix.unlink unexpected_path;

    with_switch (fun sw ->
      let store = require_open (Store.open_ ~sw ~base_path) in
      let restored =
        match Store.find_active store ~session_id:valid_session.session_id with
        | Some session -> session
        | None -> fail "valid sibling was not restored after invalid entries were removed"
      in
      check_session ~label:"valid sibling" valid_session restored;
      check int
        "invalid entries never became active state"
        1
        (List.length (Store.active_sessions store))))

let test_atomic_temporary_is_quarantined_before_restore () =
  with_temp_root (fun base_path ->
    let session = make_session "quarantine-sibling" in
    let store_dir =
      with_switch (fun sw ->
        let store, lock_path = store_and_lock ~sw ~base_path in
        require_initialize store session;
        Filename.dirname lock_path)
    in
    let temporary_path = Filename.concat store_dir ".atomic_manual.tmp" in
    write_file temporary_path "partial-or-complete-writer-artifact";
    with_switch (fun sw ->
      let store = require_open (Store.open_ ~sw ~base_path) in
      check bool "owned temporary is removed from canonical store" false
        (Sys.file_exists temporary_path);
      check bool "canonical sibling remains restorable" true
        (Option.is_some (Store.find_active store ~session_id:session.session_id))))

let test_symlink_base_shares_lock_and_store_alias_is_rejected () =
  with_temp_root (fun root ->
    let real_base = Filename.concat root "real-workspace" in
    let base_alias = Filename.concat root "workspace-symlink" in
    let store_alias_base = Filename.concat root "store-alias-workspace" in
    mkdir real_base;
    mkdir store_alias_base;
    let canonical_lock_path, canonical_store_dir =
      with_switch (fun sw ->
        let _store, lock_path = store_and_lock ~sw ~base_path:real_base in
        lock_path, Filename.dirname lock_path)
    in
    Unix.symlink real_base base_alias;
    let alias_masc_root = Config_dir_resolver.masc_root ~base_path:store_alias_base in
    mkdir alias_masc_root;
    let aliased_store_path =
      Filename.concat alias_masc_root (Filename.basename canonical_store_dir)
    in
    Unix.symlink canonical_store_dir aliased_store_path;

    with_switch (fun sw ->
      let _store, self_lock_path = store_and_lock ~sw ~base_path:real_base in
      check string
        "real BasePath resolves canonical lock"
        canonical_lock_path
        self_lock_path;
      let base_alias_lock =
        require_store_locked (Store.open_ ~sw ~base_path:base_alias)
      in
      check string
        "BasePath symlink cannot acquire a second writer"
        canonical_lock_path
        base_alias_lock;
      require_store_directory_rejected
        ~expected_path:aliased_store_path
        (Store.open_ ~sw ~base_path:store_alias_base));

    with_switch (fun sw ->
      let alias_store = require_open (Store.open_ ~sw ~base_path:base_alias) in
      check string
        "alias handle retains its explicit BasePath"
        base_alias
        (Store.base_path alias_store);
      require_store_directory_rejected
        ~expected_path:aliased_store_path
        (Store.open_ ~sw ~base_path:store_alias_base));

    Unix.unlink aliased_store_path;
    mkdir aliased_store_path;
    with_switch (fun sw ->
      let alias_store =
        require_open (Store.open_ ~sw ~base_path:store_alias_base)
      in
      check string
        "physical store opens after rejected symlink is replaced"
        store_alias_base
        (Store.base_path alias_store)))

let () =
  run "server_mcp_session_persist"
    [ ( "durable store"
      , [ test_case
            "empty open, self lock metadata, release and reopen"
            `Quick
            test_empty_open_self_lock_and_reopen
        ; test_case
            "separate BasePaths are independent"
            `Quick
            test_separate_base_paths_are_independent
        ; test_case
            "initialize, tombstone, restart, and deleted-id rejection"
            `Quick
            test_initialize_delete_tombstone_and_restart
        ; test_case
            "unknown delete is explicit"
            `Quick
            test_unknown_delete_is_explicit
        ; test_case
            "invalid entries reject all restore state and release lock"
            `Quick
            test_restore_rejects_invalid_entries_and_releases_lock
        ; test_case
            "owned atomic temporary is quarantined before restore"
            `Quick
            test_atomic_temporary_is_quarantined_before_restore
        ; test_case
            "BasePath alias shares lock and store symlink is rejected"
            `Quick
            test_symlink_base_shares_lock_and_store_alias_is_rejected
        ] ) ]
