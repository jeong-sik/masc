let member key json =
  match json with
  | `Assoc fields -> List.assoc_opt key fields
  | _ -> None

let list_member key json =
  match member key json with
  | Some (`List items) -> Some items
  | Some _ | None -> None

(* A brief whose status word this build cannot name is a Keeper whose state no
   one can read, the same as an unread Keeper: the Keeper is there, its state
   is not. *)
let status_unreadable brief =
  match member "status" brief with
  | Some (`String status) ->
    Option.is_none (Keeper_status_runtime.control_plane_status_of_string_opt status)
  | Some _ | None -> true

let of_briefing json =
  let health =
    match Option.bind (member "summary" json) (member "workspace_health") with
    | Some (`String _ as health) -> Ok health
    | Some _ | None -> Error "briefing has no summary.workspace_health"
  in
  match health, member "keepers_listing" json, list_member "keepers_unread" json with
  | Ok health, Some listing, Some unread ->
    let briefs = Option.value ~default:[] (list_member "keeper_briefs" json) in
    let unreadable =
      List.length unread + List.length (List.filter status_unreadable briefs)
    in
    `Assoc
      [ "workspace_health", health
      ; "keepers_listing", listing
      ; "unreadable_keepers", `Int unreadable
      ]
  | Error detail, _, _ -> `Assoc [ "error", `String detail ]
  | Ok _, None, _ -> `Assoc [ "error", `String "briefing has no keepers_listing" ]
  | Ok _, Some _, None -> `Assoc [ "error", `String "briefing has no keepers_unread list" ]

let last : (string, Yojson.Safe.t) Hashtbl.t = Hashtbl.create 1
let last_mu = Stdlib.Mutex.create ()

let observe ~base_path json =
  let line = of_briefing json in
  let moved =
    Stdlib.Mutex.protect last_mu (fun () ->
      match Hashtbl.find_opt last base_path with
      | Some previous when Yojson.Safe.equal previous line -> false
      | Some _ | None ->
        Hashtbl.replace last base_path line;
        true)
  in
  if moved then
    Workspace_dataset_event.announce ~base_path Workspace_dataset_event.Workspace_health
