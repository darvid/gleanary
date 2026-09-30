// Bundled Readability 0.6.0 and Turndown 7.2.0 are evaluated in this local content world.
// Source-page JavaScript is disabled. This function returns data, never executable markup.
const article = new Readability(document.cloneNode(true), {
  charThreshold: 80,
  maxElemsToParse: 50000,
  keepClasses: false
}).parse();
if (!article || !article.content) throw new Error('No readable article');
const content = new DOMParser().parseFromString(article.content, 'text/html');
const warnings = [];
const converter = new TurndownService({ headingStyle: 'atx', codeBlockStyle: 'fenced', bulletListMarker: '-' });
converter.addRule('safeTables', {
  filter: 'table',
  replacement: function (_text, node) {
    const rows = Array.from(node.rows).map(row => Array.from(row.cells).map(cell =>
      cell.textContent.trim().replace(/\s+/g, ' ').replace(/\|/g, '\\|')));
    if (!rows.length) return '';
    if (node.querySelector('[rowspan]:not([rowspan="1"]), [colspan]:not([colspan="1"])')) {
      warnings.push('A merged-cell table was retained as text; consult the original for its layout.');
      return '\n\n```text\n' + rows.map(row => row.join('\t')).join('\n') + '\n```\n\n';
    }
    const width = Math.max(...rows.map(row => row.length));
    const hasHeader = node.rows[0].querySelector('th') !== null;
    const header = hasHeader ? rows.shift() : Array.from({length: width}, (_, i) => 'Column ' + (i + 1));
    if (!hasHeader) warnings.push('A table without declared headers uses generated column labels; all source rows are retained.');
    const render = row => '| ' + Array.from({length: width}, (_, i) => row[i] || '').join(' | ') + ' |';
    return '\n\n' + [render(header), render(Array(width).fill('---')), ...rows.map(render)].join('\n') + '\n\n';
  }
});
const blocks = [];
const headings = [];
const kinds = {P:'paragraph', UL:'list', OL:'list', PRE:'code', TABLE:'table', BLOCKQUOTE:'quote', IMG:'image'};
function readableText(node) {
  if (node.nodeType === Node.TEXT_NODE) return node.textContent;
  if (node.nodeType !== Node.ELEMENT_NODE) return '';
  if (node.tagName === 'IMG') return node.getAttribute('alt') || '';
  if (node.tagName === 'BR') return '\n';
  if (node.tagName === 'PRE') return node.textContent;
  const body = Array.from(node.childNodes).map(readableText).join('');
  return body + (/^(P|LI|TR|TD|TH|H[1-6]|DIV|BLOCKQUOTE)$/.test(node.tagName) ? '\n' : '');
}
function walk(node) {
  if (blocks.length >= 20000) throw new Error('Too many blocks');
  if (node.nodeType === Node.TEXT_NODE) {
    const text = node.textContent.trim();
    if (text) {
      const p = content.createElement('p');
      p.textContent = text;
      blocks.push({kind:'paragraph', markdown:converter.turndown(p.outerHTML), text, section:headings.filter(Boolean).join(' › ') || null, method:'readability'});
    }
    return;
  }
  if (node.nodeType !== Node.ELEMENT_NODE) return;
  const tag = node.tagName;
  const heading = /^H[1-6]$/.test(tag);
  if (heading || kinds[tag]) {
    const text = readableText(node).trim();
    if (heading) {
      const level = Number(tag.slice(1));
      headings.length = level;
      headings[level - 1] = text;
    }
    const markdown = converter.turndown(node.outerHTML).trim();
    if (markdown) blocks.push({kind:heading ? 'heading' : kinds[tag], markdown, text, section:headings.filter(Boolean).join(' › ') || null, method:'readability'});
    return;
  }
  Array.from(node.childNodes).forEach(walk);
}
Array.from(content.body.childNodes).forEach(walk);
return JSON.stringify({title:article.title || '', byline:article.byline || null, blocks, warnings});
