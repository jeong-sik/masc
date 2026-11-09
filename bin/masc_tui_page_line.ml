type tone = Quiet | Plain | Info | Attention | Failure

type t =
  | Title of string
  | Fact of { label : string; value : string; tone : tone }
  | Note of { text : string; tone : tone }
  | Items of { label : string; values : string list; tone : tone }

let fact ?(tone = Plain) label value = Fact { label; value; tone }
let note ?(tone = Plain) text = Note { text; tone }
let items ?(tone = Plain) label values = Items { label; values; tone }

let text = function
  | Title text | Note { text; _ } -> text
  | Fact { label; value; _ } -> label ^ ": " ^ value
  | Items { label; values; _ } -> label ^ ": " ^ String.concat ", " values
