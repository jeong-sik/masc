type tone = Quiet | Plain | Attention | Failure

type t =
  | Title of string
  | Fact of { label : string; value : string; tone : tone }
  | Note of { text : string; tone : tone }

let fact ?(tone = Plain) label value = Fact { label; value; tone }
let note ?(tone = Plain) text = Note { text; tone }

let text = function
  | Title text | Note { text; _ } -> text
  | Fact { label; value; _ } -> label ^ ": " ^ value
