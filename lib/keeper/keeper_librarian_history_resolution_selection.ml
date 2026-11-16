module Request = Keeper_librarian_durable_request
module Fence = Keeper_librarian_history_resolution_state
module Store = Lane_addon_store
open Result.Syntax
type error = Unresolved_cut of string | Unavailable of string
let error_to_string = function
  | Unresolved_cut request_id ->
    "History Cut requires a confirmed resolution successor before fresh selection: " ^ request_id
  | Unavailable detail -> "History resolution inventory is unavailable: " ^ detail
let unavailable result = Result.map_error (fun detail -> Unavailable detail) result
let check ~config ~keeper_name =
  let* scope=unavailable (Request.discovery_scope ~base_path:config.Workspace.base_path
    ~keepers_dir:(Config_dir_resolver.keepers_dir_for_base_path ~base_path:config.base_path)
    ~keeper_id:keeper_name) in
  let* rows=unavailable (Store.history_fence_inventory (Store.of_config config) ~scope) in
  List.fold_left (fun result (name,json) ->
    let* ()=result in
    let* fence=unavailable (Fence.of_json json) in
    let* ()=if fence.scope=scope && name=Store.digest fence.request_id ^ ".json" then Ok ()
      else Error (Unavailable "History fence is stored under another original or scope") in
    match fence.authority with
    | Fence.Worker_absent -> Ok ()
    | Excluded_cut _ -> Error (Unresolved_cut fence.request_id)) (Ok ()) rows
