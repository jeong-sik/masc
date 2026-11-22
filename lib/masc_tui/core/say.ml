type lang =
  | Lang_ko
  | Lang_en

type t = {
  ko : string;
  en : string;
}

let make ~ko ~en = { ko; en }
let literal text = { ko = text; en = text }

let resolve lang t =
  match lang with
  | Lang_ko -> t.ko
  | Lang_en -> t.en

let map f t = { ko = f t.ko; en = f t.en }

let concat ~sep items =
  {
    ko = String.concat sep (List.map (fun item -> item.ko) items);
    en = String.concat sep (List.map (fun item -> item.en) items);
  }

let lang_code = function
  | Lang_ko -> "ko"
  | Lang_en -> "en"

let lang_of_code code =
  match String.lowercase_ascii (String.trim code) with
  | "ko" | "ko-kr" -> Some Lang_ko
  | "en" | "en-us" -> Some Lang_en
  | _ -> None

let equal_lang a b =
  match a, b with
  | Lang_ko, Lang_ko | Lang_en, Lang_en -> true
  | Lang_ko, Lang_en | Lang_en, Lang_ko -> false

let equal a b = String.equal a.ko b.ko && String.equal a.en b.en
