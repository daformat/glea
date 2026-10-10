// Glea Clipper: collects from the browser into Glea by opening a
// glea://capture URL, which Glea handles (glea/src/app/ExternalCapture.swift).
// The same file runs as Chrome's service worker and Firefox/Safari's
// background script.

const api = globalThis.browser ?? globalThis.chrome;

// Longer captures go through the clipboard (browsers drop very long URLs).
const MAX_URL_LENGTH = 1_500_000;

const DEFAULTS = { to: 'journal', open: false };

async function settings() {
  return Object.assign({}, DEFAULTS, await api.storage.local.get(Object.keys(DEFAULTS)));
}

function isWebPage(url) {
  return /^https?:/i.test(url || '');
}

// Runs capture.js in the tab, then one of its functions.
async function inPage(tabId, name, ...args) {
  await api.scripting.executeScript({ target: { tabId }, files: ['capture.js'] });
  const [result] = await api.scripting.executeScript({
    target: { tabId },
    func: (name, args) => window.__gleaClip[name](...args),
    args: [name, args],
  });
  return result && result.result;
}

async function copyInPage(tabId, text) {
  const [result] = await api.scripting.executeScript({
    target: { tabId },
    func: async (text) => {
      try {
        await navigator.clipboard.writeText(text);
        return true;
      } catch (e) {
        const field = document.createElement('textarea');
        field.value = text;
        field.style.cssText = 'position:fixed;top:-1000px;opacity:0';
        document.documentElement.appendChild(field);
        field.select();
        const copied = document.execCommand('copy');
        field.remove();
        return copied;
      }
    },
    args: [text],
  });
  return !!(result && result.result);
}

// What to collect from the tab: 'page', 'selection', 'article', or
// { image: src } / { link: url, text }. Returns the capture to send.
async function extract(tab, what) {
  const page = { url: tab.url, title: tab.title || tab.url };
  if (what === 'page') return { ...page, kind: 'page', markdown: '' };
  // (Objects only: strings have a .link() method of their own.)
  if (typeof what === 'object' && what.link) {
    return { kind: 'page', markdown: '', url: what.link, title: (what.text || '').trim() || what.link };
  }
  if (typeof what === 'object' && what.image) {
    let capture;
    try { capture = await inPage(tab.id, 'image', what.image); } catch (e) { /* restricted page */ }
    return { ...page, ...(capture || { kind: 'image', markdown: `![](${what.image})`, text: '' }), title: page.title };
  }
  const capture = await inPage(tab.id, what);
  if (!capture) throw new Error(what === 'selection' ? 'Nothing is selected.' : 'Nothing to collect on this page.');
  return { ...page, ...capture, title: capture.title || page.title };
}

// Sends a capture to Glea. `to`: 'journal', 'ask', or { note: name }.
async function send(tab, capture, to, open) {
  const params = new URLSearchParams();
  params.set('kind', capture.kind);
  params.set('url', capture.url);
  params.set('title', capture.title || '');
  if (capture.text) params.set('text', capture.text);
  if (to && to.note) {
    params.set('to', 'note');
    params.set('note', to.note);
  } else {
    params.set('to', to === 'ask' ? 'ask' : 'journal');
  }
  if (open) params.set('open', '1');

  // %20, not +: Glea reads the query with URLComponents.
  const encode = (p) => p.toString().replace(/\+/g, '%20');
  let url = `glea://capture?${encode(params)}`;
  if (capture.markdown) {
    const withContent = new URLSearchParams(params);
    withContent.set('markdown', capture.markdown);
    url = `glea://capture?${encode(withContent)}`;
    if (url.length > MAX_URL_LENGTH) {
      if (!(await copyInPage(tab.id, capture.markdown))) throw new Error('This capture is too long to send to Glea.');
      params.set('clipboard', '1');
      url = `glea://capture?${encode(params)}`;
    }
  }
  // Navigating the tab to the scheme hands the URL to Glea (the browser asks
  // the first time) and leaves the page where it is.
  await api.tabs.update(tab.id, { url });
}

async function collect(tab, what, destination) {
  if (!tab || !isWebPage(tab.url)) throw new Error('Glea can only collect from web pages.');
  const prefs = await settings();
  const capture = await extract(tab, what);
  await send(tab, capture, destination?.to ?? prefs.to, destination?.open ?? prefs.open);
  return capture.kind;
}

// -------------------------------------------------------- point and shoot

function base64(buffer) {
  const bytes = new Uint8Array(buffer);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

// A dragged area: the visible tab, cropped to `rect` (CSS pixels), as a
// data URL (Glea saves it into assets/).
async function screenshot(tab, rect, viewport) {
  const shot = await api.tabs.captureVisibleTab(tab.windowId, { format: 'png' });
  const bitmap = await createImageBitmap(await (await fetch(shot)).blob());
  const scale = bitmap.width / (viewport?.width || bitmap.width);
  const x = Math.max(0, Math.round(rect.x * scale)), y = Math.max(0, Math.round(rect.y * scale));
  const width = Math.min(bitmap.width - x, Math.round(rect.width * scale));
  const height = Math.min(bitmap.height - y, Math.round(rect.height * scale));
  if (width < 4 || height < 4) throw new Error('That area is off the page.');
  const canvas = new OffscreenCanvas(width, height);
  canvas.getContext('2d').drawImage(bitmap, x, y, width, height, 0, 0, width, height);
  let blob = await canvas.convertToBlob({ type: 'image/png' });
  // Photos make huge PNGs: a JPEG keeps it under what a URL can carry.
  if (blob.size > 700_000) blob = await canvas.convertToBlob({ type: 'image/jpeg', quality: 0.9 });
  return `data:${blob.type};base64,${base64(await blob.arrayBuffer())}`;
}

async function pointAndShoot(tab, name, payload) {
  const prefs = await settings();
  const page = { url: payload.url || tab.url, title: payload.title || tab.title || tab.url };
  let capture;
  let shot = false;
  if (name === 'captureArea') {
    const image = await screenshot(tab, payload.rect, payload.viewport);
    shot = true;
    const alt = `Screenshot of ${page.title}`.replace(/[\[\]\n]/g, ' ');
    capture = { ...page, kind: 'image', markdown: `![${alt}](${image})`, text: alt };
  } else if (name === 'capture') {
    capture = { ...page, kind: payload.kind || 'element', markdown: payload.markdown || '', text: payload.text || '' };
  } else {
    return { ok: false };
  }
  await send(tab, capture, prefs.to, prefs.open);
  return { ok: true, shot };
}

// ------------------------------------------------------------------ popup

api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message?.action === 'pns' && sender.tab) {
    pointAndShoot(sender.tab, message.name, message.payload || {})
      .then(sendResponse)
      .catch((error) => sendResponse({ ok: false, error: error.message || String(error) }));
    return true;
  }
  if (message?.action !== 'collect') return false;
  api.tabs.get(message.tabId)
    .then((tab) => collect(tab, message.what, { to: message.to, open: message.open }))
    .then((kind) => sendResponse({ ok: true, kind }))
    .catch((error) => sendResponse({ ok: false, error: error.message || String(error) }));
  return true;
});

// ----------------------------------------------------------- context menu

const MENU = [
  { id: 'glea-selection', title: 'Collect Selection to Glea', contexts: ['selection'] },
  { id: 'glea-image', title: 'Collect Image to Glea', contexts: ['image'] },
  { id: 'glea-link', title: 'Collect Link to Glea', contexts: ['link'] },
  { id: 'glea-page', title: 'Collect Page to Glea', contexts: ['page'] },
  { id: 'glea-article', title: 'Clip Article to Glea', contexts: ['page'] },
];

const CONTENT_SCRIPTS = ['pns-driver.js', 'vendor/glea-content-script.js'];

// Safari's comes inside Glea; elsewhere Glea may not be on this Mac yet.
const BUNDLED_WITH_GLEA = api.runtime.getURL('').startsWith('safari-web-extension:');

api.runtime.onInstalled.addListener(async ({ reason }) => {
  if (reason === 'install' && !BUNDLED_WITH_GLEA) api.tabs.create({ url: 'welcome.html' });
  await api.contextMenus.removeAll();
  for (const item of MENU) {
    api.contextMenus.create({ ...item, documentUrlPatterns: ['http://*/*', 'https://*/*'] });
  }
  // Pages already open get point-and-shoot without a reload.
  for (const tab of await api.tabs.query({ url: ['http://*/*', 'https://*/*'] })) {
    api.scripting.executeScript({ target: { tabId: tab.id }, files: CONTENT_SCRIPTS }).catch(() => {});
  }
});

// The page's point-and-shoot collects it, with its own feedback, when it's
// there (false: it isn't, e.g. a page the browser won't let it run on).
async function viaPage(tab, message) {
  try {
    await api.tabs.sendMessage(tab.id, message);
    return true;
  } catch (e) {
    return false;
  }
}

api.contextMenus.onClicked.addListener(async (info, tab) => {
  if (info.menuItemId === 'glea-selection' && await viaPage(tab, { action: 'pns-selection' })) return;
  if (info.menuItemId === 'glea-image' && await viaPage(tab, { action: 'pns-image', src: info.srcUrl })) return;
  const what = {
    'glea-selection': 'selection',
    'glea-image': { image: info.srcUrl },
    'glea-link': { link: info.linkUrl, text: info.selectionText || info.linkText },
    'glea-page': 'page',
    'glea-article': 'article',
  }[info.menuItemId];
  if (what) collect(tab, what).catch((error) => console.warn('Glea:', error.message));
});

// --------------------------------------------------------------- shortcut

api.commands.onCommand.addListener(async (command, tab) => {
  if (command !== 'collect-selection') return;
  tab = tab ?? (await api.tabs.query({ active: true, currentWindow: true }))[0];
  try {
    const selected = await inPage(tab.id, 'hasSelection');
    await collect(tab, selected ? 'selection' : 'page');
  } catch (error) {
    console.warn('Glea:', error.message);
  }
});
