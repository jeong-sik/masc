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
