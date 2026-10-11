type t = string
let fresh () = Random_id.uuid_v7 ()
let to_string id = id
let of_string text = Random_id.parse_uuid_v7 text
let equal = String.equal
