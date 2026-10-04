// Injected into the page on demand (activeTab): turns the selection, the
// page's main content or an image into Markdown for Glea.
// The HTML → Markdown converter is Glea's own, from
// glea/src/resources/content-script.js: keep the two in sync.
(() => {
  if (window.__gleaClip) return;

  // Elements left out of an article (navigation, comments, share bars…).
  let skipped = new WeakSet();

  // -------------------------------------------------------- HTML -> Markdown

  const SKIP = new Set(['script', 'style', 'noscript', 'template', 'button', 'input', 'select',
    'textarea', 'form', 'nav', 'iframe', 'object', 'embed', 'dialog']);

  function absolute(url) {
    try { return new URL(url, document.baseURI).href; } catch (e) { return ''; }
  }

  function imageSource(img) {
    let src = img.currentSrc || img.getAttribute('src') || '';
    if ((!src || src.startsWith('data:')) && (img.dataset.src || img.dataset.lazySrc)) {
      src = img.dataset.src || img.dataset.lazySrc;
    }
    if (!src && img.getAttribute('srcset')) src = img.getAttribute('srcset').split(',').pop().trim().split(' ')[0];
    if (src.startsWith('data:') && src.length > 200000) return '';
    return src.startsWith('data:') ? src : absolute(src);
  }

  // Shown at 32px or less both ways (or sized so in its attributes, for
  // selections, which are copies off the page).
  function isIcon(img) {
    const width = img.isConnected ? img.width : parseInt(img.getAttribute('width'), 10);
    const height = img.isConnected ? img.height : parseInt(img.getAttribute('height'), 10);
    return width > 0 && height > 0 && width <= 32 && height <= 32;
  }

  function escapeText(text) {
    return text.replace(/([\\`*_[\]])/g, '\\$1');
  }

  function isHidden(el) {
    if (!el.isConnected) return false;
    const style = getComputedStyle(el);
    return style.display === 'none' || style.visibility === 'hidden';
  }

  function children(node, ctx) {
    return Array.from(node.childNodes).map((n) => convert(n, ctx)).join('');
  }

  function block(text) {
    const trimmed = text.trim();
    return trimmed ? `\n\n${trimmed}\n\n` : '';
  }

  function list(node, ctx) {
    const ordered = node.tagName === 'OL';
    let index = parseInt(node.getAttribute('start') || '1', 10) || 1;
    const items = [];
    for (const li of node.children) {
      if (li.tagName !== 'LI') continue;
      const marker = ordered ? `${index++}. ` : '- ';
      let content = Array.from(li.childNodes).map((n) => {
        if (n.nodeType === 1 && (n.tagName === 'UL' || n.tagName === 'OL')) {
          return '\n' + list(n, ctx).trim().replace(/^/gm, '  ');
        }
        return convert(n, ctx);
      }).join('');
      content = content.replace(/\n{2,}/g, '\n').trim();
      const checkbox = li.querySelector(':scope > input[type=checkbox]');
      const task = checkbox ? (checkbox.checked ? '[x] ' : '[ ] ') : '';
      items.push(marker + task + content.replace(/\n/g, '\n' + ' '.repeat(marker.length)));
    }
    return `\n\n${items.join('\n')}\n\n`;
  }

  function table(node, ctx) {
    const rows = Array.from(node.querySelectorAll('tr')).map((tr) =>
      Array.from(tr.children).map((cell) => children(cell, ctx).replace(/\s+/g, ' ').replace(/\|/g, '\\|').trim()));
    if (!rows.length) return '';
    const width = Math.max(...rows.map((r) => r.length));
    const pad = (r) => r.concat(Array(width - r.length).fill(''));
    const lines = [`| ${pad(rows[0]).join(' | ')} |`, `| ${Array(width).fill('---').join(' | ')} |`];
    for (const r of rows.slice(1)) lines.push(`| ${pad(r).join(' | ')} |`);
    return `\n\n${lines.join('\n')}\n\n`;
  }

  function convert(node, ctx = {}) {
    if (node.nodeType === Node.TEXT_NODE) {
      return ctx.pre ? node.nodeValue : escapeText(node.nodeValue.replace(/\s+/g, ' '));
    }
    if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) return children(node, ctx);
    if (node.nodeType !== Node.ELEMENT_NODE) return '';
    const tag = node.tagName.toLowerCase();
    if (SKIP.has(tag) || skipped.has(node) || node.getAttribute('aria-hidden') === 'true' || isHidden(node)) return '';
    // Footnote markers like [1] mean nothing outside the page.
    if (tag === 'sup' && /^\s*\[\s*[\w\s]{1,12}\]\s*$/.test(node.textContent)) return '';

    switch (tag) {
      case 'h1': case 'h2': case 'h3': case 'h4': case 'h5': case 'h6': {
        const text = children(node, ctx).replace(/\s+/g, ' ').trim();
        return text ? `\n\n${'#'.repeat(+tag[1])} ${text}\n\n` : '';
      }
      case 'p': case 'div': case 'section': case 'article': case 'header': case 'footer':
      case 'main': case 'aside': case 'figure': case 'dl': case 'dd': case 'dt': case 'details':
      case 'summary': case 'address':
        return block(children(node, ctx));
      case 'br':
        return '\n';
      case 'hr':
        return '\n\n---\n\n';
      case 'strong': case 'b': {
        const text = children(node, ctx);
        return text.trim() ? `**${text.trim()}**` : text;
      }
      case 'em': case 'i': case 'cite': {
        const text = children(node, ctx);
        return text.trim() ? `*${text.trim()}*` : text;
      }
      case 'del': case 's': case 'strike': {
        const text = children(node, ctx);
        return text.trim() ? `~~${text.trim()}~~` : text;
      }
      case 'code': case 'kbd': case 'samp':
        return ctx.pre ? node.textContent : '`' + node.textContent.replace(/`/g, "'") + '`';
      case 'pre': {
        const code = node.innerText !== undefined && node.isConnected ? node.innerText : node.textContent;
        const lang = (node.querySelector('code')?.className.match(/language-(\S+)/) || [])[1] || '';
        return `\n\n\`\`\`${lang}\n${code.replace(/\n+$/, '')}\n\`\`\`\n\n`;
      }
      case 'blockquote':
        return '\n\n' + children(node, ctx).trim().replace(/\n{3,}/g, '\n\n').replace(/^/gm, '> ') + '\n\n';
      case 'ul': case 'ol':
        return list(node, ctx);
      case 'li':
        return block('- ' + children(node, ctx).trim());
      case 'table':
        return table(node, ctx);
      case 'a': {
        const text = children(node, ctx).replace(/\s+/g, ' ').trim();
        const href = node.getAttribute('href');
        if (!href || href.startsWith('javascript:') || href.startsWith('#')) return text;
        if (!text) return '';
        return /^!\[/.test(text) ? text : `[${text}](${absolute(href)})`;
      }
      case 'img': {
        // Icons (portal badges, "source" pens, flags) clutter a note.
        if (isIcon(node)) return '';
        const src = imageSource(node);
        if (!src) return '';
        const alt = (node.getAttribute('alt') || '').replace(/[\[\]\n]/g, ' ').trim();
        return `![${alt}](${src})`;
      }
      case 'picture': {
        const img = node.querySelector('img');
        return img ? convert(img, ctx) : '';
      }
      case 'figcaption': {
        const text = children(node, ctx).trim();
        return text ? `\n\n*${text}*\n\n` : '';
      }
      case 'video': {
        const src = node.currentSrc || node.getAttribute('src');
        return src ? `![Video](${absolute(src)})` : '';
      }
      case 'svg': case 'canvas':
        return '';
      default:
        return children(node, ctx);
    }
  }

  function toMarkdown(node) {
    return convert(node)
      .replace(/[ \t]+\n/g, '\n')
      .replace(/\n{3,}/g, '\n\n')
      .trim();
  }


  // -------------------------------------------------------------- article

  const JUNK = 'nav, aside, footer, form, [role="navigation"], [role="complementary"], [role="contentinfo"], ' +
    '[aria-label*="share" i], [class*="share" i], [class*="social" i], [class*="related" i], ' +
    '[class*="comment" i], [id*="comment" i], [class*="newsletter" i], [class*="subscribe" i], ' +
    '[class*="advert" i], [class*="promo" i], [class*="sidebar" i], [class*="breadcrumb" i], ' +
    '.navbox, .reflist, .mw-editsection, .catlinks, .noprint, .ambox, .metadata';

  function textLength(node) {
    return (node.innerText || node.textContent || '').replace(/\s+/g, ' ').trim().length;
  }

  // The element holding the page's main text: the parent of the most
  // paragraph text, widened until it holds most of the page's paragraphs,
  // then to the article around it (its title and byline).
  function mainContent() {
    const scores = new Map();
    let total = 0;
    const paragraphs = [];
    for (const p of document.querySelectorAll('p, pre, blockquote')) {
      const length = textLength(p);
      if (length < 40 || isHidden(p) || p.closest('nav, aside, footer')) continue;
      paragraphs.push([p, length]);
      total += length;
      const parent = p.parentElement, grandparent = parent && parent.parentElement;
      if (parent) scores.set(parent, (scores.get(parent) || 0) + length);
      if (grandparent) scores.set(grandparent, (scores.get(grandparent) || 0) + length / 2);
    }
    let top = null, topScore = 0;
    for (const [node, score] of scores) if (score > topScore) { top = node; topScore = score; }
    if (!top) return document.querySelector('article, main, [role="main"]') || document.body;

    const covered = (node) => paragraphs.reduce((sum, [p, length]) => sum + (node.contains(p) ? length : 0), 0);
    while (top.parentElement && top !== document.body && covered(top) < total * 0.6) top = top.parentElement;
    return top.closest('[itemprop="articleBody"], article') || top;
  }

  function meta(name) {
    const el = document.querySelector(`meta[property="${name}"], meta[name="${name}"]`);
    return el ? (el.getAttribute('content') || '').trim() : '';
  }

  function pageTitle() {
    return meta('og:title') || document.title.trim() || location.href;
  }

  function article() {
    const root = mainContent();
    skipped = new WeakSet();
    for (const node of root.querySelectorAll(JUNK)) {
      // Never drop most of the article because of a loose class name.
      if (textLength(node) < textLength(root) / 2) skipped.add(node);
    }
    let markdown = toMarkdown(root);
    skipped = new WeakSet();
    const title = pageTitle();
    const h1 = document.querySelector('h1');
    const headline = (h1 && textLength(h1) < 300 && h1.innerText.trim()) || title;
    if (!/^# /.test(markdown)) markdown = `# ${escapeText(headline.replace(/\s+/g, ' '))}\n\n${markdown}`;
    return { kind: 'article', markdown, text: (meta('description') || meta('og:description') || '').slice(0, 600), title };
  }

  // ------------------------------------------------------------- selection

  function selection() {
    const sel = getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null;
    const parts = [];
    for (let i = 0; i < sel.rangeCount; i++) {
      const range = sel.getRangeAt(i);
      parts.push(toMarkdown(range.cloneContents()) || escapeText(range.toString()));
    }
    const markdown = parts.join('\n\n').trim();
    if (!markdown) return null;
    return { kind: 'selection', markdown, text: sel.toString().trim().slice(0, 600), title: document.title };
  }

  // ----------------------------------------------------------------- image

  function image(src) {
    const img = Array.from(document.images).find((i) => i.currentSrc === src || i.src === src);
    const alt = img ? (img.getAttribute('alt') || '').replace(/[\[\]\n]/g, ' ').trim() : '';
    const figure = img && img.closest('figure');
    const markdown = figure && figure.querySelector('figcaption') ? toMarkdown(figure) : `![${alt}](${src})`;
    return { kind: 'image', markdown, text: alt, title: document.title };
  }

  window.__gleaClip = {
    selection,
    article,
    image,
    hasSelection: () => !!getSelection() && !getSelection().isCollapsed && getSelection().toString().trim().length > 0,
    title: pageTitle,
  };
})();
