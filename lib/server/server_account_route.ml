(* See server_account_route.mli. *)

type entry =
  { path : string
  ; kind : Http_server_eio.Router.route_kind
  ; methods : Httpun.Method.t list
  ; access : Route_access.t
  }

let of_router router =
  Http_server_eio.Router.effective_routes router
  |> List.map (fun (route : Http_server_eio.Router.route) ->
    { path = route.path; kind = route.kind; methods = route.methods; access = route.access })
;;

let keeper_prefix = "/api/v1/keepers/"

let method_listed entry method_ =
  List.exists (fun listed -> listed = method_) entry.methods
;;

let covering entries ~path ~method_ =
  List.find_opt
    (fun entry ->
      method_listed entry method_
      &&
      match entry.kind with
      | Http_server_eio.Router.Exact -> String.equal entry.path path
      | Http_server_eio.Router.Prefix ->
        String.length path >= String.length entry.path
        && String.equal (String.sub path 0 (String.length entry.path)) entry.path)
    entries
;;

let covers entries ~path ~method_ =
  Option.is_some (covering entries ~path ~method_)
;;

let keeper_prefix_present entries =
  List.exists
    (fun entry ->
      (match entry.kind with
       | Http_server_eio.Router.Prefix -> true
       | Http_server_eio.Router.Exact -> false)
      && String.equal entry.path keeper_prefix)
    entries
;;

let entry_json entry =
  `Assoc
    [ "path", `String entry.path
    ; ( "kind"
      , `String
          (match entry.kind with
           | Http_server_eio.Router.Exact -> "exact"
           | Http_server_eio.Router.Prefix -> "prefix") )
    ; "methods", `List (List.map (fun m -> `String (Httpun.Method.to_string m)) entry.methods)
    ; "access", Route_access.to_json entry.access
    ]
;;

let to_json entries = `List (List.map entry_json entries)
