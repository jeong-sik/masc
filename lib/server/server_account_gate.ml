(* See server_account_gate.mli. *)

type refusal =
  | Uninventoried of
      { path : string
      ; method_ : Httpun.Method.t
      }
  | Keeper_prefix_missing

type decision =
  | Allowed of Server_account_route.entry
  | Refused of refusal

let decide entries ~path ~method_ =
  match Server_account_route.covering entries ~path ~method_ with
  | Some entry -> Allowed entry
  | None ->
    if
      (not (Server_account_route.keeper_prefix_present entries))
      && String.starts_with ~prefix:Server_account_route.keeper_prefix path
    then Refused Keeper_prefix_missing
    else Refused (Uninventoried { path; method_ })
;;

let same_access left right =
  Yojson.Safe.equal (Route_access.to_json left) (Route_access.to_json right)
;;

let duplicate_exact_path entries =
  let rec loop seen = function
    | [] -> None
    | (entry : Server_account_route.entry) :: rest ->
      (match entry.kind with
       | Http_server_eio.Router.Prefix -> loop seen rest
       | Http_server_eio.Router.Exact ->
         (match List.assoc_opt entry.path seen with
          | None -> loop ((entry.path, entry.access) :: seen) rest
          | Some access ->
            if same_access access entry.access then loop seen rest else Some entry.path))
  in
  loop [] entries
;;

(* A prefix route is matched by [String.sub], so a prefix that does not end in
   [/] also covers a path beside it: [/api/v1/board] would cover
   [/api/v1/board-secret]. The table is judged before it serves anything, so
   the shapes that would widen a route are refused here rather than read. *)
let prefix_without_slash entries =
  List.find_map
    (fun (entry : Server_account_route.entry) ->
       match entry.kind with
       | Http_server_eio.Router.Exact -> None
       | Http_server_eio.Router.Prefix ->
         if String.ends_with ~suffix:"/" entry.path then None else Some entry.path)
    entries
;;

let reconcile entries =
  match prefix_without_slash entries with
  | Some path ->
    Error
      (Printf.sprintf
         "the prefix route %s does not end in /, so it also covers the paths beside it"
         path)
  | None ->
    if entries = []
    then Error "the inventory is empty"
    else if not (Server_account_route.keeper_prefix_present entries)
    then
      Error
        (Printf.sprintf
           "the inventory has no %s prefix, so keeper sub-routes are unnameable"
           Server_account_route.keeper_prefix)
    else (
      match duplicate_exact_path entries with
      | Some path ->
        Error (Printf.sprintf "%s is in the inventory twice with different accesses" path)
      | None -> Ok ())
;;

let refusal_text = function
  | Uninventoried { path; method_ } ->
    Printf.sprintf
      "%s %s is not a route the account inventory names"
      (Httpun.Method.to_string method_)
      path
  | Keeper_prefix_missing ->
    Printf.sprintf
      "the account inventory has no %s prefix"
      Server_account_route.keeper_prefix
;;
