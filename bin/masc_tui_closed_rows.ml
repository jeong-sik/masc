type 'a t = { mutable cells : 'a array; mutable length : int }

type 'a prefix = { owner : 'a t; prefix_length : int }

let initial_capacity = 16

let create () = { cells = [||]; length = 0 }

let append t value =
  if t.length = Array.length t.cells then begin
    let grown = Array.make (Int.max initial_capacity (2 * t.length)) value in
    Array.blit t.cells 0 grown 0 t.length;
    t.cells <- grown
  end;
  t.cells.(t.length) <- value;
  t.length <- t.length + 1

let prefix t = { owner = t; prefix_length = t.length }

let of_array cells = { owner = { cells; length = Array.length cells }; prefix_length = Array.length cells }

let empty () = prefix (create ())

let length prefix = prefix.prefix_length

let get prefix index =
  if index < 0 || index >= prefix.prefix_length then invalid_arg "Masc_tui_closed_rows.get"
  else prefix.owner.cells.(index)

let extends prefix ~kept = prefix.owner == kept.owner && prefix.prefix_length >= kept.prefix_length

let same left right = left.owner == right.owner && left.prefix_length = right.prefix_length

let sub_list prefix ~start ~stop =
  let start = Int.max 0 start and stop = Int.min prefix.prefix_length stop in
  let cells = prefix.owner.cells in
  let rec collect index acc = if index < start then acc else collect (index - 1) (cells.(index) :: acc) in
  collect (stop - 1) []

let to_list prefix = sub_list prefix ~start:0 ~stop:prefix.prefix_length
