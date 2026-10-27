let runtime = {js|function mascPointerFeedback(args) {
  const key = Symbol.for('masc.browser.pointer.feedback.v1');
  let state = window[key];
  if (!state || state.document !== document) {
    // A receipt can arrive after navigation. Only a new operation installs
    // feedback in this document; the old document's finish owns no badge here.
    if (args.phase !== 'working') return null;
    const host = document.createElement('div');
    host.setAttribute('data-masc-browser-overlay', '');
    host.setAttribute('aria-hidden', 'true');
    host.inert = true;
    host.style.cssText = 'all:initial!important;position:fixed!important;inset:0!important;pointer-events:none!important;z-index:2147483647!important;';
    const shadow = host.attachShadow({mode:'closed'});
    const style = document.createElement('style');
    style.textContent = `:host,*{pointer-events:none!important;box-sizing:border-box}
      .badge{position:fixed;right:14px;top:14px;max-width:70vw;padding:8px 12px;
        border:1px solid #58d3c9;border-radius:12px;background:#10292ff2;color:#e9fffc;
        font:13px/1.4 system-ui,sans-serif;box-shadow:0 3px 18px #0005;white-space:pre-wrap}
      .pointer{position:fixed;width:20px;height:20px;transform:translate(-50%,-50%);
        border:2px solid #36e1ce;border-radius:50%;background:#36e1ce26;display:none}
      .pointer::after{content:'';position:absolute;left:7px;top:7px;width:2px;height:2px;background:#fff}
      .coordinates{position:absolute;left:18px;top:18px;padding:2px 5px;background:#10292fee;
        border-radius:4px;color:#e9fffc;font:11px/1.4 ui-monospace,monospace;white-space:nowrap}`;
    const badge = document.createElement('div'); badge.className = 'badge';
    const pointer = document.createElement('div'); pointer.className = 'pointer';
    const coordinates = document.createElement('span'); coordinates.className = 'coordinates';
    pointer.append(coordinates); shadow.append(style, badge, pointer);
    document.documentElement.append(host);
    state = {document, host, badge, marker:pointer, coordinates, pointer:null,
      requestId:null, actor:null, action:null, phase:'idle'};
    window[key] = state;
    const observed = event => {
      if (!event.isTrusted || !Number.isFinite(event.clientX) || !Number.isFinite(event.clientY)) return;
      state.pointer = {x:event.clientX,y:event.clientY,buttons:event.buttons,
        source:event.type};
      state.marker.style.left = event.clientX + 'px'; state.marker.style.top = event.clientY + 'px';
      state.marker.style.display = 'block';
      state.coordinates.textContent = Math.round(event.clientX) + ', ' + Math.round(event.clientY);
    };
    for (const type of ['pointermove','pointerdown','pointerup','wheel','dragover','drop'])
      window.addEventListener(type, observed, {capture:true,passive:true});
    window.addEventListener('pointerout', event => {
      if (event.isTrusted && event.relatedTarget === null) {
        state.pointer = null; state.marker.style.display = 'none';
      }
    }, {capture:true,passive:true});
  }
  // A late finish belongs only to its own operation. It must not reattach or
  // rewrite the feedback of a newer request in the same document.
  if (args.phase !== 'working' && args.requestId !== state.requestId) return null;
  if (!state.host.isConnected) document.documentElement.append(state.host);
  if (args.phase === 'working') {
    state.requestId = args.requestId; state.actor = args.actor; state.action = args.action;
    state.phase = 'working';
  } else if (args.requestId === state.requestId) state.phase = args.phase;
  const phases = {working:'Working',finished:'Finished',refused:'Not performed',unknown:'Outcome unknown'};
  state.badge.textContent = 'MASC · ' + (state.actor || 'agent') + '\n'
    + (phases[state.phase] || state.phase) + ' · ' + state.action;
  return {actor:state.actor,action:state.action,phase:state.phase,pointer:state.pointer};
}|js}

let begin_script = runtime ^ "\nreturn mascPointerFeedback({...arguments[0],phase:'working'});"
let finish_script = runtime ^ "\nreturn mascPointerFeedback(arguments[0]);"

type outcome = Finished | Refused | Unknown
let outcome_to_json = function Finished -> `String "finished" | Refused -> `String "refused" | Unknown -> `String "unknown"
