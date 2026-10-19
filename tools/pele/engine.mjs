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

export function renderDiagram(request) {
  if (typeof request?.source !== 'string') throw new TypeError('source must be a string');
  if (!Number.isSafeInteger(request.maxWidth) || request.maxWidth <= 0) {
    throw new TypeError('maxWidth must be a positive pixel width');
  }
  const colors = new Map();
  let background;
  if (request.colors !== undefined) {
    const fg = color(request.colors.foreground, 'foreground');
    background = color(request.colors.background, 'background');
    for (const name of ['fg', 'line', 'muted', 'border']) colors.set(`--pele-${name}`, fg);
    for (const name of ['bg', 'surface', 'surface-alt']) colors.set(`--pele-${name}`, background);
  }
  const result = render(request.source, {
    maxWidth: request.maxWidth, images: false, links: false,
    responsive: false, fontFamily: 'sans-serif',
  });
  const svg = concreteSvg(result.svg, colors);
  const renderer = new Resvg(svg, {
    background: background ?? '#ffffff',
    fitTo: { mode: 'width', value: Math.min(Math.ceil(result.width), request.maxWidth) },
  });
  if (renderer.imagesToResolve().length) throw new Error('Diagram contains unresolved images');
  return { ...result, svg, png: renderer.render().asPng() };
}
