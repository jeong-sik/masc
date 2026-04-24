(** Route staging view for Bonsai tabs that do not yet have a dedicated
    data-backed page.

    The shell already gives these routes real dashboard chrome.  This body keeps
    each route useful as an operator-facing intent panel instead of falling back
    to the older centered "phase" card. *)

open! Core
open! Bonsai_web
open Virtual_dom.Vdom

module Style =
[%css
stylesheet
  {|
  .grid {
    display: grid;
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: 12px;
  }

  .panel {
    min-height: 148px;
    border: 1px solid var(--border-main);
    background:
      linear-gradient(180deg, rgba(28,18,14,0.68), rgba(14,10,8,0.86));
    padding: 15px 16px;
    display: flex;
    flex-direction: column;
    gap: 10px;
  }

  .panel_title {
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.28em;
    text-transform: uppercase;
    color: var(--text-dim);
    margin: 0;
  }

  .panel_text {
    font-family: var(--font-body, 'EB Garamond', serif);
    font-size: 15px;
    line-height: 1.55;
    color: var(--text-primary);
    margin: 0;
  }

  .panel_code {
    margin-top: auto;
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    line-height: 1.45;
    color: var(--text-dim);
    overflow-wrap: anywhere;
  }

  .cta {
    display: flex;
    flex-wrap: wrap;
    gap: 8px;
    align-items: center;
    padding: 14px 16px;
    border: 1px solid var(--border-highlight);
    background:
      linear-gradient(180deg, rgba(42,30,20,0.4), rgba(20,12,8,0.7));
  }

  .btn {
    display: inline-flex;
    align-items: center;
    gap: 6px;
    min-height: 30px;
    padding: 7px 12px;
    border: 1px solid var(--accent-brass-dim);
    background: linear-gradient(180deg, #241a12, #14100a);
    color: var(--text-primary);
    font-family: var(--font-ui, 'Noto Sans KR', sans-serif);
    font-size: 11px;
    letter-spacing: 0.24em;
    text-transform: uppercase;
    text-decoration: none;
  }

  .btn:hover {
    color: var(--accent-brass);
    border-color: var(--accent-brass);
  }
  .btn:focus-visible { outline: 2px solid var(--accent-brass); outline-offset: -2px; }

  .btn_primary {
    color: var(--accent-brass);
    border-color: var(--accent-brass);
    background: linear-gradient(180deg, #3a2a16, #241810);
  }

  .cta_note {
    margin-left: auto;
    font-family: var(--font-mono, 'JetBrains Mono', monospace);
    font-size: 11px;
    color: var(--text-dim);
    font-variant-numeric: tabular-nums;
  }

  @media (max-width: 920px) {
    .grid { grid-template-columns: 1fr; }
    .panel { min-height: 0; }
    .cta_note { width: 100%; margin-left: 0; }
  }
|}]

type blueprint = {
  eyebrow : string;
  title : string;
  tail : string;
  signal : string;
  source : string;
  cadence : string;
  vow : string;
  measure : string;
  next_step : string;
  endpoint : string;
}

let blueprint_of_route : Route.t -> blueprint = function
  | Observatory ->
    {
      eyebrow = "runtime · observatory";
      title = "observatory";
      tail = "· sightline";
      signal = "keeper spans · event loss · pressure drift";
      source = "trace store · metrics · runtime health";
      cadence = "live when spans land";
      vow =
        "A single sightline for runtime pressure, missing telemetry, and keeper \
         stall signatures.";
      measure = "Dropped spans, stale heartbeat windows, and blocked capability claims.";
      next_step = "Bind span summaries to the pressure and journal lanes.";
      endpoint = "/api/v1/dashboard/*";
    }
  | Intervene ->
    {
      eyebrow = "runtime · intervene";
      title = "intervene";
      tail = "· override";
      signal = "pause · resume · nudge · handoff";
      source = "operator control · keeper runtime";
      cadence = "manual gate";
      vow =
        "Operator action should carry intent, target, and evidence before it \
         touches a live keeper.";
      measure = "Pending approvals, active holds, and restart budget.";
      next_step = "Wire guarded actions after the audit trail is visible.";
      endpoint = "/api/v1/operator/*";
    }
  | Tools ->
    {
      eyebrow = "lab · tools";
      title = "tools";
      tail = "· capability";
      signal = "public · keeper · privileged";
      source = "capability registry · OAS catalog";
      cadence = "on schema drift";
      vow =
        "Every callable surface should reveal its audience, risk class, and \
         evidence path.";
      measure = "Tool count, hidden capability claims, and schema budget pressure.";
      next_step = "Project capability groups into a compact registry table.";
      endpoint = "/api/v1/tools/list";
    }
  | Sessions ->
    {
      eyebrow = "lab · sessions";
      title = "sessions";
      tail = "· memory";
      signal = "handoff · checkpoint · replay";
      source = "trace fragments · memory bank · keeper checkpoints";
      cadence = "after each handoff";
      vow =
        "A session should tell where it began, what it changed, and what remains \
         risky.";
      measure = "Open handoffs, stale checkpoints, and replay gaps.";
      next_step = "Join checkpoint summaries with recent handoff notes.";
      endpoint = "/api/v1/keepers/*";
    }
  | Social_board ->
    {
      eyebrow = "lab · hearth";
      title = "social board";
      tail = "· speech";
      signal = "claim · block · ask · note";
      source = "board posts · keeper social model";
      cadence = "live stream";
      vow =
        "Agent speech should surface urgency, blockers, and accountable claims \
         without burying the operator.";
      measure = "Unread board posts, unresolved asks, and stale blocker claims.";
      next_step = "Group board traffic by speech act and current owner.";
      endpoint = "/api/v1/board/*";
    }
  | route ->
    {
      eyebrow = "runtime · route";
      title = Route.label route;
      tail = "· staged";
      signal = "pending";
      source = "dashboard shell";
      cadence = "on demand";
      vow = "The route is named, anchored, and ready for a data projection.";
      measure = "No route-specific signal yet.";
      next_step = "Choose the read model and collapse it into one operator view.";
      endpoint = Route.path route;
    }
;;

let panel ~title ~text ~code =
  Node.div
    ~attrs:[ Style.panel; Attr.role "listitem"; Attr.arialabel title ]
    [ Node.h4 ~attrs:[ Style.panel_title ] [ Node.text title ]
    ; Node.p ~attrs:[ Style.panel_text ] [ Node.text text ]
    ; Node.div ~attrs:[ Style.panel_code ] [ Node.text code ]
    ]
;;

let component ~(route : Route.t) (_graph @ local) =
  let bp = blueprint_of_route route in
  Bonsai.map (Bonsai.Expert.Var.value Overview_var.var) ~f:(fun shell ->
    Shell_view.view
      ~shell
      ~active:route
      [ Hero.view
          ~eyebrow:bp.eyebrow
          ~title:bp.title
          ~tail:(bp.tail, `Brass)
          ~sub:bp.vow
          ()
      ; Meta.strip
          ~label:"Route status"
          [ Meta.cell ~color:`Brass ~k:"signal" ~v:bp.signal ()
          ; Meta.cell ~k:"source" ~v:bp.source ()
          ; Meta.cell ~k:"cadence" ~v:bp.cadence ()
          ]
      ; Sec.view ~title:"operator contract" ~sub:"target · measure · next" ()
      ; Node.div
          ~attrs:[ Style.grid; Attr.role "list" ]
          [ panel ~title:"measure" ~text:bp.measure ~code:"what must stay visible"
          ; panel ~title:"next" ~text:bp.next_step ~code:bp.endpoint
          ; panel
              ~title:"fallback"
              ~text:"The journal remains the live runtime witness while this lane gathers signal."
              ~code:(Route.path Logs)
          ]
      ; Node.div
          ~attrs:[ Style.cta ]
          [ Node.a
              ~attrs:[ Attr.href (Route.path Logs); Style.btn; Style.btn_primary ]
              [ Node.text "journal" ]
          ; Node.a
              ~attrs:[ Attr.href "/dashboard/"; Style.btn ]
              [ Node.text "legacy" ]
          ; Node.span
              ~attrs:[ Style.cta_note ]
              [ Node.text (Route.path route) ]
          ]
      ])
;;
