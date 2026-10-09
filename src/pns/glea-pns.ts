// Point-and-shoot: injected into every page's main frame before page scripts.
// Built with the library into src/resources/content-script.js (`pnpm build`
// here), which the app evaluates and glea-extensions copies.
//
// @daformat/point-and-shoot does the pointing: the spotlight that morphs onto
// the block under the cursor, the press, the drag, the flash and the shake.
// This is Glea's part around it: posts and videos as embeds, what a shot
// sends to the app, the badge, and the window.__gleaPNS calls the app (and
// the extensions' pns-driver.js) already make:
//
// - setActive(on, x, y) while ⌥ is held; setTextOnly(on) while ⌘ joins it.
// - A click posts __gleaNative.post("capture", json), a drag "captureArea".
//   The shot stays pending until the app answers: done(message) or cancel(),
//   and shotTaken() once an area's pixels are taken.
// - collectSelection() and collectImage(src), from the context menu.

import {
  type AreaRect,
  createPointAndShoot,
  defaultTargets,
  selectionRange,
  type ShootContext,
  type Target,
  type Targeter,
} from "@daformat/point-and-shoot";
import { escapeMarkdown, toMarkdown } from "@daformat/point-and-shoot/markdown";

declare const __gleaNative: { post(name: string, json: string): void } | undefined;

declare global {
  interface Window {
    __gleaPNS?: unknown;
  }
}

type Embed = { url: string };
type Answer = { message?: string } | undefined;

(() => {
  // Chromium's own error page: keep it blank (in Glea's background color).
  // The app shows its own error view, and this avoids a flash of both.
  if (location.protocol === "chrome-error:") {
    // The document is still empty here; an adopted sheet applies before the
    // first paint anyway.
    const sheet = new CSSStyleSheet();
    sheet.replaceSync(
      "html { background: #fff !important; } body { display: none !important; }" +
        "@media (prefers-color-scheme: dark) { html { background: #1c1c1f !important; } }",
    );
    document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
    return;
  }
  if (window.__gleaPNS || typeof __gleaNative === "undefined") {
    return;
  }
  const native = __gleaNative;

  // ------------------------------------------------------------- embeds

  // Posts and videos the notes can embed again (YouTube, X, Bluesky,
  // Instagram): pointing anywhere over one spotlights all of it, and
  // collecting it keeps its address, which the note shows as an embed.

  const YOUTUBE_ITEMS =
    "ytd-rich-item-renderer, ytd-video-renderer, ytd-compact-video-renderer, " +
    "ytd-grid-video-renderer, ytd-playlist-video-renderer, ytd-reel-item-renderer, yt-lockup-view-model, " +
    "ytm-shorts-lockup-view-model, ytm-video-with-context-renderer, ytm-compact-video-renderer";

  function siteHost(): string {
    return location.hostname.replace(/^(?:www|mobile|m)\./, "");
  }

  function parentOf(node: Element): Element | null {
    return (
      node.parentElement ||
      (node.parentNode instanceof ShadowRoot ? node.parentNode.host : null)
    );
  }

  // The first link inside `node` to a page of `hosts` whose path matches.
  function linkIn(node: Element, hosts: RegExp, path: RegExp): URL | null {
    for (const a of Array.from(node.querySelectorAll("a[href]"))) {
      let url: URL;
      try {
        url = new URL(a.getAttribute("href")!, location.href);
      } catch {
        continue;
      }
      if (hosts.test(url.hostname) && path.test(url.pathname)) {
        return url;
      }
    }
    return null;
  }

  function youtubeURL(url: URL | null): string | null {
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

  // The post or video `node` is, on these sites or embedded elsewhere.
  function embedOf(node: Element): string | null {
    const tag = node.tagName;
    // Embeds on other sites, before (or without) their script: the quote.
    if (tag === "BLOCKQUOTE") {
      if (node.classList.contains("twitter-tweet")) {
        const links = Array.from(node.querySelectorAll<HTMLAnchorElement>('a[href*="/status/"]'));
        return links.length ? links[links.length - 1]!.href.split("?")[0]! : null;
      }
      if (node.classList.contains("bluesky-embed")) {
        const uri = (node as HTMLElement).dataset.blueskyUri || "";
        const m = uri.match(/^at:\/\/([^/]+)\/app\.bsky\.feed\.post\/(\w+)/);
        if (m) {
          return `https://bsky.app/profile/${m[1]}/post/${m[2]}`;
        }
        const link = linkIn(node, /(^|\.)bsky\.app$/, /^\/profile\/[^/]+\/post\/\w+\/?$/);
        return link ? link.href : null;
      }
      if (node.classList.contains("instagram-media")) {
        const permalink = (node as HTMLElement).dataset.instgrmPermalink;
        return permalink ? permalink.split("?")[0]! : null;
      }
      return null;
    }
    const host = siteHost();
    if ((host === "x.com" || host === "twitter.com") && tag === "ARTICLE") {
      // The post's own address is the link around its timestamp.
      const time = node.querySelector('a[href*="/status/"] time');
      if (time) {
        return time.closest("a")!.href.split("?")[0]!;
      }
      const link = linkIn(node, /(^|\.)(x|twitter)\.com$/, /^\/\w+\/status\/\d+\/?$/);
      if (link) {
        return link.href;
      }
      // The post a status page is about has no link to itself.
      return /^\/\w+\/status\/\d+\/?$/.test(location.pathname)
        ? location.origin + location.pathname
        : null;
    }
    if (
      host === "bsky.app" &&
      node.matches('[data-testid^="feedItem-by-"], [data-testid^="postThreadItem-by-"]')
    ) {
      const link = linkIn(node, /(^|\.)bsky\.app$/, /^\/profile\/[^/]+\/post\/\w+\/?$/);
      if (link) {
        return link.href;
      }
      return /^\/profile\/[^/]+\/post\/\w+\/?$/.test(location.pathname)
        ? location.origin + location.pathname
        : null;
    }
    if (host === "instagram.com" && tag === "ARTICLE") {
      const link = linkIn(node, /(^|\.)instagram\.com$/, /^\/(?:[\w.]+\/)?(?:p|reel|tv)\/[\w-]+\/?$/);
      const path = link ? link.pathname : location.pathname;
      const m = path.match(/\/(p|reel|tv)\/([\w-]+)/);
      return m ? `https://www.instagram.com/${m[1]}/${m[2]}/` : null;
    }
    if (host === "youtube.com") {
      // The player: the video being watched. A thumbnail or list item: its video.
      if (node.matches("#movie_player, .html5-video-player, #player-container-id")) {
        return youtubeURL(new URL(location.href));
      }
      if (node.matches(YOUTUBE_ITEMS)) {
        return youtubeURL(linkIn(node, /(^|\.)youtube\.com$/, /^\/(?:watch|shorts\/)/));
      }
    }
    return null;
  }

  // The post or video around `start` (itself or an ancestor), if any.
  function findEmbed(start: Element): { node: Element; url: string } | null {
    for (
      let node: Element | null = start, depth = 0;
      node && node !== document.body && depth < 40;
      node = parentOf(node), depth++
    ) {
      const url = embedOf(node);
      if (url) {
        return { node, url };
      }
    }
    return null;
  }

  // Through empty layers (a dialog's backdrop, a transparent link), up to the
  // first element with something of its own to show. ⌘ held: none of this.
  const embeds: Targeter<Embed> = {
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
    },
  };

  // Player addresses back to the page people share (the notes recognise those).
  function embedURL(src: string): string {
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
      return `https://bsky.app/profile/${decodeURIComponent(m[1]!)}/post/${m[2]}`;
    }
    m = src.match(/instagram\.com\/(p|reel|tv)\/([\w-]+)/);
    if (m) {
      return `https://www.instagram.com/${m[1]}/${m[2]}/`;
    }
    return src;
  }

  // ------------------------------------------------------------- the app

  // The shot waiting for the app's answer, and the overlay waiting for an
  // area's pixels to be taken.
  let answer: { resolve(a: Answer): void } | null = null;
  let pixelsTaken: (() => void) | null = null;

  function post(name: string, payload: object, ctx: ShootContext<Answer>): Promise<Answer> {
    native.post(name, JSON.stringify({ url: location.href, title: document.title, ...payload }));
    return new Promise<Answer>((resolve) => {
      answer = { resolve };
      // Escape (or a new page) drops it.
      ctx.signal.addEventListener("abort", () => {
        if (answer?.resolve === resolve) {
          answer = null;
        }
      });
    });
  }

  function absolute(url: string): string {
    try {
      return new URL(url, document.baseURI).href;
    } catch {
      return "";
    }
  }

  function backgroundImage(element: Element): string | null {
    const m = getComputedStyle(element).backgroundImage.match(/url\(\s*(['"]?)(.*?)\1\s*\)/);
    return m && m[2] ? m[2] : null;
  }

  function textOf(node: Element): string {
    return ((node instanceof HTMLElement ? node.innerText : node.textContent) || "").trim().slice(0, 600);
  }

  // Taken as a picture: hides the overlay so it isn't in it; the app calls
  // shotTaken() once it has the pixels.
  async function captureArea(rect: AreaRect, ctx: ShootContext<Answer>): Promise<Answer> {
    if (rect.viewport.width < 4 || rect.viewport.height < 4) {
      throw new Error("Too small");
    }
    pixelsTaken = await ctx.hideOverlay();
    return post(
      "captureArea",
      { rect: rect.viewport, page: rect.page, viewport: rect.viewportSize },
      ctx,
    );
  }

  function shoot(target: Target<Embed>, ctx: ShootContext<Answer>): Promise<Answer> {
    const rect = ctx.rect.viewport;
    if (target.node instanceof Range) {
      const range = target.node;
      const markdown = toMarkdown(range) || escapeMarkdown(range.toString());
      return post("capture", { kind: "selection", markdown, text: range.toString().trim().slice(0, 600), rect }, ctx);
    }
    const node = target.node;
    if (target.kind === "embed" && target.data) {
      return post("capture", { kind: "element", markdown: target.data.url, text: textOf(node), rect }, ctx);
    }
    if (node instanceof HTMLIFrameElement) {
      // An embedded player or post: its address (the notes embed it again).
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
    const img = node.tagName === "IMG" ? (node as HTMLImageElement) : node.querySelector("img");
    let markdown = image && img ? toMarkdown(node.tagName === "FIGURE" ? node : img) : toMarkdown(node);
    if (!markdown && image) {
      const bg = backgroundImage(node);
      if (bg) {
        markdown = `![](${absolute(bg)})`;
      }
    }
    // Nothing Markdown can hold (drawings, custom widgets): keep a picture.
    if (!markdown) {
      return ctx.captureArea();
    }
    return post(
      "capture",
      {
        kind: image ? "image" : "element",
        markdown,
        text: image ? (img && img.alt) || "" : textOf(node),
        rect,
      },
      ctx,
    );
  }

  const pns = createPointAndShoot<Embed, Answer>({
    targets: [embeds, ...defaultTargets],
    // Text selected: ⌥ collects it at once (Beam), no click.
    selection: "shoot",
    onShoot: shoot,
    area: { onCapture: captureArea },
    // ⌥, alone or with ⌘: a release can go unseen (focus elsewhere, another
    // app), so the real key state decides.
    guard: (e) => e.altKey && !e.ctrlKey,
    feedback: {
      announce: { success: (r) => r.value?.message ?? "Collected" },
    },
  });

  // ⌘ joining ⌥ (or leaving), seen on the pointer: posts and videos as text.
  addEventListener(
    "pointermove",
    (e) => {
      if (pns.state === "active" && e.metaKey !== !!pns.flags.textOnly) {
        pns.setFlags({ textOnly: e.metaKey });
      }
    },
    true,
  );

  // A shortcut (⌥⌘→...), not ⌘ joining ⌥: leave the mode.
  addEventListener(
    "keydown",
    (e) => {
      if (pns.state === "active" && (e.ctrlKey || (e.metaKey && e.key !== "Meta"))) {
        pns.deactivate();
      }
    },
    true,
  );

  // ------------------------------------------------------------- the badge

  // "Sent to Glea" from the extensions, by the target; the app shows its own toast.
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

  function showBadge(message: string, r: { x: number; y: number; width: number; height: number }) {
    // Built node by node: pages with Trusted Types (Gmail) reject innerHTML.
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
      "stroke-linejoin": "round",
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

  // setActive(true) while a shot waits for the app's answer (⌥ still held
  // as it lands, on glea.app's demo): the mode comes back once it's collected.
  let activateAfter: { at?: { x: number; y: number } } | null = null;

  pns.on("shot", (result) => {
    const message = result.ok ? result.value?.message : undefined;
    if (message) {
      showBadge(message, result.rect.viewport);
    }
    const again = activateAfter;
    activateAfter = null;
    if (again && result.ok) {
      // After the shot has let go of the mode (this runs just before).
      queueMicrotask(() => pns.activate(again));
    }
  });

  // ------------------------------------------------------------- the API

  let pointerKnown = false;
  addEventListener("pointermove", () => (pointerKnown = true), { capture: true, once: true });

  const api = {
    // x/y: the pointer in the viewport, from the app, for when the page
    // hasn't seen the mouse move yet.
    setActive(on: boolean, x?: number, y?: number) {
      if (!on) {
        // A shot waiting for the app keeps the spotlight until it answers.
        activateAfter = null;
        pns.deactivate();
        return;
      }
      const at = !pointerKnown && typeof x === "number" && typeof y === "number" ? { x, y } : undefined;
      if (pns.state === "pending") {
        activateAfter = { at };
        return;
      }
      pns.activate({ at });
    },
    // ⌘ held with ⌥: posts and videos are collected as text and images.
    setTextOnly(on: boolean) {
      if (!!pns.flags.textOnly !== !!on) {
        pns.setFlags({ textOnly: !!on });
      }
    },
    // The app collected it. With a message, a badge confirms on the page.
    done(message?: string) {
      const pending = answer;
      answer = null;
      pixelsTaken = null;
      if (pending) {
        pending.resolve(message ? { message } : undefined);
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
      // In shadow roots too, where the page sees only a collapsed range.
      const range = selectionRange();
      if (range) {
        void pns.shoot(range);
      }
    },
    collectImage(src: string) {
      const img = Array.from(document.images).find((i) => i.currentSrc === src || i.src === src);
      if (img) {
        void pns.shoot(img.closest("figure") || img);
      } else {
        native.post(
          "capture",
          JSON.stringify({ url: location.href, title: document.title, kind: "image", markdown: `![](${src})`, text: "", rect: null }),
        );
      }
    },
  };
  Object.defineProperty(window, "__gleaPNS", { value: Object.freeze(api), enumerable: false });
})();
