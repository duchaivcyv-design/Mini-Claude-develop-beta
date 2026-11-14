(function () {
  'use strict';

  // Turns a model reply (Markdown with optional LaTeX) into safe HTML.
  // Uses markdown-it, highlight.js and KaTeX from vendor.js. Plain ES5: iOS 12's WebKit is Safari 12.

  var copyLabel = 'Copy';
  var CACHE_LIMIT = 400;
  var hlCache = {}, hlCount = 0;
  var mathCache = {}, mathCount = 0;

  function escapeHtml(s) {
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }

  // ---------------------------------------------------------------------------------------------
  // Highlighting and math, both cached: a reply is re-rendered many times while it streams in.
  // ---------------------------------------------------------------------------------------------

  function highlight(code, lang) {
    var key = 'k' + lang + '\u0000' + code;
    if (hlCache[key] !== undefined) { return hlCache[key]; }
    var html;
    try {
      if (lang && window.hljs && window.hljs.getLanguage(lang)) {
        html = window.hljs.highlight(code, { language: lang, ignoreIllegals: true }).value;
      } else {
        html = escapeHtml(code);
      }
    } catch (e) {
      html = escapeHtml(code);
    }
    if (hlCount > CACHE_LIMIT) { hlCache = {}; hlCount = 0; }
    hlCache[key] = html;
    hlCount++;
    return html;
  }

  function renderMath(tex, display) {
    var key = (display ? 'D' : 'I') + tex;
    if (mathCache[key] !== undefined) { return mathCache[key]; }
    var html;
    try {
      html = window.katex.renderToString(tex, {
        displayMode: display,
        throwOnError: false,   // a broken formula is shown as red source text instead of failing
        strict: 'ignore',      // accented letters inside \text{} are fine
        output: 'html',
        trust: false,          // no \href, \url, \includegraphics ...
        maxExpand: 1000,
        maxSize: 50,
        errorColor: '#B3402A'
      });
    } catch (e) {
      html = '<code>' + escapeHtml(tex) + '</code>';
    }
    if (mathCount > CACHE_LIMIT) { mathCache = {}; mathCount = 0; }
    mathCache[key] = html;
    mathCount++;
    return html;
  }

  // ---------------------------------------------------------------------------------------------
  // Math must be lifted out BEFORE markdown runs (markdown would eat underscores, asterisks, backslashes).
  // Code is skipped. Placeholders use private-use characters that cannot appear in normal text.
  // ---------------------------------------------------------------------------------------------

  function hold(items, tex, display) {
    items.push({ tex: tex, display: display });
    return '\uE000' + (items.length - 1) + '\uE001';
  }

  // Splits the text into fenced-code segments and normal segments. An unclosed fence stays code until the end,
  // which is exactly what a half-streamed code block should look like.
  function splitFences(src) {
    var lines = src.split('\n'), segs = [], cur = [], inFence = false, fch = '', flen = 0;
    function flush(isCode) {
      if (cur.length) { segs.push({ code: isCode, text: cur.join('\n') }); cur = []; }
    }
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i];
      var m = /^ {0,3}(`{3,}|~{3,})/.exec(line);
      if (!inFence) {
        if (m) { flush(false); inFence = true; fch = m[1].charAt(0); flen = m[1].length; }
        cur.push(line);
      } else {
        cur.push(line);
        if (m && m[1].charAt(0) === fch && m[1].length >= flen && /^ {0,3}[`~]+\s*$/.test(line)) {
          flush(true);
          inFence = false;
        }
      }
    }
    flush(inFence);
    return segs;
  }

  function protectMath(s, items) {
    var out = '', i = 0, n = s.length;
    while (i < n) {
      var c = s.charAt(i);

      if (c === '\\') {
        var nx = s.charAt(i + 1);
        if (nx === '$' || nx === '\\') { out += c + nx; i += 2; continue; }   // \$ stays a literal dollar; \\ is not an escape for what follows
        if (nx === '[' || nx === '(') {
          var close = nx === '[' ? '\\]' : '\\)';
          var end = s.indexOf(close, i + 2);
          if (end > 0) { out += hold(items, s.substring(i + 2, end), nx === '['); i = end + 2; continue; }
        }
        out += c; i++; continue;
      }

      if (c === '`') {   // inline code: leave untouched
        var run = 1;
        while (s.charAt(i + run) === '`') { run++; }
        var ticks = s.substr(i, run);
        var endTick = s.indexOf(ticks, i + run);
        if (endTick > 0) { out += s.substring(i, endTick + run); i = endTick + run; continue; }
        out += ticks; i += run; continue;
      }

      if (c === '$') {
        if (s.charAt(i + 1) === '$') {   // $$ ... $$
          var e2 = s.indexOf('$$', i + 2);
          if (e2 > 0) { out += hold(items, s.substring(i + 2, e2), true); i = e2 + 2; continue; }
          out += '$$'; i += 2; continue;   // not closed yet (still streaming): show as text for now
        }
        // $ ... $ : the opening $ needs a non-space after it, the closing $ a non-space before it and no digit after it,
        // so "costs $5 and $10" stays text while "$x^2$" becomes math.
        var after = s.charAt(i + 1);
        if (after && !/\s/.test(after)) {
          var j = i + 1, found = -1;
          while (j < n) {
            var d = s.charAt(j);
            if (d === '\n' && s.charAt(j + 1) === '\n') { break; }   // math never spans a blank line
            if (d === '\\') { j += 2; continue; }
            if (d === '$') {
              if (!/\s/.test(s.charAt(j - 1)) && !/[0-9]/.test(s.charAt(j + 1))) { found = j; }
              break;   // the first following $ decides
            }
            j++;
          }
          if (found > i + 1) { out += hold(items, s.substring(i + 1, found), false); i = found + 1; continue; }
        }
        out += '$'; i++; continue;
      }

      out += c; i++;
    }
    return out;
  }

  // ---------------------------------------------------------------------------------------------
  // markdown-it
  // ---------------------------------------------------------------------------------------------

  function codeBlock(code, lang) {
    lang = (lang || '').toLowerCase();
    var label = lang || 'code';
    return '<div class="codeblock"><div class="codehead"><span class="lang">' + escapeHtml(label) +
           '</span><button type="button" class="act copycode">' + escapeHtml(copyLabel) + '</button></div>' +
           '<pre><code class="hljs">' + highlight(code.replace(/\n$/, ''), lang) + '</code></pre></div>\n';
  }

  var md = null;
  try {
    md = window.markdownit({ html: false, linkify: true, breaks: true, typographer: false });
    // "main.py" or "README.md" must not turn into links just because .py / .md are country domains.
    md.linkify.set({ fuzzyLink: false, fuzzyEmail: false, fuzzyIP: false });
    md.renderer.rules.fence = function (tokens, idx) {
      var info = (tokens[idx].info || '').trim().split(/\s+/)[0];
      return codeBlock(tokens[idx].content, info);
    };
    md.renderer.rules.code_block = function (tokens, idx) {
      return codeBlock(tokens[idx].content, '');
    };
    md.renderer.rules.table_open = function () { return '<div class="tablewrap"><table>\n'; };
    md.renderer.rules.table_close = function () { return '</table></div>\n'; };
  } catch (e) {
    md = null;
  }

  function render(text) {
    var src = String(text === undefined || text === null ? '' : text).replace(/[\uE000\uE001]/g, '');
    if (!md) { return '<div style="white-space:pre-wrap">' + escapeHtml(src) + '</div>'; }

    var items = [];
    var segs = splitFences(src), parts = [];
    for (var i = 0; i < segs.length; i++) {
      parts.push(segs[i].code ? segs[i].text : protectMath(segs[i].text, items));
    }
    var html = md.render(parts.join('\n'));
    if (items.length) {
      html = html.replace(/\uE000(\d+)\uE001/g, function (m, idx) {
        var item = items[parseInt(idx, 10)];
        return item ? renderMath(item.tex, item.display) : '';
      });
    }
    return html;
  }

  window.MD = {
    render: render,
    setCopyLabel: function (label) { copyLabel = label; },
    ready: !!md
  };
})();
