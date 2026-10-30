module Categories = Set_util.StringMap

type t =
  { category_cap : int
  ; facts_per_category_cap : int
  ; category_counts : (string * int) list
  }

let measure ~category_cap ~facts_per_category_cap facts =
  let counts =
    List.fold_left
      (fun counts (fact : Keeper_memory_os_types.fact) ->
         let category = Keeper_memory_os_types.category_to_string fact.category in
         Categories.update category
           (function None -> Some 1 | Some count -> Some (count + 1)) counts)
      Categories.empty facts
  in
  { category_cap; facts_per_category_cap; category_counts = Categories.bindings counts }
;;

let current facts =
  measure
    ~category_cap:(Env_config.KeeperMemoryOs.category_cap ())
    ~facts_per_category_cap:(Env_config.KeeperMemoryOs.facts_per_category_cap ())
    facts
;;

let exceeded { category_cap; facts_per_category_cap; category_counts } =
  List.length category_counts > category_cap
  || List.exists (fun (_, count) -> count > facts_per_category_cap) category_counts
;;

let excess { category_cap; facts_per_category_cap; category_counts } =
  let categories = max 0 (List.length category_counts - category_cap) in
  let items = List.fold_left
      (fun total (_, count) -> total + max 0 (count - facts_per_category_cap))
      0 category_counts in
  categories, items
;;

let excess_reduced ~before ~after =
  let before_categories, before_items = excess before in
  let after_categories, after_items = excess after in
  before.category_cap = after.category_cap
  && before.facts_per_category_cap = after.facts_per_category_cap
  && after_categories <= before_categories
  && after_items <= before_items
  && (after_categories < before_categories || after_items < before_items)
;;

let to_json { category_cap; facts_per_category_cap; category_counts } =
  let category_count = List.length category_counts in
  `Assoc
    [ "scope", `String "ordinary_current"
    ; "enforcement", `String "advisory"
    ; "category_cap", `Int category_cap
    ; "facts_per_category_cap", `Int facts_per_category_cap
    ; "category_count", `Int category_count
    ; "categories_over_cap", `Int (max 0 (category_count - category_cap))
    ; "categories", `List
        (List.map
           (fun (category, count) ->
              `Assoc
                [ "category", `String category
                ; "count", `Int count
                ; "items_over_cap", `Int (max 0 (count - facts_per_category_cap))
                ])
           category_counts)
    ]
;;
