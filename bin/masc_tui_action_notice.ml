type rejection_kind = Input_rejected | Paste_rejected
type rejection = { kind : rejection_kind; generation : int list }
type preferred = No_preferred | Csi_recovery | Rejection of rejection
type lifetime = Pending of rejection | Draining of rejection | Presented of rejection * float
type csi = Csi_inactive | Csi_active
type t = {
  ordinary : (string * float) option;
  rejection : lifetime option;
  next_generation : int list;
  csi : csi;
}

let empty = { ordinary = None; rejection = None; next_generation = [0]; csi = Csi_inactive }
let ordinary notice = notice.ordinary
let ordinary_visible notice ~now ~window =
  match notice.ordinary with
  | Some (_, at) as ordinary when now -. at <= window -> ordinary
  | Some _ | None -> None
let set_ordinary notice ordinary = { notice with ordinary }
let csi_active notice = match notice.csi with Csi_inactive -> false | Csi_active -> true
let start_csi notice = { notice with csi = Csi_active }
let end_csi notice = { notice with csi = Csi_inactive }

(* Little-endian digits avoid both integer wraparound and a mutable token. *)
let rec successor = function
  | [] -> [1]
  | digit :: rest when digit = max_int -> 0 :: successor rest
  | digit :: rest -> (digit + 1) :: rest

let reject notice kind ~now ~window =
  match notice.rejection, kind with
  | Some (Pending {kind = Paste_rejected; _} | Draining {kind = Paste_rejected; _}),
    Input_rejected -> notice
  | Some (Presented ({kind = Paste_rejected; _}, at)), Input_rejected
    when now -. at <= window -> notice
  | (Some (Pending _ | Draining _ | Presented _) | None), (Input_rejected | Paste_rejected) ->
      { notice with rejection = Some (Pending {kind; generation = notice.next_generation});
                    next_generation = successor notice.next_generation }

let rejection notice ~now ~window =
  match notice.rejection with
  | Some (Pending rejection | Draining rejection) -> Some rejection
  | Some (Presented (rejection, at)) when now -. at <= window -> Some rejection
  | Some (Presented _) | None -> None

let preferred notice ~existing_action ~now ~window =
  if existing_action then No_preferred
  else if csi_active notice then Csi_recovery
  else match rejection notice ~now ~window with
    | Some notice -> Rejection notice
    | None -> No_preferred

let rejection_text rejection = match rejection.kind with
  | Input_rejected -> "Input lost; retry"
  | Paste_rejected -> "Paste lost; retry"

let same_rejection left right = List.equal Int.equal left.generation right.generation

let presented notice shown ~at ~input_pending =
  match notice.rejection with
  | Some (Pending current) when same_rejection current shown ->
      { notice with rejection = Some (if input_pending then Draining current
          else Presented (current, at)) }
  | Some (Pending _ | Draining _ | Presented _) | None -> notice

let after_drain notice ~at ~input_pending ~currently_visible =
  match notice.rejection with
  | Some (Draining current) when not input_pending ->
      let lifetime = match currently_visible with
        | Some visible when same_rejection current visible -> Presented (current, at)
        | Some _ | None -> Pending current in
      { notice with rejection = Some lifetime }
  | Some (Pending _ | Draining _ | Presented _) | None -> notice

let after_input notice ~input_seen ~operator_input ~currently_visible ~now ~window =
  let ordinary = if input_seen then None else notice.ordinary in
  let rejection = match notice.rejection with
    | Some (Presented (_, at)) when now -. at > window -> None
    | Some (Presented (current, _)) ->
        (match currently_visible with
         | Some visible when same_rejection current visible ->
             if operator_input then None else notice.rejection
         | Some _ | None -> Some (Pending current))
    | Some (Pending _ | Draining _) | None -> notice.rejection in
  { notice with ordinary; rejection }
