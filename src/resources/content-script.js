// Generated from src/pns/glea-pns.ts by `pnpm build` there: edit that, not this.
"use strict";
(() => {
  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/announcer.js
  var HIDDEN = "position: fixed !important; width: 1px !important; height: 1px !important; margin: -1px !important; padding: 0 !important; border: 0 !important; overflow: hidden !important; clip-path: inset(50%) !important; white-space: nowrap !important;";
  function createAnnouncer() {
    let region = null;
    let timer = 0;
    return {
      say(message) {
        if (typeof document === "undefined" || !message) {
          return;
        }
        if (!region || !region.isConnected) {
          region = document.createElement("div");
          region.setAttribute("aria-live", "polite");
          region.setAttribute("aria-atomic", "true");
          region.setAttribute("data-point-and-shoot", "announcer");
          region.style.cssText = HIDDEN;
          (document.body || document.documentElement).appendChild(region);
        }
        region.textContent = "";
        clearTimeout(timer);
        const target = region;
        timer = window.setTimeout(() => {
          target.textContent = message;
        }, 50);
      },
      destroy() {
        clearTimeout(timer);
        region?.remove();
        region = null;
      }
    };
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/dom.js
  var HOST_TAG = "point-and-shoot";
  var SKIP_TAGS = /* @__PURE__ */ new Set([
    "SCRIPT",
    "STYLE",
    "NOSCRIPT",
    "TEMPLATE",
    "LINK",
    "META"
  ]);
  var FRAMES = "iframe, frame, embed, object";
  function parentOf(node) {
    if (node.parentElement) {
      return node.parentElement;
    }
    const parent = node.parentNode;
    return parent instanceof ShadowRoot ? parent.host : null;
  }
  function closestAcross(start, selector) {
    for (let node = start; node; node = parentOf(node)) {
      if (node.matches(selector)) {
        return node;
      }
    }
    return null;
  }
  function within(root, node) {
    if (root.nodeType === Node.DOCUMENT_NODE) {
      return node.ownerDocument === root || node === root;
    }
    for (let n = node; n; n = parentOf(n)) {
      if (n === root) {
        return true;
      }
    }
    return false;
  }
  function childrenOf(node, limit) {
    const kids = node instanceof Element && node.shadowRoot ? [node.shadowRoot] : [];
    for (let c = node.firstChild; c && kids.length < limit; c = c.nextSibling) {
      kids.push(c);
    }
    return kids;
  }
  function findContent(root, test, budget) {
    const stack = [root];
    while (stack.length) {
      if (--budget < 0) {
        return null;
      }
      const node = stack.pop();
      const result = node === root ? false : test(node);
      if (result === true) {
        return true;
      }
      if (result === "skip" || node instanceof Element && SKIP_TAGS.has(node.tagName)) {
        continue;
      }
      stack.push(...childrenOf(node, budget).reverse());
    }
    return false;
  }
  function backgroundImage(element) {
    const m = getComputedStyle(element).backgroundImage.match(/url\(\s*(['"]?)(.*?)\1\s*\)/);
    return m && m[2] ? m[2] : null;
  }
  function prunes(element) {
    const style = getComputedStyle(element);
    return style.display === "none" || style.opacity === "0";
  }
  function invisible(style) {
    return style.visibility === "hidden" || style.visibility === "collapse";
  }
  function isVisible(element) {
    if (typeof element.checkVisibility === "function") {
      return element.checkVisibility({
        opacityProperty: true,
        visibilityProperty: true
      });
    }
    return !prunes(element) && !invisible(getComputedStyle(element));
  }
  function elementsAtPoint(point, root = document) {
    const doc = root.nodeType === Node.DOCUMENT_NODE ? root : root.ownerDocument;
    if (typeof doc.elementsFromPoint !== "function") {
      return [];
    }
    let stack = doc.elementsFromPoint(point.x, point.y);
    for (let host = stack[0], depth = 0; host && host.shadowRoot && depth < 8; depth++) {
      const inner = host.shadowRoot.elementsFromPoint(point.x, point.y).filter((n) => !stack.includes(n));
      if (!inner.length) {
        break;
      }
      stack = inner.concat(stack);
      host = inner[0];
    }
    const top = stack[0];
    for (const frame2 of Array.from(doc.querySelectorAll(FRAMES)).reverse()) {
      if (stack.includes(frame2) || top && !top.contains(frame2)) {
        continue;
      }
      const r = frame2.getBoundingClientRect();
      if (point.x >= r.left && point.x < r.right && point.y >= r.top && point.y < r.bottom && isVisible(frame2)) {
        stack = [frame2, ...stack];
        break;
      }
    }
    return stack.filter((node) => node !== doc.body && node !== doc.documentElement && node.localName !== HOST_TAG && within(root, node));
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/geometry.js
  function plain(r) {
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  }
  function union(a, b) {
    if (!a) {
      return b;
    }
    if (!b) {
      return a;
    }
    const x = Math.min(a.x, b.x);
    const y = Math.min(a.y, b.y);
    return {
      x,
      y,
      width: Math.max(a.x + a.width, b.x + b.width) - x,
      height: Math.max(a.y + a.height, b.y + b.height) - y
    };
  }
  function intersect(r, box, clipX = true, clipY = true) {
    const x = clipX ? Math.max(r.x, box.x) : r.x;
    const y = clipY ? Math.max(r.y, box.y) : r.y;
    const right = clipX ? Math.min(r.x + r.width, box.x + box.width) : r.x + r.width;
    const bottom = clipY ? Math.min(r.y + r.height, box.y + box.height) : r.y + r.height;
    return right - x > 0 && bottom - y > 0 ? { x, y, width: right - x, height: bottom - y } : null;
  }
  function near(r, p, slack) {
    return !!r && r.x - p.x < slack && p.x - (r.x + r.width) < slack && r.y - p.y < slack && p.y - (r.y + r.height) < slack;
  }
  function spanning(a, b) {
    return {
      x: Math.min(a.x, b.x),
      y: Math.min(a.y, b.y),
      width: Math.abs(a.x - b.x),
      height: Math.abs(a.y - b.y)
    };
  }
  function areaRect(viewport) {
    const view = typeof window === "undefined" ? null : window;
    return {
      viewport: plain(viewport),
      page: {
        x: viewport.x + (view?.scrollX ?? 0),
        y: viewport.y + (view?.scrollY ?? 0),
        width: viewport.width,
        height: viewport.height
      },
      viewportSize: {
        width: view?.innerWidth ?? 0,
        height: view?.innerHeight ?? 0
      }
    };
  }
  function lean(r, p) {
    const cx = r.x + r.width / 2;
    const cy = r.y + r.height / 2;
    const rx = (p.x - cx) / ((r.width + 10) / 2);
    const ry = (p.y - cy) / ((r.height + 10) / 2);
    return {
      x: Math.sign(rx) * Math.min(Math.sqrt(Math.abs(rx)), 1),
      y: Math.sign(ry) * Math.min(Math.sqrt(Math.abs(ry)), 1)
    };
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/heuristics.js
  var MEDIA_TAGS = [
    "VIDEO",
    "IFRAME",
    "EMBED",
    "OBJECT",
    "CANVAS",
    "PICTURE",
    "AUDIO"
  ];
  var MEANINGFUL = /[\p{L}\p{N}]/u;
  var PROBE_BUDGET = 300;
  function isSVG(element) {
    return element instanceof SVGSVGElement;
  }
  function createHeuristics(options = {}) {
    const mediaTags = new Set((options.mediaTags ?? MEDIA_TAGS).map((t) => t.toUpperCase()));
    const maxArea = options.maxArea ?? 1.5;
    const maxHeight = options.maxHeight ?? 4;
    const root = options.root;
    const mediaTag = (el2) => mediaTags.has(el2.tagName.toUpperCase());
    const whole = (el2) => el2.tagName === "IMG" || isSVG(el2) || mediaTag(el2);
    function hasMeaningfulText(element) {
      const found = findContent(element, (node) => {
        if (node instanceof Element) {
          return prunes(node) ? "skip" : false;
        }
        if (node.nodeType !== Node.TEXT_NODE || !MEANINGFUL.test(node.data)) {
          return false;
        }
        const parent = node.parentElement;
        if (!parent) {
          return true;
        }
        const box = parent.getBoundingClientRect();
        return !invisible(getComputedStyle(parent)) && box.width > 1 && box.height > 1;
      }, PROBE_BUDGET);
      return found !== false;
    }
    function hasMedia(element) {
      return findContent(element, (node) => {
        if (!(node instanceof Element)) {
          return false;
        }
        if (prunes(node)) {
          return "skip";
        }
        if (!whole(node) && !backgroundImage(node)) {
          return false;
        }
        const box = node.getBoundingClientRect();
        return box.width > 1 && box.height > 1 ? true : "skip";
      }, PROBE_BUDGET) === true;
    }
    function image(element) {
      if (element.tagName === "IMG" || isSVG(element)) {
        return true;
      }
      return !!backgroundImage(element) && !hasMeaningfulText(element);
    }
    function media(element) {
      if (image(element) || mediaTag(element)) {
        return true;
      }
      return !hasMeaningfulText(element) && hasMedia(element);
    }
    function isPage(element) {
      const doc = element.ownerDocument;
      return element === doc.body || element === doc.documentElement;
    }
    function meaningful(element) {
      if (!(element instanceof Element) || isPage(element)) {
        return false;
      }
      if (root && !within(root, element)) {
        return false;
      }
      const box = element.getBoundingClientRect();
      if (box.width < 1 || box.height < 1) {
        return false;
      }
      if (box.width * box.height > maxArea * innerWidth * innerHeight || box.height > maxHeight * innerHeight) {
        return false;
      }
      if (!isVisible(element)) {
        return false;
      }
      if (whole(element)) {
        return true;
      }
      return hasMeaningfulText(element) || !!backgroundImage(element) || hasMedia(element);
    }
    function block2(node) {
      let current = node;
      for (let i = 0; i < 12; i++) {
        if (image(current) || mediaTag(current)) {
          break;
        }
        const display = getComputedStyle(current).display;
        if (display !== "inline" && display !== "contents") {
          break;
        }
        const parent = parentOf(current);
        if (!parent || isPage(parent) || root && !within(root, parent) || !meaningful(parent)) {
          break;
        }
        current = parent;
      }
      return current;
    }
    return { meaningful, image, media, whole, mediaTag, block: block2 };
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/bounds.js
  var BOUNDS_BUDGET = 600;
  var BOUNDS_DEPTH = 24;
  var defaults = createHeuristics();
  function clipBy(clip, element, style) {
    const clipX = style.overflowX !== "visible" && style.overflowX !== "";
    const clipY = style.overflowY !== "visible" && style.overflowY !== "";
    if (!clipX && !clipY) {
      return clip;
    }
    const box = element.getBoundingClientRect();
    const far = { x: -1e7, y: -1e7, width: 2e7, height: 2e7 };
    return intersect(clip || far, box, clipX, clipY) || {
      x: box.x,
      y: box.y,
      width: 0,
      height: 0
    };
  }
  function ancestorClip(element) {
    const doc = element.ownerDocument;
    let clip = null;
    let fixed = getComputedStyle(element).position === "fixed";
    for (let a = parentOf(element), i = 0; a && !fixed && i < 50; a = parentOf(a), i++) {
      if (a === doc.body || a === doc.documentElement) {
        break;
      }
      const style = getComputedStyle(a);
      clip = clipBy(clip, a, style);
      fixed = style.position === "fixed";
    }
    return clip;
  }
  function contentBounds(root, whole = defaults.whole) {
    const range = root.ownerDocument.createRange();
    const stack = [
      [root, null, 0, false]
    ];
    let budget = BOUNDS_BUDGET;
    let raw = null;
    let clipped = null;
    while (stack.length) {
      if (--budget < 0) {
        return null;
      }
      const [node, clip, depth, hidden] = stack.pop();
      let r = null;
      let leaf = false;
      let kidClip = clip;
      let kidHidden = hidden;
      if (node.nodeType === Node.TEXT_NODE) {
        if (hidden || !/\S/.test(node.data)) {
          continue;
        }
        range.selectNodeContents(node);
        r = range.getBoundingClientRect();
        leaf = true;
      } else if (node instanceof Element) {
        if (SKIP_TAGS.has(node.tagName)) {
          continue;
        }
        const style = getComputedStyle(node);
        if (style.display === "none" || style.opacity === "0") {
          continue;
        }
        kidHidden = invisible(style);
        leaf = whole(node) || depth >= BOUNDS_DEPTH;
        if (!kidHidden && (leaf || style.backgroundImage.includes("url("))) {
          r = node.getBoundingClientRect();
        }
        if (!leaf) {
          kidClip = clipBy(clip, node, style);
        }
      }
      if (r && r.width > 0 && r.height > 0) {
        raw = union(raw, plain(r));
        const c = clip ? intersect(r, clip) : r;
        if (c && c.width > 1 && c.height > 1) {
          clipped = union(clipped, plain(c));
        }
      }
      if (leaf) {
        continue;
      }
      const kids = childrenOf(node, budget);
      for (let i = kids.length - 1; i >= 0; i--) {
        stack.push([kids[i], kidClip, depth + 1, kidHidden]);
      }
    }
    return clipped || raw;
  }
  function boundsFor(target, whole = defaults.whole) {
    if (target.bounds) {
      return target.bounds();
    }
    const node = target.node;
    if (node instanceof Range) {
      const r = node.getBoundingClientRect();
      return r.width > 0 || r.height > 0 ? plain(r) : null;
    }
    if (!node.isConnected) {
      return null;
    }
    const own = plain(node.getBoundingClientRect());
    const isWhole = target.whole ?? whole(node);
    const content = !isWhole && contentBounds(node, whole) || own;
    if (content.width <= 0 || content.height <= 0) {
      return null;
    }
    const outer = ancestorClip(node);
    return outer && intersect(content, outer) || content;
  }
  var REPLACED = /* @__PURE__ */ new Set([
    "IMG",
    "SVG",
    "VIDEO",
    "CANVAS",
    "IFRAME",
    "EMBED",
    "OBJECT",
    "PICTURE",
    "INPUT",
    "TEXTAREA",
    "SELECT"
  ]);
  function mergeLines(rects) {
    rects.sort((a, b) => a.y + a.height / 2 - (b.y + b.height / 2) || a.x - b.x);
    const lines = [];
    for (const r of rects) {
      const mid = r.y + r.height / 2;
      let merged = false;
      for (let k = lines.length - 1; k >= 0 && k >= lines.length - 4; k--) {
        const l = lines[k];
        const sameLine = Math.abs(l.y + l.height / 2 - mid) < Math.min(l.height, r.height) / 2;
        const gap = Math.max(l.x, r.x) - Math.min(l.x + l.width, r.x + r.width);
        const near2 = Math.min(16, Math.max(6, Math.min(l.height, r.height) * 0.6));
        if (sameLine && gap <= near2) {
          lines[k] = union(l, r);
          merged = true;
          break;
        }
      }
      if (!merged) {
        lines.push(r);
      }
    }
    return lines;
  }
  function firstNode(range) {
    const c = range.startContainer;
    if (c.nodeType === Node.TEXT_NODE || !c.childNodes.length) {
      return c;
    }
    const child = c.childNodes[range.startOffset];
    if (child) {
      return child;
    }
    for (let n = c; n; n = n.parentNode) {
      if (n.nextSibling) {
        return n.nextSibling;
      }
    }
    return null;
  }
  function gatherLines(range, maxNodes, maxRects) {
    const doc = range.startContainer.ownerDocument ?? document;
    const bounds = () => {
      const r = range.getBoundingClientRect();
      return r.width > 0 && r.height > 0 ? [plain(r)] : [];
    };
    const rects = [];
    const visible = /* @__PURE__ */ new Map();
    const shows = (el2) => {
      if (!el2) {
        return true;
      }
      let v = visible.get(el2);
      if (v === void 0) {
        const box = el2.getBoundingClientRect();
        v = !invisible(getComputedStyle(el2)) && box.width >= 2 && box.height >= 2;
        visible.set(el2, v);
      }
      return v;
    };
    const clips = /* @__PURE__ */ new Map();
    const clipOf = (el2) => {
      if (clips.has(el2)) {
        return clips.get(el2);
      }
      const parent = parentOf(el2);
      let clip = null;
      if (parent && parent !== doc.body && parent !== doc.documentElement) {
        const style = getComputedStyle(el2);
        clip = style.position === "fixed" ? null : clipBy(clipOf(parent), parent, getComputedStyle(parent));
      }
      clips.set(el2, clip);
      return clip;
    };
    const push = (list2, el2) => {
      const clip = el2 ? clipOf(el2) : null;
      for (let k = 0; k < list2.length; k++) {
        const r = list2[k];
        if (r.width < 2 || r.height < 2) {
          continue;
        }
        const shown = clip ? intersect(r, clip) : plain(r);
        if (shown && shown.width >= 2 && shown.height >= 2) {
          rects.push(shown);
        }
      }
    };
    const common = range.commonAncestorContainer;
    if (common.nodeType === Node.TEXT_NODE) {
      push(range.getClientRects(), common.parentElement);
      return mergeLines(rects);
    }
    const walker = doc.createTreeWalker(common, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
    const sub = doc.createRange();
    let node = firstNode(range);
    if (!node || !common.contains(node)) {
      return bounds();
    }
    walker.currentNode = node;
    const skip = () => {
      let n = walker.nextSibling();
      while (!n) {
        if (!walker.parentNode()) {
          return null;
        }
        n = walker.nextSibling();
      }
      return n;
    };
    let budget = maxNodes;
    while (node) {
      if (--budget < 0 || rects.length > maxRects) {
        return bounds();
      }
      if (!range.intersectsNode(node)) {
        if (range.comparePoint(node, 0) > 0) {
          break;
        }
        node = walker.nextNode();
        continue;
      }
      if (node.nodeType === Node.TEXT_NODE) {
        if (/\S/.test(node.data) && shows(node.parentElement)) {
          sub.selectNodeContents(node);
          if (node === range.startContainer) {
            sub.setStart(node, range.startOffset);
          }
          if (node === range.endContainer) {
            sub.setEnd(node, range.endOffset);
          }
          push(sub.getClientRects(), node.parentElement);
        }
        node = walker.nextNode();
        continue;
      }
      const tag = node.tagName.toUpperCase();
      if (SKIP_TAGS.has(tag)) {
        node = skip();
      } else if (REPLACED.has(tag)) {
        push([node.getBoundingClientRect()], node);
        node = skip();
      } else {
        node = walker.nextNode();
      }
    }
    return mergeLines(rects);
  }
  var lineCache = null;
  function lineRects(range, options = {}) {
    const view = range.startContainer.ownerDocument?.defaultView ?? window;
    const key = [
      range.startOffset,
      range.endOffset,
      view.innerWidth,
      view.innerHeight
    ].join(",");
    const c = lineCache;
    if (c && c.key === key && c.start === range.startContainer && c.end === range.endContainer) {
      const dx = c.scrollX - view.scrollX;
      const dy = c.scrollY - view.scrollY;
      if (dx || dy) {
        c.lines = c.lines.map((r) => ({ ...r, x: r.x + dx, y: r.y + dy }));
        c.scrollX = view.scrollX;
        c.scrollY = view.scrollY;
      }
      return c.lines;
    }
    const lines = gatherLines(range, options.maxNodes ?? 4e3, options.maxRects ?? 2e3);
    lineCache = {
      key,
      start: range.startContainer,
      end: range.endContainer,
      scrollX: view.scrollX,
      scrollY: view.scrollY,
      lines
    };
    return lines;
  }
  function forgetLineRects() {
    lineCache = null;
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/targets.js
  var SELECTION = /* @__PURE__ */ Symbol("point-and-shoot.selection");
  function shadowRootsIn(nodes, budget = 2e3) {
    const roots = [];
    const stack = [...nodes];
    while (stack.length && --budget > 0) {
      const node = stack.pop();
      if (node instanceof Element && node.shadowRoot) {
        roots.push(node.shadowRoot);
        stack.push(node.shadowRoot);
      }
      for (let c = node.firstChild; c; c = c.nextSibling) {
        stack.push(c);
      }
    }
    return roots;
  }
  function shadowRange(sel, at) {
    const doc = at.startContainer.ownerDocument ?? document;
    const container = at.startContainer;
    const hosts = [
      container.childNodes[at.startOffset - 1],
      container.childNodes[at.startOffset],
      container
    ].filter((n) => !!n);
    const roots = shadowRootsIn(hosts);
    if (!roots.length) {
      return null;
    }
    let found = null;
    if (typeof sel.getComposedRanges === "function") {
      try {
        found = sel.getComposedRanges({ shadowRoots: roots })[0] ?? null;
      } catch {
        found = sel.getComposedRanges(...roots)[0] ?? null;
      }
    }
    if (!found || found.collapsed) {
      for (const root of roots) {
        const own = root.getSelection?.();
        if (own && own.rangeCount && !own.isCollapsed) {
          return own.getRangeAt(0);
        }
      }
      return null;
    }
    const range = doc.createRange();
    range.setStart(found.startContainer, found.startOffset);
    if (found.endContainer.getRootNode() === found.startContainer.getRootNode()) {
      range.setEnd(found.endContainer, found.endOffset);
    } else {
      range.setEndAfter(found.startContainer.getRootNode().lastChild ?? found.startContainer);
    }
    return range.collapsed ? null : range;
  }
  function selectionRange(doc = document) {
    const sel = doc.getSelection();
    if (!sel || !sel.rangeCount || !sel.toString().trim()) {
      return null;
    }
    const range = sel.getRangeAt(0);
    return range.collapsed ? shadowRange(sel, range) : range;
  }
  function selectionTarget(range) {
    return { kind: "selection", node: range };
  }
  function selection(options = {}) {
    const targeter = {
      name: "selection",
      [SELECTION]: true,
      resolve: ({ point, root }) => {
        const doc = root.nodeType === Node.DOCUMENT_NODE ? root : root.ownerDocument;
        const range = selectionRange(doc);
        if (!range) {
          return null;
        }
        if (options.anywhere) {
          return selectionTarget(range);
        }
        for (const r of lineRects(range)) {
          if (near(r, point, 4)) {
            return selectionTarget(range);
          }
        }
        return null;
      }
    };
    return targeter;
  }
  function elements(options = {}) {
    const blocks = options.blocks ?? true;
    let cached = null;
    const heuristicsFor = (root) => {
      if (!cached || cached.root !== root) {
        cached = { root, is: createHeuristics({ ...options, root }) };
      }
      return cached.is;
    };
    return {
      name: "elements",
      resolve: ({ stack, root }) => {
        const is = heuristicsFor(root);
        const meaningful = stack.filter(is.meaningful);
        const images = meaningful.filter(is.image).sort((a, b) => (a.tagName === "IMG" ? -1 : 1) - (b.tagName === "IMG" ? -1 : 1));
        let pick = images[0] || meaningful.find(is.mediaTag) || meaningful[0] || null;
        if (!pick) {
          return null;
        }
        const svg = pick.closest("svg");
        if (svg && pick !== svg) {
          let outer = svg;
          for (let s = svg.parentElement?.closest("svg"); s; s = s.parentElement?.closest("svg")) {
            outer = s;
          }
          pick = outer;
        }
        const node = blocks ? is.block(pick) : pick;
        return { kind: kindOf(node, is), node, whole: is.whole(node) };
      }
    };
  }
  function kindOf(node, is = createHeuristics()) {
    if (is.image(node)) {
      return "image";
    }
    if (is.mediaTag(node)) {
      return "media";
    }
    if (is.media(node)) {
      return node.querySelector("img, svg, picture") ? "image" : "media";
    }
    return "element";
  }
  var defaultTargets = Object.freeze([
    selection(),
    elements()
  ]);

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/emitter.js
  function createEmitter() {
    const listeners = /* @__PURE__ */ new Map();
    return {
      on(type, listener) {
        let set = listeners.get(type);
        if (!set) {
          set = /* @__PURE__ */ new Set();
          listeners.set(type, set);
        }
        set.add(listener);
        return () => {
          set.delete(listener);
        };
      },
      emit(type, ...args) {
        const set = listeners.get(type);
        if (!set) {
          return;
        }
        for (const listener of [...set]) {
          try {
            listener(...args);
          } catch (error) {
            queueMicrotask(() => {
              throw error;
            });
          }
        }
      },
      clear() {
        listeners.clear();
      }
    };
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/outline.js
  var snap = (v) => Math.round(v * 2) / 2;
  function sortedUnique(values) {
    values.sort((a, b) => a - b);
    const out = [];
    for (const v of values) {
      if (out.length === 0 || out[out.length - 1] !== v) {
        out.push(v);
      }
    }
    return out;
  }
  function roundedLoop(xs, ys, radius) {
    const n = xs.length;
    let d = "";
    for (let k = 0; k < n; k++) {
      const px2 = xs[(k + n - 1) % n];
      const py = ys[(k + n - 1) % n];
      const cx = xs[k];
      const cy = ys[k];
      const nx = xs[(k + 1) % n];
      const ny = ys[(k + 1) % n];
      const inLen = Math.abs(cx - px2) + Math.abs(cy - py);
      const outLen = Math.abs(nx - cx) + Math.abs(ny - cy);
      const r = Math.min(radius, inLen / 2, outLen / 2);
      const ix = Math.sign(cx - px2);
      const iy = Math.sign(cy - py);
      const ox = Math.sign(nx - cx);
      const oy = Math.sign(ny - cy);
      const ax = cx - ix * r;
      const ay = cy - iy * r;
      const bx = cx + ox * r;
      const by = cy + oy * r;
      const sweep = ix * oy - iy * ox > 0 ? 1 : 0;
      d += `${k === 0 ? "M" : "L"}${ax} ${ay}`;
      d += r > 0 ? `A${r} ${r} 0 0 ${sweep} ${bx} ${by}` : "";
    }
    return d + "Z";
  }
  function outlinePath(rects, options = {}) {
    const radius = options.radius ?? 6;
    const maxCells = options.maxCells ?? 16e4;
    const boxes = rects.filter((r) => r.width > 0 && r.height > 0);
    if (!boxes.length) {
      return null;
    }
    const xs = sortedUnique(boxes.flatMap((r) => [snap(r.x), snap(r.x + r.width)]));
    const ys = sortedUnique(boxes.flatMap((r) => [snap(r.y), snap(r.y + r.height)]));
    const W = xs.length - 1;
    const H = ys.length - 1;
    if (W < 1 || H < 1 || W * H > maxCells) {
      return null;
    }
    const xi = new Map(xs.map((v2, i) => [v2, i]));
    const yi = new Map(ys.map((v2, i) => [v2, i]));
    const stride = W + 1;
    const diff = new Int32Array((W + 1) * (H + 1));
    for (const r of boxes) {
      const x0 = xi.get(snap(r.x));
      const x1 = xi.get(snap(r.x + r.width));
      const y0 = yi.get(snap(r.y));
      const y1 = yi.get(snap(r.y + r.height));
      if (x0 === x1 || y0 === y1) {
        continue;
      }
      diff[y0 * stride + x0] += 1;
      diff[y0 * stride + x1] -= 1;
      diff[y1 * stride + x0] -= 1;
      diff[y1 * stride + x1] += 1;
    }
    const filled = new Uint8Array(W * H);
    const row = new Int32Array(W + 1);
    for (let j = 0; j < H; j++) {
      let run = 0;
      for (let i = 0; i < W; i++) {
        run += diff[j * stride + i];
        row[i] = row[i] + run;
        filled[j * W + i] = row[i] > 0 ? 1 : 0;
      }
    }
    const at = (i, j) => i >= 0 && j >= 0 && i < W && j < H ? filled[j * W + i] : 0;
    const vertices = (W + 1) * (H + 1);
    const out1 = new Int32Array(vertices).fill(-1);
    const out2 = new Int32Array(vertices).fill(-1);
    const edgeFrom = [];
    const edgeTo = [];
    const addEdge = (from, to) => {
      const id = edgeFrom.length;
      edgeFrom.push(from);
      edgeTo.push(to);
      if (out1[from] === -1) {
        out1[from] = id;
      } else {
        out2[from] = id;
      }
    };
    const v = (i, j) => j * stride + i;
    for (let j = 0; j < H; j++) {
      for (let i = 0; i < W; i++) {
        if (!filled[j * W + i]) {
          continue;
        }
        if (!at(i, j - 1)) {
          addEdge(v(i, j), v(i + 1, j));
        }
        if (!at(i + 1, j)) {
          addEdge(v(i + 1, j), v(i + 1, j + 1));
        }
        if (!at(i, j + 1)) {
          addEdge(v(i + 1, j + 1), v(i, j + 1));
        }
        if (!at(i - 1, j)) {
          addEdge(v(i, j + 1), v(i, j));
        }
      }
    }
    const used = new Uint8Array(edgeFrom.length);
    const dir = (e) => {
      const from = edgeFrom[e];
      const to = edgeTo[e];
      return [
        Math.sign(to % stride - from % stride),
        Math.sign(Math.floor(to / stride) - Math.floor(from / stride))
      ];
    };
    let d = "";
    for (let start = 0; start < edgeFrom.length; start++) {
      if (used[start]) {
        continue;
      }
      const cornersX = [];
      const cornersY = [];
      let e = start;
      let [dx, dy] = dir(e);
      for (let guard = 0; guard <= edgeFrom.length; guard++) {
        used[e] = 1;
        const to = edgeTo[e];
        let next = out1[to];
        const other = out2[to];
        if (other !== -1) {
          const [ax, ay] = dir(next);
          if (!(ax === -dy && ay === dx) || used[next]) {
            next = used[other] ? next : other;
          }
        }
        const [nx, ny] = dir(next);
        if (nx !== dx || ny !== dy) {
          cornersX.push(xs[to % stride]);
          cornersY.push(ys[Math.floor(to / stride)]);
        }
        if (next === start || used[next]) {
          break;
        }
        e = next;
        dx = nx;
        dy = ny;
      }
      if (cornersX.length >= 4) {
        d += roundedLoop(cornersX, cornersY, radius);
      }
    }
    return d || null;
  }
  function roundedRectPath(r, radius = 6) {
    const rad = Math.min(radius, r.width / 2, r.height / 2);
    return roundedLoop([r.x, r.x + r.width, r.x + r.width, r.x], [r.y, r.y, r.y + r.height, r.y + r.height], rad);
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/spotlight.js
  var SVG = "http://www.w3.org/2000/svg";
  var px = (n) => `${n}px`;
  var ms = (n) => `${n}ms`;
  var PROPERTIES = [
    ["color", "--pns-color", String],
    ["pressedColor", "--pns-pressed-color", String],
    ["dotColor", "--pns-dot-color", String],
    ["border", "--pns-border", String],
    ["padding", "--pns-padding", px],
    ["radius", "--pns-radius", px],
    ["dotSize", "--pns-dot-size", px],
    ["pressScale", "--pns-press-scale", String],
    ["lean", "--pns-lean", px],
    ["duration", "--pns-duration", ms],
    ["zIndex", "--pns-z-index", String]
  ];
  var SPRING = "linear(0, 0.009, 0.035 2.1%, 0.141, 0.281 6.7%, 0.723 12.9%, 0.938 16.7%, 1.017, 1.077, 1.121, 1.149 24.3%, 1.159, 1.163, 1.161, 1.154 29.9%, 1.129 32.8%, 1.051 39.6%, 1.017 43.1%, 0.991, 0.977 51%, 0.974 53.8%, 0.975 57.1%, 0.997 69.8%, 1.003 76.9%, 1)";
  var CSS = `
  :host {
    all: initial;
    --pns-color: rgb(112 88 255 / 0.2);
    --pns-pressed-color: rgb(112 88 255 / 0.3);
    --pns-dot-color: rgb(112 88 255 / 0.5);
    --pns-border: none;
    --pns-padding: 5px;
    --pns-radius: 8px;
    --pns-dot-size: 4px;
    --pns-press-scale: 0.95;
    --pns-lean: 4px;
    --pns-duration: 110ms;
    --pns-z-index: 2147483647;
    --pns-flash-color: rgb(160 140 255);
    --pns-flash-intensity: 0.55;
    --pns-flash-duration: 420ms;
    --pns-shake-distance: 4px;
    --pns-shake-duration: 820ms;
  }
  @supports (color: rgb(from red r g b)) {
    :host {
      --pns-pressed-color: rgb(from var(--pns-color) r g b / calc(alpha * 1.5));
      --pns-dot-color: rgb(from var(--pns-color) r g b / calc(alpha * 2.5));
    }
  }
  .root {
    --x: -20px; --y: -20px; --w: 0px; --h: 0px; --lx: 0; --ly: 0; --scale: 1;
    --ease: cubic-bezier(0.32, 0.72, 0, 1);
    --spring: ${SPRING};
    pointer-events: none;
  }
  .portal {
    position: fixed; inset: 0; pointer-events: none; z-index: var(--pns-z-index);
    transition: opacity 200ms ease-out;
  }
  .root.leaving .portal { opacity: 0; }
  .root.hidden .portal { visibility: hidden; transition: none; }

  .shift {
    position: absolute; inset: 0;
    transform: translate(calc(var(--lx) * var(--pns-lean)), calc(var(--ly) * var(--pns-lean) / 2));
    transition: transform 50ms linear;
  }

  .area {
    --pad: var(--pns-padding);
    position: absolute; left: 0; top: 0; box-sizing: border-box;
    width: calc(var(--w) + 2 * var(--pad));
    height: calc(var(--h) + 2 * var(--pad));
    transform: translate(calc(var(--x) - var(--pad)), calc(var(--y) - var(--pad))) scale(var(--scale));
    transform-origin: center;
    border: var(--pns-border);
    border-radius: var(--pns-radius);
    background: var(--pns-color);
    opacity: 0;
    transition:
      transform var(--pns-duration) var(--ease),
      width var(--pns-duration) var(--ease),
      height var(--pns-duration) var(--ease),
      border-radius var(--pns-duration) var(--ease),
      background-color 160ms ease-out,
      opacity 160ms ease-out;
    will-change: transform, width, height;
  }
  .root.on .area { opacity: 1; }
  /* With nothing targeted, the dot sits under the pointer: no easing. */
  .root.blank .area {
    --pad: calc(var(--pns-dot-size) / 2);
    border-radius: calc(var(--pns-dot-size) / 2);
    background: var(--pns-dot-color);
    transition: opacity 160ms ease-out;
  }
  /* The dot morphs into the first element it points at, and back when the
     pointer leaves it: frame, corners and tint together, a little longer
     than moves between elements. */
  .root.morphing .area {
    transition: transform 240ms var(--ease), width 240ms var(--ease), height 240ms var(--ease),
                border-radius 240ms var(--ease), background-color 240ms ease-out, opacity 160ms ease-out;
  }
  /* Press down, then spring back when released. */
  .root.pressed { --scale: var(--pns-press-scale); }
  .root.pressed .area { background: var(--pns-pressed-color); transition-timing-function: cubic-bezier(0.3, 0, 0.5, 1); }
  .root.released .area {
    transition: transform 520ms var(--spring), width var(--pns-duration) var(--ease),
                height var(--pns-duration) var(--ease), background-color 160ms ease-out, opacity 160ms ease-out;
  }
  /* The drawn area is what's captured: no padding around it. */
  .root.dragging .area { --pad: 0px; transition: none; }
  .root.instant .area, .root.instant .shift { transition: none; }

  /* A text selection: its lines lit as one shape, corners rounded. */
  .lines {
    position: absolute; left: 0; top: 0; width: 100%; height: 100%; overflow: visible;
    opacity: 0; transition: opacity 160ms ease-out;
  }
  .lines .fill { fill: var(--pns-color); }
  .lines .flash { fill: var(--pns-flash-color); }
  .root.selection .area { display: none; }
  .root.selection.on .lines { opacity: 1; }

  /* The shot: a flash of light inside the highlight. */
  .flash {
    position: absolute; inset: 0; border-radius: inherit;
    background: var(--pns-flash-color); opacity: 0;
  }
  .root.shot .flash { animation: pns-flash var(--pns-flash-duration) ease-out; }
  @keyframes pns-flash { 0% { opacity: var(--pns-flash-intensity); } 100% { opacity: 0; } }

  /* A miss: the highlight shakes its head. */
  .root.error .shift { animation: pns-shake var(--pns-shake-duration) cubic-bezier(.36, .07, .19, .97) both; }
  @keyframes pns-shake {
    10%, 90% { transform: translate3d(calc(var(--pns-shake-distance) * -0.25), 0, 0); }
    20%, 80% { transform: translate3d(calc(var(--pns-shake-distance) * 0.5), 0, 0); }
    30%, 50%, 70% { transform: translate3d(calc(var(--pns-shake-distance) * -1), 0, 0); }
    40%, 60% { transform: translate3d(var(--pns-shake-distance), 0, 0); }
  }
  @keyframes pns-pulse { 0%, 100% { opacity: 1; } 35% { opacity: 0.35; } }
`;
  var REDUCED = `
  .area, .root.blank .area, .root.morphing .area, .root.released .area {
    transition: background-color 160ms ease-out, opacity 160ms ease-out;
  }
  .shift { transform: none; transition: none; }
  .root.pressed { --scale: 1; }
  .root.error .shift { animation: none; }
  .root.error .area, .root.error .lines .fill { animation: pns-pulse 400ms ease-out; }
  .root.shot .flash { animation-duration: calc(var(--pns-flash-duration) / 2); }
`;
  function cssFor(motion) {
    if (motion === "full") {
      return CSS;
    }
    if (motion === "none") {
      return CSS + REDUCED;
    }
    return `${CSS}@media (prefers-reduced-motion: reduce) {${REDUCED}}`;
  }
  function el(tag, className, parent) {
    const node = document.createElement(tag);
    node.className = className;
    parent.appendChild(node);
    return node;
  }
  function spotlight(style = {}) {
    let host = null;
    let root = null;
    let area = null;
    let lines = null;
    let fill = null;
    let flashPath = null;
    let drawn = null;
    let last = null;
    let morphTimer = 0;
    function build() {
      host = document.createElement(HOST_TAG);
      host.style.cssText = "all: initial !important; display: contents !important;";
      for (const [key, property, write] of PROPERTIES) {
        const value = style[key];
        if (value !== void 0) {
          host.style.setProperty(property, write(value));
        }
      }
      const shadow = host.attachShadow({ mode: "closed" });
      el("style", "", shadow).textContent = cssFor(style.motion);
      root = el("div", "root blank leaving", shadow);
      const portal = el("div", "portal", root);
      const shift = el("div", "shift", portal);
      area = el("div", "area", shift);
      area.setAttribute("part", "highlight dot");
      el("div", "flash", area).setAttribute("part", "flash");
      lines = document.createElementNS(SVG, "svg");
      lines.setAttribute("class", "lines");
      fill = document.createElementNS(SVG, "path");
      fill.setAttribute("class", "fill");
      fill.setAttribute("part", "selection");
      flashPath = document.createElementNS(SVG, "path");
      flashPath.setAttribute("class", "flash");
      flashPath.setAttribute("part", "flash");
      lines.append(fill, flashPath);
      shift.appendChild(lines);
    }
    function setVar(name, value) {
      root.style.setProperty(name, value);
    }
    function drawLines(rects) {
      if (rects === drawn) {
        return;
      }
      drawn = rects;
      const pad = style.selectionPadding ?? 4;
      const radius = style.selectionRadius ?? 6;
      const margin = pad + radius + 50;
      const view = {
        x: -margin,
        y: -margin,
        width: innerWidth + 2 * margin,
        height: innerHeight + 2 * margin
      };
      const near2 = [];
      for (const r of rects) {
        const p = {
          x: r.x - pad,
          y: r.y - pad,
          width: r.width + 2 * pad,
          height: r.height + 2 * pad
        };
        if (intersect(p, view)) {
          near2.push(p);
        }
      }
      let d = outlinePath(near2, { radius });
      if (!d && near2.length) {
        const box = near2.reduce((u, r) => union(u, r), null);
        d = roundedRectPath(intersect(box, view) ?? box, radius);
      }
      fill.setAttribute("d", d ?? "");
      flashPath.setAttribute("d", d ?? "");
    }
    function restart(className) {
      root.classList.remove(className);
      void root.offsetWidth;
      root.classList.add(className);
    }
    return {
      mount() {
        if (!host) {
          build();
        }
        if (!host.isConnected) {
          (document.documentElement || document).appendChild(host);
        }
      },
      unmount() {
        host?.remove();
        last = null;
        clearTimeout(morphTimer);
      },
      render(view) {
        if (!root || !area) {
          return;
        }
        const prev = last;
        last = view;
        const list2 = root.classList;
        const appearing = !prev || prev.state === "idle";
        const dot = !view.rect && !view.lines;
        const wasDot = !prev || !prev.rect && !prev.lines;
        if (view.instant || appearing) {
          list2.add("instant");
        }
        if (view.rect) {
          setVar("--x", px(view.rect.x));
          setVar("--y", px(view.rect.y));
          setVar("--w", px(Math.max(0, view.rect.width)));
          setVar("--h", px(Math.max(0, view.rect.height)));
        } else {
          setVar("--x", px(view.pointer.x));
          setVar("--y", px(view.pointer.y));
          setVar("--w", "0px");
          setVar("--h", "0px");
        }
        setVar("--lx", String(view.lean.x));
        setVar("--ly", String(view.lean.y));
        if (list2.contains("instant")) {
          void root.offsetHeight;
          list2.remove("instant");
        }
        if (!appearing && dot !== wasDot && view.state !== "dragging") {
          list2.add("morphing");
          clearTimeout(morphTimer);
          morphTimer = window.setTimeout(() => list2.remove("morphing"), 260);
        }
        if (view.state === "pressed" || view.state === "dragging") {
          list2.remove("released");
        } else if (prev?.state === "pressed") {
          list2.add("released");
        }
        list2.toggle("on", view.state !== "idle");
        list2.toggle("leaving", view.state === "idle");
        list2.toggle("pressed", view.state === "pressed");
        list2.toggle("dragging", view.state === "dragging");
        list2.toggle("blank", dot);
        list2.toggle("selection", !!view.lines);
        area.setAttribute("part", dot ? "highlight dot" : "highlight");
        host.dataset.state = view.state;
        if (view.lines) {
          drawLines(view.lines);
        } else if (drawn) {
          drawn = null;
          fill.setAttribute("d", "");
          flashPath.setAttribute("d", "");
        }
        if (appearing) {
          list2.remove("error", "shot", "released");
        }
      },
      setHidden(hidden) {
        root?.classList.toggle("hidden", hidden);
      },
      flash(s) {
        if (!root) {
          return;
        }
        if (s.color !== void 0) {
          setVar("--pns-flash-color", s.color);
        }
        if (s.intensity !== void 0) {
          setVar("--pns-flash-intensity", String(s.intensity));
        }
        if (s.duration !== void 0) {
          setVar("--pns-flash-duration", ms(s.duration));
        }
        restart("shot");
      },
      shake(s) {
        if (!root) {
          return;
        }
        if (s.distance !== void 0) {
          setVar("--pns-shake-distance", px(s.distance));
        }
        if (s.duration !== void 0) {
          setVar("--pns-shake-duration", ms(s.duration));
        }
        restart("error");
      }
    };
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/controller.js
  var ACTIVE = /* @__PURE__ */ Symbol.for("@daformat/point-and-shoot.active");
  var HIDE_SELECTION = "*::selection { background: transparent !important; text-shadow: none !important; }";
  var FADE = 260;
  var CLICK_WINDOW = 600;
  var MOUSE_EVENTS = [
    "mousedown",
    "mouseup",
    "click",
    "auxclick",
    "dblclick",
    "contextmenu"
  ];
  function isRenderer(value) {
    return !!value && typeof value.render === "function" && typeof value.mount === "function";
  }
  function sameNode(a, b) {
    if (a === b) {
      return true;
    }
    if (a instanceof Range && b instanceof Range) {
      return a.startContainer === b.startContainer && a.startOffset === b.startOffset && a.endContainer === b.endContainer && a.endOffset === b.endOffset;
    }
    return false;
  }
  function same(a, b) {
    return !!a && !!b && a.kind === b.kind && sameNode(a.node, b.node);
  }
  function stop(e) {
    e.preventDefault();
    e.stopImmediatePropagation();
  }
  var frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
  function createPointAndShoot(options = {}) {
    let opts = { ...options };
    let renderer = null;
    let is = createHeuristics({ root: opts.root });
    const pointer = { x: -1, y: -1 };
    let pointerKnown = false;
    let flags = {};
    let active = false;
    let pending = null;
    let pressed = false;
    let dragging = false;
    let moved = false;
    let tapPreview = false;
    let pressPoint = null;
    let target = null;
    let rect = null;
    let mounted = false;
    let destroyed = false;
    let hideTimer = 0;
    let flashEnd = 0;
    let swallowClick = 0;
    let containerCandidate = null;
    let containerSince = 0;
    let containerTimer = 0;
    let cursorStyle = null;
    let listeners = null;
    const emitter = createEmitter();
    const announcer = createAnnouncer();
    function setRenderer() {
      const overlay = opts.overlay;
      if (renderer && mounted) {
        renderer.unmount();
        mounted = false;
      }
      renderer = overlay === null ? null : isRenderer(overlay) ? overlay : spotlight(overlay ?? {});
    }
    setRenderer();
    const root = () => opts.root ?? document;
    const doc = () => {
      const r = root();
      return r.nodeType === Node.DOCUMENT_NODE ? r : r.ownerDocument;
    };
    const state = () => pending ? "pending" : dragging ? "dragging" : pressed ? "pressed" : active ? "active" : "idle";
    const flashOptions = () => opts.feedback?.flash === false ? null : opts.feedback?.flash ?? {};
    const shakeOptions = () => opts.feedback?.shake === false ? null : opts.feedback?.shake ?? {};
    function flash() {
      const f = flashOptions();
      if (f && mounted && renderer) {
        renderer.flash({
          color: f.color,
          intensity: f.intensity,
          duration: f.duration
        });
        flashEnd = performance.now() + (f.duration ?? 420);
      }
    }
    function shake() {
      const s = shakeOptions();
      if (s && mounted) {
        renderer?.shake({ distance: s.distance, duration: s.duration });
      }
    }
    function flashOn(moment) {
      const f = flashOptions();
      if (f && (f.on ?? "shoot") === moment) {
        flash();
      }
    }
    function shakeOn(moment) {
      const s = shakeOptions();
      const on = s?.on ?? "both";
      if (s && (on === "both" || on === moment)) {
        shake();
      }
    }
    function defaultActivate() {
      const how = opts.area ? "Click or drag to capture" : "Click to capture";
      return `Point and shoot. ${how}${opts.escape === false ? "" : ", Escape to cancel"}.`;
    }
    function say(key, fallback, arg) {
      const messages = opts.feedback?.announce;
      if (messages === false) {
        return;
      }
      const value = messages?.[key];
      if (value === false) {
        return;
      }
      const text = value === void 0 ? fallback : typeof value === "function" ? value(arg) : value;
      if (text) {
        announcer.say(text);
      }
    }
    function view(instant) {
      const range = target?.node instanceof Range ? target.node : null;
      const s = state();
      return {
        state: s,
        rect,
        lines: range ? lineRects(range) : null,
        pointer: { ...pointer },
        lean: rect && !range && (s === "active" || s === "pressed") ? lean(rect, pointer) : { x: 0, y: 0 },
        instant
      };
    }
    function render(instant = false) {
      if (renderer && mounted) {
        const v = view(instant);
        renderer.render(v);
        syncSelectionHighlight(v.lines && v.state !== "idle" ? target.node : null);
      } else {
        syncSelectionHighlight(null);
      }
    }
    let hiddenSelection = null;
    function syncSelectionHighlight(range) {
      const hide2 = !!range && opts.hideSelection !== false;
      const root2 = range?.startContainer.getRootNode() ?? null;
      const shadow = root2 instanceof ShadowRoot ? root2 : null;
      if (hide2 && hiddenSelection && hiddenSelection.root === shadow) {
        return;
      }
      if (hiddenSelection) {
        hiddenSelection.style.remove();
        const { root: r, sheet: sheet2 } = hiddenSelection;
        if (r && sheet2) {
          r.adoptedStyleSheets = r.adoptedStyleSheets.filter((s) => s !== sheet2);
        }
        hiddenSelection = null;
      }
      if (!hide2) {
        return;
      }
      const d = doc();
      const style = d.createElement("style");
      style.setAttribute("data-point-and-shoot", "selection");
      style.textContent = HIDE_SELECTION;
      (d.head || d.documentElement).appendChild(style);
      let sheet = null;
      if (shadow && typeof CSSStyleSheet === "function" && "adoptedStyleSheets" in shadow) {
        try {
          sheet = new CSSStyleSheet();
          sheet.replaceSync(HIDE_SELECTION);
          shadow.adoptedStyleSheets = [...shadow.adoptedStyleSheets, sheet];
        } catch {
          sheet = null;
        }
      }
      hiddenSelection = { style, root: shadow, sheet };
    }
    function mount() {
      clearTimeout(hideTimer);
      if (renderer && !mounted) {
        renderer.mount();
        mounted = true;
      } else if (renderer) {
        renderer.mount();
      }
    }
    function hide() {
      clearTimeout(hideTimer);
      const fade = () => {
        render();
        target = null;
        rect = null;
        hideTimer = window.setTimeout(() => {
          if (state() === "idle" && renderer && mounted) {
            renderer.unmount();
            mounted = false;
          }
        }, FADE);
      };
      const wait = flashEnd - performance.now();
      if (wait > 0 && mounted) {
        hideTimer = window.setTimeout(fade, wait);
      } else {
        fade();
      }
    }
    function setCursor(on) {
      cursorStyle?.remove();
      cursorStyle = null;
      if (!on) {
        return;
      }
      const rules = [];
      if (opts.cursor !== false) {
        rules.push(`cursor: ${opts.cursor ?? "pointer"} !important;`);
      }
      if (opts.area) {
        rules.push("touch-action: none !important;");
      }
      let css = `${FRAMES} { pointer-events: none !important; }`;
      if (rules.length) {
        css += ` * { ${rules.join(" ")} }`;
      }
      const d = doc();
      cursorStyle = d.createElement("style");
      cursorStyle.setAttribute("data-point-and-shoot", "cursor");
      cursorStyle.textContent = css;
      (d.head || d.documentElement).appendChild(cursorStyle);
    }
    function resolve() {
      const ignore = opts.ignore;
      const ctx = {
        point: { ...pointer },
        stack: elementsAtPoint(pointer, root()).filter((el2) => !ignore || !closestAcross(el2, ignore)),
        flags,
        current: target,
        root: root(),
        is
      };
      for (const targeter of opts.targets ?? defaultTargets) {
        if (!targeter.resolve) {
          continue;
        }
        if (SELECTION in targeter && opts.selection === "ignore") {
          continue;
        }
        if (SELECTION in targeter && opts.selection === "anywhere") {
          const range = selectionRange(doc());
          if (range) {
            return selectionTarget(range);
          }
          continue;
        }
        const found = targeter.resolve(ctx);
        if (found) {
          return found;
        }
      }
      return null;
    }
    function isContainerOfTarget(next) {
      const current = target?.node;
      return current instanceof Element && next.node instanceof Element && next.node !== current && next.node.contains(current);
    }
    function retarget(next, r) {
      const previous = target;
      target = next;
      rect = r;
      if (!same(previous, next)) {
        emitter.emit("target", next, previous);
        if (next) {
          say("target", null, next);
        }
      }
    }
    function update(instant = false, remeasure = false) {
      if (!active || pending || dragging || destroyed) {
        return;
      }
      if (remeasure && target) {
        const r = boundsFor(target, is.whole);
        if (r) {
          rect = r;
        } else {
          retarget(null, null);
        }
      }
      if (!pointerKnown) {
        render(instant);
        return;
      }
      let next = resolve();
      const dwell = opts.dwell ?? 180;
      if (next && isContainerOfTarget(next)) {
        const node = next.node;
        if (containerCandidate !== node) {
          containerCandidate = node;
          containerSince = performance.now();
          clearTimeout(containerTimer);
          containerTimer = window.setTimeout(() => update(), dwell);
        }
        if (performance.now() - containerSince < dwell) {
          next = target;
        }
      } else {
        containerCandidate = null;
        clearTimeout(containerTimer);
      }
      if (next && !same(next, target)) {
        const r = boundsFor(next, is.whole);
        if (r && r.width > 0 && r.height > 0) {
          retarget(next, r);
        }
      } else if (!next && !near(rect, pointer, opts.grace ?? 20)) {
        retarget(null, null);
      }
      render(instant);
    }
    function miss(point) {
      emitter.emit("miss", point);
      shakeOn("miss");
      say("miss", "Nothing to capture here");
    }
    async function run(shotTarget, shotRect, exec) {
      listen();
      mount();
      const p = { abort: new AbortController(), hiding: false };
      pending = p;
      pressed = false;
      dragging = false;
      const area = areaRect(shotRect);
      render();
      const ctx = {
        signal: p.abort.signal,
        flags: { ...flags },
        point: { ...pointer },
        rect: area,
        hideOverlay: async () => {
          p.hiding = true;
          renderer?.setHidden(true);
          await frame();
          await frame();
          return () => {
            renderer?.setHidden(false);
            if (pending === p) {
              flashOn("shoot");
            }
          };
        },
        captureArea: (r) => {
          const handler = opts.area?.onCapture;
          if (!handler) {
            return Promise.reject(new Error("point-and-shoot: captureArea() needs the area option."));
          }
          return Promise.resolve().then(() => handler(r ? areaRect(r) : area, ctx));
        }
      };
      if (shotTarget) {
        emitter.emit("shoot", shotTarget, area);
      } else {
        emitter.emit("areaend", area);
      }
      let result;
      try {
        result = Promise.resolve(exec(ctx));
      } catch (error) {
        result = Promise.reject(error);
      }
      if (!p.hiding) {
        flashOn("shoot");
      }
      const aborted = new Promise((_, reject) => {
        p.abort.signal.addEventListener("abort", () => reject(p.abort.signal.reason));
      });
      let outcome;
      try {
        const value = await Promise.race([result, aborted]);
        outcome = { ok: true, value, target: shotTarget, rect: area };
      } catch (error) {
        outcome = {
          ok: false,
          error,
          cancelled: p.abort.signal.aborted,
          target: shotTarget,
          rect: area
        };
      }
      if (pending === p && !destroyed) {
        settle(outcome);
      }
      return outcome;
    }
    function settle(outcome) {
      pending = null;
      renderer?.setHidden(false);
      if (outcome.ok) {
        flashOn("success");
        say("success", "Captured", outcome);
      } else if (outcome.cancelled) {
        say("cancel", "Cancelled");
      } else {
        shakeOn("failure");
        say("failure", "Couldn't capture that", outcome);
      }
      emitter.emit("shot", outcome);
      if (pending) {
        return;
      }
      const stay = active && (!outcome.ok || opts.after === "stay");
      if (stay) {
        update(false, true);
      } else if (active) {
        deactivate();
      } else {
        hide();
      }
    }
    function busy() {
      return {
        ok: false,
        error: new Error("point-and-shoot: a shot is already pending."),
        cancelled: false,
        target: null,
        rect: areaRect(rect ?? { x: 0, y: 0, width: 0, height: 0 })
      };
    }
    function toTarget(input) {
      if (input instanceof Range) {
        return selectionTarget(input);
      }
      if (input instanceof Element) {
        return { kind: kindOf(input, is), node: input, whole: is.whole(input) };
      }
      return input;
    }
    function shootTarget(t) {
      const onShoot = opts.onShoot;
      return run(t, rect ?? { x: pointer.x, y: pointer.y, width: 0, height: 0 }, (ctx) => onShoot ? onShoot(t, ctx) : void 0);
    }
    function shootArea(r) {
      const onCapture = opts.area.onCapture;
      retarget(null, r);
      return run(null, r, (ctx) => onCapture(ctx.rect, ctx));
    }
    function onPointerTrack(e) {
      pointer.x = e.clientX;
      pointer.y = e.clientY;
      pointerKnown = true;
    }
    function ignored(e) {
      const ignore = opts.ignore;
      const origin = e.composedPath()[0];
      return !!ignore && origin instanceof Element && !!closestAcross(origin, ignore);
    }
    function guardFails(e) {
      return active && !pending && !!opts.guard && !opts.guard(e);
    }
    function onPointerMove(e) {
      if (!active || pending) {
        return;
      }
      if (!pressed && guardFails(e)) {
        deactivate();
        return;
      }
      if (pressed && pressPoint) {
        const far = Math.hypot(pointer.x - pressPoint.x, pointer.y - pressPoint.y) > (opts.area?.threshold ?? 4);
        if (far && !moved) {
          moved = true;
        }
        if (moved && opts.area) {
          const starting = !dragging;
          dragging = true;
          rect = spanning(pressPoint, pointer);
          if (target) {
            const previous = target;
            target = null;
            emitter.emit("target", null, previous);
          }
          render();
          emitter.emit(starting ? "areastart" : "areamove", areaRect(rect));
          return;
        }
        if (moved) {
          return;
        }
      }
      update();
    }
    function onPointerDown(e) {
      if ((active || pending) && ignored(e)) {
        return;
      }
      if (pending) {
        stop(e);
        return;
      }
      if (!active) {
        return;
      }
      if (guardFails(e)) {
        deactivate();
        return;
      }
      if (e.button !== 0) {
        return;
      }
      stop(e);
      pressed = true;
      moved = false;
      pressPoint = { x: e.clientX, y: e.clientY };
      try {
        doc().documentElement.setPointerCapture(e.pointerId);
      } catch {
      }
      const before = target;
      update();
      tapPreview = e.pointerType !== "mouse" && !same(before, target);
      render();
      emitter.emit("press", target);
    }
    function onPointerUp(e) {
      if (!pressed) {
        return;
      }
      stop(e);
      pressed = false;
      swallowClick = performance.now();
      const point = { x: e.clientX, y: e.clientY };
      if (dragging) {
        dragging = false;
        const minSize = opts.area?.minSize ?? 8;
        if (opts.area && rect && rect.width >= minSize && rect.height >= minSize) {
          void shootArea(rect);
        } else {
          rect = null;
          render();
          miss(point);
          update();
        }
        return;
      }
      if (moved) {
        moved = false;
        render();
        miss(point);
        return;
      }
      if (tapPreview) {
        tapPreview = false;
        render();
        if (!target) {
          miss(point);
        }
        return;
      }
      const selected = target?.node instanceof Range;
      if (!target || !selected && !near(rect, pointer, opts.grace ?? 20)) {
        render();
        miss(point);
        return;
      }
      void shootTarget(target);
    }
    function onPointerCancel() {
      if (!pressed) {
        return;
      }
      pressed = false;
      dragging = false;
      moved = false;
      tapPreview = false;
      render();
      update();
    }
    function onMouse(e) {
      if (swallowClick && (e.type === "click" || e.type === "dblclick")) {
        const recent = performance.now() - swallowClick < CLICK_WINDOW;
        swallowClick = 0;
        if (recent) {
          stop(e);
          return;
        }
      }
      if ((active || pending) && !ignored(e)) {
        stop(e);
      }
    }
    function onKeyDown(e) {
      if (e.key === "Escape" && opts.escape !== false && (active || pending)) {
        stop(e);
        cancel();
      }
    }
    function onBlur() {
      if (opts.exitOnBlur !== false && active && !pending) {
        deactivate();
      }
    }
    function onVisibility() {
      if (doc().hidden) {
        onBlur();
      }
    }
    function onScroll(e) {
      if (e.target !== doc() && e.target !== doc().defaultView) {
        forgetLineRects();
      }
      if (!mounted) {
        return;
      }
      if (pending && target) {
        rect = boundsFor(target, is.whole) ?? rect;
        render(true);
      } else if (active && !pressed) {
        update(true, true);
      }
    }
    function onResize() {
      if (target && mounted) {
        rect = boundsFor(target, is.whole) ?? rect;
        render(true);
      }
    }
    function listen() {
      if (listeners || destroyed) {
        return;
      }
      listeners = new AbortController();
      const signal = listeners.signal;
      const capture = { capture: true, signal };
      const view2 = doc().defaultView ?? window;
      view2.addEventListener("pointermove", onPointerMove, capture);
      view2.addEventListener("pointerdown", onPointerDown, capture);
      view2.addEventListener("pointerup", onPointerUp, capture);
      view2.addEventListener("pointercancel", onPointerCancel, capture);
      for (const type of MOUSE_EVENTS) {
        view2.addEventListener(type, onMouse, capture);
      }
      view2.addEventListener("keydown", onKeyDown, capture);
      view2.addEventListener("scroll", onScroll, capture);
      view2.addEventListener("resize", onResize, { signal });
      view2.addEventListener("blur", onBlur, { signal });
      doc().addEventListener("visibilitychange", onVisibility, { signal });
    }
    const tracker = new AbortController();
    if (typeof window !== "undefined") {
      window.addEventListener("pointermove", onPointerTrack, {
        capture: true,
        passive: true,
        signal: tracker.signal
      });
      window.addEventListener("pointerdown", onPointerTrack, {
        capture: true,
        passive: true,
        signal: tracker.signal
      });
    }
    function activate(o = {}) {
      if (destroyed) {
        return;
      }
      if (o.at) {
        pointer.x = o.at.x;
        pointer.y = o.at.y;
        pointerKnown = true;
      }
      if (active || pending) {
        return;
      }
      const d = doc();
      const other = d[ACTIVE];
      if (other && other !== api) {
        other.deactivate();
      }
      d[ACTIVE] = api;
      active = true;
      listen();
      mount();
      setCursor(true);
      emitter.emit("activate");
      say("activate", defaultActivate());
      if (opts.selection === "shoot") {
        const range = selectionRange(doc());
        if (range) {
          const t = selectionTarget(range);
          rect = boundsFor(t, is.whole);
          target = t;
          render(true);
          void shootTarget(t);
          return;
        }
      }
      target = null;
      rect = null;
      render(true);
      requestAnimationFrame(() => update());
    }
    function deactivate() {
      if (!active) {
        return;
      }
      active = false;
      pressed = false;
      dragging = false;
      moved = false;
      tapPreview = false;
      containerCandidate = null;
      clearTimeout(containerTimer);
      setCursor(false);
      const d = doc();
      if (d[ACTIVE] === api) {
        delete d[ACTIVE];
      }
      emitter.emit("deactivate");
      if (!pending) {
        hide();
      }
    }
    function cancel() {
      if (pending) {
        pending.abort.abort(typeof DOMException === "function" ? new DOMException("Cancelled", "AbortError") : new Error("Cancelled"));
      }
      deactivate();
    }
    const api = {
      get state() {
        return state();
      },
      get target() {
        return target;
      },
      get flags() {
        return flags;
      },
      activate,
      deactivate,
      toggle(o) {
        if (active) {
          deactivate();
        } else {
          activate(o);
        }
      },
      shoot(input) {
        if (destroyed || pending) {
          return Promise.resolve(busy());
        }
        const t = input === void 0 ? target : toTarget(input);
        if (!t) {
          return Promise.resolve({
            ...busy(),
            error: new Error("point-and-shoot: nothing to shoot.")
          });
        }
        target = t;
        rect = boundsFor(t, is.whole);
        return shootTarget(t);
      },
      captureArea(r) {
        if (destroyed || pending) {
          return Promise.resolve(busy());
        }
        if (!opts.area) {
          return Promise.resolve({
            ...busy(),
            error: new Error("point-and-shoot: captureArea() needs the area option.")
          });
        }
        listen();
        mount();
        return shootArea(r);
      },
      cancel,
      setFlags(next) {
        flags = { ...flags, ...next };
        update(false, true);
      },
      refresh() {
        update(false, true);
      },
      configure(next) {
        const overlayChanged = "overlay" in next && next.overlay !== opts.overlay;
        opts = { ...opts, ...next };
        if ("root" in next) {
          is = createHeuristics({ root: opts.root });
        }
        if (overlayChanged) {
          setRenderer();
          if (state() !== "idle") {
            mount();
            render(true);
          }
        }
        if (active) {
          setCursor(true);
          update(false, true);
        }
      },
      flash,
      shake,
      announce(message) {
        if (opts.feedback?.announce !== false) {
          announcer.say(message);
        }
      },
      on(type, listener) {
        return emitter.on(type, listener);
      },
      destroy() {
        if (destroyed) {
          return;
        }
        cancel();
        destroyed = true;
        pending = null;
        listeners?.abort();
        tracker.abort();
        clearTimeout(hideTimer);
        clearTimeout(containerTimer);
        if (renderer && mounted) {
          renderer.unmount();
        }
        mounted = false;
        syncSelectionHighlight(null);
        announcer.destroy();
        emitter.clear();
      }
    };
    return api;
  }

  // node_modules/.pnpm/@daformat+point-and-shoot@1.0.0/node_modules/@daformat/point-and-shoot/dist/markdown.js
  var SKIP = /* @__PURE__ */ new Set([
    "script",
    "style",
    "noscript",
    "template",
    "button",
    "input",
    "select",
    "textarea",
    "form",
    "nav",
    "iframe",
    "object",
    "embed",
    "dialog",
    "point-and-shoot"
  ]);
  function escapeMarkdown(text) {
    return text.replace(/([\\`*_[\]])/g, "\\$1");
  }
  function absolute(url, ctx) {
    try {
      return new URL(url, ctx.baseURI).href;
    } catch {
      return "";
    }
  }
  function imageSource(img, ctx) {
    let src = img.currentSrc || img.getAttribute("src") || "";
    if ((!src || src.startsWith("data:")) && (img.dataset.src || img.dataset.lazySrc)) {
      src = img.dataset.src || img.dataset.lazySrc || "";
    }
    const srcset = img.getAttribute("srcset");
    if (!src && srcset) {
      src = srcset.split(",").pop().trim().split(" ")[0] ?? "";
    }
    if (src.startsWith("data:")) {
      return src.length > ctx.maxDataURL ? "" : src;
    }
    return src ? absolute(src, ctx) : "";
  }
  function isIcon(img, ctx) {
    if (!ctx.iconSize) {
      return false;
    }
    const width = img.isConnected ? img.width : parseInt(img.getAttribute("width") ?? "", 10);
    const height = img.isConnected ? img.height : parseInt(img.getAttribute("height") ?? "", 10);
    return width > 0 && height > 0 && width <= ctx.iconSize && height <= ctx.iconSize;
  }
  function isHidden(el2) {
    if (!el2.isConnected || typeof getComputedStyle !== "function") {
      return false;
    }
    const style = getComputedStyle(el2);
    return style.display === "none" || style.visibility === "hidden";
  }
  function children(node, ctx) {
    return Array.from(node.childNodes).map((n) => convert(n, ctx)).join("");
  }
  function block(text) {
    const trimmed = text.trim();
    return trimmed ? `

${trimmed}

` : "";
  }
  function list(node, ctx) {
    const ordered = node.tagName === "OL";
    let index = parseInt(node.getAttribute("start") || "1", 10) || 1;
    const items = [];
    for (const li of Array.from(node.children)) {
      if (li.tagName !== "LI") {
        continue;
      }
      const marker = ordered ? `${index++}. ` : "- ";
      let content = Array.from(li.childNodes).map((n) => {
        if (n instanceof Element && (n.tagName === "UL" || n.tagName === "OL")) {
          return "\n" + list(n, ctx).trim().replace(/^/gm, "  ");
        }
        return convert(n, ctx);
      }).join("");
      content = content.replace(/\n{2,}/g, "\n").trim();
      const checkbox = li.querySelector(":scope > input[type=checkbox]");
      const task = checkbox ? checkbox.checked ? "[x] " : "[ ] " : "";
      items.push(marker + task + content.replace(/\n/g, "\n" + " ".repeat(marker.length)));
    }
    return `

${items.join("\n")}

`;
  }
  function table(node, ctx) {
    const rows = Array.from(node.querySelectorAll("tr")).map((tr) => Array.from(tr.children).map((cell) => children(cell, ctx).replace(/\s+/g, " ").replace(/\|/g, "\\|").trim()));
    if (!rows.length) {
      return "";
    }
    const width = Math.max(...rows.map((r) => r.length));
    const pad = (r) => r.concat(Array(width - r.length).fill(""));
    const lines = [
      `| ${pad(rows[0]).join(" | ")} |`,
      `| ${Array(width).fill("---").join(" | ")} |`
    ];
    for (const r of rows.slice(1)) {
      lines.push(`| ${pad(r).join(" | ")} |`);
    }
    return `

${lines.join("\n")}

`;
  }
  function wrap(text, mark) {
    return text.trim() ? `${mark}${text.trim()}${mark}` : text;
  }
  function convert(node, ctx) {
    if (node.nodeType === Node.TEXT_NODE) {
      const value = node.nodeValue ?? "";
      return ctx.pre ? value : escapeMarkdown(value.replace(/\s+/g, " "));
    }
    if (node.nodeType === Node.DOCUMENT_FRAGMENT_NODE) {
      return children(node, ctx);
    }
    if (!(node instanceof Element)) {
      return "";
    }
    const tag = node.tagName.toLowerCase();
    if (SKIP.has(tag) || node.getAttribute("aria-hidden") === "true" || isHidden(node)) {
      return "";
    }
    if (tag === "sup" && /^\s*\[\s*[\w\s]{1,12}\]\s*$/.test(node.textContent ?? "")) {
      return "";
    }
    switch (tag) {
      case "h1":
      case "h2":
      case "h3":
      case "h4":
      case "h5":
      case "h6": {
        const text = children(node, ctx).replace(/\s+/g, " ").trim();
        return text ? `

${"#".repeat(+tag[1])} ${text}

` : "";
      }
      case "p":
      case "div":
      case "section":
      case "article":
      case "header":
      case "footer":
      case "main":
      case "aside":
      case "figure":
      case "dl":
      case "dd":
      case "dt":
      case "details":
      case "summary":
      case "address":
        return block(children(node, ctx));
      case "br":
        return "\n";
      case "hr":
        return "\n\n---\n\n";
      case "strong":
      case "b":
        return wrap(children(node, ctx), "**");
      case "em":
      case "i":
      case "cite":
        return wrap(children(node, ctx), "*");
      case "del":
      case "s":
      case "strike":
        return wrap(children(node, ctx), "~~");
      case "code":
      case "kbd":
      case "samp":
        return ctx.pre ? node.textContent ?? "" : "`" + (node.textContent ?? "").replace(/`/g, "'") + "`";
      case "pre": {
        const code = node instanceof HTMLElement && node.isConnected && typeof node.innerText === "string" ? node.innerText : node.textContent ?? "";
        const lang = (node.querySelector("code")?.className.match(/language-(\S+)/) || [])[1] || "";
        return `

\`\`\`${lang}
${code.replace(/\n+$/, "")}
\`\`\`

`;
      }
      case "blockquote":
        return "\n\n" + children(node, ctx).trim().replace(/\n{3,}/g, "\n\n").replace(/^/gm, "> ") + "\n\n";
      case "ul":
      case "ol":
        return list(node, ctx);
      case "li":
        return block("- " + children(node, ctx).trim());
      case "table":
        return table(node, ctx);
      case "a": {
        const text = children(node, ctx).replace(/\s+/g, " ").trim();
        const href = node.getAttribute("href");
        if (!href || href.startsWith("javascript:") || href.startsWith("#")) {
          return text;
        }
        if (!text) {
          return "";
        }
        return /^!\[/.test(text) ? text : `[${text}](${absolute(href, ctx)})`;
      }
      case "img": {
        const img = node;
        if (isIcon(img, ctx)) {
          return "";
        }
        const src = imageSource(img, ctx);
        if (!src) {
          return "";
        }
        const alt = (node.getAttribute("alt") || "").replace(/[[\]\n]/g, " ").trim();
        return `![${alt}](${src})`;
      }
      case "picture": {
        const img = node.querySelector("img");
        return img ? convert(img, ctx) : "";
      }
      case "figcaption": {
        const text = children(node, ctx).trim();
        return text ? `

*${text}*

` : "";
      }
      case "video": {
        const video = node;
        const src = video.currentSrc || node.getAttribute("src");
        return src ? `![Video](${absolute(src, ctx)})` : "";
      }
      case "svg":
      case "canvas":
        return "";
      default:
        return children(node, ctx);
    }
  }
  function toMarkdown(node, options = {}) {
    const source = node instanceof Range ? node.cloneContents() : node;
    const doc = node instanceof Range ? node.startContainer.ownerDocument : node.ownerDocument;
    const ctx = {
      baseURI: options.baseURI ?? doc?.baseURI ?? "",
      iconSize: options.iconSize ?? 32,
      maxDataURL: options.maxDataURL ?? 2e5
    };
    const markdown = convert(source, ctx).replace(/[ \t]+\n/g, "\n").replace(/\n{3,}/g, "\n\n").trim();
    if (!markdown && node instanceof Range) {
      return escapeMarkdown(node.toString().trim());
    }
    return markdown;
  }

  // glea-pns.ts
  (() => {
    if (location.protocol === "chrome-error:") {
      const sheet = new CSSStyleSheet();
      sheet.replaceSync(
        "html { background: #fff !important; } body { display: none !important; }@media (prefers-color-scheme: dark) { html { background: #1c1c1f !important; } }"
      );
      document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      return;
    }
    if (window.__gleaPNS || typeof __gleaNative === "undefined") {
      return;
    }
    const native = __gleaNative;
    const YOUTUBE_ITEMS = "ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, ytd-playlist-video-renderer, ytd-reel-item-renderer, yt-lockup-view-model, ytm-shorts-lockup-view-model, ytm-video-with-context-renderer, ytm-compact-video-renderer";
    function siteHost() {
      return location.hostname.replace(/^(?:www|mobile|m)\./, "");
    }
    function parentOf2(node) {
      return node.parentElement || (node.parentNode instanceof ShadowRoot ? node.parentNode.host : null);
    }
    function linkIn(node, hosts, path) {
      for (const a of Array.from(node.querySelectorAll("a[href]"))) {
        let url;
        try {
          url = new URL(a.getAttribute("href"), location.href);
        } catch {
          continue;
        }
        if (hosts.test(url.hostname) && path.test(url.pathname)) {
          return url;
        }
      }
      return null;
    }
    function youtubeURL(url) {
      if (!url) {
        return null;
      }
      const shorts = url.pathname.match(/^\/shorts\/([\w-]+)/);
      if (shorts) {
        return `https://www.youtube.com/shorts/${shorts[1]}`;
      }
      const id = url.searchParams.get("v");
      return id ? `https://www.youtube.com/watch?v=${id}` : null;
    }
    function embedOf(node) {
      const tag = node.tagName;
      if (tag === "BLOCKQUOTE") {
        if (node.classList.contains("twitter-tweet")) {
          const links = Array.from(node.querySelectorAll('a[href*="/status/"]'));
          return links.length ? links[links.length - 1].href.split("?")[0] : null;
        }
        if (node.classList.contains("bluesky-embed")) {
          const uri = node.dataset.blueskyUri || "";
          const m = uri.match(/^at:\/\/([^/]+)\/app\.bsky\.feed\.post\/(\w+)/);
          if (m) {
            return `https://bsky.app/profile/${m[1]}/post/${m[2]}`;
          }
          const link = linkIn(node, /(^|\.)bsky\.app$/, /^\/profile\/[^/]+\/post\/\w+\/?$/);
          return link ? link.href : null;
        }
        if (node.classList.contains("instagram-media")) {
          const permalink = node.dataset.instgrmPermalink;
          return permalink ? permalink.split("?")[0] : null;
        }
        return null;
      }
      const host = siteHost();
      if ((host === "x.com" || host === "twitter.com") && tag === "ARTICLE") {
        const time = node.querySelector('a[href*="/status/"] time');
        if (time) {
          return time.closest("a").href.split("?")[0];
        }
        const link = linkIn(node, /(^|\.)(x|twitter)\.com$/, /^\/\w+\/status\/\d+\/?$/);
        if (link) {
          return link.href;
        }
        return /^\/\w+\/status\/\d+\/?$/.test(location.pathname) ? location.origin + location.pathname : null;
      }
      if (host === "bsky.app" && node.matches('[data-testid^="feedItem-by-"], [data-testid^="postThreadItem-by-"]')) {
        const link = linkIn(node, /(^|\.)bsky\.app$/, /^\/profile\/[^/]+\/post\/\w+\/?$/);
        if (link) {
          return link.href;
        }
        return /^\/profile\/[^/]+\/post\/\w+\/?$/.test(location.pathname) ? location.origin + location.pathname : null;
      }
      if (host === "instagram.com" && tag === "ARTICLE") {
        const link = linkIn(node, /(^|\.)instagram\.com$/, /^\/(?:[\w.]+\/)?(?:p|reel|tv)\/[\w-]+\/?$/);
        const path = link ? link.pathname : location.pathname;
        const m = path.match(/\/(p|reel|tv)\/([\w-]+)/);
        return m ? `https://www.instagram.com/${m[1]}/${m[2]}/` : null;
      }
      if (host === "youtube.com") {
        if (node.matches("#movie_player, .html5-video-player, #player-container-id")) {
          return youtubeURL(new URL(location.href));
        }
        if (node.matches(YOUTUBE_ITEMS)) {
          return youtubeURL(linkIn(node, /(^|\.)youtube\.com$/, /^\/(?:watch|shorts\/)/));
        }
      }
      return null;
    }
    function findEmbed(start) {
      for (let node = start, depth = 0; node && node !== document.body && depth < 40; node = parentOf2(node), depth++) {
        const url = embedOf(node);
        if (url) {
          return { node, url };
        }
      }
      return null;
    }
    const embeds = {
      name: "embeds",
      resolve: ({ stack, flags, is }) => {
        if (flags.textOnly) {
          return null;
        }
        for (const node of stack) {
          const hit = findEmbed(node);
          if (hit && hit.node.getBoundingClientRect().width > 0) {
            return { kind: "embed", node: hit.node, whole: true, data: { url: hit.url } };
          }
          if (is.meaningful(node)) {
            break;
          }
        }
        return null;
      }
    };
    function embedURL(src) {
      let m = src.match(/youtube(?:-nocookie)?\.com\/embed\/([\w-]+)/);
      if (m) {
        return `https://www.youtube.com/watch?v=${m[1]}`;
      }
      m = src.match(/player\.vimeo\.com\/video\/(\d+)/);
      if (m) {
        return `https://vimeo.com/${m[1]}`;
      }
      m = src.match(/open\.spotify\.com\/embed\/(\w+)\/(\w+)/);
      if (m) {
        return `https://open.spotify.com/${m[1]}/${m[2]}`;
      }
      m = src.match(/platform\.twitter\.com\/embed\/Tweet\.html\?(?:.*&)?id=(\d+)/);
      if (m) {
        return `https://twitter.com/i/status/${m[1]}`;
      }
      m = src.match(/embed\.bsky\.app\/embed\/([^/]+)\/app\.bsky\.feed\.post\/(\w+)/);
      if (m) {
        return `https://bsky.app/profile/${decodeURIComponent(m[1])}/post/${m[2]}`;
      }
      m = src.match(/instagram\.com\/(p|reel|tv)\/([\w-]+)/);
      if (m) {
        return `https://www.instagram.com/${m[1]}/${m[2]}/`;
      }
      return src;
    }
    let answer = null;
    let pixelsTaken = null;
    function post(name, payload, ctx) {
      native.post(name, JSON.stringify({ url: location.href, title: document.title, ...payload }));
      return new Promise((resolve) => {
        answer = { resolve };
        ctx.signal.addEventListener("abort", () => {
          if (answer?.resolve === resolve) {
            answer = null;
          }
        });
      });
    }
    function absolute2(url) {
      try {
        return new URL(url, document.baseURI).href;
      } catch {
        return "";
      }
    }
    function backgroundImage2(element) {
      const m = getComputedStyle(element).backgroundImage.match(/url\(\s*(['"]?)(.*?)\1\s*\)/);
      return m && m[2] ? m[2] : null;
    }
    function textOf(node) {
      return ((node instanceof HTMLElement ? node.innerText : node.textContent) || "").trim().slice(0, 600);
    }
    async function captureArea(rect, ctx) {
      if (rect.viewport.width < 4 || rect.viewport.height < 4) {
        throw new Error("Too small");
      }
      pixelsTaken = await ctx.hideOverlay();
      return post(
        "captureArea",
        { rect: rect.viewport, page: rect.page, viewport: rect.viewportSize },
        ctx
      );
    }
    function shoot(target, ctx) {
      const rect = ctx.rect.viewport;
      if (target.node instanceof Range) {
        const range = target.node;
        const markdown2 = toMarkdown(range) || escapeMarkdown(range.toString());
        return post("capture", { kind: "selection", markdown: markdown2, text: range.toString().trim().slice(0, 600), rect }, ctx);
      }
      const node = target.node;
      if (target.kind === "embed" && target.data) {
        return post("capture", { kind: "element", markdown: target.data.url, text: textOf(node), rect }, ctx);
      }
      if (node instanceof HTMLIFrameElement) {
        const src = node.src || node.getAttribute("src") || "";
        if (/^https?:/.test(src)) {
          return post("capture", { kind: "element", markdown: embedURL(src), text: node.title || "", rect }, ctx);
        }
        return ctx.captureArea();
      }
      if (node instanceof HTMLCanvasElement) {
        return ctx.captureArea();
      }
      const image = target.kind !== "element";
      const img = node.tagName === "IMG" ? node : node.querySelector("img");
      let markdown = image && img ? toMarkdown(node.tagName === "FIGURE" ? node : img) : toMarkdown(node);
      if (!markdown && image) {
        const bg = backgroundImage2(node);
        if (bg) {
          markdown = `![](${absolute2(bg)})`;
        }
      }
      if (!markdown) {
        return ctx.captureArea();
      }
      return post(
        "capture",
        {
          kind: image ? "image" : "element",
          markdown,
          text: image ? img && img.alt || "" : textOf(node),
          rect
        },
        ctx
      );
    }
    const pns = createPointAndShoot({
      targets: [embeds, ...defaultTargets],
      // Text selected: ⌥ collects it at once (Beam), no click.
      selection: "shoot",
      onShoot: shoot,
      area: { onCapture: captureArea },
      // ⌥, alone or with ⌘: a release can go unseen (focus elsewhere, another
      // app), so the real key state decides.
      guard: (e) => e.altKey && !e.ctrlKey,
      feedback: {
        announce: { success: (r) => r.value?.message ?? "Collected" }
      }
    });
    addEventListener(
      "pointermove",
      (e) => {
        if (pns.state === "active" && e.metaKey !== !!pns.flags.textOnly) {
          pns.setFlags({ textOnly: e.metaKey });
        }
      },
      true
    );
    addEventListener(
      "keydown",
      (e) => {
        if (pns.state === "active" && (e.ctrlKey || e.metaKey && e.key !== "Meta")) {
          pns.deactivate();
        }
      },
      true
    );
    const BADGE_CSS = `
    :host { all: initial; }
    .badge {
      position: fixed; left: 0; top: 0; z-index: 2147483647;
      transform: translate(var(--bx), var(--by)) scale(.9); transform-origin: left top;
      opacity: 0; padding: 5px 10px 5px 8px; border-radius: 999px;
      display: flex; align-items: center; gap: 6px; white-space: nowrap; pointer-events: none;
      font: 600 12px/16px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif;
      color: #fff; background: rgba(28, 28, 32, .92);
      box-shadow: 0 4px 14px rgba(0,0,0,.18), 0 1px 2px rgba(0,0,0,.2);
      transition: opacity 180ms ease-out, transform 420ms cubic-bezier(0.32, 0.72, 0, 1);
    }
    .badge.show { opacity: 1; transform: translate(var(--bx), var(--by)) scale(1); }
    svg { width: 14px; height: 14px; flex: none; }
    path { stroke-dasharray: 16; stroke-dashoffset: 16; transition: stroke-dashoffset 320ms 120ms ease-out; }
    .badge.show path { stroke-dashoffset: 0; }
  `;
    let badgeTimer = 0;
    function showBadge(message, r) {
      const host = document.createElement("glea-badge");
      host.style.cssText = "all: initial !important; display: contents !important;";
      const shadow = host.attachShadow({ mode: "closed" });
      const style = document.createElement("style");
      style.textContent = BADGE_CSS;
      const badge = document.createElement("div");
      badge.className = "badge";
      const svg = document.createElementNS("http://www.w3.org/2000/svg", "svg");
      svg.setAttribute("viewBox", "0 0 16 16");
      svg.setAttribute("fill", "none");
      const circle = document.createElementNS("http://www.w3.org/2000/svg", "circle");
      for (const [k, v] of Object.entries({ cx: "8", cy: "8", r: "7.25", fill: "#34c759" })) {
        circle.setAttribute(k, v);
      }
      const path = document.createElementNS("http://www.w3.org/2000/svg", "path");
      for (const [k, v] of Object.entries({
        d: "M4.8 8.3l2.1 2.1 4.3-4.6",
        stroke: "#fff",
        "stroke-width": "1.7",
        "stroke-linecap": "round",
        "stroke-linejoin": "round"
      })) {
        path.setAttribute(k, v);
      }
      svg.append(circle, path);
      const text = document.createElement("span");
      text.textContent = message;
      badge.append(svg, text);
      shadow.append(style, badge);
      document.querySelector("glea-badge")?.remove();
      (document.documentElement || document).appendChild(host);
      const below = r.y + r.height + 12;
      const y = below + 30 < innerHeight ? below : Math.max(8, r.y - 38);
      badge.style.setProperty("--bx", `${Math.max(8, Math.min(r.x, innerWidth - 220))}px`);
      badge.style.setProperty("--by", `${y}px`);
      void badge.offsetWidth;
      badge.classList.add("show");
      clearTimeout(badgeTimer);
      badgeTimer = window.setTimeout(() => {
        badge.classList.remove("show");
        badgeTimer = window.setTimeout(() => host.remove(), 260);
      }, 1400);
    }
    let activateAfter = null;
    pns.on("shot", (result) => {
      const message = result.ok ? result.value?.message : void 0;
      if (message) {
        showBadge(message, result.rect.viewport);
      }
      const again = activateAfter;
      activateAfter = null;
      if (again && result.ok) {
        queueMicrotask(() => pns.activate(again));
      }
    });
    let pointerKnown = false;
    addEventListener("pointermove", () => pointerKnown = true, { capture: true, once: true });
    const api = {
      // x/y: the pointer in the viewport, from the app, for when the page
      // hasn't seen the mouse move yet.
      setActive(on, x, y) {
        if (!on) {
          activateAfter = null;
          pns.deactivate();
          return;
        }
        const at = !pointerKnown && typeof x === "number" && typeof y === "number" ? { x, y } : void 0;
        if (pns.state === "pending") {
          activateAfter = { at };
          return;
        }
        pns.activate({ at });
      },
      // ⌘ held with ⌥: posts and videos are collected as text and images.
      setTextOnly(on) {
        if (!!pns.flags.textOnly !== !!on) {
          pns.setFlags({ textOnly: !!on });
        }
      },
      // The app collected it. With a message, a badge confirms on the page.
      done(message) {
        const pending = answer;
        answer = null;
        pixelsTaken = null;
        if (pending) {
          pending.resolve(message ? { message } : void 0);
        } else {
          pns.deactivate();
        }
      },
      // An area's pixels are taken: the overlay comes back, with its flash.
      shotTaken() {
        pixelsTaken?.();
        pixelsTaken = null;
      },
      // Nothing collected: let go of the target, quietly.
      cancel() {
        answer = null;
        pixelsTaken = null;
        pns.cancel();
      },
      collectSelection() {
        const range = selectionRange();
        if (range) {
          void pns.shoot(range);
        }
      },
      collectImage(src) {
        const img = Array.from(document.images).find((i) => i.currentSrc === src || i.src === src);
        if (img) {
          void pns.shoot(img.closest("figure") || img);
        } else {
          native.post(
            "capture",
            JSON.stringify({ url: location.href, title: document.title, kind: "image", markdown: `![](${src})`, text: "", rect: null })
          );
        }
      }
    };
    Object.defineProperty(window, "__gleaPNS", { value: Object.freeze(api), enumerable: false });
  })();
})();
