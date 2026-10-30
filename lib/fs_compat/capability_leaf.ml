type t = string

let is_valid value =
  not (String.equal value "")
  && Filename.is_relative value
  && String.equal (Filename.basename value) value
  && not (String.equal value ".")
  && not (String.equal value "..")
;;

let of_string value = if is_valid value then Some value else None
let to_string value = value
let equal = String.equal
