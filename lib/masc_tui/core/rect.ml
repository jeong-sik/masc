type t = {
  x : int;
  y : int;
  w : int;
  h : int;
}

let empty = { x = 0; y = 0; w = 0; h = 0 }
let make ~x ~y ~w ~h = { x; y; w = Int.max 0 w; h = Int.max 0 h }
let right r = r.x + r.w
let bottom r = r.y + r.h
let area r = r.w * r.h
let is_empty r = r.w <= 0 || r.h <= 0

let contains r ~x ~y =
  x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h

let intersect a b =
  let x0 = Int.max a.x b.x in
  let y0 = Int.max a.y b.y in
  let x1 = Int.min (right a) (right b) in
  let y1 = Int.min (bottom a) (bottom b) in
  if x1 <= x0 || y1 <= y0 then { x = x0; y = y0; w = 0; h = 0 }
  else { x = x0; y = y0; w = x1 - x0; h = y1 - y0 }

let inset ?(top = 0) ?(right = 0) ?(bottom = 0) ?(left = 0) r =
  let top = Int.max 0 top in
  let right = Int.max 0 right in
  let bottom = Int.max 0 bottom in
  let left = Int.max 0 left in
  make ~x:(r.x + left) ~y:(r.y + top)
    ~w:(r.w - left - right) ~h:(r.h - top - bottom)

let inset_uniform ~dx ~dy r = inset ~top:dy ~right:dx ~bottom:dy ~left:dx r

let split_h r ~left_w =
  let lw = Int.max 0 (Int.min r.w left_w) in
  let left = { x = r.x; y = r.y; w = lw; h = r.h } in
  let right = { x = r.x + lw; y = r.y; w = r.w - lw; h = r.h } in
  (left, right)

let split_v r ~top_h =
  let th = Int.max 0 (Int.min r.h top_h) in
  let top = { x = r.x; y = r.y; w = r.w; h = th } in
  let bottom = { x = r.x; y = r.y + th; w = r.w; h = r.h - th } in
  (top, bottom)

let equal a b =
  Int.equal a.x b.x
  && Int.equal a.y b.y
  && Int.equal a.w b.w
  && Int.equal a.h b.h
