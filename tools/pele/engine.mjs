import { render } from 'pele';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { Resvg } from '@resvg/resvg-js';

// resvg does not implement CSS custom properties. Resolve them in attributes,
// with element-local inheritance, without touching label text or path data.
function concreteSvg(svg, colors) {
  const document = new DOMParser().parseFromString(svg, 'image/svg+xml');
  const presentationAttributes = new Set([
    'fill', 'stroke', 'color', 'stop-color', 'flood-color', 'lighting-color',
    'font-family', 'font-size', 'font-weight', 'font-style',
    'opacity', 'fill-opacity', 'stroke-opacity', 'stop-opacity',
    'stroke-width', 'stroke-dasharray', 'stroke-dashoffset', 'rx', 'ry',
  ]);
  function resolve(value, variables, seen = new Set()) {
    return value.replace(/var\((--[\w-]+)(?:,([^()]*))?\)/g, (_, name, fallback) => {
      if (seen.has(name)) throw new Error(`Cyclic SVG theme variable: ${name}`);
      const next = variables.get(name) ?? fallback;
      if (next === undefined) throw new Error(`Unresolved SVG theme variable: ${name}`);
      return resolve(next, variables, new Set([...seen, name]));
    });
  }
  function walk(element, inherited) {
    const variables = new Map(inherited);
    const declarations = (element.getAttribute('style') ?? '').split(';')
      .map(entry => {
        const colon = entry.indexOf(':');
        return [entry.slice(0, colon).trim(), entry.slice(colon + 1).trim()];
      }).filter(([name]) => name);
    for (const [name, value] of declarations) {
      if (name.startsWith('--')) variables.set(name, value);
    }
    // Explicit terminal colors take precedence over any diagram theme defaults.
    for (const [name, value] of colors) variables.set(name, value);
    if (element.hasAttribute('style')) {
      element.setAttribute('style', declarations.filter(([name]) => !name.startsWith('--'))
        .map(([name, value]) => `${name}:${resolve(value, variables)}`).join(';'));
    }
    for (const attribute of Array.from(element.attributes)) {
      if (presentationAttributes.has(attribute.name) && attribute.value.includes('var(')) {
        element.setAttribute(attribute.name, resolve(attribute.value, variables));
      }
    }
    // Raster previews never load diagram-supplied images or external resources.
    if (element.localName === 'image' || element.localName === 'foreignObject') {
      throw new Error('External image and HTML content is unavailable in terminal diagrams');
    }
    for (const child of Array.from(element.childNodes)) {
      if (child.nodeType === 1) walk(child, variables);
    }
  }
  walk(document.documentElement, new Map());
  return new XMLSerializer().serializeToString(document);
}

function color(value, name) {
  if (typeof value !== 'string' || !/^#[\da-f]{6}$/i.test(value)) {
    throw new TypeError(`${name} must be an RGB hex color`);
  }
  return value;
}

function rgb(hex) {
  return [1, 3, 5].map(start => Number.parseInt(hex.slice(start, start + 2), 16));
}

function mix(background, foreground, weight) {
  const bg = rgb(background);
  return '#' + rgb(foreground).map((channel, index) =>
    Math.round(bg[index] + (channel - bg[index]) * weight).toString(16).padStart(2, '0')).join('');
}

function luminance(hex) {
  const linear = rgb(hex).map(channel => {
    const srgb = channel / 255;
    return srgb <= 0.04045 ? srgb / 12.92 : ((srgb + 0.055) / 1.055) ** 2.4;
  });
  return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}

function contrast(first, second) {
  const a = luminance(first), b = luminance(second);
  return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
}

function terminalTheme(foreground, background) {
  // Neutral tints follow the observed terminal palette in either light or dark
  // mode. Recede only while retaining WCAG text (4.5) / boundary (3) contrast.
  // An already low-contrast user palette stays intact rather than being inverted.
  const surface = weight => {
    const tinted = mix(background, foreground, weight);
    return contrast(foreground, tinted) >= 4.5 ? tinted : background;
  };
  // Pele composites cluster fills at half opacity. Keep their visible tint
  // distinct from the node surface after that compositing step.
  const node = surface(0.06), group = surface(0.24);
  const readable = (weight, minimum) => {
    const tinted = mix(background, foreground, weight);
    return [background, node, group].every(bg => contrast(tinted, bg) >= minimum)
      ? tinted : foreground;
  };
  return new Map(Object.entries({
    '--pele-fg': foreground,
    '--pele-bg': background,
    '--pele-line': foreground,
    '--pele-muted': readable(0.7, 4.5),
    '--pele-border': readable(0.55, 3),
    '--pele-surface': node,
    '--pele-surface-alt': group,
  }));
}

function retainedSvg(source) {
  const document = new DOMParser({ onError() { throw new Error('Malformed SVG XML'); } })
    .parseFromString(source, 'image/svg+xml');
  const root = document.documentElement;
  if (!root || root.localName !== 'svg' || root.namespaceURI !== 'http://www.w3.org/2000/svg') {
    throw new TypeError('source must be an SVG document');
  }
  function inspect(node) {
    switch (node.nodeType) {
      case 1:
        if (node.namespaceURI !== 'http://www.w3.org/2000/svg') {
          throw new Error('Foreign content is unavailable in terminal SVG');
        }
        switch (node.localName) {
          case 'script': case 'image': case 'feImage': case 'foreignObject':
            throw new Error('Scripts, images and HTML content are unavailable in terminal SVG');
        }
        for (const attribute of Array.from(node.attributes)) {
          // SVG's href and XLink href may only refer to this document's IDs.
          if (attribute.localName === 'href' && !attribute.value.trim().startsWith('#')) {
            throw new Error('External references are unavailable in terminal SVG');
          }
          if (attribute.localName.startsWith('on')) {
            throw new Error('Event handlers are unavailable in terminal SVG');
          }
        }
        break;
      case 7:
        // xmldom retains the XML declaration as a PI; it is not a stylesheet
        // instruction and is valid only at the beginning of this document.
        if (node.target === 'xml' && node.parentNode === document && node === document.firstChild) break;
        throw new Error('Processing instructions are unavailable in terminal SVG');
      case 10:
        throw new Error('Processing instructions and DOCTYPE are unavailable in terminal SVG');
    }
    for (const child of Array.from(node.childNodes ?? [])) inspect(child);
  }
  inspect(document);
  return source;
}

export function renderDocument(request) {
  if (typeof request?.source !== 'string') throw new TypeError('source must be a string');
  if (!Number.isSafeInteger(request.maxWidth) || request.maxWidth <= 0) {
    throw new TypeError('maxWidth must be a positive pixel width');
  }
  let colors = new Map();
  let background;
  if (request.colors !== undefined) {
    const fg = color(request.colors.foreground, 'foreground');
    background = color(request.colors.background, 'background');
    colors = terminalTheme(fg, background);
  }
  let result, svg, renderer;
  switch (request.format) {
    case 'mermaid':
      result = render(request.source, {
        maxWidth: request.maxWidth, images: false, links: false,
        responsive: false, fontFamily: 'sans-serif',
      });
      svg = concreteSvg(result.svg, colors);
      renderer = new Resvg(svg, {
        background: background ?? '#ffffff',
        fitTo: { mode: 'width', value: Math.min(Math.ceil(result.width), request.maxWidth) },
      });
      break;
    case 'svg': {
      svg = retainedSvg(request.source);
      const original = new Resvg(svg, { background });
      result = { width: original.width, height: original.height };
      renderer = original.width <= request.maxWidth ? original : new Resvg(svg, {
        background, fitTo: { mode: 'width', value: request.maxWidth },
      });
      break;
    }
    default:
      throw new TypeError('format must be mermaid or svg');
  }
  if (renderer.imagesToResolve().length) throw new Error('Diagram contains unresolved images');
  return { ...result, svg, png: renderer.render().asPng() };
}
