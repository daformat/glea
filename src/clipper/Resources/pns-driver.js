// Point-and-shoot in other browsers: plays the part Glea's app plays for
// vendor/glea-content-script.js (Glea's own script, unchanged), which loads
// right after this file in the same content-script world.
//
// - Holding ⌥ alone for a moment turns it on (⌘ joining it collects posts
//   and videos as text), like Glea's modifierFlagsChanged.
// - __gleaNative.post() hands captures to the background script, which sends
//   them to Glea and answers; the page then confirms or shakes.
(() => {
  if (globalThis.__gleaNative) return;
  const api = globalThis.browser ?? globalThis.chrome;
  const pns = () => window.__gleaPNS;

  const pointer = { x: -1, y: -1 };
  addEventListener('pointermove', (e) => { pointer.x = e.clientX; pointer.y = e.clientY; }, true);

  async function relay(name, payload) {
    let reply;
    try {
      reply = await api.runtime.sendMessage({ action: 'pns', name, payload });
    } catch (e) {
      reply = { ok: false, error: e.message };
    }
    if (name === 'captureArea' && reply?.shot) pns()?.shotTaken();
    if (reply?.ok) {
      pns()?.done(reply.message || 'Sent to Glea');
    } else {
      if (reply?.error) console.warn('Glea:', reply.error);
      pns()?.cancel();
    }
  }

  globalThis.__gleaNative = {
    post(name, json) {
      let payload = {};
      try { payload = JSON.parse(json); } catch (e) { /* ignore */ }
      relay(name, payload);
    },
  };

  // ---------------------------------------------------------------- ⌥ key

  let pending = 0;
  let on = false;

  // Typing in a field: ⌥ makes characters there (⌥5 is "{" on some
  // layouts), and a selection in it would be collected at once.
  function editing() {
    let el = document.activeElement;
    while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
    return !!el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName));
  }

  function setActive(active) {
    clearTimeout(pending);
    pending = 0;
    if (on === active) return;
    on = active;
    const args = pointer.x >= 0 ? [active, pointer.x, pointer.y] : [active];
    pns()?.setActive(...args);
  }

  addEventListener('keydown', (e) => {
    if (e.key === 'Alt') {
      if (e.repeat || e.ctrlKey || e.shiftKey || editing() || on || pending) return;
      // Held on its own for a moment: ⌥ on the way to ⌥⌘→ never starts a capture.
      pending = setTimeout(() => {
        pending = 0;
        if (document.hasFocus()) setActive(true);
      }, 120);
      return;
    }
    if (e.key === 'Meta') {
      if (on) pns()?.setTextOnly(true);
      return;
    }
    // Any other key: a shortcut or a character, not a capture.
    if (pending || on) setActive(false);
  }, true);

  addEventListener('keyup', (e) => {
    if (e.key === 'Alt') setActive(false);
    else if (e.key === 'Meta' && on) pns()?.setTextOnly(false);
  }, true);

  addEventListener('blur', () => setActive(false));

  // The context menu's Collect Selection / Collect Image, with the page's
  // own feedback (the background asks when this script is there).
  api.runtime.onMessage.addListener((message) => {
    if (message?.action === 'pns-selection') pns()?.collectSelection();
    else if (message?.action === 'pns-image') pns()?.collectImage(message.src);
  });
})();
