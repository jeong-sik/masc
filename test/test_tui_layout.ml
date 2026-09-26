(* Masc_tui_layout.allocate, over every small budget and every short list of
   sections. The Overview used to share its rows first come first served, and
   the defects that produced were combinations nobody had drawn: GOALS and
   Team together left Tasks one row at 40 (#38607), and a taller terminal drew
   fewer Tasks rows than a shorter one (#38911). A table of cases would pin the
   combinations someone thought of, so the properties are checked on all of
   them instead. *)

open Alcotest

module Layout = Masc_tui_layout

let section floor want = { Layout.floor; want }

(* Floors and wants a caller might hand over, the ones the allocator has to
   clamp included: a negative count, and a floor above its want. *)
let counts = [ -1; 0; 1; 2; 3; 4 ]
let budgets = List.init 14 (fun budget -> budget - 1)

let rec section_lists length =
  if length = 0 then [ [] ]
  else
    let shorter = section_lists (length - 1) in
    List.concat_map
      (fun floor ->
        List.concat_map
          (fun want ->
            List.map (fun rest -> section floor want :: rest) shorter)
          counts)
      counts

let every_section_list =
  List.concat_map section_lists [ 0; 1; 2; 3 ]

let want (s : Layout.section) = max 0 s.want
let floor (s : Layout.section) = max 0 (min s.floor (want s))

let show sections =
  String.concat "; "
    (List.map
       (fun (s : Layout.section) -> Printf.sprintf "%d/%d" s.floor s.want)
       sections)

let show_rows rows = String.concat "," (List.map string_of_int rows)

let rows ~budget sections = (Layout.allocate ~budget sections).rows

let for_every_case check =
  List.iter
    (fun sections -> List.iter (fun budget -> check ~budget sections) budgets)
    every_section_list

let test_the_counts_fit_the_budget () =
  for_every_case (fun ~budget sections ->
      let allocation = Layout.allocate ~budget sections in
      let given = List.fold_left ( + ) 0 allocation.rows in
      if List.length allocation.rows <> List.length sections then
        failf "budget %d [%s]: %d counts for %d sections" budget
          (show sections)
          (List.length allocation.rows)
          (List.length sections);
      if given + allocation.filler <> max 0 budget then
        failf "budget %d [%s]: %s and filler %d do not add up" budget
          (show sections) (show_rows allocation.rows) allocation.filler;
      List.iter2
        (fun (s : Layout.section) given ->
          if given < 0 || given > want s then
            failf "budget %d [%s]: %d rows for a section that wants %d" budget
              (show sections) given (want s))
        sections allocation.rows;
      if allocation.filler < 0 then
        failf "budget %d [%s]: filler %d" budget (show sections)
          allocation.filler)

(* No section grows past its floor while another is short of its own, and a
   floor cut short leaves nothing for the sections after it. *)
let test_every_floor_is_paid_before_any_want () =
  for_every_case (fun ~budget sections ->
      let given = rows ~budget sections in
      let pairs = List.combine sections given in
      let short =
        List.exists (fun (s, given) -> given < floor s) pairs
      in
      let grown =
        List.exists (fun (s, given) -> given > floor s) pairs
      in
      if short && grown then
        failf "budget %d [%s]: %s grows a section while a floor is short"
          budget (show sections) (show_rows given);
      let rec after_a_short_floor = function
        | [] -> ()
        | (s, rows) :: rest when rows < floor s ->
            if List.exists (fun (_, later) -> later > 0) rest then
              failf "budget %d [%s]: %s pays a later section past a short floor"
                budget (show sections) (show_rows given)
        | _ :: rest -> after_a_short_floor rest
      in
      after_a_short_floor pairs)

let no_section_shrinks ~label ~budget sections ~before ~after =
  List.iteri
    (fun index (before, after) ->
      if after < before then
        failf "budget %d [%s]: %s takes section %d from %d to %d rows" budget
          (show sections) label index before after)
    (List.combine before after)

(* One more row never takes a row from anyone. *)
let test_a_larger_budget_never_shrinks_a_section () =
  for_every_case (fun ~budget sections ->
      no_section_shrinks ~label:"one more row" ~budget sections
        ~before:(rows ~budget sections)
        ~after:(rows ~budget:(budget + 1) sections))

(* A section asking for less never costs another section a row. *)
let test_asking_for_less_never_costs_another_section () =
  for_every_case (fun ~budget sections ->
      let before = rows ~budget sections in
      List.iteri
        (fun index (s : Layout.section) ->
          let others given =
            List.filteri (fun other _ -> other <> index) given
          in
          let replaced replacement =
            List.mapi
              (fun other original -> if other = index then replacement else original)
              sections
          in
          List.iter
            (fun (label, smaller) ->
              no_section_shrinks ~label ~budget sections ~before:(others before)
                ~after:(others (rows ~budget (replaced smaller))))
            [ ("a lower floor", section (floor s - 1) s.want)
            ; ("a lower want", section s.floor (want s - 1))
            ])
        sections)

let () =
  run "tui_layout"
    [ ( "allocate"
      , [ test_case "the counts fit the budget" `Quick
            test_the_counts_fit_the_budget
        ; test_case "every floor is paid before any want" `Quick
            test_every_floor_is_paid_before_any_want
        ; test_case "a larger budget never shrinks a section" `Quick
            test_a_larger_budget_never_shrinks_a_section
        ; test_case "asking for less never costs another section" `Quick
            test_asking_for_less_never_costs_another_section
        ] )
    ]
