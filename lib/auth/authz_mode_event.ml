(* HIGH-RISK-UNREVIEWED: this module writes and reads the body of the record that
   changes the mode of the installation. The mode decides whether a boot runs
   with accounts or without them. *)

(* See authz_mode_event.mli. *)

open Authz_types

let ( let* ) = Result.bind

type event =
  | Fresh_bootstrap
  | Off
  | Reactivate

type t =
  { event : event
  ; workspace_id : Workspace_id.t
  }

(* [event_label] names every constructor, so the compiler stops at a new one.
   [events] is what a label is read back through: a constructor that is missing
   from it is written and then read as [Unknown_event]. *)
let events = [ Fresh_bootstrap; Off; Reactivate ]

let event_label = function
  | Fresh_bootstrap -> "fresh_bootstrap"
  | Off -> "off"
  | Reactivate -> "reactivate"
;;

let event_of_label label =
  List.find_opt (fun event -> String.equal (event_label event) label) events
;;

let equal a b = a.event = b.event && Workspace_id.equal a.workspace_id b.workspace_id

let to_body { event; workspace_id } =
  let* event = Authz_body.string (event_label event) in
  let* workspace_id = Authz_body.string (Workspace_id.to_string workspace_id) in
  Authz_body.object_ [ "event", event; "workspace_id", workspace_id ]
;;

type error =
  | Not_an_object
  | Wrong_members
  | Unknown_event of string
  | Invalid_workspace_id of Authz_id.error

let id_error_to_string : Authz_id.error -> string = function
  | Authz_id.Empty -> "empty"
  | Authz_id.Too_long -> "too long"
  | Authz_id.Invalid_byte { index } -> Printf.sprintf "invalid byte at %d" index
  | Authz_id.Path_segment -> "a path segment"
;;

let error_to_string = function
  | Not_an_object -> "the body of a mode event is an object"
  | Wrong_members ->
    "the body of a mode event has the members event and workspace_id, in this order, both strings"
  | Unknown_event label -> Printf.sprintf "%S is not an event of the mode" label
  | Invalid_workspace_id error ->
    Printf.sprintf "the workspace id is not valid: %s" (id_error_to_string error)
;;

let of_body (body : Authz_body.t) =
  match body with
  | Authz_body.Object
      [ ("event", Authz_body.String event); ("workspace_id", Authz_body.String workspace_id) ]
    ->
    let* event =
      match event_of_label event with
      | Some event -> Ok event
      | None -> Error (Unknown_event event)
    in
    let* workspace_id =
      Result.map_error (fun error -> Invalid_workspace_id error) (Workspace_id.of_string workspace_id)
    in
    Ok { event; workspace_id }
  | Authz_body.Object _ -> Error Wrong_members
  | Authz_body.Null
  | Authz_body.Bool _
  | Authz_body.Int _
  | Authz_body.String _
  | Authz_body.List _ -> Error Not_an_object
;;
