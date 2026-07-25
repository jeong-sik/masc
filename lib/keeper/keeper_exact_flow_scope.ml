module Exact_output = Agent_sdk.Exact_output

type surface =
  | Compaction
  | Board_attention
  | Hitl_summary
  | Librarian

type t =
  { preference_store : Exact_output.flow_preference_store
  ; scope : Exact_output.flow_scope
  }

type owner =
  { compaction : t
  ; board_attention : t
  ; hitl_summary : t
  ; librarian : t
  }

let surface_label = function
  | Compaction -> "compaction"
  | Board_attention -> "board_attention"
  | Hitl_summary -> "hitl_summary"
  | Librarian -> "librarian"
;;

let create_scope ~base_path ~keeper_name surface =
  let owner_fingerprint =
    String.concat "\000" [ base_path; keeper_name; surface_label surface ]
    |> Digestif.SHA256.digest_string
    |> Digestif.SHA256.to_hex
  in
  let preference_store =
    Exact_output.create_flow_preference_store ~capacity:1
    |> Result.get_ok
  in
  let scope =
    Exact_output.make_flow_scope ~id:("masc:" ^ owner_fingerprint)
    |> Result.get_ok
  in
  { preference_store; scope }
;;

let create_owner ~base_path ~keeper_name =
  { compaction = create_scope ~base_path ~keeper_name Compaction
  ; board_attention = create_scope ~base_path ~keeper_name Board_attention
  ; hitl_summary = create_scope ~base_path ~keeper_name Hitl_summary
  ; librarian = create_scope ~base_path ~keeper_name Librarian
  }
;;

let surface_scope owner = function
  | Compaction -> owner.compaction
  | Board_attention -> owner.board_attention
  | Hitl_summary -> owner.hitl_summary
  | Librarian -> owner.librarian
;;

let owners : (string, owner) Hashtbl.t = Hashtbl.create 16
let owners_mu = Stdlib.Mutex.create ()

let owner_key ~base_path ~keeper_name =
  Keeper_registry_types.registry_key ~base_path keeper_name
;;

let for_registered ~is_registered ~base_path ~keeper_name ~surface =
  Keeper_lifecycle_reservation.with_key_lock
    ~base_path
    ~keeper_name
    (fun () ->
       if not (is_registered ())
       then
         Error
           (Printf.sprintf
              "exact-flow owner is not registered: keeper=%s"
              keeper_name)
       else
         let key = owner_key ~base_path ~keeper_name in
         let owner =
           Stdlib.Mutex.protect owners_mu (fun () ->
             match Hashtbl.find_opt owners key with
             | Some owner -> owner
             | None ->
               let owner = create_owner ~base_path ~keeper_name in
               Hashtbl.add owners key owner;
               owner)
         in
         Ok (surface_scope owner surface))
;;

let preference_store scope = scope.preference_store
let scope scope = scope.scope

let release_owner ~base_path ~keeper_name =
  let key = owner_key ~base_path ~keeper_name in
  Stdlib.Mutex.protect owners_mu (fun () -> Hashtbl.remove owners key)
;;

let clear () =
  Stdlib.Mutex.protect owners_mu (fun () -> Hashtbl.reset owners)
;;

module For_testing = struct
  let create ~base_path ~keeper_name ~surface =
    create_scope ~base_path ~keeper_name surface
  ;;
end
