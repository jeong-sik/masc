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

(* dispatch has no HEAD table: a HEAD request is answered by the GET route
   ([Http_server_eio.Router.request_routes]). Reading the inventory the way
   dispatch does means asking for GET when the request is HEAD. *)
let request_method = function
  | `HEAD -> `GET
  | method_ -> method_
;;

let path_matched entry path =
  match entry.kind with
  | Http_server_eio.Router.Exact -> String.equal entry.path path
  | Http_server_eio.Router.Prefix ->
    String.length path >= String.length entry.path
    && String.equal (String.sub path 0 (String.length entry.path)) entry.path
;;

(* The row dispatch reaches. Its order is not this list's order: it looks in
   the exact table before any prefix row, and among prefixes the longest one
   wins, with the later registration winning a tie
   ([Http_server_eio.Router.resolve] and [insert_prefix_route]). Naming another
   row would name another access. [entries] is in registration order, so a tie
   keeps the row seen later. *)
let covering entries ~path ~method_ =
  let method_ = request_method method_ in
  match
    List.find_opt
      (fun (entry : entry) ->
         (match entry.kind with
          | Http_server_eio.Router.Exact -> true
          | Http_server_eio.Router.Prefix -> false)
         && String.equal entry.path path
         && method_listed entry method_)
      entries
  with
  | Some _ as found -> found
  | None ->
    List.fold_left
      (fun best (entry : entry) ->
         match entry.kind with
         | Http_server_eio.Router.Exact -> best
         | Http_server_eio.Router.Prefix ->
           if (not (method_listed entry method_)) || not (path_matched entry path)
           then best
           else (
             match best with
             | None -> Some entry
             | Some (current : entry) ->
               if String.length entry.path >= String.length current.path
               then Some entry
               else best))
      None
      entries
;;

let covers entries ~path ~method_ =
  Option.is_some (covering entries ~path ~method_)
;;

(* The methods some entry answers at [path], in registration order and without
   a duplicate. 405 lists HEAD after GET ([Http_server_eio.Router.allowed_methods]),
   so the answer here does the same. *)
let methods_at entries ~path =
  let methods =
    List.fold_left
      (fun acc entry ->
         if path_matched entry path
         then
           List.fold_left
             (fun acc method_ -> if List.mem method_ acc then acc else acc @ [ method_ ])
             acc
             entry.methods
         else acc)
      []
      entries
  in
  if List.mem `GET methods && not (List.mem `HEAD methods)
  then
    List.concat_map
      (fun method_ -> if method_ = `GET then [ `GET; `HEAD ] else [ method_ ])
      methods
  else methods
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
