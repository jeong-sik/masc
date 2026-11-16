import dagre from '@dagrejs/dagre';

function escapeXml(value) {
  return String(value ?? '').replace(/[&<>"']/g, ch => ({
    '&': '&amp;',
    '<': '&lt;',
    '>': '&gt;',
    '"': '&quot;',
    "'": '&apos;',
  })[ch]);
}

function parseHex(hex) {
  if (typeof hex !== 'string' || !/^#[\da-f]{6}$/i.test(hex)) return null;
  return [1, 3, 5].map(i => Number.parseInt(hex.slice(i, i + 2), 16));
}

function mixHex(bgHex, fgHex, weight) {
  const bg = parseHex(bgHex);
  const fg = parseHex(fgHex);
  if (!bg || !fg) return bgHex;
  return '#' + fg.map((ch, i) =>
    Math.round(bg[i] + (ch - bg[i]) * weight).toString(16).padStart(2, '0')).join('');
}

function luminance(hex) {
  const channels = parseHex(hex);
  if (!channels) return 0;
  const linear = channels.map(ch => {
    const s = ch / 255;
    return s <= 0.04045 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  });
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}

function contrast(a, b) {
  const la = luminance(a);
  const lb = luminance(b);
  return (Math.max(la, lb) + 0.05) / (Math.min(la, lb) + 0.05);
}

function ensureContrast(colorHex, surfaceHex, targetHex, minRatio) {
  let candidate = parseHex(colorHex) ? colorHex : targetHex;
  if (contrast(candidate, surfaceHex) >= minRatio) return candidate;
  for (let step = 1; step <= 10; step++) {
    const mixed = mixHex(candidate, targetHex, step / 10);
    if (contrast(mixed, surfaceHex) >= minRatio) return mixed;
  }
  return targetHex;
}

function isWideCodePoint(cp) {
  return (
    (cp >= 0x1100 && cp <= 0x115f) ||
    cp === 0x2329 || cp === 0x232a ||
    (cp >= 0x2e80 && cp <= 0x303e) ||
    (cp >= 0x3040 && cp <= 0xa4cf) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xfe10 && cp <= 0xfe19) ||
    (cp >= 0xfe30 && cp <= 0xfe6f) ||
    (cp >= 0xff01 && cp <= 0xff60) ||
    (cp >= 0xffe0 && cp <= 0xffe6) ||
    (cp >= 0x1f300 && cp <= 0x1faff) ||
    (cp >= 0x20000 && cp <= 0x3fffd)
  );
}

export function estimateTextWidth(text, fontSize, isMono = false) {
  let width = 0;
  for (const ch of String(text ?? '')) {
    const cp = ch.codePointAt(0);
    if (isWideCodePoint(cp)) {
      width += fontSize * 1.02;
    } else if (isMono) {
      width += fontSize * 0.62;
    } else if (ch === 'i' || ch === 'l' || ch === 'I' || ch === '!' || ch === '.' || ch === ',' || ch === ':' || ch === ';' || ch === ' ') {
      width += fontSize * 0.38;
    } else if (ch === 'M' || ch === 'W' || ch === '@' || ch === '%' || ch === '#') {
      width += fontSize * 0.94;
    } else if (cp >= 0x41 && cp <= 0x5a) {
      width += fontSize * 0.74;
    } else {
      width += fontSize * 0.60;
    }
  }
  return width * 1.06;
}

function buildTheme(colors, palette) {
  const fg = parseHex(colors?.foreground) ? colors.foreground : '#1f2937';
  const bg = parseHex(colors?.background) ? colors.background : '#f8fafc';
  const isDark = luminance(bg) < 0.25;

  const pageBg = bg;
  const headerBg = mixHex(bg, fg, isDark ? 0.06 : 0.04);
  const cardBg = mixHex(bg, fg, isDark ? 0.05 : 0.025);
  const cardHeaderBg = mixHex(bg, fg, isDark ? 0.10 : 0.06);
  const eventBg = mixHex(bg, fg, isDark ? 0.08 : 0.05);
  const canvasBg = mixHex(bg, fg, isDark ? 0.02 : 0.015);
  const borderSubtle = ensureContrast(mixHex(bg, fg, 0.24), cardBg, fg, 1.8);
  const borderStrong = ensureContrast(mixHex(bg, fg, 0.45), cardBg, fg, 3.0);
  const ink = ensureContrast(fg, cardBg, fg, 4.5);
  const inkMuted = ensureContrast(mixHex(bg, fg, 0.66), cardBg, fg, 4.5);

  const defaults = isDark
    ? { ok: '#4ade80', info: '#60a5fa', warn: '#fbbf24', bad: '#f87171', cyan: '#22d3ee' }
    : { ok: '#15803d', info: '#1d4ed8', warn: '#b45309', bad: '#b91c1c', cyan: '#0e7490' };

  const resolveTone = key => {
    const raw = palette?.[key] ?? defaults[key];
    const stroke = ensureContrast(raw, cardBg, fg, 3.2);
    const text = ensureContrast(raw, cardBg, fg, 4.5);
    const pillBg = mixHex(cardBg, stroke, isDark ? 0.18 : 0.12);
    const pillText = ensureContrast(stroke, pillBg, fg, 4.5);
    return { stroke, text, pillBg, pillText };
  };

  return {
    isDark,
    pageBg,
    headerBg,
    canvasBg,
    cardBg,
    cardHeaderBg,
    eventBg,
    borderSubtle,
    borderStrong,
    ink,
    inkMuted,
    tones: {
      ok: resolveTone('ok'),
      info: resolveTone('info'),
      warn: resolveTone('warn'),
      bad: resolveTone('bad'),
      cyan: resolveTone('cyan'),
    },
  };
}

function toneForFactStatus(theme, status) {
  switch (status) {
    case 'retained': return theme.tones.ok;
    case 'unconfirmed': return theme.tones.warn;
    case 'consumed':
    default: return theme.tones.cyan;
  }
}

function toneForEvent(theme, toneName) {
  switch (toneName) {
    case 'ok': return theme.tones.ok;
    case 'warn': return theme.tones.warn;
    case 'bad': return theme.tones.bad;
    case 'info':
    default: return theme.tones.info;
  }
}

function bezierPath(points) {
  if (!points || points.length === 0) return '';
  if (points.length === 1) return `M ${points[0].x.toFixed(1)} ${points[0].y.toFixed(1)}`;
  if (points.length === 2) {
    const [p0, p1] = points;
    const midY = (p0.y + p1.y) / 2;
    return `M ${p0.x.toFixed(1)} ${p0.y.toFixed(1)} C ${p0.x.toFixed(1)} ${midY.toFixed(1)} ${p1.x.toFixed(1)} ${midY.toFixed(1)} ${p1.x.toFixed(1)} ${p1.y.toFixed(1)}`;
  }
  let d = `M ${points[0].x.toFixed(1)} ${points[0].y.toFixed(1)}`;
  for (let i = 1; i < points.length - 1; i++) {
    const curr = points[i];
    const next = points[i + 1];
    const midX = (curr.x + next.x) / 2;
    const midY = (curr.y + next.y) / 2;
    d += ` Q ${curr.x.toFixed(1)} ${curr.y.toFixed(1)} ${midX.toFixed(1)} ${midY.toFixed(1)}`;
  }
  const last = points[points.length - 1];
  d += ` L ${last.x.toFixed(1)} ${last.y.toFixed(1)}`;
  return d;
}

function validateGraphPayload(source) {
  let payload;
  try {
    payload = JSON.parse(source);
  } catch (error) {
    throw new TypeError(`Invalid graph JSON: ${error.message}`);
  }
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new TypeError('Graph payload must be a JSON object');
  }
  if (!Array.isArray(payload.nodes) || !Array.isArray(payload.edges)) {
    throw new TypeError('Graph payload requires nodes and edges arrays');
  }
  return payload;
}

export function renderGraphSvg(source, { colors } = {}) {
  const payload = validateGraphPayload(source);
  const theme = buildTheme(colors, payload.palette);

  const bodyFontSize = 14;
  const bodyLineHeight = 21;
  const monoFontSize = 11.5;
  const reasonFontSize = 12.5;
  const reasonLineHeight = 19;

  const nodeSpecs = new Map();
  const g = new dagre.graphlib.Graph({ multigraph: true });
  g.setGraph({
    rankdir: 'TB',
    nodesep: 38,
    ranksep: 48,
    edgesep: 20,
    marginx: 28,
    marginy: 26,
    acyclicer: 'greedy',
    ranker: 'network-simplex',
  });
  g.setDefaultEdgeLabel(() => ({}));

  for (const node of payload.nodes) {
    if (!node || typeof node.id !== 'string' || node.id === '') {
      throw new TypeError('Every graph node requires a non-empty string id');
    }
    if (node.kind === 'fact') {
      const lines = Array.isArray(node.lines) && node.lines.length > 0 ? node.lines.map(String) : [''];
      const tagText = String(node.tag ?? '');
      const memIdText = String(node.memoryId ?? '');
      const badgeText = String(node.badge ?? '');
      const headerWidth =
        estimateTextWidth(tagText, monoFontSize, true) + 22 +
        estimateTextWidth(memIdText, monoFontSize, true) + 22 +
        estimateTextWidth(badgeText, monoFontSize, false) + 26 + 44;
      const bodyWidth = Math.max(0, ...lines.map(line => estimateTextWidth(line, bodyFontSize, false))) + 46;
      const width = Math.max(320, Math.min(760, Math.ceil(Math.max(headerWidth, bodyWidth))));
      const headerHeight = 36;
      const height = headerHeight + 14 + lines.length * bodyLineHeight + 14;
      const spec = { ...node, lines, width, height, headerHeight };
      nodeSpecs.set(node.id, spec);
      g.setNode(node.id, { width, height });
    } else if (node.kind === 'event') {
      const tagText = String(node.tag ?? '');
      const countsText = String(node.counts ?? '');
      const selectedLabel = node.selected ? String(node.selectedLabel ?? '★') : '';
      const metaText = [node.revision, node.timestamp].filter(Boolean).join(' · ');
      const reasonLines = Array.isArray(node.reasonLines) ? node.reasonLines.map(String).filter(Boolean) : [];
      const topRowWidth =
        estimateTextWidth(tagText, 13, false) + 26 +
        estimateTextWidth(countsText, monoFontSize, true) + 22 +
        (selectedLabel ? estimateTextWidth(selectedLabel, monoFontSize, false) + 26 : 0) + 46;
      const metaWidth = estimateTextWidth(metaText, monoFontSize, true) + 40;
      const reasonWidth = reasonLines.length > 0
        ? Math.max(...reasonLines.map(line => estimateTextWidth(line, reasonFontSize, false))) + 48
        : 0;
      const width = Math.max(280, Math.min(720, Math.ceil(Math.max(topRowWidth, metaWidth, reasonWidth))));
      const baseHeight = 72;
      const reasonBoxHeight = reasonLines.length > 0 ? reasonLines.length * reasonLineHeight + 22 : 0;
      const height = baseHeight + (reasonBoxHeight > 0 ? reasonBoxHeight + 8 : 0);
      const spec = { ...node, metaText, reasonLines, width, height, baseHeight, reasonBoxHeight };
      nodeSpecs.set(node.id, spec);
      g.setNode(node.id, { width, height });
    } else {
      throw new TypeError(`Unsupported graph node kind: ${String(node.kind)}`);
    }
  }

  const edgeSpecs = [];
  payload.edges.forEach((edge, index) => {
    if (!edge || !nodeSpecs.has(edge.from) || !nodeSpecs.has(edge.to)) return;
    const name = `e${index}`;
    g.setEdge(edge.from, edge.to, { index }, name);
    edgeSpecs.push({ ...edge, name });
  });

  if (payload.nodes.length > 0) {
    dagre.layout(g);
  }

  const graphMeta = g.graph();
  const graphWidth = Math.max(640, Math.ceil(graphMeta.width ?? 640));
  const graphHeight = Math.max(160, Math.ceil(graphMeta.height ?? 160));

  const titleText = String(payload.title ?? 'Memory lineage');
  const subtitleText = String(payload.subtitle ?? '');
  const notes = Array.isArray(payload.notes) ? payload.notes.map(String).filter(Boolean) : [];
  const legend = payload.legend ?? {};

  const legendItems = [
    { label: legend.retained ?? 'Retained', tone: theme.tones.ok, dashed: false },
    { label: legend.consumed ?? 'Prior', tone: theme.tones.cyan, dashed: false },
    { label: legend.unconfirmed ?? 'Unconfirmed', tone: theme.tones.warn, dashed: true },
  ];
  const legendWidth = legendItems.reduce((acc, item) => acc + estimateTextWidth(item.label, 11.5, false) + 34, 0);
  const titleWidth = Math.max(
    estimateTextWidth(titleText, 20, false),
    estimateTextWidth(subtitleText, 12.5, false),
  ) + 56;

  const minBannerWidth = Math.max(760, Math.ceil(titleWidth + legendWidth + 40));
  const noteMaxWidth = notes.length > 0
    ? Math.ceil(Math.max(...notes.map(n => estimateTextWidth(n, 12.5, false))) + 84)
    : 0;

  const canvasWidth = Math.max(graphWidth, minBannerWidth, Math.min(1200, noteMaxWidth));
  const headerHeight = 76;
  const notePadY = 10;
  const noteLineHeight = 19;
  const notesHeight = notes.length > 0 ? notes.length * noteLineHeight + notePadY * 2 + 12 : 0;
  const footerHeight = 42;

  const totalWidth = canvasWidth + 32;
  const totalHeight = headerHeight + notesHeight + graphHeight + footerHeight + 24;
  const graphOffsetX = 16 + Math.max(0, (canvasWidth - graphWidth) / 2);
  const graphOffsetY = 12 + headerHeight + notesHeight;

  const out = [];
  const push = line => out.push(line);

  push(`<svg xmlns="http://www.w3.org/2000/svg" width="${totalWidth}" height="${totalHeight}" viewBox="0 0 ${totalWidth} ${totalHeight}">`);
  push(`<title>${escapeXml(titleText)}</title>`);
  push(`<defs>`);
  const markers = [
    ['arrow-input', theme.borderStrong],
    ['arrow-output', theme.tones.info.stroke],
    ['arrow-selected', theme.tones.cyan.stroke],
    ['arrow-warn', theme.tones.warn.stroke],
  ];
  for (const [id, color] of markers) {
    push(`<marker id="${id}" markerWidth="9" markerHeight="9" refX="7.5" refY="4.5" orient="auto" markerUnits="userSpaceOnUse"><path d="M1 1.5 L8 4.5 L1 7.5 Z" fill="${color}"/></marker>`);
  }
  push(`</defs>`);

  // Page background
  push(`<rect width="${totalWidth}" height="${totalHeight}" rx="18" fill="${theme.pageBg}"/>`);

  // Header banner
  push(`<rect x="16" y="12" width="${canvasWidth}" height="${headerHeight}" rx="14" fill="${theme.headerBg}" stroke="${theme.borderSubtle}" stroke-width="1.2"/>`);
  push(`<text x="36" y="42" font-family="sans-serif" font-size="20" font-weight="700" fill="${theme.ink}">${escapeXml(titleText)}</text>`);
  if (subtitleText) {
    push(`<text x="36" y="68" font-family="sans-serif" font-size="12.5" fill="${theme.inkMuted}">${escapeXml(subtitleText)}</text>`);
  }

  // Right-aligned legend pills in header
  let lx = 16 + canvasWidth - 18;
  for (let i = legendItems.length - 1; i >= 0; i--) {
    const item = legendItems[i];
    const pw = Math.ceil(estimateTextWidth(item.label, 11.5, false) + 26);
    lx -= pw;
    const dashAttr = item.dashed ? ' stroke-dasharray="3 2"' : '';
    push(`<rect x="${lx}" y="31" width="${pw}" height="24" rx="12" fill="${item.tone.pillBg}" stroke="${item.tone.stroke}" stroke-width="1.2"${dashAttr}/>`);
    push(`<circle cx="${lx + 11}" cy="43" r="3.5" fill="${item.tone.stroke}"/>`);
    push(`<text x="${lx + 19}" y="47" font-family="sans-serif" font-size="11.5" font-weight="600" fill="${item.tone.pillText}">${escapeXml(item.label)}</text>`);
    lx -= 8;
  }

  // Optional full-text warning/observation notes strip
  if (notes.length > 0) {
    const ny = 12 + headerHeight + 10;
    const nh = notesHeight - 12;
    const warn = theme.tones.warn;
    push(`<rect x="16" y="${ny}" width="${canvasWidth}" height="${nh}" rx="10" fill="${warn.pillBg}" stroke="${warn.stroke}" stroke-width="1.2" stroke-dasharray="5 3"/>`);
    notes.forEach((note, idx) => {
      const ty = ny + notePadY + 14 + idx * noteLineHeight;
      push(`<text x="34" y="${ty}" font-family="sans-serif" font-size="12.5" font-weight="500" fill="${warn.pillText}">! ${escapeXml(note)}</text>`);
    });
  }

  // Graph container background
  push(`<rect x="16" y="${graphOffsetY}" width="${canvasWidth}" height="${graphHeight}" rx="14" fill="${theme.canvasBg}" stroke="${theme.borderSubtle}" stroke-width="1"/>`);

  // Graph body
  push(`<g transform="translate(${graphOffsetX.toFixed(1)}, ${graphOffsetY.toFixed(1)})">`);

  // Render edges behind nodes
  for (const spec of edgeSpecs) {
    const edgeData = g.edge(spec.from, spec.to, spec.name);
    if (!edgeData || !edgeData.points || edgeData.points.length < 2) continue;
    const fromSpec = nodeSpecs.get(spec.from);
    const toSpec = nodeSpecs.get(spec.to);
    const touchesSelected = Boolean(fromSpec?.selected || toSpec?.selected);
    let stroke = theme.borderStrong;
    let marker = 'arrow-input';
    let width = touchesSelected ? 2.2 : 1.6;
    let dash = '';
    if (spec.dashed || spec.role === 'unconfirmed') {
      stroke = theme.tones.warn.stroke;
      marker = 'arrow-warn';
      width = touchesSelected ? 2.4 : 1.8;
      dash = ' stroke-dasharray="6 4"';
    } else if (spec.role === 'output') {
      stroke = touchesSelected ? theme.tones.cyan.stroke : theme.tones.info.stroke;
      marker = touchesSelected ? 'arrow-selected' : 'arrow-output';
      width = touchesSelected ? 2.5 : 2.0;
    }
    const d = bezierPath(edgeData.points);
    push(`<path d="${d}" fill="none" stroke="${stroke}" stroke-width="${width}" stroke-linecap="round"${dash} marker-end="url(#${marker})"/>`);
  }

  // Render nodes
  for (const [id, spec] of nodeSpecs.entries()) {
    const layout = g.node(id);
    if (!layout) continue;
    const x = layout.x - spec.width / 2;
    const y = layout.y - spec.height / 2;
    push(`<g data-node-id="${escapeXml(id)}" transform="translate(${x.toFixed(1)}, ${y.toFixed(1)})">`);

    if (spec.kind === 'fact') {
      const tone = toneForFactStatus(theme, spec.status);
      const dash = spec.status === 'unconfirmed' ? ' stroke-dasharray="6 4"' : '';
      // Card body
      push(`<rect width="${spec.width}" height="${spec.height}" rx="12" fill="${theme.cardBg}" stroke="${tone.stroke}" stroke-width="1.5"${dash}/>`);
      // Header band
      push(`<path d="M 1 12 Q 1 1 12 1 L ${spec.width - 12} 1 Q ${spec.width - 1} 1 ${spec.width - 1} 12 L ${spec.width - 1} ${spec.headerHeight} L 1 ${spec.headerHeight} Z" fill="${theme.cardHeaderBg}"/>`);
      push(`<line x1="1" y1="${spec.headerHeight}" x2="${spec.width - 1}" y2="${spec.headerHeight}" stroke="${theme.borderSubtle}" stroke-width="1"/>`);
      // Left accent bar
      push(`<rect x="1" y="8" width="4" height="${spec.height - 16}" rx="2" fill="${tone.stroke}"/>`);

      // Header pills: F-tag, memory_id, right-aligned status badge
      let hx = 14;
      if (spec.tag) {
        const tw = Math.ceil(estimateTextWidth(spec.tag, monoFontSize, true) + 14);
        push(`<rect x="${hx}" y="7" width="${tw}" height="22" rx="6" fill="${tone.pillBg}" stroke="${tone.stroke}" stroke-width="1"/>`);
        push(`<text x="${hx + 7}" y="22" font-family="Menlo,monospace" font-size="${monoFontSize}" font-weight="700" fill="${tone.pillText}">${escapeXml(spec.tag)}</text>`);
        hx += tw + 8;
      }
      if (spec.memoryId) {
        const mw = Math.ceil(estimateTextWidth(spec.memoryId, monoFontSize, true) + 14);
        push(`<rect x="${hx}" y="7" width="${mw}" height="22" rx="6" fill="${theme.pageBg}" stroke="${theme.borderSubtle}" stroke-width="1"/>`);
        push(`<text x="${hx + 7}" y="22" font-family="Menlo,monospace" font-size="${monoFontSize}" fill="${theme.inkMuted}">${escapeXml(spec.memoryId)}</text>`);
      }
      if (spec.badge) {
        const bw = Math.ceil(estimateTextWidth(spec.badge, monoFontSize, false) + 18);
        const bx = spec.width - bw - 12;
        push(`<rect x="${bx}" y="7" width="${bw}" height="22" rx="11" fill="${tone.pillBg}"/>`);
        push(`<text x="${bx + 9}" y="22" font-family="sans-serif" font-size="${monoFontSize}" font-weight="600" fill="${tone.pillText}">${escapeXml(spec.badge)}</text>`);
      }

      // Full untruncated body lines
      spec.lines.forEach((line, rowIdx) => {
        const ly = spec.headerHeight + 24 + rowIdx * bodyLineHeight;
        push(`<text x="16" y="${ly}" font-family="sans-serif" font-size="${bodyFontSize}" fill="${theme.ink}">${escapeXml(line)}</text>`);
      });
    } else if (spec.kind === 'event') {
      const tone = toneForEvent(theme, spec.tone);
      const dash = spec.tone === 'warn' && !spec.selected ? ' stroke-dasharray="5 4"' : '';
      if (spec.selected) {
        push(`<rect x="-4" y="-4" width="${spec.width + 8}" height="${spec.height + 8}" rx="22" fill="none" stroke="${tone.stroke}" stroke-opacity="0.35" stroke-width="3"/>`);
      }
      push(`<rect width="${spec.width}" height="${spec.height}" rx="18" fill="${theme.eventBg}" stroke="${tone.stroke}" stroke-width="${spec.selected ? 2.4 : 1.6}"${dash}/>`);

      // Top row: kind pill + selected pill + counts pill
      const kindText = String(spec.tag ?? '');
      const kw = Math.ceil(estimateTextWidth(kindText, 13, false) + 20);
      push(`<rect x="12" y="10" width="${kw}" height="24" rx="12" fill="${tone.pillBg}" stroke="${tone.stroke}" stroke-width="1"/>`);
      push(`<text x="22" y="26" font-family="sans-serif" font-size="13" font-weight="700" fill="${tone.pillText}">${escapeXml(kindText)}</text>`);

      let rx = spec.width - 12;
      if (spec.counts) {
        const cw = Math.ceil(estimateTextWidth(spec.counts, monoFontSize, true) + 16);
        rx -= cw;
        push(`<rect x="${rx}" y="10" width="${cw}" height="24" rx="8" fill="${theme.pageBg}" stroke="${theme.borderSubtle}" stroke-width="1"/>`);
        push(`<text x="${rx + 8}" y="26" font-family="Menlo,monospace" font-size="${monoFontSize}" font-weight="700" fill="${theme.ink}">${escapeXml(spec.counts)}</text>`);
        rx -= 6;
      }
      if (spec.selected) {
        const sl = String(spec.selectedLabel ?? '★');
        const sw = Math.ceil(estimateTextWidth(sl, monoFontSize, false) + 16);
        rx -= sw;
        push(`<rect x="${rx}" y="10" width="${sw}" height="24" rx="12" fill="${tone.stroke}"/>`);
        const selText = contrast('#ffffff', tone.stroke) >= contrast('#000000', tone.stroke) ? '#ffffff' : '#000000';
        push(`<text x="${rx + 8}" y="26" font-family="sans-serif" font-size="${monoFontSize}" font-weight="700" fill="${selText}">${escapeXml(sl)}</text>`);
      }

      // Revision + timestamp metadata line
      if (spec.metaText) {
        push(`<text x="14" y="54" font-family="Menlo,monospace" font-size="${monoFontSize}" fill="${theme.inkMuted}">${escapeXml(spec.metaText)}</text>`);
      }

      // Optional full reason callout box
      if (spec.reasonLines.length > 0) {
        const ry = 66;
        push(`<rect x="12" y="${ry}" width="${spec.width - 24}" height="${spec.reasonBoxHeight}" rx="8" fill="${theme.pageBg}" stroke="${theme.borderSubtle}" stroke-width="1"/>`);
        spec.reasonLines.forEach((line, rIdx) => {
          const ty = ry + 18 + rIdx * reasonLineHeight;
          push(`<text x="22" y="${ty}" font-family="sans-serif" font-size="${reasonFontSize}" fill="${theme.inkMuted}">${escapeXml(line)}</text>`);
        });
      }
    }

    push(`</g>`);
  }

  push(`</g>`);

  // Footer strip
  const fy = totalHeight - 16;
  const footerLeft = legend.footer ?? '+/- zoom · arrows/hjkl pan · 0 fit · Esc back';
  const footerRight = `${legend.solid ?? 'Confirmed transition'}  —  ${legend.dashed ?? 'Unresolved relation'}`;
  push(`<text x="24" y="${fy}" font-family="sans-serif" font-size="12" fill="${theme.inkMuted}">${escapeXml(footerLeft)}</text>`);
  const rightW = estimateTextWidth(footerRight, 12, false);
  push(`<text x="${Math.max(24, totalWidth - 24 - rightW).toFixed(0)}" y="${fy}" font-family="sans-serif" font-size="12" fill="${theme.inkMuted}">${escapeXml(footerRight)}</text>`);

  push(`</svg>`);
  return out.join('\n');
}
