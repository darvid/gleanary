// Executed only by Infactory in an isolated content world. Never reads cookies, storage, forms, or inputs.
const source = new URL(sourceURL);
let truncated = false;
const posts = [];
const seen = new Set();
function content(node) {
  if (!node) return '';
  if (node.nodeType === Node.TEXT_NODE) return node.textContent;
  if (node.nodeType !== Node.ELEMENT_NODE || /^(SCRIPT|STYLE|BUTTON|INPUT|TEXTAREA|FORM)$/.test(node.tagName)) return '';
  if (node.tagName === 'BR') return '\n';
  if (node.tagName === 'IMG') return node.getAttribute('alt') || '';
  return Array.from(node.childNodes).map(content).join('') + (/^(P|DIV|LI|BLOCKQUOTE|PRE)$/.test(node.tagName) ? '\n' : '');
}
function link(value) {
  if (typeof value !== 'string' || !value.trim()) return null;
  try { const u = new URL(value, source); u.search = ''; u.hash = ''; return u.protocol === 'https:' && !u.username && !u.password ? u.href : null; }
  catch { return null; }
}
function add(post) {
  if (!post.id || !post.url || seen.has(post.id)) return;
  if (posts.length >= 300) { truncated = true; return; }
  post.text = (post.text || '').trim();
  if (post.text.length > 50000) { post.text = post.text.slice(0, 50000); truncated = true; }
  seen.add(post.id); posts.push(post);
}
if (platform === 'reddit') {
  const thread = source.pathname.split('/').filter(Boolean);
  const rootID = 't3_' + thread[thread.indexOf('comments') + 1];
  for (const node of document.querySelectorAll('shreddit-post, .thing.link')) {
    const id = node.getAttribute('id')?.startsWith('t3_') ? node.getAttribute('id') : node.getAttribute('data-fullname');
    const title = node.getAttribute('post-title') || content(node.querySelector('a.title, h1'));
    const body = node.querySelector('[slot="text-body"], .usertext-body .md');
    const outbound = link(node.getAttribute('content-href') || node.querySelector('a.title')?.getAttribute('href'));
    const bodyText = content(body);
    add({id, url:link(node.getAttribute('permalink') || node.getAttribute('data-permalink') || source.href),
      text:[title,bodyText,outbound && !bodyText.includes(outbound) ? outbound : null].filter(Boolean).join('\n\n'), author:node.getAttribute('author') || content(node.querySelector('a.author')) || null,
      published:node.getAttribute('created-timestamp') || node.querySelector('time')?.getAttribute('datetime') || null, parentID:null, quoteID:null});
  }
  for (const node of document.querySelectorAll('shreddit-comment, .commentarea .thing.comment')) {
    const parent = node.parentElement?.closest('shreddit-comment, .thing.comment');
    const ancestorID = parent?.getAttribute('thingid') || parent?.getAttribute('data-fullname');
    const id = node.getAttribute('thingid') || node.getAttribute('data-fullname');
    const entry = Array.from(node.children).find(child=>child.classList.contains('entry'));
    const body = Array.from(node.querySelectorAll('[slot="comment"]')).find(child=>child.closest('shreddit-comment') === node) || entry?.querySelector('.usertext-body .md');
    add({id, url:link(node.getAttribute('permalink') || node.querySelector('a.bylink')?.getAttribute('href') || source.href + '_/' + (id || '').replace(/^t1_/, '') + '/'),
      text:content(body), author:node.getAttribute('author') || content(entry?.querySelector('a.author')) || null,
      published:node.getAttribute('created') || node.querySelector('time')?.getAttribute('datetime') || null,
      parentID:node.getAttribute('parentid') || ancestorID || rootID, quoteID:null});
  }
} else if (platform === 'x') {
  function tweet(node) {
    const quote = node.querySelector('[data-testid="quoteTweet"]');
    const copy = node.cloneNode(true);
    copy.querySelectorAll('[data-testid="quoteTweet"]').forEach(n=>n.remove());
    const anchor = Array.from(copy.querySelectorAll('a[href*="/status/"]')).find(a=>a.querySelector('time'));
    const url = link(anchor?.getAttribute('href'));
    const id = url && new URL(url).pathname.match(/\/status\/(\d+)/)?.[1];
    let quoteID = null;
    if (quote) { const q = tweet(quote); if (q) { quoteID=q.id; add(q); } }
    if (!id || !url) return null;
    const bodies = Array.from(copy.querySelectorAll('[data-testid="tweetText"]'));
    const alt = Array.from(copy.querySelectorAll('[data-testid="tweetPhoto"] img')).map(n=>n.getAttribute('alt')).filter(v=>v && v !== 'Image');
    return {id, url, text:[...bodies.map(content),...alt].join('\n'),
      author:content(copy.querySelector('[data-testid="User-Name"]')).trim() || null,
      published:copy.querySelector('time')?.getAttribute('datetime') || null,
      parentID:node.getAttribute('data-in-reply-to-status-id') || null, quoteID};
  }
  for (const node of document.querySelectorAll('article[data-testid="tweet"]')) { const post=tweet(node); if (post) add(post); }
}
const payload = {pageURL:link(location.href === 'about:blank' ? source.href : location.href), title:document.title || '', posts, truncated};
return JSON.stringify(payload);
