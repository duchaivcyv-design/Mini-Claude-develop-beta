(function () {
  'use strict';

  // Written in plain ES5 on purpose: iOS 12's WebKit is Safari 12.
  var S = {
    emptyTitle: '',
    emptySub: '',
    copy: 'Copy',
    copyCode: 'Copy',
    copied: 'Copied',
    regenerate: 'Regenerate',
    retry: 'Retry',
    edit: 'Edit',
    save: 'Save',
    share: 'Share'
  };

  var msgsEl = document.getElementById('messages');
  var toastEl = document.getElementById('toast');
  var current = null;     // the reply that is being streamed right now
  var stick = true;       // follow the bottom while streaming, unless the user scrolled up
  var toastTimer = null;
  var RENDER_INTERVAL = 90;   // ms: how often a streaming reply is re-rendered (the iPhone 6 is slow)

  function post(obj) {
    try { window.webkit.messageHandlers.native.postMessage(obj); } catch (e) { /* not inside the app */ }
  }

  function nearBottom() {
    return window.innerHeight + window.pageYOffset >= document.documentElement.scrollHeight - 60;
  }

  function toBottom(force) {
    if (force || stick) {
      window.scrollTo(0, document.documentElement.scrollHeight);
    }
  }

  // Page errors go to the app's diagnostic log, so a problem can be reported with the real message.
  window.onerror = function (message, source, line) {
    post({ type: 'jserror', message: String(message), line: line });
    return false;
  };

  window.addEventListener('scroll', function () { stick = nearBottom(); }, false);

  function el(tag, cls, text) {
    var e = document.createElement(tag);
    if (cls) { e.className = cls; }
    if (text !== undefined && text !== null) { e.textContent = text; }
    return e;
  }

  function toast(msg) {
    toastEl.textContent = msg;
    toastEl.className = 'show';
    if (toastTimer) { clearTimeout(toastTimer); }
    toastTimer = setTimeout(function () { toastEl.className = ''; }, 1400);
  }

  function showEmpty() {
    msgsEl.innerHTML = '';
    var box = el('div', 'empty');
    box.id = 'empty';
    box.appendChild(el('div', 'logo'));
    box.appendChild(el('h1', null, S.emptyTitle));
    box.appendChild(el('p', null, S.emptySub));
    msgsEl.appendChild(box);
  }

  function removeEmpty() {
    var e = document.getElementById('empty');
    if (e && e.parentNode) { e.parentNode.removeChild(e); }
  }

  function clearErrors() {
    var errs = msgsEl.querySelectorAll('.row.error');
    for (var i = 0; i < errs.length; i++) {
      errs[i].parentNode.removeChild(errs[i]);
    }
  }

  function actionButton(label, handler) {
    var b = el('button', 'act', label);
    b.type = 'button';
    b.addEventListener('click', handler, false);
    return b;
  }

  function buildActions(row) {
    var old = row.querySelector('.actions');
    if (old) { row.removeChild(old); }
    var box = el('div', 'actions');
    box.appendChild(actionButton(S.copy, function () {
      post({ type: 'copy', text: row._text || '' });
      toast(S.copied);
    }));
    box.appendChild(actionButton(S.save, function () {
      post({ type: 'save', text: row._text || '' });
    }));
    row.appendChild(box);
  }

  // The "Regenerate" button only belongs to the very last reply.
  function refreshRegenerate() {
    var old = msgsEl.querySelectorAll('.regen');
    for (var i = 0; i < old.length; i++) {
      old[i].parentNode.removeChild(old[i]);
    }
    var rows = msgsEl.children;
    var last = rows.length ? rows[rows.length - 1] : null;
    if (last && last.className.indexOf('assistant') >= 0 && !last._streaming) {
      var acts = last.querySelector('.actions');
      if (acts) {
        var b = actionButton(S.regenerate, function () { post({ type: 'regenerate' }); });
        b.className = 'act regen';
        acts.appendChild(b);
      }
    }
  }

  function extLabel(att) {
    if (att.kind === 'pdf') { return 'PDF'; }
    if (att.kind === 'image') { return 'IMG'; }
    var m = /\.([A-Za-z0-9]{1,5})$/.exec(att.name || '');
    return m ? m[1].toUpperCase() : 'TXT';
  }

  function bindImageTap(img, id) {
    img.addEventListener('click', function () { post({ type: 'image', id: id }); }, false);
  }

  function buildUserActions(row, messageIndex) {
    var box = el('div', 'actions');
    box.appendChild(actionButton(S.copy, function () {
      post({ type: 'copy', text: row._text || '' });
      toast(S.copied);
    }));
    box.appendChild(actionButton(S.edit, function () {
      post({ type: 'edit', index: messageIndex });
    }));
    row.appendChild(box);
  }

  // A user message: optional attachments (photo thumbnails / file chips) above the text.
  function addUser(text, atts, messageIndex) {
    var row = el('div', 'row user');
    var bubble = el('div', 'bubble');
    if (atts && atts.length) {
      var box = el('div', 'atts');
      for (var i = 0; i < atts.length; i++) {
        var a = atts[i];
        if (a.kind === 'image' && a.thumb) {
          var img = document.createElement('img');
          img.className = 'thumb';
          img.src = a.thumb;
          img.alt = a.name || '';
          bindImageTap(img, a.id);
          box.appendChild(img);
        } else {
          var chip = el('div', 'file');
          chip.appendChild(el('span', 'ext', extLabel(a)));
          chip.appendChild(el('span', 'fname', a.name || ''));
          box.appendChild(chip);
        }
      }
      bubble.appendChild(box);
    }
    if (text) { bubble.appendChild(el('div', 'btext', text)); }
    row.appendChild(bubble);
    row._text = text || '';
    msgsEl.appendChild(row);
    buildUserActions(row, messageIndex);
  }

  function renderInto(node, text) {
    node.innerHTML = window.MD ? window.MD.render(text) : '';
    if (!window.MD) { node.textContent = text; }
  }

  function addAssistant(text, atts) {
    var row = el('div', 'row assistant');
    var imageId = null;
    if (atts && atts.length) {
      var media = el('div', 'assistant-media');
      for (var i = 0; i < atts.length; i++) {
        var a = atts[i];
        if (a.kind === 'image' && a.thumb) {
          var img = document.createElement('img');
          img.className = 'generated-image';
          img.src = a.thumb;
          img.alt = a.name || 'Generated image';
          bindImageTap(img, a.id);
          media.appendChild(img);
          imageId = a.id;
        }
      }
      if (media.childNodes.length) { row.appendChild(media); }
    }
    var body = el('div', 'body md');
    if (text) {
      renderInto(body, text);
      row.appendChild(body);
    }
    row._text = text || '';
    msgsEl.appendChild(row);
    if (text) { buildActions(row); }
    if (imageId) {
      var actions = row.querySelector('.actions');
      if (!actions) { actions = el('div', 'actions'); row.appendChild(actions); }
      actions.appendChild(actionButton(S.share, function () { post({ type: 'shareImage', id: imageId }); }));
    }
  }

  window.ChatUI = {
    setStrings: function (obj) {
      for (var k in obj) {
        if (Object.prototype.hasOwnProperty.call(obj, k)) { S[k] = obj[k]; }
      }
      if (window.MD) { window.MD.setCopyLabel(S.copyCode); }
    },

    clear: function () {
      current = null;
      showEmpty();
      stick = true;
    },

    load: function (list) {
      current = null;
      msgsEl.innerHTML = '';
      if (!list || !list.length) {
        showEmpty();
        return;
      }
      for (var i = 0; i < list.length; i++) {
        if (list[i].role === 'user') { addUser(list[i].text, list[i].attachments, list[i].index !== undefined ? list[i].index : i); } else { addAssistant(list[i].text, list[i].attachments); }
      }
      refreshRegenerate();
      stick = true;
      toBottom(true);
    },

    addUser: function (text, atts, messageIndex) {
      removeEmpty();
      clearErrors();
      addUser(text, atts, messageIndex);
      stick = true;
      toBottom(true);
    },

    begin: function () {
      removeEmpty();
      clearErrors();
      var row = el('div', 'row assistant');
      row._streaming = true;
      var body = el('div', 'body md');
      var content = el('div', 'mdc');
      var dot = el('span', 'dot');
      body.appendChild(content);
      body.appendChild(dot);
      row.appendChild(body);
      msgsEl.appendChild(row);
      current = { row: row, content: content, dot: dot, text: '', timer: null, rendered: false };
      refreshRegenerate();
      toBottom(false);
    },

    delta: function (s) {
      if (!current) { return; }
      current.text += s;
      var c = current;
      if (!c.rendered) {            // first words appear immediately
        c.rendered = true;
        renderInto(c.content, c.text);
        toBottom(false);
      } else if (!c.timer) {        // then at most once per RENDER_INTERVAL
        c.timer = setTimeout(function () {
          c.timer = null;
          if (current === c) { renderInto(c.content, c.text); toBottom(false); }
        }, RENDER_INTERVAL);
      }
    },

    end: function (finalText) {
      if (!current) { return; }
      var c = current;
      current = null;
      if (c.timer) { clearTimeout(c.timer); c.timer = null; }
      if (c.dot.parentNode) { c.dot.parentNode.removeChild(c.dot); }
      c.row._streaming = false;
      var text = (finalText !== undefined && finalText !== null && finalText !== '') ? finalText : c.text;
      if (!text) {
        c.row.parentNode.removeChild(c.row);
      } else {
        renderInto(c.content, text);
        c.row._text = text;
        buildActions(c.row);
      }
      refreshRegenerate();
    },

    error: function (msg, canRetry) {
      clearErrors();
      var row = el('div', 'row error');
      row.appendChild(el('div', 'errtext', msg));
      if (canRetry) {
        var b = actionButton(S.retry, function () { post({ type: 'regenerate' }); });
        b.className = 'act retry';
        row.appendChild(b);
      }
      msgsEl.appendChild(row);
      refreshRegenerate();
      stick = true;
      toBottom(true);
    },

    scrollEnd: function () {
      stick = true;
      toBottom(true);
    }
  };

  msgsEl.addEventListener('click', function (e) {
    var node = e.target;
    while (node && node !== msgsEl) {
      if (node.classList && node.classList.contains('copycode')) {
        var block = node.parentNode ? node.parentNode.parentNode : null;
        var code = block ? block.querySelector('pre code') : null;
        if (code) { post({ type: 'copy', text: code.textContent }); toast(S.copied); }
        return;
      }
      node = node.parentNode;
    }
  }, false);

  window.addEventListener('load', function () { post({ type: 'ready' }); }, false);
})();
