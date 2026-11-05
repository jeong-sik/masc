(* RFC-0480 §3.4: a repository catalog write tells its workspace's readers. *)

open Alcotest
open Masc

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> fail detail
;;

let repository ~local_path : Repo_manager_types.repository =
  { id = "catalog-announce"; name = "catalog-announce"; url = "file://" ^ local_path
  ; local_path; aliases = []; default_branch = "main"; keepers = []
  ; status = Repo_manager_types.Active; auto_sync = false; sync_interval = 0
  ; created_at = 0L; updated_at = 0L }
;;

let test_catalog_writes_announce () =
  Eio_main.run @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = Unix.realpath (Filename.temp_dir "repository-announce-" "") in
  Fun.protect
    ~finally:(fun () ->
      Repo_store.install_written_observer (fun ~base_path:_ -> ());
      Fs_compat.remove_tree base_path)
    (fun () ->
      ignore (Workspace.init (Workspace.default_config base_path) ~agent_name:None);
      Workspace_dataset_event.install_store_observers ();
      let heard = ref 0 in
      let id = "repository-catalog-announce" in
      Sse.subscribe_external ~runtime_authority:(Sse.runtime_authority_exn ~base_path) ~id
        ~callback:(fun (event : Sse.external_event) ->
          match Json_util.assoc_string_opt "type" event.ext_payload with
          | Some kind when String.equal kind Workspace_dataset_event.event_type ->
            (match event.ext_payload with
             | `Assoc fields ->
               (match Workspace_dataset_event.of_fields fields with
                | Ok Workspace_dataset_event.Repositories -> incr heard
                | Ok _ | Error _ -> ())
             | _ -> ())
          | Some _ | None -> ())
        ();
      Fun.protect ~finally:(fun () -> Sse.unsubscribe_external id) (fun () ->
        let repo = repository ~local_path:(Filename.concat base_path "repo") in
        ignore (ok_or_fail (Repo_store.add ~base_path repo));
        check int "adding a repository announces" 1 !heard;
        ok_or_fail (Repo_store.update_status ~base_path repo.Repo_manager_types.id Repo_manager_types.Cloning);
        check int "a status write announces" 2 !heard;
        ok_or_fail (Repo_store.remove ~base_path repo.Repo_manager_types.id);
        check int "removing it announces" 3 !heard))
;;

let () =
  run "repository_catalog_announce"
    [ "catalog", [ test_case "catalog writes announce" `Quick test_catalog_writes_announce ] ]
;;
