open Keeper_dead_revival_payload_types
open Keeper_dead_revival_payload_domain
open Keeper_dead_revival_payload_codec
open Keeper_dead_revival_payload_store

let real_directory path =
  try
    match
      (Eio_guard.run_in_systhread (fun () -> Unix.lstat path)).Unix.st_kind
    with
    | Unix.S_DIR -> Ok true
    | _ -> Error (Inventory_failed ("inventory entry is not a real directory: " ^ path))
  with
  | Eio.Cancel.Cancelled _ as cancelled -> raise cancelled
  | Unix.Unix_error (Unix.ENOENT, _, _) -> Ok false
  | exception_ ->
    let backtrace = Printexc.get_raw_backtrace () in
    reraise_fatal exception_ backtrace;
    Error
      (Inventory_failed
         ("inventory directory inspection failed: "
          ^ Printexc.to_string exception_))
;;

let inventory_authority_shards config =
  let root = payload_directory config in
  let* root_exists = real_directory root in
  if not root_exists
  then Ok []
  else
    match Safe_ops.list_dir_safe root with
    | Error detail -> Error (Inventory_failed detail)
    | Ok names ->
      let rec collect accumulated = function
        | [] ->
          Ok
            (List.sort
               (fun left right ->
                  String.compare
                    left.authority_leaf
                    right.authority_leaf)
               accumulated)
        | name :: rest ->
          if not (valid_authority_leaf name)
          then
            Error
              (Inventory_failed
                 ("unexpected non-authority entry in payload root: "
                  ^ name))
          else
            let path = Filename.concat root name in
            let* is_directory = real_directory path in
            if not is_directory
            then
              Error
                (Inventory_failed
                   ("authority shard disappeared during inventory: "
                    ^ name))
            else
              collect
                ({ keeper_name = None; authority_leaf = name }
                 :: accumulated)
                rest
      in
      collect [] names
;;

let inventory_transactions config shard =
  if not (authority_shard_is_valid shard)
  then Error (Invalid_binding "authority shard is not canonical")
  else
    let directory =
      payload_shard_directory config shard.authority_leaf
    in
    let* directory_exists = real_directory directory in
    if not directory_exists
    then Ok []
    else
      match Safe_ops.list_dir_safe directory with
      | Error detail -> Error (Inventory_failed detail)
      | Ok names ->
      let rec collect accumulated = function
        | [] ->
          Ok
            (List.sort
               (fun left right ->
                  String.compare
                    left.inventory_transaction_leaf
                    right.inventory_transaction_leaf)
               accumulated)
        | name :: rest ->
          if valid_transaction_leaf name
          then
            collect
              ({ inventory_authority_leaf = shard.authority_leaf
               ; inventory_transaction_leaf = name
               }
               :: accumulated)
              rest
          else
            Error
              (Inventory_failed
                 ("unexpected non-transaction entry in authority shard: "
                  ^ name))
      in
      collect [] names
;;

let inventory_transaction_matches inventory ~transaction_id =
  match transaction_leaf_for_id ~transaction_id with
  | Error _ -> false
  | Ok expected ->
    String.equal inventory.inventory_transaction_leaf expected
;;

let delete_inventory_transaction
      config
      ~authority_shard
      inventory
  =
  if
    not (authority_shard_is_valid authority_shard)
    || not
         (String.equal
            inventory.inventory_authority_leaf
            authority_shard.authority_leaf)
    || not
         (valid_transaction_leaf
            inventory.inventory_transaction_leaf)
  then Error (Invalid_binding "inventory transaction is not bound to authority shard")
  else
    let directory =
      payload_shard_directory config authority_shard.authority_leaf
    in
    let path =
      Filename.concat
        directory
        inventory.inventory_transaction_leaf
    in
    Keeper_fs.remove_file_durable
      ~ownership_root:(Workspace.masc_root_dir config)
      path
    |> Result.map_error (fun failure -> Delete_failed failure)
;;
