(** Dot — atomic round status / keeper-slot indicator.

    See [dot.mli] for the public contract.

    Visual reference:
    - Status (no-glow tier): [dashboard/design-system/source_styles/tokens.css:421]
      [.dot-{kind}] selectors — solid color, no chrome. Carried forward
      here for [`Status `Idle] which the SPEC defines as silent.
    - Status (with-glow tier): mirrors the [.dot-running] / Pill /
      Surf glow pattern at 0.5 alpha (SPEC §3.5 elevated-state glow).
    - Keeper slot: [.dot-k-N] selectors at [tokens.css:432-443] — solid
      [--color-keeper-N] with [box-shadow: 0 0 5px rgb(var(--k-N-glow)
      / .6)]. The bonsai primitive uses 0.5 alpha (mission-spec
      uniformity across status + keeper) rather than 0.6; the visual
      delta at 4px is sub-pixel.

    Glow alias note: status uses the canonical
    [--color-status-{kind}-glow] semantic alias (defined at
    [dashboard/src/styles/variables.css:347-351]); keeper slots
    consume the raw [--k-N-glow] triplet because no
    [--color-keeper-N-glow] semantic alias is defined upstream — the
    raw token IS the SSOT here (mirrors [.dot-k-N] reference). *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .dot_base {
    display: inline-block;
    border-radius: 50%;
    flex-shrink: 0;
    vertical-align: middle;
  }

  .size_default { width: 4px; height: 4px; }
  .size_sm      { width: 3px; height: 3px; }
  .size_md      { width: 6px; height: 6px; }

  /* Status tier — semantic glow alias (variables.css §status-glow). */
  .s_ok {
    background: var(--color-status-ok, #6a9a4a);
    box-shadow: 0 0 5px rgb(var(--color-status-ok-glow, 106 154 74) / 0.5);
  }
  .s_warn {
    background: var(--color-status-warn, #b87828);
    box-shadow: 0 0 5px rgb(var(--color-status-warn-glow, 184 120 40) / 0.5);
  }
  .s_err {
    background: var(--color-status-err, #e85050);
    box-shadow: 0 0 5px rgb(var(--color-status-err-glow, 232 80 80) / 0.5);
  }
  .s_info {
    background: var(--color-status-info, #968228);
    box-shadow: 0 0 5px rgb(var(--color-status-info-glow, 150 130 40) / 0.5);
  }
  .s_idle {
    background: var(--color-status-idle, #807870);
    /* No glow — SPEC §3.5: idle is silent state, no chrome. */
  }
  .s_stalled {
    background: var(--color-status-stalled, #8a6abf);
    box-shadow: 0 0 5px rgb(var(--color-status-stalled-glow, 138 106 191) / 0.5);
  }

  /* Keeper slot tier — raw --k-N-glow triplet (no semantic alias upstream;
     mirrors canonical [.dot-k-N] selector at tokens.css:432-443). */
  .k_1 {
    background: var(--color-keeper-1, #b8826e);
    box-shadow: 0 0 5px rgb(var(--k-1-glow, 200 134 110) / 0.5);
  }
  .k_2 {
    background: var(--color-keeper-2, #b8946a);
    box-shadow: 0 0 5px rgb(var(--k-2-glow, 204 138 123) / 0.5);
  }
  .k_3 {
    background: var(--color-keeper-3, #aaa15c);
    box-shadow: 0 0 5px rgb(var(--k-3-glow, 195 146 89) / 0.5);
  }
  .k_4 {
    background: var(--color-keeper-4, #91a85c);
    box-shadow: 0 0 5px rgb(var(--k-4-glow, 176 156 77) / 0.5);
  }
  .k_5 {
    background: var(--color-keeper-5, #74ad6f);
    box-shadow: 0 0 5px rgb(var(--k-5-glow, 147 168 92) / 0.5);
  }
  .k_6 {
    background: var(--color-keeper-6, #5ead8a);
    box-shadow: 0 0 5px rgb(var(--k-6-glow, 108 173 125) / 0.5);
  }
  .k_7 {
    background: var(--color-keeper-7, #5aaaa5);
    box-shadow: 0 0 5px rgb(var(--k-7-glow, 69 176 154) / 0.5);
  }
  .k_8 {
    background: var(--color-keeper-8, #6ba2c0);
    box-shadow: 0 0 5px rgb(var(--k-8-glow, 58 172 186) / 0.5);
  }
  .k_9 {
    background: var(--color-keeper-9, #8e96cf);
    box-shadow: 0 0 5px rgb(var(--k-9-glow, 101 160 204) / 0.5);
  }
  .k_10 {
    background: var(--color-keeper-10, #a98ac8);
    box-shadow: 0 0 5px rgb(var(--k-10-glow, 139 150 207) / 0.5);
  }
  .k_11 {
    background: var(--color-keeper-11, #b87fb6);
    box-shadow: 0 0 5px rgb(var(--k-11-glow, 169 141 202) / 0.5);
  }
  .k_12 {
    background: var(--color-keeper-12, #b87a98);
    box-shadow: 0 0 5px rgb(var(--k-12-glow, 192 138 175) / 0.5);
  }

  /* Out-of-range keeper slot — neutral grey, no glow. Mirrors the
     [.s_oob] precedent in [keeper_badge.ml]. */
  .k_oob {
    background: var(--color-fg-muted, #9a846e);
  }

  @media (prefers-contrast: more) {
    .dot_base { outline: 1px solid var(--text-bright); }
  }

  @media (forced-colors: active) {
    /* Drop glow + map to system tokens so the dot still reads as a
       state indicator under high-contrast mode. */
    .dot_base { box-shadow: none; }
    .s_ok, .s_info     { background: Highlight; }
    .s_warn            { background: Mark; }
    .s_err             { background: MarkText; }
    .s_idle            { background: GrayText; }
    .s_stalled         { background: ButtonText; }
    .k_1, .k_2, .k_3, .k_4, .k_5, .k_6,
    .k_7, .k_8, .k_9, .k_10, .k_11, .k_12 { background: ButtonText; }
    .k_oob             { background: GrayText; }
  }
|}]

type kind =
  [ `Status of
    [ `Ok
    | `Warn
    | `Err
    | `Info
    | `Idle
    | `Stalled
    ]
  | `Keeper_slot of int
  ]

type size =
  [ `Sm
  | `Md
  ]

let size_class : size option -> Attr.t = function
  | None -> Style.size_default
  | Some `Sm -> Style.size_sm
  | Some `Md -> Style.size_md
;;

let size_name : size option -> string = function
  | None -> "default"
  | Some `Sm -> "sm"
  | Some `Md -> "md"
;;

(** Resolve a keeper slot to its color class. Slots outside [1..12]
    clamp to [k_oob] (neutral grey) so a buggy caller still renders. *)
let slot_class (slot : int) : Attr.t =
  match slot with
  | 1 -> Style.k_1
  | 2 -> Style.k_2
  | 3 -> Style.k_3
  | 4 -> Style.k_4
  | 5 -> Style.k_5
  | 6 -> Style.k_6
  | 7 -> Style.k_7
  | 8 -> Style.k_8
  | 9 -> Style.k_9
  | 10 -> Style.k_10
  | 11 -> Style.k_11
  | 12 -> Style.k_12
  | _ -> Style.k_oob
;;

let slot_data_value (slot : int) : string =
  if slot >= 1 && slot <= 12 then Int.to_string slot else "oob"
;;

let kind_class : kind -> Attr.t = function
  | `Status `Ok -> Style.s_ok
  | `Status `Warn -> Style.s_warn
  | `Status `Err -> Style.s_err
  | `Status `Info -> Style.s_info
  | `Status `Idle -> Style.s_idle
  | `Status `Stalled -> Style.s_stalled
  | `Keeper_slot n -> slot_class n
;;

let status_name : [ `Ok | `Warn | `Err | `Info | `Idle | `Stalled ] -> string
  = function
  | `Ok -> "ok"
  | `Warn -> "warn"
  | `Err -> "err"
  | `Info -> "info"
  | `Idle -> "idle"
  | `Stalled -> "stalled"
;;

(** Pure: assemble the [data-*] attributes that callers / audits read
    to validate the rendered kind. Status dots emit
    [data-kind=status data-status=<name>]; keeper-slot dots emit
    [data-kind=keeper data-slot=<N|oob>]. *)
let kind_data_attrs : kind -> Attr.t list = function
  | `Status s ->
    [ Attr.create "data-kind" "status"
    ; Attr.create "data-status" (status_name s)
    ]
  | `Keeper_slot n ->
    [ Attr.create "data-kind" "keeper"
    ; Attr.create "data-slot" (slot_data_value n)
    ]
;;

let view ?size ~(kind : kind) () : Node.t =
  let attrs =
    [ Style.dot_base
    ; size_class size
    ; kind_class kind
    ; Attr.create "aria-hidden" "true"
    ; Attr.create "data-size" (size_name size)
    ]
    @ kind_data_attrs kind
  in
  Node.span ~attrs []
;;
