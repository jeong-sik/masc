(** Status facts every surface footer ends with.

    A screen supplies only its own key hints. The facts, their order, and the
    separator between them live here, so adding a fact or changing how one
    reads is a single edit instead of one per surface. Before this module the
    21 footers each spelled [Port: %d] themselves and nothing made them agree. *)

type status_item =
  | Refresh_interval of float
  | Server_build of
      { version : string
      ; commit : string
      }
  | Port of int

(* Enough of the commit to tell two checkouts apart, which is the question
   this answers: [Port: 8935] alone is the same on every build that ever
   served that port. *)
let commit_prefix_length = 7

let short_commit commit =
  if String.length commit <= commit_prefix_length
  then commit
  else String.sub commit 0 commit_prefix_length

type retention =
  | Endpoint_identity
  | Build_identity
  | Refresh_context

type projected_status =
  { text : string
  ; retention : retention
  }

let status_item_projection = function
  | Refresh_interval seconds when Float.is_finite seconds && seconds > 0. ->
    Some
      { text = Printf.sprintf "Refresh: %.0fs" seconds
      ; retention = Refresh_context
      }
  | Refresh_interval _ -> None
  | Server_build { version; commit } ->
    let version = String.trim version in
    let commit = String.trim commit in
    (match version, short_commit commit with
     | "", "" -> None
     | version, "" -> Some { text = "v" ^ version; retention = Build_identity }
     | "", commit -> Some { text = commit; retention = Build_identity }
     | version, commit ->
       Some
         { text = Printf.sprintf "v%s %s" version commit
         ; retention = Build_identity
         })
  | Port port when port > 0 ->
    Some { text = Printf.sprintf "Port: %d" port; retention = Endpoint_identity }
  | Port _ -> None

let body hints statuses =
  match statuses with
  | [] -> "  " ^ hints
  | _ ->
    Printf.sprintf "  %s  | %s" hints
      (String.concat " | " (List.map (fun status -> status.text) statuses))

let omission_order = [ Refresh_context; Build_identity; Endpoint_identity ]

let rec fit_body ~max_cells ~hints ~omissions statuses =
  let rendered = body hints statuses in
  if Masc_tui_message_layout.display_width rendered <= max_cells then rendered
  else
    match statuses, omissions with
    | [], _ -> Masc_tui_message_layout.fit_width rendered max_cells
    | _, retention :: rest ->
      fit_body ~max_cells ~hints ~omissions:rest
        (List.filter (fun status -> status.retention <> retention) statuses)
    | _, [] -> fit_body ~max_cells ~hints ~omissions:[] []

(** [line ~dim ~reset ~max_cells ~port ~hints] is one footer line, terminated by a
    newline. [Port] closes every footer and is appended here; [status] carries
    only the extra facts a surface has, in the order they should read.

    Key hints retain the row before status facts do. When the facts do not fit,
    whole typed items are omitted in this order: refresh interval, build, port.
    Only an overlong surface-owned hint uses cell-safe truncation as the final
    fallback. *)
let line ?(status = []) ~dim ~reset ~max_cells ~port ~hints () =
  let statuses =
    List.filter_map status_item_projection (status @ [ Port port ])
  in
  let fitted =
    fit_body ~max_cells:(max 0 max_cells) ~hints ~omissions:omission_order
      statuses
  in
  Printf.sprintf "%s%s%s\n" dim fitted reset
