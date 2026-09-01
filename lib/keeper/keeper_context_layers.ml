(** See [keeper_context_layers.mli] for the contract. *)

type layer_id =
  | Active_goals
  | Current_task
  | Approval_authority
  | Connected_surfaces
  | Namespace_state
  | Repository_freshness
  | Autonomous_trigger
  | Scheduled_automation
  | Completion_authority
  | Task_cancellations
  | Pending_mentions
  | Scope_messages
  | Own_board_posts
  | Board_activity
  | Own_recent_actions
  | Fleet_messages

(* Prefix-cache ordering: emit larger, more stable sections first so providers
   can reuse a longer shared prefix across cycles; highly volatile reactive
   signals stay later in the same user message. [Current_task] sits directly
   after [Active_goals]: the claimed task is standing context that changes on
   claim/release, not per cycle. [Own_board_posts] changes only when the
   keeper itself publishes, so it sits just ahead of the per-cycle reactive
   [Board_activity]. [Own_recent_actions] is a window that slides every turn,
   so it cannot hold a stable prefix and sits behind the sections that can.
   [Fleet_messages] carries any keeper's broadcast, so it is the most
   fleet-volatile section and sits last. *)
let ordered =
  [ Active_goals
  ; Current_task
  ; Approval_authority
  ; Connected_surfaces
  ; Namespace_state
  ; Repository_freshness
  ; Autonomous_trigger
  ; Scheduled_automation
  ; Completion_authority
  ; Task_cancellations
  ; Pending_mentions
  ; Scope_messages
  ; Own_board_posts
  ; Board_activity
  ; Own_recent_actions
  ; Fleet_messages
  ]
;;

(* Exhaustive over [layer_id]: adding a variant breaks this match at compile
   time, forcing both a position here and (via the [content_of] match at the
   call site) a rendering for the new layer. *)
let order_index = function
  | Active_goals -> 0
  | Current_task -> 1
  | Approval_authority -> 2
  | Connected_surfaces -> 3
  | Namespace_state -> 4
  | Repository_freshness -> 5
  | Autonomous_trigger -> 6
  | Scheduled_automation -> 7
  | Completion_authority -> 8
  | Task_cancellations -> 9
  | Pending_mentions -> 10
  | Scope_messages -> 11
  | Own_board_posts -> 12
  | Board_activity -> 13
  | Own_recent_actions -> 14
  | Fleet_messages -> 15
;;

type retention =
  | Required
  | Trimmable of int

(* Exhaustive over [layer_id] for the same reason as [order_index]: a new
   section must state whether it can be withheld, not inherit an answer.

   This is not a ranking of how useful a section is. It names the sections
   whose rows can carry content the runtime does not bound: a refused call
   replays its argument object verbatim, so one [Own_recent_actions] row can
   outweigh a hundred rows of another section. Every other section renders
   identities and summaries whose width the producing record already fixes,
   so its row budget does bound its bytes. A section that starts rendering
   unbounded content joins the trimmable set here. *)
let retention = function
  | Active_goals -> Required
  | Current_task -> Required
  | Approval_authority -> Required
  | Connected_surfaces -> Required
  | Namespace_state -> Required
  (* Bounded rows: checkout name, branch, and small ints — the discovery
     itself caps the checkout count (Keeper_playground_checkouts). *)
  | Repository_freshness -> Required
  | Autonomous_trigger -> Required
  | Scheduled_automation -> Required
  | Completion_authority -> Required
  | Task_cancellations -> Required
  | Pending_mentions -> Required
  | Scope_messages -> Required
  | Own_board_posts -> Required
  | Board_activity -> Required
  | Fleet_messages -> Required
  | Own_recent_actions -> Trimmable 0
;;

type section =
  | Block of string
  | Rows of
      { rows : string list
      ; render : string list -> string
      }

let render_section ~withheld = function
  | Block text -> text
  | Rows { rows; render } ->
    let rec drop n xs =
      if n <= 0 then xs else match xs with [] -> [] | _ :: tl -> drop (n - 1) tl
    in
    render (drop withheld rows)
;;

let section_text section = render_section ~withheld:0 section

let row_count = function
  | Block _ -> 0
  | Rows { rows; _ } -> List.length rows
;;

(* One layer's state while fitting. [text] is what [withheld] currently
   renders, kept alongside so the running total needs no re-render of the
   layers that did not change. *)
type fitting =
  { section : section
  ; rank : int option
  ; mutable withheld : int
  ; mutable text : string
  }

(* Withhold one more row from the lowest-ranked layer that still has rows, and
   report the byte delta. [None] when no layer can give up anything more. *)
let withhold_one (layers : fitting array) =
  let candidate = ref None in
  Array.iter
    (fun layer ->
      match layer.rank with
      | None -> ()
      | Some rank ->
        if layer.withheld < row_count layer.section
        then (
          match !candidate with
          | Some (best_rank, _) when best_rank <= rank -> ()
          | _ -> candidate := Some (rank, layer)))
    layers;
  match !candidate with
  | None -> None
  | Some (_, layer) ->
    let before = String.length layer.text in
    layer.withheld <- layer.withheld + 1;
    layer.text <- render_section ~withheld:layer.withheld layer.section;
    Some (String.length layer.text - before)
;;

let assemble ?budget_bytes ~content_of () =
  let layers =
    ordered
    |> List.filter_map (fun id ->
      content_of id
      |> Option.map (fun section ->
        { section
        ; rank = (match retention id with Required -> None | Trimmable r -> Some r)
        ; withheld = 0
        ; text = render_section ~withheld:0 section
        }))
    |> Array.of_list
  in
  let total =
    ref (Array.fold_left (fun acc layer -> acc + String.length layer.text) 0 layers)
  in
  (match budget_bytes with
   | None -> ()
   | Some budget ->
     let rec shrink () =
       if !total > budget
       then (
         match withhold_one layers with
         | None -> ()
         | Some delta ->
           total := !total + delta;
           shrink ())
     in
     shrink ());
  let buffer = Buffer.create (max 16 !total) in
  Array.iter (fun layer -> Buffer.add_string buffer layer.text) layers;
  Buffer.contents buffer
;;
