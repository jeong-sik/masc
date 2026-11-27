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
  const candidate = parseHex(colorHex) ? colorHex : targetHex;
  if (contrast(candidate, surfaceHex) >= minRatio) return candidate;
  for (let step = 1; step <= 10; step++) {
    const mixed = mixHex(candidate, targetHex, step / 10);
    if (contrast(mixed, surfaceHex) >= minRatio) return mixed;
  }
  return targetHex;
}

const DARK_SERIES = [
  '#60a5fa', '#34d399', '#fbbf24', '#f472b6',
  '#a78bfa', '#22d3ee', '#fb923c', '#f87171',
];

const LIGHT_SERIES = [
  '#2563eb', '#059669', '#d97706', '#db2777',
  '#7c3aed', '#0891b2', '#ea580c', '#dc2626',
];

function buildTheme(colors) {
  const fg = parseHex(colors?.foreground) ? colors.foreground : '#1f2937';
  const bg = parseHex(colors?.background) ? colors.background : '#ffffff';
  const isDark = luminance(bg) < 0.25;
  const panelBg = mixHex(bg, fg, isDark ? 0.04 : 0.02);
  const grid = ensureContrast(mixHex(bg, fg, isDark ? 0.20 : 0.16), panelBg, fg, 1.4);
  const axis = ensureContrast(mixHex(bg, fg, 0.45), panelBg, fg, 3.0);
  const ink = ensureContrast(fg, panelBg, fg, 4.5);
  const muted = ensureContrast(mixHex(bg, fg, 0.68), panelBg, fg, 4.5);
  const basePalette = isDark ? DARK_SERIES : LIGHT_SERIES;
  const palette = basePalette.map(c => ensureContrast(c, panelBg, fg, 3.0));
  return { isDark, bg, panelBg, grid, axis, ink, muted, fg, palette };
}

function formatTick(value) {
  if (!Number.isFinite(value)) return '0';
  const abs = Math.abs(value);
  if (abs >= 1e6) return `${(value / 1e6).toFixed(1).replace(/\.0$/, '')}M`;
  if (abs >= 1e3) return `${(value / 1e3).toFixed(1).replace(/\.0$/, '')}k`;
  if (Number.isInteger(value)) return String(value);
  return value.toFixed(abs < 10 ? 2 : 1).replace(/\.?0+$/, '');
}

function niceUpperBound(maxVal) {
  if (!Number.isFinite(maxVal) || maxVal <= 0) return 10;
  const exp = Math.floor(Math.log10(maxVal));
  const base = 10 ** exp;
  const frac = maxVal / base;
  const nice = frac <= 1 ? 1 : frac <= 2 ? 2 : frac <= 2.5 ? 2.5 : frac <= 5 ? 5 : 10;
  return nice * base;
}

function parseChartSpec(source) {
  let raw;
  try {
    raw = JSON.parse(source);
  } catch (err) {
    throw new TypeError(`Invalid chart JSON: ${err.message}`);
  }
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new TypeError('Chart JSON must be an object');
  }
  const chartTypeRaw = String(raw.type ?? raw.chart_type ?? raw.kind ?? 'line').trim().toLowerCase();
  const validTypes = new Set(['line', 'bar', 'area', 'pie']);
  if (!validTypes.has(chartTypeRaw)) {
    throw new TypeError(`Unsupported chart type "${chartTypeRaw}" (expected line, bar, area, or pie)`);
  }
  if (!Array.isArray(raw.series) || raw.series.length === 0) {
    throw new TypeError('Chart JSON requires a non-empty "series" array');
  }
  const series = raw.series.map((entry, idx) => {
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      throw new TypeError(`Chart series[${idx}] must be an object`);
    }
    const label = typeof entry.label === 'string' && entry.label.trim()
      ? entry.label.trim()
      : `Series ${idx + 1}`;
    const values = Array.isArray(entry.values)
      ? entry.values.map(v => Number(v)).filter(Number.isFinite)
      : [];
    const color = typeof entry.color === 'string' && parseHex(entry.color.trim())
      ? entry.color.trim()
      : null;
    return { label, values, color };
  });
  const maxPoints = series.reduce((m, s) => Math.max(m, s.values.length), 0);
  if (maxPoints === 0) {
    throw new TypeError('Chart series must contain at least one finite numeric value');
  }
  const labels = Array.isArray(raw.labels)
    ? raw.labels.map(v => String(v))
    : Array.from({ length: maxPoints }, (_, i) => String(i + 1));
  const title = typeof raw.title === 'string' ? raw.title.trim() : '';
  const xLabel = typeof raw.xLabel === 'string' ? raw.xLabel.trim() : '';
  const yLabel = typeof raw.yLabel === 'string' ? raw.yLabel.trim() : '';
  const yMax = raw.yMax !== undefined && Number.isFinite(Number(raw.yMax)) && Number(raw.yMax) > 0
    ? Number(raw.yMax)
    : undefined;
  return { type: chartTypeRaw, title, labels, series, xLabel, yLabel, yMax, maxPoints };
}

function renderPieSvg(spec, theme, width) {
  const height = 340;
  const cx = Math.round(width * 0.34);
  const cy = spec.title ? 186 : 172;
  const radius = Math.min(110, Math.round(width * 0.22));
  // Support either 1 series with N values + labels, or N series with 1+ values (summed).
  let slices;
  if (spec.series.length === 1 && spec.series[0].values.length > 1) {
    slices = spec.series[0].values.map((val, idx) => ({
      label: spec.labels[idx] ?? `${spec.series[0].label} ${idx + 1}`,
      value: Math.max(0, val),
      color: theme.palette[idx % theme.palette.length],
    }));
  } else {
    slices = spec.series.map((s, idx) => ({
      label: s.label,
      value: Math.max(0, s.values.reduce((acc, v) => acc + Math.max(0, v), 0)),
      color: s.color
        ? ensureContrast(s.color, theme.panelBg, theme.fg, 3.0)
        : theme.palette[idx % theme.palette.length],
    }));
  }
  const total = slices.reduce((acc, s) => acc + s.value, 0);
  const parts = [];
  parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" font-family="sans-serif">`);
  parts.push(`<rect x="0" y="0" width="${width}" height="${height}" fill="${theme.bg}" rx="6"/>`);
  if (spec.title) {
    parts.push(`<text x="20" y="30" fill="${theme.ink}" font-size="16" font-weight="700">${escapeXml(spec.title)}</text>`);
  }
  if (total <= 0) {
    parts.push(`<circle cx="${cx}" cy="${cy}" r="${radius}" fill="none" stroke="${theme.axis}" stroke-width="2"/>`);
    parts.push(`<text x="${cx}" y="${cy + 5}" text-anchor="middle" fill="${theme.muted}" font-size="13">No positive values</text>`);
  } else {
    const nonZero = slices.filter(s => s.value > 0);
    if (nonZero.length === 1) {
      parts.push(`<circle cx="${cx}" cy="${cy}" r="${radius}" fill="${nonZero[0].color}" stroke="${theme.bg}" stroke-width="2"/>`);
    } else {
      let angle = -Math.PI / 2;
      for (const slice of nonZero) {
        const sweep = (slice.value / total) * Math.PI * 2;
        const endAngle = angle + sweep;
        const x1 = cx + radius * Math.cos(angle);
        const y1 = cy + radius * Math.sin(angle);
        const x2 = cx + radius * Math.cos(endAngle);
        const y2 = cy + radius * Math.sin(endAngle);
        const largeArc = sweep > Math.PI ? 1 : 0;
        const d = `M ${cx} ${cy} L ${x1.toFixed(2)} ${y1.toFixed(2)} A ${radius} ${radius} 0 ${largeArc} 1 ${x2.toFixed(2)} ${y2.toFixed(2)} Z`;
        parts.push(`<path d="${d}" fill="${slice.color}" stroke="${theme.bg}" stroke-width="2"/>`);
        angle = endAngle;
      }
    }
  }
  const legendX = Math.round(width * 0.62);
  let legendY = spec.title ? 74 : 52;
  for (const slice of slices.slice(0, 10)) {
    const pct = total > 0 ? ((slice.value / total) * 100).toFixed(1).replace(/\.0$/, '') : '0';
    parts.push(`<rect x="${legendX}" y="${legendY - 10}" width="12" height="12" rx="2" fill="${slice.color}"/>`);
    const text = `${slice.label}: ${formatTick(slice.value)} (${pct}%)`;
    parts.push(`<text x="${legendX + 18}" y="${legendY}" fill="${theme.ink}" font-size="12">${escapeXml(text)}</text>`);
    legendY += 24;
  }
  parts.push('</svg>');
  return parts.join('\n');
}

function renderCartesianSvg(spec, theme, width) {
  const height = 340;
  const padLeft = spec.yLabel ? 72 : 56;
  const padRight = 24;
  const padTop = spec.title ? 58 : 34;
  const padBottom = (spec.xLabel ? 56 : 40) + (spec.series.length > 1 ? 22 : 0);
  const plotW = Math.max(80, width - padLeft - padRight);
  const plotH = Math.max(80, height - padTop - padBottom);

  const allVals = spec.series.flatMap(s => s.values);
  const rawMin = Math.min(0, ...allVals);
  const rawMax = Math.max(0, ...allVals);
  const yMin = rawMin < 0 ? -niceUpperBound(Math.abs(rawMin)) : 0;
  const yMax = spec.yMax !== undefined ? spec.yMax : niceUpperBound(rawMax === yMin ? yMin + 10 : rawMax);
  const ySpan = Math.max(1e-9, yMax - yMin);

  const mapY = v => padTop + plotH - ((v - yMin) / ySpan) * plotH;
  const zeroY = mapY(0);

  const parts = [];
  parts.push(`<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" font-family="sans-serif">`);
  parts.push(`<rect x="0" y="0" width="${width}" height="${height}" fill="${theme.bg}" rx="6"/>`);
  parts.push(`<rect x="${padLeft}" y="${padTop}" width="${plotW}" height="${plotH}" fill="${theme.panelBg}" rx="3"/>`);

  if (spec.title) {
    parts.push(`<text x="${padLeft}" y="28" fill="${theme.ink}" font-size="16" font-weight="700">${escapeXml(spec.title)}</text>`);
  }

  // Horizontal grid lines & Y ticks
  const tickCount = 4;
  for (let i = 0; i <= tickCount; i++) {
    const val = yMin + (ySpan * i) / tickCount;
    const y = mapY(val);
    parts.push(`<line x1="${padLeft}" y1="${y.toFixed(1)}" x2="${padLeft + plotW}" y2="${y.toFixed(1)}" stroke="${theme.grid}" stroke-width="1" stroke-dasharray="3 3"/>`);
    parts.push(`<text x="${padLeft - 8}" y="${(y + 4).toFixed(1)}" text-anchor="end" fill="${theme.muted}" font-size="11">${escapeXml(formatTick(val))}</text>`);
  }

  // Axes
  parts.push(`<line x1="${padLeft}" y1="${padTop}" x2="${padLeft}" y2="${padTop + plotH}" stroke="${theme.axis}" stroke-width="1.5"/>`);
  parts.push(`<line x1="${padLeft}" y1="${zeroY.toFixed(1)}" x2="${padLeft + plotW}" y2="${zeroY.toFixed(1)}" stroke="${theme.axis}" stroke-width="1.5"/>`);

  const count = spec.maxPoints;
  const resolvedSeries = spec.series.map((s, idx) => ({
    ...s,
    resolvedColor: s.color
      ? ensureContrast(s.color, theme.panelBg, theme.fg, 3.0)
      : theme.palette[idx % theme.palette.length],
  }));

  if (spec.type === 'bar') {
    const groupW = plotW / Math.max(1, count);
    const innerPad = Math.min(12, groupW * 0.16);
    const barSlot = Math.max(4, (groupW - innerPad * 2) / Math.max(1, resolvedSeries.length));
    const barW = Math.max(3, barSlot - 2);
    for (let i = 0; i < count; i++) {
      resolvedSeries.forEach((s, si) => {
        if (i >= s.values.length) return;
        const v = s.values[i];
        const x = padLeft + i * groupW + innerPad + si * barSlot;
        const yVal = mapY(v);
        const top = Math.min(zeroY, yVal);
        const h = Math.max(1, Math.abs(zeroY - yVal));
        parts.push(`<rect x="${x.toFixed(1)}" y="${top.toFixed(1)}" width="${barW.toFixed(1)}" height="${h.toFixed(1)}" rx="2" fill="${s.resolvedColor}"/>`);
      });
    }
  } else {
    const xAt = i => count === 1
      ? padLeft + plotW / 2
      : padLeft + (i / (count - 1)) * plotW;
    for (const s of resolvedSeries) {
      if (s.values.length === 0) continue;
      const pts = s.values.map((v, i) => [xAt(i), mapY(v)]);
      if (spec.type === 'area' && pts.length >= 2) {
        const firstX = pts[0][0].toFixed(1);
        const lastX = pts[pts.length - 1][0].toFixed(1);
        const poly = pts.map(([x, y]) => `${x.toFixed(1)},${y.toFixed(1)}`).join(' ');
        parts.push(`<polygon points="${firstX},${zeroY.toFixed(1)} ${poly} ${lastX},${zeroY.toFixed(1)}" fill="${s.resolvedColor}" fill-opacity="0.22"/>`);
      }
      if (pts.length >= 2) {
        const lineD = pts.map(([x, y], idx) => `${idx === 0 ? 'M' : 'L'} ${x.toFixed(1)} ${y.toFixed(1)}`).join(' ');
        parts.push(`<path d="${lineD}" fill="none" stroke="${s.resolvedColor}" stroke-width="2.5" stroke-linejoin="round" stroke-linecap="round"/>`);
      }
      for (const [x, y] of pts) {
        parts.push(`<circle cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="3.5" fill="${s.resolvedColor}" stroke="${theme.bg}" stroke-width="1.2"/>`);
      }
    }
  }

  // X labels (stride cleanly when many points)
  const maxXLabels = Math.max(2, Math.floor(plotW / 56));
  const step = Math.max(1, Math.ceil(count / maxXLabels));
  for (let i = 0; i < count; i += step) {
    const lbl = spec.labels[i] ?? String(i + 1);
    const x = spec.type === 'bar'
      ? padLeft + (i + 0.5) * (plotW / Math.max(1, count))
      : count === 1
        ? padLeft + plotW / 2
        : padLeft + (i / (count - 1)) * plotW;
    parts.push(`<text x="${x.toFixed(1)}" y="${(padTop + plotH + 16).toFixed(1)}" text-anchor="middle" fill="${theme.muted}" font-size="11">${escapeXml(lbl)}</text>`);
  }

  if (spec.xLabel) {
    parts.push(`<text x="${(padLeft + plotW / 2).toFixed(1)}" y="${(padTop + plotH + 34).toFixed(1)}" text-anchor="middle" fill="${theme.ink}" font-size="12" font-weight="600">${escapeXml(spec.xLabel)}</text>`);
  }
  if (spec.yLabel) {
    const midY = padTop + plotH / 2;
    parts.push(`<text x="16" y="${midY.toFixed(1)}" text-anchor="middle" fill="${theme.ink}" font-size="12" font-weight="600" transform="rotate(-90 16 ${midY.toFixed(1)})">${escapeXml(spec.yLabel)}</text>`);
  }

  // Legend row
  if (resolvedSeries.length > 1 || (resolvedSeries.length === 1 && resolvedSeries[0].label !== 'Series 1')) {
    const legendY = height - 10;
    let cursorX = padLeft;
    for (const s of resolvedSeries) {
      if (cursorX > width - 80) break;
      parts.push(`<rect x="${cursorX}" y="${legendY - 10}" width="10" height="10" rx="2" fill="${s.resolvedColor}"/>`);
      parts.push(`<text x="${cursorX + 14}" y="${legendY - 1}" fill="${theme.ink}" font-size="11">${escapeXml(s.label)}</text>`);
      cursorX += 26 + Math.min(140, s.label.length * 7.2);
    }
  }

  parts.push('</svg>');
  return parts.join('\n');
}

export function renderChartSvg(source, { colors, maxWidth } = {}) {
  const spec = parseChartSpec(source);
  const theme = buildTheme(colors);
  const width = Math.max(360, Math.min(960, Number.isFinite(maxWidth) ? Math.floor(maxWidth) : 640));
  return spec.type === 'pie'
    ? renderPieSvg(spec, theme, width)
    : renderCartesianSvg(spec, theme, width);
}
