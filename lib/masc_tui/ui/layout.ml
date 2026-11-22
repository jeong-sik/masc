module Rect = Masc_tui_core.Rect

type breakpoint =
  | Wide
  | Standard
  | Compact
  | Micro

type constraint_ =
  | Fixed of int
  | Ratio of float
  | Min_max of { min : int; max : int; weight : int }
  | Flex of int

type 'a card_slot = {
  id : 'a;
  is_empty : bool;
  constraint_ : constraint_;
}

let breakpoint_rank = function
  | Wide -> 0
  | Standard -> 1
  | Compact -> 2
  | Micro -> 3

let equal_breakpoint a b = Int.equal (breakpoint_rank a) (breakpoint_rank b)

let breakpoint_name = function
  | Wide -> "wide"
  | Standard -> "standard"
  | Compact -> "compact"
  | Micro -> "micro"

let classify_viewport ~cols ~rows =
  if cols < 80 || rows < 24 then Micro
  else if cols >= 140 && rows >= 36 then Wide
  else if cols >= 100 && rows >= 28 then Standard
  else Compact

let is_too_small_blocker ~cols ~rows = cols < 40 || rows < 12

let chrome_rows bp ~composer_expanded ~approval_strip =
  let strip = if approval_strip then 1 else 0 in
  match bp with
  | Wide | Standard -> 4 + strip
  | Compact -> (if composer_expanded then 4 else 3) + strip
  | Micro -> 2

let outer_margin = function
  | Wide | Standard -> 1
  | Compact | Micro -> 0

let card_gap_x = function
  | Wide -> 2
  | Standard | Compact -> 1
  | Micro -> 0

let card_gap_y = function
  | Wide | Standard -> 1
  | Compact | Micro -> 0

let card_pad_x = function
  | Wide | Standard -> 2
  | Compact | Micro -> 1

let table_col_gap = function
  | Wide | Standard -> 2
  | Compact | Micro -> 1

let tab_gap = function
  | Wide | Standard -> 2
  | Compact | Micro -> 1

let sub_tab_gap = function
  | Wide | Standard -> 3
  | Compact | Micro -> 2

let inset_body bp rect =
  let m = outer_margin bp in
  if m <= 0 || rect.Rect.w <= m * 2 then rect
  else Rect.inset ~left:m ~right:m rect

let adaptive_list_height ~items ?(overhead = 4) ~min_h ~max_h () =
  let lo = Int.max 0 min_h in
  let hi = Int.max lo max_h in
  let want = Int.max 0 items + Int.max 0 overhead in
  Int.max lo (Int.min hi want)

let allocate ~total ?(gap = 0) constraints =
  let n = List.length constraints in
  if n = 0 then []
  else
    let gap = Int.max 0 gap in
    let total_gap = gap * (n - 1) in
    let budget = Int.max 0 (total - total_gap) in
    if budget = 0 then List.init n (fun _ -> 0)
    else
      let arr = Array.of_list constraints in
      let sizes = Array.make n 0 in
      let flex_weights = Array.make n 0 in
      let flex_caps = Array.make n budget in
      let remaining = ref budget in
      (* Pass 1: Fixed, Ratio, and Min_max minimum reservations. *)
      for i = 0 to n - 1 do
        match arr.(i) with
        | Fixed k ->
            let take = Int.max 0 (Int.min !remaining k) in
            sizes.(i) <- take;
            remaining := !remaining - take
        | Ratio r ->
            let clamped =
              if not (Float.is_finite r) then 0.0
              else Float.max 0.0 (Float.min 1.0 r)
            in
            let want = int_of_float (Float.floor (float_of_int budget *. clamped)) in
            let take = Int.max 0 (Int.min !remaining want) in
            sizes.(i) <- take;
            remaining := !remaining - take
        | Min_max { min; max; weight } ->
            let lo = Int.max 0 min in
            let hi = Int.max lo max in
            let take = Int.min !remaining lo in
            sizes.(i) <- take;
            remaining := !remaining - take;
            flex_weights.(i) <- Int.max 1 weight;
            flex_caps.(i) <- hi
        | Flex w ->
            flex_weights.(i) <- Int.max 1 w;
            flex_caps.(i) <- budget
      done;
      (* Pass 2: Iteratively distribute remaining cells by weight while
         respecting Min_max upper caps so overflow redistributes cleanly. *)
      let active = Array.init n (fun i -> flex_weights.(i) > 0 && sizes.(i) < flex_caps.(i)) in
      let keep_going = ref (!remaining > 0) in
      while !keep_going && !remaining > 0 do
        let total_w = ref 0 in
        for i = 0 to n - 1 do
          if active.(i) then total_w := !total_w + flex_weights.(i)
        done;
        if !total_w <= 0 then keep_going := false
        else begin
          let pool = !remaining in
          let added = Array.make n 0 in
          let remainders = Array.make n 0 in
          let distributed = ref 0 in
          for i = 0 to n - 1 do
            if active.(i) then begin
              let scaled = pool * flex_weights.(i) in
              let share = scaled / !total_w in
              let room = flex_caps.(i) - sizes.(i) in
              let give = Int.min room share in
              added.(i) <- give;
              remainders.(i) <- if give < room then scaled mod !total_w else -1;
              distributed := !distributed + give
            end
          done;
          for i = 0 to n - 1 do
            if added.(i) > 0 then sizes.(i) <- sizes.(i) + added.(i)
          done;
          remaining := !remaining - !distributed;
          (* Assign leftover cells by largest remainder among uncapped slots. *)
          let order =
            Array.init n (fun i -> i)
          in
          Array.sort
            (fun a b ->
              if remainders.(a) <> remainders.(b) then
                Int.compare remainders.(b) remainders.(a)
              else Int.compare a b)
            order;
          let extra_given = ref 0 in
          for k = 0 to n - 1 do
            let i = order.(k) in
            if !remaining > 0 && active.(i) && sizes.(i) < flex_caps.(i) then begin
              sizes.(i) <- sizes.(i) + 1;
              decr remaining;
              incr extra_given
            end
          done;
          let any_capped_now = ref false in
          for i = 0 to n - 1 do
            if active.(i) && sizes.(i) >= flex_caps.(i) then begin
              active.(i) <- false;
              any_capped_now := true
            end
          done;
          if !distributed = 0 && !extra_given = 0 && not !any_capped_now then
            keep_going := false
        end
      done;
      Array.to_list sizes

let split_h ?(gap = 0) (rect : Rect.t) constraints =
  let gap = Int.max 0 gap in
  let widths = allocate ~total:rect.w ~gap constraints in
  let cursor = ref rect.x in
  List.map
    (fun w ->
      let sub = Rect.make ~x:!cursor ~y:rect.y ~w ~h:rect.h in
      cursor := !cursor + w + gap;
      sub)
    widths

let split_v ?(gap = 0) (rect : Rect.t) constraints =
  let gap = Int.max 0 gap in
  let heights = allocate ~total:rect.h ~gap constraints in
  let cursor = ref rect.y in
  List.map
    (fun h ->
      let sub = Rect.make ~x:rect.x ~y:!cursor ~w:rect.w ~h in
      cursor := !cursor + h + gap;
      sub)
    heights

let split_h_bp bp rect constraints =
  split_h ~gap:(card_gap_x bp) rect constraints

let split_v_bp bp rect constraints =
  split_v ~gap:(card_gap_y bp) rect constraints

let adaptive_split_2 ?(stack_on_compact = true) ?(left_ratio = 0.48)
    ?(top_ratio = 0.46) bp rect =
  let horizontal =
    match bp with
    | Wide | Standard -> true
    | Compact -> not stack_on_compact
    | Micro -> false
  in
  let pair =
    if horizontal then split_h_bp bp rect [ Ratio left_ratio; Flex 1 ]
    else split_v_bp bp rect [ Ratio top_ratio; Flex 1 ]
  in
  match pair with
  | [ a; b ] -> (a, b)
  | _ -> (rect, Rect.empty)

let collapse_empty_cards ?(gap = 0) rect slots =
  let active, empty =
    List.partition (fun s -> not s.is_empty) slots
  in
  let rects =
    split_v ~gap rect (List.map (fun s -> s.constraint_) active)
  in
  let assigned =
    List.map2 (fun s r -> (s.id, r)) active rects
  in
  let collapsed_ids = List.map (fun s -> s.id) empty in
  (assigned, collapsed_ids)
