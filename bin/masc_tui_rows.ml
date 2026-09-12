type 'a t = {
  first : int;  (** index in the whole list of the window's first row *)
  rows : 'a array;
}

let of_list ~first ~height rows =
  let first = max 0 first and height = max 0 height in
  if height = 0 then { first; rows = [||] }
  else begin
    (* Newest-first accumulation, reversed once at the end: appending per row
       is the quadratic this module exists to remove, one order of magnitude
       down. *)
    let rec walk index taken newest_first = function
      | [] -> newest_first
      | _ when taken >= height -> newest_first
      | row :: rest ->
          if index < first then walk (index + 1) taken newest_first rest
          else walk (index + 1) (taken + 1) (row :: newest_first) rest
    in
    { first; rows = Array.of_list (List.rev (walk 0 0 [] rows)) }
  end

let of_array rows = { first = 0; rows }

let at window index =
  let offset = index - window.first in
  if offset >= 0 && offset < Array.length window.rows then
    Some window.rows.(offset)
  else None

let length window = Array.length window.rows
