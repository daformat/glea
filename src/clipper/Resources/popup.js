const api = globalThis.browser ?? globalThis.chrome;

const $ = (selector) => document.querySelector(selector);
const state = { what: 'article', to: 'journal' };
let tab;

function select(group, attribute, value) {
  for (const button of document.querySelectorAll(`#${group} button`)) {
    button.setAttribute('aria-checked', String(button.dataset[attribute] === value));
  }
}

function setWhat(what) {
  state.what = what;
  select('what', 'what', what);
}

function setTo(to) {
  state.to = to;
  select('to', 'to', to);
  $('#note-name').hidden = to !== 'note';
  if (to === 'note') $('#note-name').select();
}

function status(message, isError = false) {
  $('#status').textContent = message;
  $('#status').classList.toggle('error', isError);
}

async function init() {
  [tab] = await api.tabs.query({ active: true, currentWindow: true });
  const prefs = Object.assign({ to: 'journal', open: false }, await api.storage.local.get(['to', 'open']));
  $('#open').checked = prefs.open;
  setTo(prefs.to);
  setWhat('article');

  if (!tab || !/^https?:/i.test(tab.url || '')) {
    $('#page-title').textContent = 'Not a web page';
    for (const button of document.querySelectorAll('button')) button.disabled = true;
    status('Glea can only collect from web pages.');
    return;
  }
  $('#page-title').textContent = tab.title || tab.url;
  $('#note-name').value = tab.title || '';

  // Pages the extension can't script (stores, PDFs…) only allow the link.
  try {
    await api.scripting.executeScript({ target: { tabId: tab.id }, files: ['capture.js'] });
    const [{ result }] = await api.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => ({ selected: window.__gleaClip.hasSelection(), title: window.__gleaClip.title() }),
    });
    if (result.title) $('#note-name').value = result.title;
    if (result.selected) {
      $('[data-what="selection"]').disabled = false;
      setWhat('selection');
    }
  } catch (e) {
    $('[data-what="article"]').disabled = true;
    setWhat('page');
  }
}

async function collect() {
  let to = state.to;
  if (to === 'note') {
    const name = $('#note-name').value.trim();
    if (!name) return $('#note-name').focus();
    to = { note: name };
  }
  // A new note isn't a default: next time starts from the journal again.
  await api.storage.local.set({ to: state.to === 'note' ? 'journal' : state.to, open: $('#open').checked });
  $('#collect').disabled = true;
  status('Sending to Glea…');
  const reply = await api.runtime.sendMessage({
    action: 'collect', tabId: tab.id, what: state.what, to, open: $('#open').checked,
  });
  if (reply?.ok) {
    status('Sent to Glea');
    setTimeout(() => window.close(), 600);
  } else {
    $('#collect').disabled = false;
    status(reply?.error || 'Couldn’t reach Glea.', true);
  }
}

$('#what').addEventListener('click', (e) => {
  const button = e.target.closest('button');
  if (button && !button.disabled) setWhat(button.dataset.what);
});
$('#to').addEventListener('click', (e) => {
  const button = e.target.closest('button');
  if (button) setTo(button.dataset.to);
});
$('#collect').addEventListener('click', collect);
document.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && !$('#collect').disabled) collect();
});

init();
