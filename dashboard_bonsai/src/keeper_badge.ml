(** KeeperBadge — keeper attribution primitive (sigil + slot color).

    SPEC §3.6.3: color alone MUST NOT identify a keeper. Every attribution
    carries a second channel — a 2-letter sigil. This primitive renders
    the canonical sigil-square: a colored mono uppercase 2-glyph badge
    using [--color-keeper-N] (1..12) for the background and [--color-bg-page]
    for the foreground.

    Bonsai mirror of Preact [dashboard/src/components/keeper-badge.ts]
    [variant=sigil]. The Preact reference also exposes [variant=full] (sigil
    + colored name) and [variant=name] (colored text only); those compose
    on top of this primitive in the caller and are out of scope here.

    Slot resolution and sigil derivation live in the caller — this module
    accepts the resolved [slot:int] (1..12) and [sigil:string] directly so
    a single primitive serves both the registry-pinned anchors and the
    FNV-1a hash fallback in upstream code. Out-of-range slots clamp to a
    [`Neutral] grey badge so a buggy caller still renders something, but
    the data-slot attribute reports [oob] so audits can catch it.

    Sigil clamping: the primitive renders at most 2 glyphs. Longer strings
    are truncated; shorter strings render as-is. Empty string renders as a
    chromeless square (no text). *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .badge {
    display: inline-flex;
    align-items: center;
    justify-content: center;
    font-family: var(--font-mono, ui-monospace, SFMono-Regular, "SF Mono", Menlo, Consolas, "Liberation Mono", monospace);
    font-weight: 700;
    letter-spacing: 0;
    color: var(--color-bg-page, #0c0b08);
    flex: none;
  }

  .size_sm { width: 14px; height: 14px; font-size: 8px;  border-radius: 2px; }
  .size_md { width: 18px; height: 18px; font-size: 9px;  border-radius: 2px; }
  .size_lg { width: 24px; height: 24px; font-size: 11px; border-radius: 3px; }

  .s_1  { background: var(--color-keeper-1,  #b8826e); }
  .s_2  { background: var(--color-keeper-2,  #b8946a); }
  .s_3  { background: var(--color-keeper-3,  #aaa15c); }
  .s_4  { background: var(--color-keeper-4,  #91a85c); }
  .s_5  { background: var(--color-keeper-5,  #74ad6f); }
  .s_6  { background: var(--color-keeper-6,  #5ead8a); }
  .s_7  { background: var(--color-keeper-7,  #5aaaa5); }
  .s_8  { background: var(--color-keeper-8,  #6ba2c0); }
  .s_9  { background: var(--color-keeper-9,  #8e96cf); }
  .s_10 { background: var(--color-keeper-10, #a98ac8); }
  .s_11 { background: var(--color-keeper-11, #b87fb6); }
  .s_12 { background: var(--color-keeper-12, #b87a98); }
  .s_oob {
    background: var(--color-fg-muted, #9a846e);
    color: var(--color-bg-page, #0c0b08);
  }

  @media (prefers-contrast: more) {
    .badge { outline: 1px solid var(--text-bright); }
  }

  @media (forced-colors: active) {
    .badge { background: ButtonText; color: ButtonFace; }
    .s_oob { background: GrayText; color: ButtonFace; }
  }
|}]

type size =
  [ `Sm
  | `Md
  | `Lg
  ]

let size_class : size -> Attr.t = function
  | `Sm -> Style.size_sm
  | `Md -> Style.size_md
  | `Lg -> Style.size_lg
;;

let size_name : size -> string = function
  | `Sm -> "sm"
  | `Md -> "md"
  | `Lg -> "lg"
;;

(** Map slot [1..12] to the matching ppx_css class. Out-of-range slots
    clamp to [s_oob] (neutral grey) so a malformed input still renders. *)
let slot_class (slot : int) : Attr.t =
  match slot with
  | 1 -> Style.s_1
  | 2 -> Style.s_2
  | 3 -> Style.s_3
  | 4 -> Style.s_4
  | 5 -> Style.s_5
  | 6 -> Style.s_6
  | 7 -> Style.s_7
  | 8 -> Style.s_8
  | 9 -> Style.s_9
  | 10 -> Style.s_10
  | 11 -> Style.s_11
  | 12 -> Style.s_12
  | _ -> Style.s_oob
;;

let slot_name (slot : int) : string =
  if slot >= 1 && slot <= 12 then Int.to_string slot else "oob"
;;

(** Truncate the sigil to at most 2 visible glyphs. Uses a byte slice
    rather than a grapheme-cluster slice — keepers are conventionally
    ASCII (FNV-1a derived monograms or 2-char registry overrides) so a
    naive prefix is safe; non-ASCII inputs degrade to the byte prefix
    rather than throwing. *)
let clamp_sigil (s : string) : string =
  let len = String.length s in
  if len <= 2 then s else String.sub s ~pos:0 ~len:2
;;

let view ?(size : size = `Md) ~(slot : int) ~(sigil : string) () : Node.t =
  let label = clamp_sigil sigil in
  let aria = if String.is_empty label then "keeper" else label in
  Node.span
    ~attrs:
      [ Style.badge
      ; size_class size
      ; slot_class slot
      ; Attr.create "data-slot" (slot_name slot)
      ; Attr.create "data-size" (size_name size)
      ; Attr.create "aria-label" aria
      ; Attr.role "img"
      ]
    [ Node.text label ]
;;
