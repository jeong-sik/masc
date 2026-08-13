type resolve_result =
  | Runtime of Keeper_turn_sandbox_runtime.t
  | No_factory
  | Local_profile

module Routing = Keeper_runtime_contract.Sandbox_routing

type routing_admission =
  { requested : Routing.requested
  ; effective : Routing.effective
  }

type routing_refusal =
  | Invalid_requested_boundary of Routing.invalid_boundary
  | Invalid_effective_boundary of Routing.invalid_boundary
  | Admission_violation of
      { violation : Routing.violation
      ; evidence : Routing.evidence
      }
  | Receipt_violation of
      { violation : Routing.violation
      ; evidence : Routing.evidence
      }
  | Invalid_receipt_boundary of Routing.invalid_boundary
  | Invalid_receipt_detail of string

type t = {
  config : Workspace.config;
  meta : Keeper_meta_contract.keeper_meta;
  turn_id : int;
  effective_profile : Keeper_types_profile_sandbox.sandbox_profile;
  effective_network : Keeper_types_profile_sandbox.network_mode;
  routing : (routing_admission, routing_refusal) result;
  cache :
    ((bool * string * string * string), Keeper_turn_sandbox_runtime.t) Hashtbl.t;
  mutex : Eio.Mutex.t;
}

let routing_refusal_to_string = function
  | Invalid_requested_boundary invalid ->
    "invalid requested sandbox route: "
    ^ Routing.invalid_boundary_to_string invalid
  | Invalid_effective_boundary invalid ->
    "invalid effective sandbox route: "
    ^ Routing.invalid_boundary_to_string invalid
  | Admission_violation { violation; _ }
  | Receipt_violation { violation; _ } ->
    Routing.violation_to_string violation
  | Invalid_receipt_boundary invalid ->
    "receipt observed an invalid sandbox route: "
    ^ Routing.invalid_boundary_to_string invalid
  | Invalid_receipt_detail detail ->
    "sandbox routing receipt detail is invalid: " ^ detail
;;

let routing_refusal_evidence = function
  | Admission_violation { evidence; _ }
  | Receipt_violation { evidence; _ } ->
    Some evidence
  | Invalid_requested_boundary _
  | Invalid_effective_boundary _
  | Invalid_receipt_boundary _
  | Invalid_receipt_detail _ ->
    None
;;

let routing_admission_of_routes
      ~requested_sandbox_profile
      ~requested_network_mode
      ~effective_profile
      ~effective_network
  =
  match
    Routing.requested_of_config
      ~sandbox_profile:requested_sandbox_profile
      ~network_mode:requested_network_mode
  with
  | Error invalid -> Error (Invalid_requested_boundary invalid)
  | Ok requested ->
    (match
       Routing.effective_resolved
         ~sandbox_profile:effective_profile
         ~network_mode:effective_network
     with
     | Error invalid -> Error (Invalid_effective_boundary invalid)
     | Ok effective ->
       (match Routing.verify_effective requested effective with
        | Ok () -> Ok { requested; effective }
        | Error violation ->
          let receipt =
            Routing.receipt_unobserved
              ~detail:"receipt not written because sandbox routing admission failed"
          in
          (match receipt with
           | Ok receipt ->
             let evidence = Routing.evidence ~requested ~effective ~receipt in
             Error (Admission_violation { violation; evidence })
           | Error detail -> Error (Invalid_receipt_detail detail))))
;;

let create ?default_network_override ?requested_sandbox_profile
    ?requested_network_mode
    ~(config : Workspace.config) ~(meta : Keeper_meta_contract.keeper_meta) ?(turn_id = 0) () =
  let effective_profile, declared_network =
    Keeper_sandbox_runner.effective_sandbox_profile ~meta
  in
  let effective_network =
    Option.value default_network_override ~default:declared_network
  in
  let requested_sandbox_profile =
    Option.value requested_sandbox_profile ~default:meta.sandbox_profile
  in
  let requested_network_mode =
    Option.value requested_network_mode ~default:meta.network_mode
  in
  {
    config;
    meta;
    turn_id;
    effective_profile;
    effective_network;
    routing =
      routing_admission_of_routes
        ~requested_sandbox_profile
        ~requested_network_mode
        ~effective_profile
        ~effective_network;
    cache = Hashtbl.create 4;
    mutex = Eio.Mutex.create ();
  }

let routing_admission t = Result.map (fun _ -> ()) t.routing

let routing_evidence_for_receipt t =
  match t.routing with
  | Error _ as error -> error
  | Ok { requested; effective } ->
    (match
       Routing.receipt_observed
         ~sandbox_profile:t.effective_profile
         ~network_mode:t.effective_network
     with
     | Error invalid -> Error (Invalid_receipt_boundary invalid)
     | Ok receipt ->
       let evidence = Routing.evidence ~requested ~effective ~receipt in
       (match Routing.verify evidence with
        | Ok _ -> Ok evidence
        | Error violation ->
          Error (Receipt_violation { violation; evidence })))
;;

let with_lock (t : t) f =
  Eio.Mutex.use_rw ~protect:true t.mutex f

let strip_trailing_slashes = Env_config_core.strip_trailing_slashes

let normalize p =
  Keeper_alerting_path.normalize_path_for_check p
  |> strip_trailing_slashes

let runtime_image (meta : Keeper_meta_contract.keeper_meta) =
  match meta.sandbox_image with
  | Some img when String.trim img <> "" -> img
  | _ -> Env_config_sandbox.Runtime.docker_image ()

let in_playground_of_cwd (t : t) ~meta ~cwd =
  let host_root =
    Keeper_sandbox.host_root_abs_of_meta ~config:t.config meta
    |> normalize
  in
  let cwd_norm = normalize cwd in
  String.equal cwd_norm host_root
  || String.starts_with ~prefix:(host_root ^ "/") cwd_norm

let resolve (t : t) ~cwd =
  with_lock t (fun () ->
    let meta = t.meta in
    let in_playground = in_playground_of_cwd t ~meta ~cwd in
    let actual_network = t.effective_network in
    match t.effective_profile with
    | Keeper_types_profile_sandbox.Local -> Local_profile
    | Keeper_types_profile_sandbox.Docker ->
      let host_root =
        Keeper_sandbox.host_root_abs_of_meta ~config:t.config meta
        |> normalize
      in
      let image = runtime_image meta in
      let key =
        ( in_playground
        , Keeper_types_profile_sandbox.network_mode_to_string actual_network
        , host_root
        , image )
      in
      match Hashtbl.find_opt t.cache key with
      | Some r -> Runtime r
      | None ->
        let r =
          Keeper_turn_sandbox_runtime.create
            ~config:t.config
            ~meta
            ~network_mode:actual_network
            ~turn_id:t.turn_id
            ()
        in
        Hashtbl.add t.cache key r;
        Runtime r)

let resolve_opt t_opt ~cwd =
  match t_opt with
  | None -> No_factory
  | Some t -> resolve t ~cwd

(* Delegates to the one projection in Keeper_sandbox. This used to carry its
   own copy of the exact/prefix/suffix walk plus a container-side passthrough
   check, which is what [visible_path_of_raw] now does in one place.

   The unmappable case keeps its previous answer, the sandbox root, rather
   than propagating the [Error]: this returns a plain string to callers that
   have no way to render a failure, so widening the type is its own change.
   Deciding that here at least confines the substitute to one site instead of
   leaving it implied by a [| None ->] branch. *)
let container_cwd_of_host t ~host_cwd =
  let sandbox = Keeper_sandbox.of_meta ~config:t.config ~meta:t.meta in
  match Keeper_sandbox.visible_path_of_raw sandbox host_cwd with
  | Ok visible -> Keeper_sandbox.Path.visible_to_string visible
  | Error _ -> Keeper_sandbox.keeper_visible_root_abs sandbox

let container_cwd_of_host_opt t_opt ~host_cwd =
  Option.map (fun t -> container_cwd_of_host t ~host_cwd) t_opt

let cleanup (t : t) =
  if Hashtbl.length t.cache = 0 then ()
  else
    with_lock t (fun () ->
      Hashtbl.iter
        (fun _ r -> Keeper_turn_sandbox_runtime.cleanup r)
        t.cache;
      Hashtbl.reset t.cache)
