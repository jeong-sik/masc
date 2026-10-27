module P = Endpoint_job_protocol
module R = Endpoint_job_registry
module G = Endpoint_process_gate
let ( let* ) = Result.bind

type execution = { executable : string; env : string list; cwd : string; payload_gid : int }
type error =
  | Scope_unavailable
  | Registry_error of R.error | Group_error of G.Group.error | Process_error of G.error
  | Codec_error of P.codec_error | Storage_unavailable
  | Publication_failed of Fs_compat.capability_write_error | Recovery_failed of string
let error_to_string = function
  | Scope_unavailable -> "execution boundary unavailable"
  | Registry_error e -> R.error_to_string e
  | Group_error e -> G.Group.error_to_string e
  | Process_error e -> G.error_to_string e
  | Codec_error e -> P.error_to_string e
  | Storage_unavailable -> "original launch storage unavailable"
  | Publication_failed e -> Fs_compat.capability_write_error_to_string e
  | Recovery_failed detail -> "launch publication recovery: " ^ detail

type activation = Requested | Held of error
type t = { target : R.launch_target; group : G.Group.t; child : G.t; activation : activation
  ; storage : Eio.Fs.dir_ty Eio.Path.t; publication_lock : Eio.Mutex.t }
let activation t = t.activation
let original t = P.original ~binding:t.target.binding ~admission_id:t.target.admission_id
let observe_original t = R.refresh t.target.original_record |> Result.map_error (fun e -> Registry_error e)
let specification t = t.target.spec
let storage t = t.storage
let with_storage_publication t f =
  let value=Eio.Mutex.use_ro t.publication_lock (fun () -> Eio.Cancel.protect f) in
  Eio.Fiber.check ();
  value
let rendezvous_leaf = "launch-rendezvous.json"
let activation_leaf = "activation-intent.json"

let io f = try Ok (f ()) with
  | Eio.Io _ | Unix.Unix_error _ | Sys_error _ -> Error Storage_unavailable
let cpu f = Domain_pool_ref.submit_cpu_or_inline ~name:__FUNCTION__ f
let process value = Result.map_error (fun e -> Process_error e) value
let group value = Result.map_error (fun e -> Group_error e) value
let scope (spec : P.spec) =
  match spec.domain,spec.mode,spec.network_policy_sha256 with
  | P.Workspace_process,Exec_ssh_protocol.Effect,None -> Ok ()
  | P.Workspace_process,(Observe | Guest_local),_
  | P.Workspace_process,Effect,Some _ | P.Isolated_job _,_,_ -> Error Scope_unavailable

let encoded value = `String (Base64.encode_string value)
let identifier value = `String (P.Id.to_string value)
let number value = `String (string_of_int value)
let rendezvous_json (target : R.launch_target) execution group_name =
  let* request=P.request_to_json (P.Start {binding=target.binding;spec=target.spec})
    |> Result.map_error (fun e -> Codec_error e) in
  Ok (`Assoc ["version",`Int 1;"original_start",request;
    "admission_id",identifier target.admission_id;"launch_id",identifier target.launch_id;
    "kernel_group",`String group_name;"gate",`String "ready";
    "actual_execution",`Assoc ["executable_b64",encoded execution.executable;
      "argv_b64",`List (List.map encoded target.spec.argv);
      "env_b64",`List (List.map encoded execution.env);"cwd_b64",encoded execution.cwd;
      "payload_uid",number target.payload_uid;"payload_gid",number execution.payload_gid]])

let publish recovery storage ~leaf json =
  let content=cpu (fun () -> Yojson.Safe.to_string json) in
  let* stat=io (fun () -> Eio.Path.stat ~follow:true storage) in
  let* path=io (fun () -> Eio.Path.native_exn storage) in
  let* target=Fs_compat.capability_publication_target ~allowed_root_path:path
      ~allowed_root_device:stat.dev ~allowed_root_inode:stat.ino
      ~parent_components:[] ~target_leaf:leaf ~permissions:0o400
    |> Result.map_error (fun e -> Recovery_failed
      (Fs_compat.capability_publication_target_error_to_string e)) in
  Eio.Cancel.protect (fun () ->
    let* outcome=Fs_compat.Publication_recovery.with_lane ~registry:recovery ~owner:"launch" (fun recovery ->
      Fs_compat.create_capability_file_exclusive ~recovery ~parent:storage ~target content
      |> Result.map_error (fun e -> Publication_failed e))
      |> Result.map_error (fun e -> Recovery_failed (Fs_compat.Publication_recovery.lane_open_error_to_string e)) in
    match outcome with
    | Lane_released value -> value
    | Lane_release_failed {value;release_failure} ->
      let detail=Fs_compat.Publication_recovery.lane_release_failure_to_string release_failure in
      Error (Recovery_failed (match value with Ok () -> detail | Error e -> error_to_string e ^ "; " ^ detail)))

let launch_with_hook ~after_rendezvous ~sw ~fs ~cgroup_parent_path ~(execution : execution)
    ~stdin ~stdout ~stderr intent =
  let result=R.with_launch ~sw intent (fun target ~storage ->
    let* ()=scope target.spec in
    let group_name="masc-job-" ^ P.Id.to_string target.launch_id in
    let* tree=G.Group.create ~sw ~parent_path:cgroup_parent_path ~name:group_name |> group in
    let* child=G.create_in_group ~group:tree ~sw ~executable:execution.executable
      ~argv:(Array.of_list target.spec.argv) ~env:(Array.of_list execution.env)
      ~cwd:execution.cwd ~payload_uid:target.payload_uid ~payload_gid:execution.payload_gid
      ~stdin ~stdout ~stderr |> process in
    let activate () =
      let* ()=G.await_ready child |> process in
      let* recovery=Eio.Cancel.protect (fun () ->
        Fs_compat.Publication_recovery.open_registry ~sw ~fs ~registry_root:storage
        |> Result.map_error (fun e -> Recovery_failed (Fs_compat.Publication_recovery.registry_error_to_string e))) in
      let* rendezvous=cpu (fun () -> rendezvous_json target execution group_name) in
      let* ()=publish recovery storage ~leaf:rendezvous_leaf rendezvous in
      after_rendezvous ();
      let intent=`Assoc ["version",`Int 1;"admission_id",identifier target.admission_id;
        "launch_id",identifier target.launch_id;"decision",`String "activate"] in
      let* ()=publish recovery storage ~leaf:activation_leaf intent in
      Eio.Switch.check sw;
      Eio.Fiber.check ();
      G.activate child |> process in
    let activation=match activate () with Ok () -> Requested | Error e -> Held e in
    Ok {target;group=tree;child;activation;storage;publication_lock=Eio.Mutex.create ()}) in
  Eio.Fiber.check ();
  result

let cancel_with_hook ~after_intent t =
  let* committed=R.request_cancel t.target.original_record ~confirmed_admission_id:t.target.admission_id
    |> Result.map_error (fun e -> Registry_error e) in
  after_intent committed;
  let* ()=G.Group.kill_tree t.group |> group in
  Ok committed

let await_quiescent t =
  let* exit=G.await_exit t.child |> process in
  let* ()=G.Group.await_empty t.group |> group in
  Ok exit

let launch_effect_workspace ~sw ~fs ~cgroup_parent_path ~execution ~stdin ~stdout ~stderr intent =
  launch_with_hook ~after_rendezvous:(fun () -> ()) ~sw ~fs ~cgroup_parent_path
    ~execution ~stdin ~stdout ~stderr intent
let cancel t = cancel_with_hook ~after_intent:(fun _ -> ()) t
module For_testing = struct
  let launch_effect_workspace = launch_with_hook
  let cancel = cancel_with_hook
end
