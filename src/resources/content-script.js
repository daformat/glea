// Point-and-shoot: injected into every page's main frame before page scripts.
//
// The browser toggles the mode with __gleaPNS.setActive(bool) while the
// Option key is held. The page dims and a spotlight morphs onto the block
// under the cursor (or the text selection). Clicking presses the spotlight
// down and "shoots": the block is converted to Markdown and posted with
// __gleaNative.post("capture", json). Dragging captures a rectangular area
// as a screenshot instead ("captureArea").
//
// The visual design follows Beam: the page stays as is, and a translucent
// purple overlay (no outline) morphs onto the target.
(() => {
  'use strict';
  // Chromium's own error page: keep it blank (in Glea's background color).
  // The app shows its own error view, and this avoids a flash of both.
  if (location.protocol === 'chrome-error:') {
    // The document is still empty here; an adopted sheet applies before the
    // first paint anyway.
    const sheet = new CSSStyleSheet();
    sheet.replaceSync('html { background: #fff !important; } body { display: none !important; }' +
      '@media (prefers-color-scheme: dark) { html { background: #1c1c1f !important; } }');
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    return;
  }
  if (window.__gleaPNS || typeof __gleaNative === 'undefined') return;
  const native = __gleaNative;

  // ------------------------------------------------------------------ state

  const pointer = { x: -1, y: -1 };
  let active = false;       // Option is held
  let locked = false;       // a capture is waiting for the app's answer
  let pressed = false;
  let pressPoint = null;
  let dragging = false;
  let target = null;        // Element | Range
  let rect = null;          // spotlight rect for the target (viewport coords)
  let blank = true;         // spotlight is a dot following the pointer
  let container = null;
  let cursorStyle = null;
  let hideTimer = 0;
  let scrollTimer = 0;
  let swallowClick = 0;
  let textOnly = false;     // ⌘ is held too: posts and videos are plain content

  // ---------------------------------------------------------------- overlay

  const CSS = `
    :host { all: initial; }
    .root {
      --x: -20px; --y: -20px; --w: 4px; --h: 4px; --scale: 1; --dx: 0px; --dy: 0px;
      /* Short, so the wash keeps up with the pointer. */
      --duration: 110ms;
      --ease: cubic-bezier(0.32, 0.72, 0, 1);
      --spring: linear(0, 0.009, 0.035 2.1%, 0.141, 0.281 6.7%, 0.723 12.9%, 0.938 16.7%, 1.017,
                1.077, 1.121, 1.149 24.3%, 1.159, 1.163, 1.161, 1.154 29.9%, 1.129 32.8%,
                1.051 39.6%, 1.017 43.1%, 0.991, 0.977 51%, 0.974 53.8%, 0.975 57.1%,
                0.997 69.8%, 1.003 76.9%, 1);
      pointer-events: none;
    }
    .portal, .outline-portal {
      position: fixed; inset: 0; pointer-events: none; z-index: 2147483647;
      transition: background-color 160ms ease-out, opacity 200ms ease-out;
    }
    /* The page isn't dimmed: only the outline portal draws. */
    .portal { display: none; }
    .root.leaving .portal, .root.leaving .outline-portal { opacity: 0; }

    .shift { transform: translate(var(--dx), var(--dy)); transition: transform 50ms linear; }

    .area {
      --pad: 5px; --border: 0px;
      position: absolute; left: 0; top: 0; box-sizing: border-box;
      width: calc(var(--w) + 2 * (var(--pad) + var(--border)));
      height: calc(var(--h) + 2 * (var(--pad) + var(--border)));
      transform:
        translate(calc(var(--x) - var(--pad) - var(--border)), calc(var(--y) - var(--pad) - var(--border)))
        scale(var(--scale));
      transform-origin: center;
      border-radius: 8px;
      opacity: 0;
      transition:
        transform var(--duration) var(--ease),
        width var(--duration) var(--ease),
        height var(--duration) var(--ease),
        border-radius var(--duration) var(--ease),
        opacity 160ms ease-out;
      will-change: transform, width, height;
    }
    .root.on .area { opacity: 1; }
    .root.blank .area { border-radius: 4px; }
    /* With nothing targeted, the dot sits under the pointer: no easing. */
    .root.blank .area { transition: opacity 160ms ease-out; }
    /* The dot morphs into the first element it points at, and back when the
       pointer leaves it: frame, corners and tint together, a little longer
       than moves between elements. */
    .root.morphing .area {
      transition: transform 240ms var(--ease), width 240ms var(--ease), height 240ms var(--ease),
                  border-radius 240ms var(--ease), background-color 240ms ease-out, opacity 160ms ease-out;
    }
    .outline-portal .area {
      background: rgba(112, 88, 255, 0.2);
      border-radius: 8px;
    }
    .root.blank .outline-portal .area { border-radius: 6px; background: rgba(112, 88, 255, 0.5); }
    .root.pressed .outline-portal .area { background: rgba(112, 88, 255, 0.3); }

    /* Press down, then spring back when released. */
    .root.pressed { --scale: 0.95; }
    .root.pressed .area { transition-duration: var(--duration), var(--duration), var(--duration), var(--duration), 160ms;
                          transition-timing-function: cubic-bezier(0.3, 0, 0.5, 1); }
    .root.released .area { transition: transform 520ms var(--spring), width var(--duration) var(--ease),
                           height var(--duration) var(--ease), opacity 160ms ease-out; }
    .root.dragging .area { transition: none; }
    .root.capturing .portal, .root.capturing .outline-portal { visibility: hidden; transition: none; }
    .root.scrolling .area, .root.scrolling .shift { transition: none; }

    /* A text selection (Beam's): each line lit, padded 4px with 4px corners,
       all in one wash (the opacity is the group's, so overlaps don't darken). */
    .lines { position: absolute; inset: 0; opacity: 0; transition: opacity 160ms ease-out; }
    .line { position: absolute; border-radius: 4px; background: rgb(112, 88, 255); }
    .root.selection .outline-portal .area { display: none; }
    .root.selection.on .lines { opacity: .2; }
    .root.selection.shot .lines { animation: glea-lines-flash 420ms ease-out; }
    @keyframes glea-lines-flash { 0% { opacity: .5; } 100% { opacity: .2; } }

    /* The "shoot": a flash of light inside the captured area. */
    .flash { position: absolute; inset: 0; border-radius: inherit; background: rgba(160, 140, 255, 1); opacity: 0; }
    .root.shot .outline-portal .flash { animation: glea-flash 420ms ease-out; }
    @keyframes glea-flash { 0% { opacity: .55; } 100% { opacity: 0; } }

    .root.error .shift { animation: glea-shake 0.82s cubic-bezier(.36,.07,.19,.97) both; }
    @keyframes glea-shake {
      10%, 90% { transform: translate3d(-1px, 0, 0); }
      20%, 80% { transform: translate3d(2px, 0, 0); }
      30%, 50%, 70% { transform: translate3d(-4px, 0, 0); }
      40%, 60% { transform: translate3d(4px, 0, 0); }
    }

    .badge {
      position: fixed; left: 0; top: 0; z-index: 2147483647;
      transform: translate(var(--bx), var(--by)) scale(.9); transform-origin: left top;
      opacity: 0; padding: 5px 10px 5px 8px; border-radius: 999px;
      display: flex; align-items: center; gap: 6px; white-space: nowrap;
      font: 600 12px/16px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      color: #fff; background: rgba(28, 28, 32, .92);
      box-shadow: 0 4px 14px rgba(0,0,0,.18), 0 1px 2px rgba(0,0,0,.2);
      transition: opacity 180ms ease-out, transform 420ms var(--spring);
    }
    .badge.show { opacity: 1; transform: translate(var(--bx), var(--by)) scale(1); }
    .badge svg { width: 14px; height: 14px; flex: none; }
    .badge path { stroke-dasharray: 16; stroke-dashoffset: 16; transition: stroke-dashoffset 320ms 120ms ease-out; }
    .badge.show path { stroke-dashoffset: 0; }
  `;

  function el(tag, className, parent) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (parent) parent.appendChild(node);
    return node;
  }

  function svgEl(tag, attributes, parent) {
    const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
    for (const [name, value] of Object.entries(attributes)) node.setAttribute(name, value);
    parent.appendChild(node);
    return node;
  }

  function ensureOverlay() {
    if (container && container.isConnected) return;
    // display:contents keeps the host from creating a stacking context, so the
    // portal's multiply blend mixes with the page itself.
    const host = document.createElement('glea-pns');
    // all: initial undoes page rules that reach it, like Reddit's
    // ":not(:defined) { visibility: hidden }" (it's never a defined element).
    host.style.cssText = 'all: initial !important; display: contents !important;';
    const shadow = host.attachShadow({ mode: 'closed' });
    el('style', null, shadow).textContent = CSS;
    container = el('div', 'root blank', shadow);
    for (const portalClass of ['portal', 'outline-portal']) {
      const portal = el('div', portalClass, container);
      const shift = el('div', 'shift', portal);
      const area = el('div', 'area', shift);
      if (portalClass === 'outline-portal') {
        el('div', 'flash', area);
        el('div', 'lines', portal);
      }
    }
    // Built node by node: pages with Trusted Types (Gmail) reject innerHTML.
    const badge = el('div', 'badge', container);
    const svg = svgEl('svg', { viewBox: '0 0 16 16', fill: 'none' }, badge);
    svgEl('circle', { cx: '8', cy: '8', r: '7.25', fill: '#34c759' }, svg);
    svgEl('path', { d: 'M4.8 8.3l2.1 2.1 4.3-4.6', stroke: '#fff', 'stroke-width': '1.7',
                    'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, svg);
    el('span', null, badge);
    (document.documentElement || document).appendChild(host);
  }

  function setVar(name, value) {
    container.style.setProperty(name, value);
  }

  function setRect(r) {
    setVar('--x', r.x + 'px');
    setVar('--y', r.y + 'px');
    setVar('--w', Math.max(0, r.width) + 'px');
    setVar('--h', Math.max(0, r.height) + 'px');
  }

  // Jump without animating (e.g. when the spotlight appears).
  function teleport(r) {
    container.classList.add('scrolling');
    setRect(r);
    void container.offsetHeight;
    container.classList.remove('scrolling');
  }

  function setBlank() {
    blank = true;
    target = null;
    rect = null;
    container.classList.add('blank');
    setRect({ x: pointer.x - 2, y: pointer.y - 2, width: 4, height: 4 });
    setVar('--dx', '0px');
    setVar('--dy', '0px');
  }

  // Leans the spotlight a few pixels towards the pointer (Kosmik's displacement).
  function displacement(r) {
    const cx = r.x + r.width / 2;
    const cy = r.y + r.height / 2;
    const rx = (pointer.x - cx) / ((r.width + 10) / 2);
    const ry = (pointer.y - cy) / ((r.height + 10) / 2);
    const { sign, min, sqrt, abs } = Math;
    return { x: sign(rx) * min(sqrt(abs(rx)) * 4, 4), y: sign(ry) * min(sqrt(abs(ry)) * 2, 2) };
  }

  function withinGrace(r) {
    return r && r.x - pointer.x < 20 && pointer.x - (r.x + r.width) < 20 &&
      r.y - pointer.y < 20 && pointer.y - (r.y + r.height) < 20;
  }

  // ------------------------------------------------------------- targeting

  // Elements with no text of their own that are still worth capturing whole.
  const MEDIA_TAGS = new Set(['VIDEO', 'IFRAME', 'EMBED', 'OBJECT', 'CANVAS', 'PICTURE']);
  // Never rendered: not worth walking into.
  const SKIP_TAGS = new Set(['SCRIPT', 'STYLE', 'NOSCRIPT', 'TEMPLATE', 'LINK', 'META']);
  // Text counts once it has a letter or a digit (any script): bullets,
  // dashes, pipes and middle dots alone are decoration.
  const MEANINGFUL = /[\p{L}\p{N}]/u;
  // Per-call node budgets, so pointer moves stay cheap on huge subtrees.
  const PROBE_BUDGET = 300;
  const BOUNDS_BUDGET = 600;
  const BOUNDS_DEPTH = 24;

  function textOf(node) {
    return (node instanceof HTMLElement ? node.innerText : node && node.textContent) || '';
  }

  function backgroundImage(element) {
    const m = getComputedStyle(element).backgroundImage.match(/url\(\s*(['"]?)(.*?)\1\s*\)/);
    return m && m[2] ? m[2] : null;
  }

  function isSVG(element) {
    return element instanceof SVGSVGElement;
  }

  // Taken whole by the spotlight: their pixels are the content.
  function isWhole(element) {
    return element.tagName === 'IMG' || isSVG(element) || MEDIA_TAGS.has(element.tagName);
  }

  function plain(r) {
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  }

  // A node's first children (at most `limit`), its open shadow root first.
  function childrenOf(node, limit) {
    const kids = node.shadowRoot ? [node.shadowRoot] : [];
    for (let c = node.firstChild; c && kids.length < limit; c = c.nextSibling) kids.push(c);
    return kids;
  }

  // Depth-first over root's descendants (open shadow roots included) until
  // test() returns true; 'skip' prunes a subtree. null: budget ran out first.
  function findContent(root, test, budget) {
    const stack = [root];
    while (stack.length) {
      if (--budget < 0) return null;
      const node = stack.pop();
      const result = node === root ? false : test(node);
      if (result === true) return true;
      if (result === 'skip' || (node.nodeType === 1 && SKIP_TAGS.has(node.tagName))) continue;
      stack.push(...childrenOf(node, budget).reverse());
    }
    return false;
  }

  // display:none or fully transparent subtrees show nothing.
  function prunes(element) {
    const style = getComputedStyle(element);
    return style.display === 'none' || style.opacity === '0';
  }

  function hasMeaningfulText(element) {
    const found = findContent(element, (node) => {
      if (node.nodeType === 1) return prunes(node) ? 'skip' : false;
      if (node.nodeType !== 3 || !MEANINGFUL.test(node.data)) return false;
      const parent = node.parentElement;
      if (!parent) return true;
      // Hidden text, or screen-reader-only text squeezed into a 1px box.
      const box = parent.getBoundingClientRect();
      return getComputedStyle(parent).visibility === 'visible' && box.width > 1 && box.height > 1;
    }, PROBE_BUDGET);
    // Too big to scan: a subtree that large almost surely holds text.
    return found !== false;
  }

  function hasMedia(element) {
    return findContent(element, (node) => {
      if (node.nodeType !== 1) return false;
      if (prunes(node)) return 'skip';
      if (!isWhole(node) && !backgroundImage(node)) return false;
      const box = node.getBoundingClientRect();
      return box.width > 1 && box.height > 1 ? true : 'skip';
    }, PROBE_BUDGET) === true;
  }

  function isImage(element) {
    if (element.tagName === 'IMG' || isSVG(element)) return true;
    return !!backgroundImage(element) && !hasMeaningfulText(element);
  }

  function isMediaContainer(element) {
    if (isImage(element) || MEDIA_TAGS.has(element.tagName)) return true;
    return !hasMeaningfulText(element) && hasMedia(element);
  }

  function isMeaningful(element) {
    if (!(element instanceof Element) || element === document.body || element === document.documentElement) return false;
    if (element.closest('glea-pns')) return false;
    const box = element.getBoundingClientRect();
    if (box.width < 1 || box.height < 1) return false;
    // A wrapper covering more than 1.5 viewports, or 4 screens tall, lights
    // up most of the page: no help in picking something. A long article
    // column still passes.
    if (box.width * box.height > 1.5 * innerWidth * innerHeight || box.height > 4 * innerHeight) return false;
    const visible = element.checkVisibility
      ? element.checkVisibility({ opacityProperty: true, visibilityProperty: true })
      : !prunes(element) && getComputedStyle(element).visibility === 'visible';
    if (!visible) return false;
    if (isWhole(element)) return true;
    return hasMeaningfulText(element) || !!backgroundImage(element) || hasMedia(element);
  }

  function union(a, b) {
    if (!a) return b;
    if (!b) return a;
    const x = Math.min(a.x, b.x);
    const y = Math.min(a.y, b.y);
    return {
      x, y,
      width: Math.max(a.x + a.width, b.x + b.width) - x,
      height: Math.max(a.y + a.height, b.y + b.height) - y,
    };
  }

  // r cut down to box on the clipped axes; null when nothing is left.
  function intersect(r, box, clipX = true, clipY = true) {
    const x = clipX ? Math.max(r.x, box.x) : r.x;
    const y = clipY ? Math.max(r.y, box.y) : r.y;
    const right = clipX ? Math.min(r.x + r.width, box.x + box.width) : r.x + r.width;
    const bottom = clipY ? Math.min(r.y + r.height, box.y + box.height) : r.y + r.height;
    return right - x > 0 && bottom - y > 0 ? { x, y, width: right - x, height: bottom - y } : null;
  }

  // Folds a clipping element (overflow other than visible) into clip.
  function clipBy(clip, element, style) {
    const clipX = style.overflowX !== 'visible';
    const clipY = style.overflowY !== 'visible';
    if (!clipX && !clipY) return clip;
    const box = element.getBoundingClientRect();
    const far = { x: -1e7, y: -1e7, width: 2e7, height: 2e7 };
    return intersect(clip || far, box, clipX, clipY) || { x: box.x, y: box.y, width: 0, height: 0 };
  }

  // The visible area left by the element's scrolling/clipping ancestors
  // (a carousel, a sidebar). The body's overflow is the viewport's: skipped.
  function ancestorClip(element) {
    let clip = null;
    let fixed = getComputedStyle(element).position === 'fixed';
    for (let a = parentOf(element), i = 0; a && !fixed && i < 50; a = parentOf(a), i++) {
      if (a === document.body || a === document.documentElement) break;
      const style = getComputedStyle(a);
      clip = clipBy(clip, a, style);
      // Past a fixed element, ancestors no longer clip (roughly).
      fixed = style.position === 'fixed';
    }
    return clip;
  }

  // The extent of what's rendered inside root: its text runs and media,
  // each clipped by the overflow of elements in between. null when the
  // subtree is too big to measure (or shows nothing).
  function contentBounds(root) {
    const range = document.createRange();
    const stack = [[root, null, 0, false]];
    let budget = BOUNDS_BUDGET;
    let raw = null;
    let clipped = null;
    while (stack.length) {
      if (--budget < 0) return null;
      const [node, clip, depth, hidden] = stack.pop();
      let r = null;
      let leaf = false;
      let kidClip = clip;
      let kidHidden = hidden;
      if (node.nodeType === 3) {
        if (hidden || !/\S/.test(node.data)) continue;
        range.selectNodeContents(node);
        r = range.getBoundingClientRect();
        leaf = true;
      } else if (node.nodeType === 1) {
        if (SKIP_TAGS.has(node.tagName)) continue;
        const style = getComputedStyle(node);
        if (style.display === 'none' || style.opacity === '0') continue;
        kidHidden = style.visibility !== 'visible';
        // Media whole; past the depth limit, a box stands in for its content.
        leaf = isWhole(node) || depth >= BOUNDS_DEPTH;
        if (!kidHidden && (leaf || style.backgroundImage.includes('url('))) r = node.getBoundingClientRect();
        if (!leaf) kidClip = clipBy(clip, node, style);
      }
      if (r && r.width > 0 && r.height > 0) {
        raw = union(raw, plain(r));
        const c = clip ? intersect(r, clip) : r;
        if (c && c.width > 1 && c.height > 1) clipped = union(clipped, plain(c));
      }
      if (leaf) continue;
      const kids = childrenOf(node, budget);
      for (let i = kids.length - 1; i >= 0; i--) stack.push([kids[i], kidClip, depth + 1, kidHidden]);
    }
    return clipped || raw;
  }

  function boundsFor(target) {
    if (target instanceof Range) {
      const r = target.getBoundingClientRect();
      return r.width > 0 || r.height > 0 ? plain(r) : null;
    }
    if (!(target instanceof Element) || !target.isConnected) return null;
    const own = plain(target.getBoundingClientRect());
    // A post or video is taken whole, like media.
    const whole = isWhole(target) || (!textOnly && embedTargets.has(target));
    const content = (!whole && contentBounds(target)) || own;
    if (content.width <= 0 || content.height <= 0) return null;
    const outer = ancestorClip(target);
    // Clipped away entirely: better the unclipped box than nothing.
    return (outer && intersect(content, outer)) || content;
  }

  function selectionRange() {
    const sel = window.getSelection();
    if (!sel || sel.isCollapsed || !sel.rangeCount || !sel.toString().trim()) return null;
    return sel.getRangeAt(0);
  }

  // elementsFromPoint stops at open shadow roots (web components): look
  // inside them too, innermost first.
  function elementsAtPointer() {
    let stack = document.elementsFromPoint(pointer.x, pointer.y);
    for (let host = stack[0], depth = 0; host && host.shadowRoot && depth < 8; depth++) {
      const inner = host.shadowRoot.elementsFromPoint(pointer.x, pointer.y).filter((n) => !stack.includes(n));
      if (!inner.length) break;
      stack = inner.concat(stack);
      host = inner[0];
    }
    return stack.filter((node) => node !== document.body && node.tagName !== 'GLEA-PNS');
  }

  function parentOf(node) {
    return node.parentElement || (node.parentNode instanceof ShadowRoot ? node.parentNode.host : null);
  }

  // A word inside a paragraph (an inline <span>, <a>, <em>...) targets its
  // paragraph: the block is what's worth capturing.
  function blockFor(node) {
    let current = node;
    for (let i = 0; i < 12; i++) {
      if (isImage(current) || MEDIA_TAGS.has(current.tagName)) break;
      const display = getComputedStyle(current).display;
      if (display !== 'inline' && display !== 'contents') break;
      const parent = parentOf(current);
      if (!parent || parent === document.body || parent === document.documentElement || !isMeaningful(parent)) break;
      current = parent;
    }
    return current;
  }

  // ------------------------------------------------------------- embeds

  // Posts and videos the notes can embed again (YouTube, X, Bluesky,
  // Instagram): pointing anywhere over one spotlights all of it, and
  // collecting it keeps its address, which the note shows as an embed.
  const embedTargets = new WeakMap();  // element → its post or video URL

  const YOUTUBE_ITEMS = 'ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ' +
    'ytd-grid-video-renderer, ytd-playlist-video-renderer, ytd-reel-item-renderer, yt-lockup-view-model, ' +
    'ytm-shorts-lockup-view-model, ytm-video-with-context-renderer, ytm-compact-video-renderer';

  function siteHost() {
    return location.hostname.replace(/^(?:www|mobile|m)\./, '');
  }

  // The first link inside `node` to a page of `hosts` whose path matches.
  function linkIn(node, hosts, path) {
    for (const a of node.querySelectorAll('a[href]')) {
      let url;
      try { url = new URL(a.getAttribute('href'), location.href); } catch (err) { continue; }
      if (hosts.test(url.hostname) && path.test(url.pathname)) return url;
    }
    return null;
  }

  function youtubeURL(url) {
    if (!url) return null;
    const shorts = url.pathname.match(/^\/shorts\/([\w-]+)/);
    if (shorts) return `https://www.youtube.com/shorts/${shorts[1]}`;
    const id = url.searchParams.get('v');
    return id ? `https://www.youtube.com/watch?v=${id}` : null;
  }

  // The post or video `node` is, on these sites or embedded elsewhere.
  function embedOf(node) {
    const tag = node.tagName;
    // Embeds on other sites, before (or without) their script: the quote.
    if (tag === 'BLOCKQUOTE') {
      if (node.classList.contains('twitter-tweet')) {
        const links = Array.from(node.querySelectorAll('a[href*="/status/"]'));
        return links.length ? links[links.length - 1].href.split('?')[0] : null;
      }
      if (node.classList.contains('bluesky-embed')) {
        const m = (node.dataset.blueskyUri || '').match(/^at:\/\/([^/]+)\/app\.bsky\.feed\.post\/(\w+)/);
        if (m) return `https://bsky.app/profile/${m[1]}/post/${m[2]}`;
        const link = linkIn(node, /(^|\.)bsky\.app$/, /^\/profile\/[^/]+\/post\/\w+\/?$/);
        return link ? link.href : null;
      }
      if (node.classList.contains('instagram-media')) {
        const permalink = node.dataset.instgrmPermalink;
        return permalink ? permalink.split('?')[0] : null;
      }
      return null;
    }
    const host = siteHost();
    if ((host === 'x.com' || host === 'twitter.com') && tag === 'ARTICLE') {
      // The post's own address is the link around its timestamp.
      const time = node.querySelector('a[href*="/status/"] time');
      if (time) return time.closest('a').href.split('?')[0];
      const link = linkIn(node, /(^|\.)(x|twitter)\.com$/, /^\/\w+\/status\/\d+\/?$/);
      if (link) return link.href;
      // The post a status page is about has no link to itself.
      return /^\/\w+\/status\/\d+\/?$/.test(location.pathname) ? location.origin + location.pathname : null;
    }
    if (host === 'bsky.app' && node.matches('[data-testid^="feedItem-by-"], [data-testid^="postThreadItem-by-"]')) {
      const link = linkIn(node, /(^|\.)bsky\.app$/, /^\/profile\/[^/]+\/post\/\w+\/?$/);
      if (link) return link.href;
      return /^\/profile\/[^/]+\/post\/\w+\/?$/.test(location.pathname) ? location.origin + location.pathname : null;
    }
    if (host === 'instagram.com' && tag === 'ARTICLE') {
      const link = linkIn(node, /(^|\.)instagram\.com$/, /^\/(?:[\w.]+\/)?(?:p|reel|tv)\/[\w-]+\/?$/);
      const path = link ? link.pathname : location.pathname;
      const m = path.match(/\/(p|reel|tv)\/([\w-]+)/);
      return m ? `https://www.instagram.com/${m[1]}/${m[2]}/` : null;
    }
    if (host === 'youtube.com') {
      // The player: the video being watched. A thumbnail or list item: its video.
      if (node.matches('#movie_player, .html5-video-player, #player-container-id')) return youtubeURL(new URL(location.href));
      if (node.matches(YOUTUBE_ITEMS)) return youtubeURL(linkIn(node, /(^|\.)youtube\.com$/, /^\/(?:watch|shorts\/)/));
    }
    return null;
  }

  // The post or video around `start` (itself or an ancestor), if any.
  function findEmbed(start) {
    for (let node = start, depth = 0; node && node !== document.body && depth < 40; node = parentOf(node), depth++) {
      if (!(node instanceof Element)) continue;
      const url = embedOf(node);
      if (url) return { node, url };
    }
    return null;
  }

  function elementAtPointer() {
    const stack = elementsAtPointer();
    // Through empty layers (a dialog's backdrop, a transparent link), up to
    // the first element with something of its own to show.
    for (const node of textOnly ? [] : stack) {
      const hit = findEmbed(node);
      if (hit && hit.node.getBoundingClientRect().width > 0) {
        embedTargets.set(hit.node, hit.url);
        return hit.node;
      }
      if (isMeaningful(node)) break;
    }
    const meaningful = stack.filter(isMeaningful);
    // Prefer images under the pointer (an <img> over other image-likes).
    const images = meaningful.filter(isImage).sort((a, b) => (a.tagName === 'IMG' ? -1 : 1) - (b.tagName === 'IMG' ? -1 : 1));
    const pick = images[0] || meaningful.find((n) => MEDIA_TAGS.has(n.tagName)) || meaningful[0];
    if (!pick) return null;
    if (pick.closest('svg') && pick.tagName.toLowerCase() !== 'svg') return pick.closest('svg');
    return blockFor(pick);
  }

  let morphTimer = null;

  // How long the pointer must rest on the current target's container before
  // the wash moves to it.
  const CONTAINER_DWELL = 180;
  let containerCandidate = null;
  let containerSince = 0;
  let containerTimer = null;

  function isContainerOfTarget(node) {
    return target instanceof Element && node instanceof Element && node !== target && node.contains(target);
  }

  // Morphs between the dot and an element's wash (either way) for a moment.
  function morph() {
    container.classList.add('morphing');
    clearTimeout(morphTimer);
    morphTimer = setTimeout(() => container && container.classList.remove('morphing'), 260);
  }

  function update() {
    if (!active || locked || !container) return;
    if (dragging) return;
    const range = selectionRange();
    let next = range || elementAtPointer();
    // Crossing the gaps between small siblings (a row of icons) lands on
    // their container for a moment: keep the current target unless the
    // pointer rests there, so the wash doesn't balloon between each one.
    if (next && isContainerOfTarget(next)) {
      if (containerCandidate !== next) {
        containerCandidate = next;
        clearTimeout(containerTimer);
        containerTimer = setTimeout(update, CONTAINER_DWELL);
        containerSince = performance.now();
      }
      if (performance.now() - containerSince < CONTAINER_DWELL) next = target;
    } else {
      containerCandidate = null;
      clearTimeout(containerTimer);
    }
    if (next && next !== target) {
      const r = boundsFor(next);
      if (r && r.width > 0 && r.height > 0) {
        if (blank) {
          teleport({ x: pointer.x - 2, y: pointer.y - 2, width: 4, height: 4 });
          morph();
        }
        target = next;
        rect = r;
        blank = false;
        container.classList.remove('blank');
        setRect(r);
      }
    } else if (!next && !withinGrace(rect)) {
      // Leaving an element: the wash shrinks back into the dot.
      if (!blank) morph();
      setBlank();
    }
    if (blank) {
      setRect({ x: pointer.x - 2, y: pointer.y - 2, width: 4, height: 4 });
    } else if (rect) {
      const d = displacement(rect);
      setVar('--dx', d.x + 'px');
      setVar('--dy', d.y + 'px');
    }
  }

  // --------------------------------------------------------------- activation

  function activate() {
    clearTimeout(hideTimer);
    ensureOverlay();
    container.classList.remove('leaving', 'error', 'shot', 'released', 'selection');
    clearLines();
    // Text selected: ⌥ collects it at once (Beam), no click.
    const range = selectionRange();
    if (range) {
      shootSelection(range);
      return;
    }
    if (!cursorStyle) {
      cursorStyle = document.createElement('style');
      cursorStyle.textContent = '* { cursor: pointer !important; }';
      (document.head || document.documentElement).appendChild(cursorStyle);
    }
    target = null;
    setBlank();
    teleport({ x: pointer.x - 2, y: pointer.y - 2, width: 4, height: 4 });
    requestAnimationFrame(() => {
      container.classList.add('on');
      update();
    });
  }

  // ------------------------------------------------------ selected text

  // The selection's lines: its client rects, those on the same line merged.
  function lineRects(range) {
    const lines = [];
    for (const r of Array.from(range.getClientRects())) {
      if (r.width < 1 || r.height < 1) continue;
      const mid = r.y + r.height / 2;
      const line = lines.find((l) => Math.abs(l.y + l.height / 2 - mid) < Math.min(l.height, r.height) / 2);
      if (line) Object.assign(line, union(line, { x: r.x, y: r.y, width: r.width, height: r.height }));
      else lines.push({ x: r.x, y: r.y, width: r.width, height: r.height });
    }
    return lines;
  }

  function drawLines(range) {
    const layer = container && container.querySelector('.lines');
    if (!layer) return;
    const lines = lineRects(range);
    while (layer.children.length > lines.length) layer.lastChild.remove();
    while (layer.children.length < lines.length) el('div', 'line', layer);
    lines.forEach((r, i) => {
      const style = layer.children[i].style;
      style.left = (r.x - 4) + 'px';
      style.top = (r.y - 4) + 'px';
      style.width = (r.width + 8) + 'px';
      style.height = (r.height + 8) + 'px';
    });
  }

  function clearLines() {
    const layer = container && container.querySelector('.lines');
    if (layer) layer.replaceChildren();
  }

  // Lights the selection's lines and collects it (the app shows its card).
  function shootSelection(range) {
    target = range;
    rect = boundsFor(range);
    blank = false;
    container.classList.remove('blank');
    container.classList.add('selection');
    drawLines(range);
    requestAnimationFrame(() => {
      if (!container) return;
      container.classList.add('on');
      shoot();
    });
    captureTarget();
  }

  function deactivate() {
    if (cursorStyle) {
      cursorStyle.remove();
      cursorStyle = null;
    }
    pressed = false;
    dragging = false;
    if (!container) return;
    container.classList.remove('on', 'pressed', 'dragging');
    container.classList.add('leaving');
    clearTimeout(hideTimer);
    hideTimer = setTimeout(() => {
      if (active || locked || !container) return;
      container.getRootNode().host.remove();
      container = null;
    }, 260);
  }

  function errorFeedback() {
    container.classList.remove('error');
    void container.offsetWidth;
    container.classList.add('error');
  }

  function shoot() {
    container.classList.remove('shot');
    void container.offsetWidth;
    container.classList.add('shot');
  }

  function showBadge(message) {
    if (!container) return;
    const badge = container.querySelector('.badge');
    badge.querySelector('span').textContent = message;
    const r = rect || { x: pointer.x, y: pointer.y, width: 0, height: 0 };
    const below = r.y + r.height + 12;
    const y = below + 30 < innerHeight ? below : Math.max(8, r.y - 38);
    badge.style.setProperty('--bx', Math.max(8, Math.min(r.x, innerWidth - 220)) + 'px');
    badge.style.setProperty('--by', y + 'px');
    badge.classList.remove('show');
    void badge.offsetWidth;
    badge.classList.add('show');
  }

  // -------------------------------------------------------- HTML -> Markdown

  const SKIP = new Set(['script', 'style', 'noscript', 'template', 'button', 'input', 'select',
    'textarea', 'form', 'nav', 'iframe', 'object', 'embed', 'glea-pns', 'dialog']);

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
    if (SKIP.has(tag) || node.getAttribute('aria-hidden') === 'true' || isHidden(node)) return '';
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

  // ---------------------------------------------------------------- capture

  function post(name, payload) {
    locked = true;
    native.post(name, JSON.stringify(Object.assign({
      url: location.href,
      title: document.title,
    }, payload)));
  }

  function rectPayload(r) {
    return r ? { x: r.x, y: r.y, width: r.width, height: r.height } : null;
  }

  // Player addresses back to the page people share (the notes recognise those).
  function embedURL(src) {
    let m = src.match(/youtube(?:-nocookie)?\.com\/embed\/([\w-]+)/);
    if (m) return `https://www.youtube.com/watch?v=${m[1]}`;
    m = src.match(/player\.vimeo\.com\/video\/(\d+)/);
    if (m) return `https://vimeo.com/${m[1]}`;
    m = src.match(/open\.spotify\.com\/embed\/(\w+)\/(\w+)/);
    if (m) return `https://open.spotify.com/${m[1]}/${m[2]}`;
    m = src.match(/platform\.twitter\.com\/embed\/Tweet\.html\?(?:.*&)?id=(\d+)/);
    if (m) return `https://twitter.com/i/status/${m[1]}`;
    m = src.match(/embed\.bsky\.app\/embed\/([^/]+)\/app\.bsky\.feed\.post\/(\w+)/);
    if (m) return `https://bsky.app/profile/${decodeURIComponent(m[1])}/post/${m[2]}`;
    m = src.match(/instagram\.com\/(p|reel|tv)\/([\w-]+)/);
    if (m) return `https://www.instagram.com/${m[1]}/${m[2]}/`;
    return src;
  }

  // Captures the area as an image: hides the overlay so it isn't in the
  // picture; the app calls shotTaken() once it has the pixels.
  function captureScreenshot(area) {
    if (!area || area.width < 4 || area.height < 4) return false;
    locked = true;
    container.classList.add('capturing');
    requestAnimationFrame(() => requestAnimationFrame(() => post('captureArea', {
      rect: rectPayload(area),
      page: { x: area.x + scrollX, y: area.y + scrollY, width: area.width, height: area.height },
      viewport: { width: innerWidth, height: innerHeight },
    })));
    return 'screenshot';
  }

  function captureTarget() {
    if (!target) return false;
    if (target instanceof Range) {
      const markdown = toMarkdown(target.cloneContents()) || escapeText(target.toString());
      post('capture', { kind: 'selection', markdown, text: target.toString().trim().slice(0, 600), rect: rectPayload(rect) });
      return true;
    }
    const node = target;
    const embed = !textOnly && embedTargets.get(node);
    if (embed) {
      post('capture', { kind: 'element', markdown: embed, text: (textOf(node) || '').trim().slice(0, 600), rect: rectPayload(rect) });
      return true;
    }
    if (node.tagName === 'IFRAME') {
      // An embedded player or post: its address (the notes embed it again).
      const src = node.src || node.getAttribute('src') || '';
      if (/^https?:/.test(src)) {
        post('capture', { kind: 'element', markdown: embedURL(src), text: node.title || '', rect: rectPayload(rect) });
        return true;
      }
      return captureScreenshot(rect);
    }
    if (node.tagName === 'CANVAS') return captureScreenshot(rect);
    const image = isMediaContainer(node);
    const img = node.tagName === 'IMG' ? node : node.querySelector('img');
    let markdown = image && img ? toMarkdown(node.tagName === 'FIGURE' ? node : img) : toMarkdown(node);
    if (!markdown && image) {
      const bg = backgroundImage(node);
      if (bg) markdown = `![](${absolute(bg)})`;
    }
    // Nothing Markdown can hold (drawings, custom widgets): keep a picture.
    if (!markdown) return captureScreenshot(rect);
    post('capture', {
      kind: image ? 'image' : 'element',
      markdown,
      text: (image ? (img && img.alt) || '' : textOf(node) || '').trim().slice(0, 600),
      rect: rectPayload(rect),
    });
    return true;
  }

  // ----------------------------------------------------------------- events

  // ⌥, alone or with ⌘ (text only).
  function optionAlone(e) {
    return e.altKey && !e.ctrlKey;
  }

  function stop(e) {
    e.preventDefault();
    e.stopImmediatePropagation();
  }

  addEventListener('pointermove', (e) => {
    pointer.x = e.clientX;
    pointer.y = e.clientY;
    // The app turns the mode on and off with the Option key, but a release
    // can go unseen (focus elsewhere, another app): trust the real key state.
    if (active && !locked && !pressed && !optionAlone(e)) {
      api.setActive(false);
      return;
    }
    if (active && !locked && e.metaKey !== textOnly) api.setTextOnly(e.metaKey);
    if (!active || locked || !container) return;
    if (pressed && pressPoint && Math.hypot(pointer.x - pressPoint.x, pointer.y - pressPoint.y) > 4) {
      // Dragging draws a free-form area to capture as an image.
      dragging = true;
      blank = false;
      target = null;
      container.classList.add('dragging');
      container.classList.remove('pressed', 'blank');
      rect = {
        x: Math.min(pressPoint.x, pointer.x),
        y: Math.min(pressPoint.y, pointer.y),
        width: Math.abs(pressPoint.x - pointer.x),
        height: Math.abs(pressPoint.y - pointer.y),
      };
      setRect(rect);
      setVar('--dx', '0px');
      setVar('--dy', '0px');
      return;
    }
    update();
  }, true);

  addEventListener('pointerdown', (e) => {
    if (active && !locked && !optionAlone(e)) {
      // Option isn't held (alone): leave capture mode and let the click through.
      api.setActive(false);
      return;
    }
    if (!active || locked || e.button !== 0) return;
    stop(e);
    pressed = true;
    pressPoint = { x: e.clientX, y: e.clientY };
    try { document.documentElement.setPointerCapture(e.pointerId); } catch (err) { /* ignore */ }
    container.classList.remove('released', 'shot', 'error');
    container.classList.add('pressed');
  }, true);

  addEventListener('pointerup', (e) => {
    if (!pressed) return;
    stop(e);
    pressed = false;
    swallowClick = performance.now();
    container.classList.remove('pressed');
    container.classList.add('released');
    if (dragging) {
      dragging = false;
      container.classList.remove('dragging');
      if (rect && rect.width > 8 && rect.height > 8) {
        // Hide the overlay so it isn't part of the screenshot; the app calls
        // shotTaken() once the pixels are captured.
        captureScreenshot(rect);
      } else {
        errorFeedback();
      }
      return;
    }
    if (!withinGrace(rect) || blank) {
      errorFeedback();
      return;
    }
    const result = captureTarget();
    if (result === true) shoot(); else if (!result) errorFeedback();
  }, true);

  for (const type of ['mousedown', 'mouseup', 'click', 'auxclick', 'dblclick', 'contextmenu']) {
    addEventListener(type, (e) => {
      // Swallow only the click that immediately follows a capture.
      if (swallowClick && (type === 'click' || type === 'dblclick')) {
        const recent = performance.now() - swallowClick < 600;
        swallowClick = 0;
        if (recent) {
          stop(e);
          return;
        }
      }
      if ((active && e.altKey) || locked) stop(e);
    }, true);
  }

  // Leaving the page (focus, tab, app) ends the mode unless a capture is pending.
  addEventListener('blur', () => { if (active && !locked) api.setActive(false); });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden && active && !locked) api.setActive(false);
  });

  addEventListener('scroll', () => {
    if (!container) return;
    // Follow scrolling instantly, then restore the morph transitions.
    container.classList.add('scrolling');
    if (locked && target) {
      rect = boundsFor(target);
      if (rect) setRect(rect);
      if (target instanceof Range && container.classList.contains('selection')) drawLines(target);
    } else if (active) {
      target = null;
      update();
    }
    clearTimeout(scrollTimer);
    scrollTimer = setTimeout(() => container && container.classList.remove('scrolling'), 40);
  }, true);

  addEventListener('resize', () => {
    if (target && container) {
      rect = boundsFor(target);
      if (rect) setRect(rect);
    }
  });

  addEventListener('keydown', (e) => {
    // A shortcut (⌥⌘→...), not ⌘ joining ⌥: leave the mode.
    if (active && !locked && (e.ctrlKey || (e.metaKey && e.key !== 'Meta'))) {
      api.setActive(false);
      return;
    }
    if (e.key === 'Escape' && (active || locked)) {
      locked = false;
      api.setActive(false);
    }
  }, true);

  const api = {
    // x/y: the pointer in the viewport, from the app, for when the page
    // hasn't seen the mouse move yet.
    setActive(on, x, y) {
      if (on && pointer.x < 0 && typeof x === 'number') {
        pointer.x = x;
        pointer.y = y;
      }
      if (locked || !!on === active) return;
      active = !!on;
      if (active) activate(); else deactivate();
    },
    // ⌘ held with ⌥: posts and videos are collected as text and images.
    setTextOnly(on) {
      if (textOnly === !!on) return;
      textOnly = !!on;
      if (active && !locked && container) {
        target = null;
        update();
      }
    },
    done(message) {
      locked = false;
      active = false;
      if (!container) return;
      // With a message, a badge confirms on the page; without, just fade out.
      if (!message) {
        deactivate();
        return;
      }
      showBadge(message);
      container.classList.remove('on');
      if (cursorStyle) {
        cursorStyle.remove();
        cursorStyle = null;
      }
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => {
        if (!container) return;
        container.querySelector('.badge').classList.remove('show');
        deactivate();
      }, 1400);
    },
    shotTaken() {
      if (!container) return;
      container.classList.remove('capturing');
      shoot();
    },
    cancel() {
      locked = false;
      active = false;
      deactivate();
    },
    collectSelection() {
      const range = selectionRange();
      if (!range) return;
      clearTimeout(hideTimer);
      ensureOverlay();
      container.classList.remove('leaving', 'error', 'shot', 'released');
      shootSelection(range);
    },
    collectImage(src) {
      const img = Array.from(document.images).find((i) => i.currentSrc === src || i.src === src);
      ensureOverlay();
      if (img) {
        target = img.closest('figure') || img;
        rect = boundsFor(target);
        captureTarget();
      } else {
        post('capture', { kind: 'image', markdown: `![](${src})`, text: '', rect: null });
      }
    },
  };
  Object.defineProperty(window, '__gleaPNS', { value: Object.freeze(api), enumerable: false });
})();
