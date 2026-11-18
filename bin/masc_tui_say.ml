type language =
  | Ko
  | En

(* A text is what it reads as in each language. A function rather than a
   pair, so that joining texts costs nothing until a row is drawn and a
   per-language format runs only for the language on screen. *)
type t = language -> string

let both ~ko ~en = function
  | Ko -> ko
  | En -> en

let per_language choose = choose
let as_received text _ = text
let empty _ = ""
let ( ++ ) left right language = left language ^ right language

let concat ~sep texts language =
  String.concat (sep language) (List.map (fun text -> text language) texts)

let render language text = text language
