(* Shutdown finalization is the only place that knows a keeper is gone for
   good: the microvm lane keeps one guest per keeper across turns, so turn
   teardown deliberately leaves it running. Before this was wired, removing a
   keeper left ~400 MB of guest behind for somebody to find by hand.

   Two properties hold it. The first is that finalization calls the teardown
   at all -- deleting the call is the regression, and no other suite would
   notice. The second is that finalization carries the declared backend so a
   Local keeper never probes microVM or Docker runtimes it cannot own. *)

module Runtime = Masc.Keeper_turn_sandbox_runtime

(* Every keeper goes through finalization, and only microvm keepers have a
   guest. If an absent guest were an error the shutdown would block on it, so
   this pins that removing nothing succeeds -- run against a name that has
   never had a guest. *)
let test_removing_an_absent_guest_succeeds () =
  let base_path = Filename.temp_file "microvm_teardown_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir base_path with _ -> ())
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       match
         Runtime.teardown_keeper_sandbox_by_name
           ~timeout_sec:30.0
           ~config
           ~keeper_name:"microvm-teardown-probe-never-started"
           ~backend:Masc.Keeper_sandbox.Micro_vm
           (* The runtime is named because teardown refuses an unnamed one:
              a guest can only be removed with the spelling of the CLI that
              booted it. *)
           ~microvm_backend:Masc.Keeper_microvm_backend.Apple_container
           ()
       with
       | Ok () -> ()
       | Error detail ->
         (* container absent from the host is not a failed teardown either:
            the suite has to pass on a machine without the CLI. *)
         if not (Astring.String.is_infix ~affix:"executable file not found" detail)
            && not (Astring.String.is_infix ~affix:"No such file" detail)
         then
           Alcotest.failf
             "removing a guest that was never started must succeed, got: %s"
             detail)

(* A fake [container] first on PATH. [inspect] always exits 1, which is all a
   name that does not exist and an apiserver that cannot answer have in
   common; the guest listing is what tells them apart. [stop] and [delete]
   remember the name they were given so a listing can report that guest. *)
let fake_container_script ~listing =
  String.concat
    "\n"
    [ "#!/bin/sh"
    ; "state=\"$(dirname \"$0\")/last-name\""
    ; "case \"$1\" in"
    ; "  inspect) echo \"Error: failed to inspect\" >&2; exit 1 ;;"
    ; "  stop) echo \"$2\" > \"$state\"; exit 0 ;;"
    ; "  delete) for name in \"$@\"; do :; done; echo \"$name\" > \"$state\"; exit 0 ;;"
    ; "  list) " ^ listing ^ " ;;"
    ; "  *) exit 0 ;;"
    ; "esac"
    ; ""
    ]
;;

let with_fake_container ~listing f =
  let dir = Filename.temp_file "fake_container_" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o755;
  let binary = Filename.concat dir "container" in
  Out_channel.with_open_text binary (fun channel ->
    output_string channel (fake_container_script ~listing));
  Unix.chmod binary 0o755;
  let original_path = Sys.getenv_opt "PATH" in
  Unix.putenv "PATH" (dir ^ ":" ^ Option.value ~default:"/usr/bin:/bin" original_path);
  Fun.protect
    ~finally:(fun () ->
      Unix.putenv "PATH" (Option.value ~default:"/usr/bin:/bin" original_path);
      List.iter
        (fun name -> try Sys.remove (Filename.concat dir name) with Sys_error _ -> ())
        [ "container"; "last-name" ];
      try Unix.rmdir dir with Unix.Unix_error _ -> ())
    f
;;

let teardown_with_fake_container ~listing keeper_name =
  with_fake_container ~listing (fun () ->
    let base_path = Filename.temp_file "microvm_teardown_fake_" "" in
    Unix.unlink base_path;
    Unix.mkdir base_path 0o755;
    Fun.protect
      ~finally:(fun () -> try Unix.rmdir base_path with Unix.Unix_error _ -> ())
      (fun () ->
         let config = Masc.Workspace.default_config base_path in
         Runtime.teardown_keeper_sandbox_by_name
           ~timeout_sec:30.0
           ~config
           ~keeper_name
           ~backend:Masc.Keeper_sandbox.Micro_vm
           ~microvm_backend:Masc.Keeper_microvm_backend.Apple_container
           ()))
;;

(* A guest the runtime does not list is gone: the name is released. *)
let test_a_guest_missing_from_the_listing_is_removed () =
  match
    teardown_with_fake_container ~listing:"echo '[]'; exit 0" "microvm-teardown-unlisted"
  with
  | Ok () -> ()
  | Error detail -> Alcotest.failf "an unlisted guest must count as removed: %s" detail
;;

(* The inspect failure alone must not read as "gone". When the listing cannot
   be read either, the apiserver is stalled and the guest may still be there
   with its credential snapshot mounted, so the teardown reports an unknown
   state and releases nothing. *)
let test_an_unreadable_inventory_leaves_the_guest_unconfirmed () =
  match
    teardown_with_fake_container
      ~listing:"echo 'Error: failed to list containers (XPC timeout)' >&2; exit 1"
      "microvm-teardown-stalled"
  with
  | Ok () -> Alcotest.fail "a stalled runtime reported the guest removed"
  | Error detail ->
    Alcotest.(check bool)
      "the failure says the state is unknown"
      true
      (Astring.String.is_infix ~affix:"post-delete state unknown" detail)
;;

(* A guest still listed after stop and delete is not removed, whatever the
   failed inspect looked like. *)
let test_a_listed_guest_is_not_reported_removed () =
  match
    teardown_with_fake_container
      ~listing:
        "name=\"$(cat \"$state\")\"; printf '[{\"id\":\"%s\",\"configuration\":{\"id\":\"%s\"}}]' \"$name\" \"$name\"; exit 0"
      "microvm-teardown-still-listed"
  with
  | Ok () -> Alcotest.fail "a guest the runtime still lists was reported removed"
  | Error detail ->
    Alcotest.(check bool)
      "the failure says the state is unknown"
      true
      (Astring.String.is_infix ~affix:"post-delete state unknown" detail)
;;

(* A caller that forgets the runtime gets a refusal, not a guess. Shutdown
   finalization treats a teardown failure as a warning and finishes, so an
   assumed runtime would report a removal it did not perform and the guest
   would stay running with nothing able to reap it. The refusal is what makes
   that mistake visible in the log instead. *)
let test_an_unnamed_runtime_is_refused () =
  let base_path = Filename.temp_file "microvm_teardown_unnamed_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir base_path with _ -> ())
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       match
         Runtime.teardown_keeper_sandbox_by_name
           ~timeout_sec:0.01
           ~config
           ~keeper_name:"microvm-teardown-runtime-not-named"
           ~backend:Masc.Keeper_sandbox.Micro_vm
           ()
       with
       | Ok () ->
         Alcotest.fail "an unnamed microVM runtime reported a removal"
       | Error detail ->
         Alcotest.(check bool)
           "the refusal names the unresolved runtime"
           true
           (Astring.String.is_infix
              ~affix:"microvm_teardown_backend_unresolved"
              detail))

let test_local_teardown_skips_container_runtimes () =
  let base_path = Filename.temp_file "local_teardown_" "" in
  Unix.unlink base_path;
  Unix.mkdir base_path 0o755;
  Fun.protect
    ~finally:(fun () -> try Unix.rmdir base_path with _ -> ())
    (fun () ->
       let config = Masc.Workspace.default_config base_path in
       match
         Runtime.teardown_keeper_sandbox_by_name
           ~timeout_sec:0.01
           ~config
           ~keeper_name:"local-teardown-never-probes-container-runtime"
           ~backend:Masc.Keeper_sandbox.Remote_ssh
           ()
       with
       | Ok () -> ()
       | Error detail ->
         Alcotest.failf "Local teardown called a container runtime: %s" detail)

let () =
  Alcotest.run
    "keeper_microvm_teardown_on_shutdown"
    [ ( "teardown"
      , [ Alcotest.test_case "removing an absent guest succeeds" `Quick
            test_removing_an_absent_guest_succeeds
        ; Alcotest.test_case "an unnamed microVM runtime is refused" `Quick
            test_an_unnamed_runtime_is_refused
        ; Alcotest.test_case "a guest missing from the listing is removed" `Quick
            test_a_guest_missing_from_the_listing_is_removed
        ; Alcotest.test_case "an unreadable inventory leaves the guest unconfirmed" `Quick
            test_an_unreadable_inventory_leaves_the_guest_unconfirmed
        ; Alcotest.test_case "a listed guest is not reported removed" `Quick
            test_a_listed_guest_is_not_reported_removed
        ; Alcotest.test_case "Local teardown skips container runtimes" `Quick
            test_local_teardown_skips_container_runtimes
        ] )
    ]
