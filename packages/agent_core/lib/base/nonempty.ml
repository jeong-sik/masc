type 'a t =
  { hd : 'a
  ; tl : 'a list
  }

let of_list = function
  | [] -> None
  | hd :: tl -> Some { hd; tl }
;;

let to_list t = t.hd :: t.tl
let hd t = t.hd
let length t = 1 + List.length t.tl
