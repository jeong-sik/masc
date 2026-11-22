type t = {
  fg : Color.t;
  bg : Color.t;
  attrs : Attr.t;
  hyperlink_id : int;
}

let default =
  { fg = Color.Default; bg = Color.Default; attrs = Attr.none; hyperlink_id = 0 }

let make ?(fg = Color.Default) ?(bg = Color.Default) ?(attrs = Attr.none)
    ?(hyperlink_id = 0) () =
  { fg; bg; attrs; hyperlink_id }

let with_fg fg t = { t with fg }
let with_bg bg t = { t with bg }
let with_attrs attrs t = { t with attrs }
let add_attr flag t = { t with attrs = Attr.(t.attrs lor flag) }
let with_hyperlink hyperlink_id t = { t with hyperlink_id }

let equal a b =
  Color.equal a.fg b.fg
  && Color.equal a.bg b.bg
  && Attr.equal a.attrs b.attrs
  && Int.equal a.hyperlink_id b.hyperlink_id
