type t = Trivial | Small | Medium | Large | Epic
let all = [Trivial; Small; Medium; Large; Epic]
let to_string = function
 | Trivial -> "trivial" | Small -> "small" | Medium -> "medium"
 | Large -> "large" | Epic -> "epic"
let of_string = function
 | "trivial" -> Some Trivial | "small" -> Some Small | "medium" -> Some Medium
 | "large" -> Some Large | "epic" -> Some Epic | _ -> None
