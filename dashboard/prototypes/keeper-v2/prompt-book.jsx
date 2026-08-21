/* MASC v2 — 프롬프트북 surface.
   Renders the keeper system prompt as a stacked, Paper-styled manuscript.
   Flip keepers (← →) to watch the same book re-fill its {{blanks}} and the
   conditional chapters appear/disappear — the prompt 적층 made legible.

   Data: prompt-book-data.jsx (PB_CHAPTERS, pbFill, pbStackFor, pbBytes).
   Mounted by settings.jsx in the `prompts` section. */

const { useState: usePbState, useEffect: usePbEffect, useRef: usePbRef, useMemo: usePbMemo } = React;

// render a chapter body: {{tokens}} become inline editable "blank" chips,
// ``code`` and ## heads get light styling. Returns an array of React nodes.
function pbRenderBody(chapter, fill) {
  const nodes = [];
  const lines = chapter.body.split('\n');
  lines.forEach((line, li) => {
    // heading
    const head = line.match(/^(#{2,3})\s+(.*)$/);
    if (head) {
      nodes.push(React.createElement('div', { key: li, className: 'pb-h' + head[1].length }, pbInline(head[2], fill, li)));
      return;
    }
    if (line.trim() === '') { nodes.push(React.createElement('div', { key: li, className: 'pb-br' })); return; }
    nodes.push(React.createElement('div', { key: li, className: 'pb-line' }, pbInline(line, fill, li)));
  });
  return nodes;
}

// inline pass: split on {{var}} and `code`, return nodes
function pbInline(text, fill, li) {
  const out = [];
  // combined regex for {{var}} and `code`
  const re = /(\{\{[a-z_]+\}\}|`[^`]+`|«[^»]+»)/g;
  let last = 0, m, k = 0;
  while ((m = re.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index));
    const tok = m[0];
    if (tok.startsWith('{{')) {
      const name = tok.slice(2, -2);
      const val = fill[name];
      out.push(React.createElement('span', {
        key: `${li}-${k++}`,
        className: 'pb-blank' + (val == null ? ' empty' : ''),
        title: `{{${name}}} — ${val == null ? '이 keeper에선 비어 있음' : '치환됨'}`,
      }, val == null ? name : String(val)));
    } else if (tok.startsWith('`')) {
      out.push(React.createElement('code', { key: `${li}-${k++}`, className: 'pb-code' }, tok.slice(1, -1)));
    } else {
      // «guillemet» emphasis — a filled proper noun
      out.push(React.createElement('span', { key: `${li}-${k++}`, className: 'pb-name' }, tok.slice(1, -1)));
    }
    last = m.index + tok.length;
  }
  if (last < text.length) out.push(text.slice(last));
  return out;
}

// prompt body + 변수 계약의 revision (SHA256 의 mock — 결정론적 짧은 해시).
// 소스에서 override 는 이 revision 에 바인딩되어 저장되고, 드리프트 시 fail-closed 된다.
function pbRev(ch) {
  const s = (ch.body || '') + '|' + (ch.vars || []).join(',');
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 0x01000193) >>> 0; }
  return h.toString(16).padStart(8, '0');
}

function PbComposition({ stack, fill }) {
  const parts = stack.map(ch => ({ ch, bytes: pbBytes(ch, fill) }));
  const total = parts.reduce((s, p) => s + p.bytes, 0) || 1;
  return React.createElement('div', { className: 'pb-comp' },
    React.createElement('div', { className: 'pb-comp-bar' },
      parts.map(p => React.createElement('span', {
        key: p.ch.id,
        className: 'pb-comp-seg',
        style: { width: (p.bytes / total * 100) + '%', background: (PB_BLOCK_META[p.ch.id] || {}).color || 'var(--text-dim)' },
        title: `${(PB_BLOCK_META[p.ch.id] || {}).lbl || p.ch.id} · ${p.bytes}B`,
      }))),
    React.createElement('div', { className: 'pb-comp-total mono' }, `${(total / 1024).toFixed(1)} KB · ${stack.length}장`));
}

function PromptBook({ keepers }) {
  const roster = usePbMemo(() => (keepers || window.KEEPERS || []), [keepers]);
  const [idx, setIdx] = usePbState(0);
  const [openId, setOpenId] = usePbState(null); // expanded chapter
  const [view, setView] = usePbState('book'); // 'book' | 'catalog'
  const scrollRef = usePbRef(null);
  const keeper = roster[idx] || roster[0];

  const go = (d) => { setIdx(i => (i + d + roster.length) % roster.length); setOpenId(null); };

  usePbEffect(() => {
    const onKey = (e) => {
      if (e.target && /INPUT|TEXTAREA|SELECT/.test(e.target.tagName)) return;
      if (e.key === 'ArrowRight') { e.preventDefault(); go(1); }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); go(-1); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [roster.length]);

  usePbEffect(() => { if (scrollRef.current) scrollRef.current.scrollTop = 0; }, [idx]);

  if (!keeper) return null;
  const fill = pbFill(keeper);
  const stack = pbStackFor(keeper);
  const slotVar = `var(--kp${keeper.slot || 6})`;
  const rt = keeper.runtime && keeper.runtime !== '—' ? keeper.runtime : '미할당';

  return React.createElement('div', { className: 'pb-wrap', 'data-theme': 'paper' },
    // ── view toggle: the assembled book vs the full md library ──
    React.createElement('div', { className: 'pb-viewbar' },
      React.createElement('div', { className: 'pb-seg' },
        React.createElement('button', { className: 'pb-seg-btn' + (view === 'book' ? ' on' : ''), onClick: () => setView('book') }, `조립 · ${stack.length}장`),
        React.createElement('button', { className: 'pb-seg-btn' + (view === 'full' ? ' on' : ''), onClick: () => setView('full') }, '전체 텍스트'),
        React.createElement('button', { className: 'pb-seg-btn' + (view === 'map' ? ' on' : ''), onClick: () => setView('map') }, '치환 지도'),
        React.createElement('button', { className: 'pb-seg-btn' + (view === 'catalog' ? ' on' : ''), onClick: () => setView('catalog') }, '파일 전체')),
      React.createElement('div', { className: 'pb-viewbar-note' }, view === 'book'
        ? '파일 3장 + 이번 턴에 해당되는 절만 이어붙입니다'
        : view === 'full'
        ? `${stack.length}장을 이어붙인 실제 텍스트`
        : view === 'map'
        ? '런타임 절의 빈칸이 어디서 채워지는지 봅니다'
        : 'prompts/ · keepers/<name>/AGENT.md')),

    view === 'catalog' ? React.createElement(PbCatalog, null) :
    view === 'map' ? React.createElement(PbVarMap, { keeper, fill, slotVar, rt }) :
    view === 'full' ? React.createElement(PbFullText, { keeper, stack, fill, slotVar, rt }) :
    // ── keeper filmstrip nav ──
    React.createElement(React.Fragment, null,
    React.createElement('div', { className: 'pb-film' },
      React.createElement('button', { className: 'pb-flip', onClick: () => go(-1), 'aria-label': '이전 keeper' }, '◂'),
      React.createElement('div', { className: 'pb-film-track' },
        roster.map((k, i) => {
          const dist = Math.abs(i - idx);
          if (dist > 3) return null;
          return React.createElement('button', {
            key: k.id,
            className: 'pb-film-chip' + (i === idx ? ' on' : ''),
            style: { '--kc': `var(--kp${k.slot || 6})` },
            onClick: () => { setIdx(i); setOpenId(null); },
            title: k.id,
          },
            React.createElement('span', { className: 'pb-film-sigil mono' }, k.sigil || k.id.slice(0, 2).toUpperCase()),
            React.createElement('span', { className: 'pb-film-name' }, k.id));
        })),
      React.createElement('button', { className: 'pb-flip', onClick: () => go(1), 'aria-label': '다음 keeper' }, '▸')),

    // ── the book ──
    React.createElement('div', { className: 'pb-book', ref: scrollRef },
      React.createElement('div', { className: 'pb-frontis' },
        React.createElement('div', { className: 'pb-frontis-mark mono', style: { color: slotVar } }, keeper.sigil || 'KP'),
        React.createElement('div', { className: 'pb-frontis-t' },
          React.createElement('h1', null, '시스템 프롬프트'),
          React.createElement('div', { className: 'pb-frontis-sub' }, `«${keeper.id}»${keeper.kr ? ` · ${keeper.kr}` : ''} 에게 이번 턴 들어가는 프롬프트`),
          React.createElement('div', { className: 'pb-frontis-meta mono' }, `${stack.length}장 · ${keeper.phase} · ${rt}`)),
      ),
      React.createElement(PbComposition, { stack, fill }),
      React.createElement('div', { className: 'pb-envelope' },
        React.createElement('b', null, '수정한 프롬프트'),
        ' — 대시보드에서 고친 프롬프트는 그때의 본문 판(rev)에 묶여 저장됩니다. 원본 파일이 바뀌어 판이 어긋나면 수정분을 버리고 파일 내용으로 돌아갑니다. keeper 프롬프트 자체는 keepers/<name>/AGENT.md 한 장이 저작 지점입니다.'),

      // chapters, in assembly order, with a running numeral
      React.createElement('div', { className: 'pb-chapters' },
        stack.map((ch, ci) => {
          const meta = PB_BLOCK_META[ch.id] || { lbl: ch.id, color: 'var(--text-dim)' };
          const open = openId === ch.id;
          const bytes = pbBytes(ch, fill);
          return React.createElement('section', { key: ch.id, className: 'pb-ch' + (open ? ' open' : ''), 'data-block': ch.id },
            React.createElement('button', { className: 'pb-ch-head', onClick: () => setOpenId(open ? null : ch.id) },
              React.createElement('span', { className: 'pb-ch-num mono' }, String(ci + 1).padStart(2, '0')),
              React.createElement('span', { className: 'pb-ch-swatch', style: { background: meta.color } }),
              React.createElement('span', { className: 'pb-ch-title' }, meta.lbl),
              !ch.always && React.createElement('span', { className: 'pb-ch-cond' }, '조건부'),
              ch.authored && React.createElement('span', { className: 'pb-ch-cond' }, '파일'),
              React.createElement('span', { className: 'pb-ch-src mono' }, ch.src),
              React.createElement('span', { className: 'pb-ch-rev mono', title: '이 블록 본문의 판 번호 — 수정분은 이 판에 묶입니다' }, 'rev ' + pbRev(ch)),
              React.createElement('span', { className: 'pb-ch-bytes mono' }, `${bytes}B`),
              React.createElement('span', { className: 'pb-ch-caret' }, open ? '▾' : '▸')),
            React.createElement('div', { className: 'pb-ch-gloss' }, ch.gloss),
            open && React.createElement('div', { className: 'pb-ch-body' }, pbRenderBody(ch, fill)),
            open && ch.vars.length > 0 && React.createElement('div', { className: 'pb-ch-vars' },
              React.createElement('span', { className: 'pb-ch-vars-k' }, '빈칸'),
              ch.vars.map(v => React.createElement('span', {
                key: v, className: 'pb-var-chip mono' + (fill[v] == null ? ' empty' : ''),
              }, v))),
            open && ch.composed && ch.composed.length > 0 && React.createElement('div', { className: 'pb-ch-vars' },
              React.createElement('span', { className: 'pb-ch-vars-k' }, '합쳐진 파일'),
              ch.composed.map(f => React.createElement('span', { key: f, className: 'pb-src-chip mono' }, f))));
        })),

      React.createElement('div', { className: 'pb-colophon' },
        React.createElement('span', null, '앞 3장은 파일 · 뒤는 런타임이 이번 턴에 붙인 절'),
        React.createElement('span', { className: 'pb-colophon-note' }, '← → 로 keeper 넘기기')))));
}

// ── the full md library, grouped by family — answers "왜 9개뽐임?" ──
function PbCatalog() {
  const cat = window.PB_CATALOG || [];
  return React.createElement('div', { className: 'pb-book pb-catalog', ref: null },
    React.createElement('div', { className: 'pb-cat-intro' },
      React.createElement('h1', null, '프롬프트 파일 전체'),
      React.createElement('div', { className: 'pb-frontis-sub' }, '사람이 쓰는 파일은 무대 1장 + keeper 당 1장입니다. 나머지는 MASC 가 관리합니다.')),
    cat.map(g => React.createElement('section', { key: g.family, className: 'pb-cat-fam' + (g.feedsTurn ? ' feeds' : '') },
      React.createElement('div', { className: 'pb-cat-fam-head' },
        React.createElement('span', { className: 'pb-cat-dot' }),
        React.createElement('span', { className: 'pb-cat-fam-name' }, g.family),
        React.createElement('span', { className: 'pb-cat-fam-count mono' }, `${g.files.length}`),
        g.feedsTurn
          ? React.createElement('span', { className: 'pb-cat-tag feeds' }, 'keeper 턴')
          : React.createElement('span', { className: 'pb-cat-tag' }, '내부 에이전트')),
      React.createElement('div', { className: 'pb-cat-fam-note' }, g.note),
      React.createElement('div', { className: 'pb-cat-files' },
        g.files.map(f => React.createElement('span', { key: f, className: 'pb-src-chip mono' }, f))))));
}

// ── Full Text: the whole assembled system prompt as one flow, with a source
//    gutter naming where each segment comes from (assembly order). ──
function pbSubst(text, fill) {
  let t = text;
  Object.keys(fill).forEach(k => { t = t.split('{{' + k + '}}').join(fill[k] == null ? '' : String(fill[k])); });
  return t;
}
function PbFullText({ keeper, stack, fill, slotVar, rt }) {
  const total = stack.reduce((s, ch) => s + pbBytes(ch, fill), 0);
  const [copied, setCopied] = usePbState(false);
  // the literal assembled string, exactly as injected — blocks joined by a blank line.
  const plain = usePbMemo(
    () => stack.map(ch => pbSubst(ch.body, fill).trim()).join('\n\n'),
    [stack, fill]
  );
  const lineCount = plain.split('\n').length;
  const doCopy = () => {
    try { navigator.clipboard && navigator.clipboard.writeText(plain); } catch (e) {}
    setCopied(true); setTimeout(() => setCopied(false), 1400);
  };
  return React.createElement('div', { className: 'pb-book pb-full' },
    React.createElement('div', { className: 'pb-full-head' },
      React.createElement('div', { className: 'pb-full-head-t' },
        React.createElement('h1', null, '전체 텍스트'),
        React.createElement('div', { className: 'pb-full-head-meta mono' },
          `«${keeper.id}» · ${(total / 1024).toFixed(1)} KB · ${lineCount}줄 · ${stack.length}장`)),
      React.createElement('button', { className: 'pb-copy-btn' + (copied ? ' done' : ''), onClick: doCopy },
        copied ? '복사됨' : '전체 복사')),
    // one continuous document — the blocks concatenated as they are injected.
    React.createElement('pre', { className: 'pb-full-doc' },
      stack.map((ch, ci) => {
        const meta = PB_BLOCK_META[ch.id] || { lbl: ch.id, color: 'var(--text-dim)' };
        return React.createElement(React.Fragment, { key: ch.id },
          ci > 0 ? '\n\n' : null,
          React.createElement('span', { className: 'pb-doc-marker', style: { '--mk': meta.color } },
            `── ${meta.lbl}${ch.always ? '' : ' · 조건부'} ──`),
          '\n',
          pbSubst(ch.body, fill).trim());
      })),
    React.createElement('div', { className: 'pb-colophon' },
      React.createElement('span', null, '회색 줄은 경계 표시입니다 · 복사에는 안 들어갑니다'),
      React.createElement('span', { className: 'pb-colophon-note' }, '← → 로 keeper 넘기기')));
}

// ── 치환 지도 (Substitution map): every {{template_variable}} grouped by the
//    source it resolves FROM (turn / checkpoint / config / memory / gate),
//    with this keeper's current filled value. Uses PB_VAR_SRC + PB_VAR_SRC_META.
const PB_SRC_ORDER = ['turn', 'checkpoint', 'memory', 'gate', 'workspace'];
function pbUsedIn(varName) {
  return (window.PB_CHAPTERS || []).filter(ch => ch.body.indexOf('{{' + varName + '}}') !== -1);
}
function PbVarMap({ keeper, fill, slotVar, rt }) {
  const srcMeta = window.PB_VAR_SRC_META || {};
  const srcOf = window.PB_VAR_SRC || {};
  const groups = PB_SRC_ORDER.map(src => ({
    src,
    meta: srcMeta[src] || { lbl: src, color: 'var(--ink-4)' },
    vars: Object.keys(srcOf).filter(v => srcOf[v] === src),
  })).filter(g => g.vars.length > 0);

  const allVars = Object.keys(srcOf);
  const filledCount = allVars.filter(v => fill[v] != null).length;

  return React.createElement('div', { className: 'pb-book pb-map' },
    React.createElement('div', { className: 'pb-frontis' },
      React.createElement('div', { className: 'pb-frontis-mark mono', style: { color: slotVar } }, keeper.sigil || 'KP'),
      React.createElement('div', { className: 'pb-frontis-t' },
        React.createElement('h1', null, '\uce58\ud658 \uc9c0\ub3c4'),
        React.createElement('div', { className: 'pb-frontis-sub' }, `«${keeper.id}» 의 이번 턴 — 런타임 절의 빈칸`),
        React.createElement('div', { className: 'pb-frontis-meta mono' }, `${filledCount}/${allVars.length} \uce58\ud658\ub428 \u00b7 ${keeper.phase} \u00b7 ${rt}`))),

    // source legend
    React.createElement('div', { className: 'pb-map-legend' },
      groups.map(g => React.createElement('span', { key: g.src, className: 'pb-map-legend-item' },
        React.createElement('span', { className: 'pb-map-legend-swatch', style: { background: g.meta.color } }),
        React.createElement('span', { className: 'pb-map-legend-lbl' }, g.meta.lbl),
        React.createElement('span', { className: 'pb-map-legend-src mono' }, g.src)))),

    // grouped rows
    groups.map(g => React.createElement('section', { key: g.src, className: 'pb-map-grp' },
      React.createElement('div', { className: 'pb-map-grp-head' },
        React.createElement('span', { className: 'pb-map-grp-swatch', style: { background: g.meta.color } }),
        React.createElement('span', { className: 'pb-map-grp-lbl' }, g.meta.lbl),
        React.createElement('span', { className: 'pb-map-grp-src mono' }, g.src),
        React.createElement('span', { className: 'pb-map-grp-count mono' }, `${g.vars.filter(v => fill[v] != null).length}/${g.vars.length}`)),
      g.vars.map(v => {
        const val = fill[v];
        const empty = val == null;
        const used = pbUsedIn(v);
        return React.createElement('div', { key: v, className: 'pb-map-row' + (empty ? ' empty' : ''), style: { '--src': g.meta.color } },
          React.createElement('div', { className: 'pb-map-var' },
            React.createElement('span', { className: 'pb-map-var-name mono' }, `{{${v}}}`),
            React.createElement('div', { className: 'pb-map-used' },
              used.length === 0
                ? React.createElement('span', { className: 'pb-map-used-none' }, '\ubbf8\uc0ac\uc6a9')
                : used.map(ch => React.createElement('span', {
                    key: ch.id, className: 'pb-map-used-chip',
                    style: { '--bc': (window.PB_BLOCK_META[ch.id] || {}).color || 'var(--ink-4)' },
                  }, (window.PB_BLOCK_META[ch.id] || {}).lbl || ch.id)))),
          React.createElement('div', { className: 'pb-map-arrow' }, '\u2192'),
          empty
            ? React.createElement('div', { className: 'pb-map-val empty' }, '이번 턴에는 값이 없어 비어 있습니다')
            : React.createElement('div', { className: 'pb-map-val mono' }, String(val)));
      }))),

    React.createElement('div', { className: 'pb-colophon' },
      React.createElement('span', null, '출처 · turn=이번 턴 · checkpoint=디스크 · memory=memory-os · gate=커넥터 · workspace=대화'),
      React.createElement('span', { className: 'pb-colophon-note' }, '\u2190 \u2192 \ub85c keeper \ub118\uae30\uba74 \uac12\uc774 \ub2e4\uc2dc \ucc44\uc6cc\uc9c4\ub2e4')));
}

window.PromptBook = PromptBook;
