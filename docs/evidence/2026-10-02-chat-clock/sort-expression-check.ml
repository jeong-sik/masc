type block = { lb_insertion:int; lb_timeline_at:float option; id:int };;
let sort settled_blocks observed_blocks other_live_blocks =
let blocks =
      settled_blocks @ observed_blocks @ other_live_blocks
      |> List.stable_sort (fun left right ->
          let by_position = Int.compare left.lb_insertion right.lb_insertion in
          if by_position <> 0 then by_position
          else match left.lb_timeline_at, right.lb_timeline_at with
            | Some left_at, Some right_at -> Float.compare left_at right_at
            | Some _, None -> -1
            | None, Some _ -> 1
            | None, None -> 0)
    in blocks;;
let checks = ref 0;;
let check label expected actual =
 if expected <> actual then failwith label;
 incr checks;;
let rec insert x = function
 | [] -> [[x]]
 | y::ys as all -> (x::all) :: List.map (fun rest -> y::rest) (insert x ys);;
let rec permutations = function
 | [] -> [[]]
 | x::xs -> List.concat_map (insert x) (permutations xs);;
let ids blocks = List.map (fun b -> b.id) blocks;;
List.iter (fun permutation ->
 let blocks = List.map (fun id -> {lb_insertion=0;lb_timeline_at=Some(float_of_int id);id}) permutation in
 check "same-slot four-message ordering" [0;1;2;3] (ids(sort blocks [] [])))
 (permutations [0;1;2;3]);;
let make slot at id = {lb_insertion=slot;lb_timeline_at=at;id};;
check "equal clock preserves source order" [3;1;2]
 (ids(sort [make 0 (Some 1.) 3;make 0 (Some 1.) 1;make 0 (Some 1.) 2] [] []));;
check "unknown clock follows known clock" [1;0]
 (ids(sort [make 0 None 0;make 0 (Some 2.) 1] [] []));;
check "causal insertion position precedes timestamp" [0;1]
 (ids(sort [make 1 (Some 1.) 1;make 0 (Some 9.) 0] [] []));;
let many = List.init 128 (fun i -> make 0 (Some(float_of_int i)) i);;
check "n+m reverse source order" (ids many) (ids(sort (List.rev many) [] []));;
Printf.printf "PASS %d exact renderer sorting-expression assertions\n" !checks;;
