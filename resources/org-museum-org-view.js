(function () {
  'use strict';

  function escapeHtml(str) {
    return String(str || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function cleanHeadingText(text) {
    if (!text) return '';
    return text
      .toLowerCase()
      .replace(/^\*+\s*/, '')
      .replace(/^[\s\d.一二三四五六七八九十百千（）()、·-]+/, '')
      .replace(/^(todo|done|next|waiting|cancelled)\s+/i, '')
      .replace(/\s*:[\w:@#%]+:\s*$/, '')
      .replace(/[^\p{L}\p{N}]+/gu, '')
      .trim();
  }

  function normalized(text) {
    return text
      .replace(/^\*+\s+/, '')
      .replace(/\s+:[\w:@#%]+:\s*$/, '')
      .replace(/^(TODO|DONE|NEXT|WAITING|CANCELLED)\s+/, '')
      .trim();
  }

  function highlightCode(rawCode, lang) {
    if (window.hljs) {
      try {
        var l = (lang || '').toLowerCase();
        if (l === 'elisp' || l === 'emacs-lisp') l = 'lisp';
        if (l === 'md') l = 'markdown';
        if (l === 'js') l = 'javascript';
        if (l === 'ts') l = 'typescript';
        if (l === 'py') l = 'python';
        if (l === 'sh') l = 'bash';

        if (l && typeof window.hljs.getLanguage === 'function' && window.hljs.getLanguage(l)) {
          return window.hljs.highlight(rawCode, { language: l, ignoreIllegals: true }).value;
        }
        if (typeof window.hljs.highlightAuto === 'function') {
          return window.hljs.highlightAuto(rawCode).value;
        }
      } catch (_) {}
    }
    return escapeHtml(rawCode);
  }

  function highlightInline(text) {
    if (!text) return '';
    var s = escapeHtml(text), tokens = [];
    // Keep generated markup out of subsequent Org pattern matches.
    function token(html) { var index = tokens.push(html) - 1; return '\u0000' + index + '\u0000'; }

    // 1. Links: [[target][desc]] or [[target]]
    s = s.replace(/\[\[([^\]]+)\](?:\[([^\]]+)\])?\]/g, function (_, target, desc) {
      var href = target;
      if (/^file:/i.test(target)) {
        var sourcePath = target.slice(5).split('::')[0];
        var filename = sourcePath.split('/').pop().replace(/\.org$/i, '.html');
        var exported = Array.from(document.querySelectorAll('.article-container a[href]')).find(function (anchor) {
          if (anchor.closest('.museum-org-view')) return false;
          var url = anchor.getAttribute('href');
          try { url = decodeURIComponent(url); } catch (_) {}
          return url.split('#')[0].split('?')[0].split('/').pop() === filename &&
            (!desc || escapeHtml(anchor.textContent) === desc);
        });
        href = exported ? escapeHtml(exported.getAttribute('href')) : sourcePath.replace(/\.org$/i, '.html');
      }
      var protocolCheck = href.replace(/[\u0000-\u0020]/g, '');
      var safe = /^(?:https?:|mailto:|#)/i.test(protocolCheck) ||
        (!/^[a-z][a-z\d+.-]*:/i.test(protocolCheck) && !/^(?:\/\/|\\)/.test(protocolCheck));
      var label = desc || target;
      var link = safe ? '<a class="org-face-org-link" href="' + href + '">' + label + '</a>' :
        '<span class="org-face-org-link">' + label + '</span>';
      if (desc) {
        return token('<span class="org-face-org-link-bracket">[[</span>' +
               '<span class="org-face-org-link-url">' + target + '</span>' +
               '<span class="org-face-org-link-bracket">][</span>' +
               link +
               '<span class="org-face-org-link-bracket">]]</span>');
      }
      return token('<span class="org-face-org-link-bracket">[[</span>' +
             link +
             '<span class="org-face-org-link-bracket">]]</span>');
    });

    // 2. Timestamps & dates: <2026-10-01 ...> or [2026-10-01 ...]
    s = s.replace(/(&lt;\d{4}-\d{2}-\d{2}[^&]*&gt;|\[\d{4}-\d{2}-\d{2}[^\]]*\])/g,
      function (_, value) { return token('<span class="org-face-org-date">' + value + '</span>'); });

    // 3. Checkboxes: [ ], [X], [-]
    s = s.replace(/\[([ Xx\-])\]/g, function (_, mark) {
      if (mark === 'X' || mark === 'x') {
        return token('<span class="org-face-org-checkbox is-checked">[X]</span>');
      } else if (mark === '-') {
        return token('<span class="org-face-org-checkbox is-partial">[-]</span>');
      }
      return token('<span class="org-face-org-checkbox">[ ]</span>');
    });

    // 4. Code & verbatim: ~code~, =verbatim=
    s = s.replace(/~([^~\n]+)~/g, function (_, value) { return token('<code class="org-face-org-code">~' + value + '~</code>'); });
    s = s.replace(/=([^=\n]+)=/g, function (_, value) { return token('<code class="org-face-org-verbatim">=' + value + '=</code>'); });

    // 5. Bold, italic, underline, strike
    s = s.replace(/(^|[\s\(\[{'"])\*([^*\n\s][^*\n]*[^*\n\s]|\S)\*(?=$|[\s\)\]}'",.?!:;])/g,
      function (_, prefix, value) { return prefix + token('<strong class="org-face-bold">*' + value + '*</strong>'); });
    s = s.replace(/(^|[\s\(\[{'"])\/([^\/\n\s][^\/\n]*[^\/\n\s]|\S)\/(?=$|[\s\)\]}'",.?!:;])/g,
      function (_, prefix, value) { return prefix + token('<em class="org-face-italic">/' + value + '/</em>'); });
    s = s.replace(/(^|[\s\(\[{'"])\_([^_\n\s][^_\n]*[^_\n\s]|\S)\_(?=$|[\s\)\]}'",.?!:;])/g,
      function (_, prefix, value) { return prefix + token('<u class="org-face-underline">_' + value + '_</u>'); });
    s = s.replace(/(^|[\s\(\[{'"])\+([^\+\n\s][^\+\n]*[^\+\n\s]|\S)\+(?=$|[\s\)\]}'",.?!:;])/g,
      function (_, prefix, value) { return prefix + token('<del class="org-face-strike">+' + value + '+</del>'); });

    // 6. Footnotes: [fn:1] or [fn:name]
    s = s.replace(/(\[fn:[a-zA-Z0-9_-]+\])/g, '<span class="org-face-org-footnote">$1</span>');

    // Later tokens may contain earlier tokens (for example a link in emphasis).
    function restore(value) {
      return value.replace(/\u0000(\d+)\u0000/g, function (_, index) { return restore(tokens[Number(index)]); });
    }
    return restore(s);
  }

  function createBabelBlockElement(lang, rawCode, originalBeginLine, originalEndLine) {
    var container = document.createElement('div');
    container.className = 'museum-org-block-container is-folded';
    container.dataset.lang = lang;
    container._isFolded = true;
    container._isRendered = false;

    var isMarkdown = /^(markdown|md)$/i.test(lang);
    var lineCount = rawCode ? rawCode.split('\n').length : 0;
    var beginLineText = originalBeginLine || ('#+begin_src ' + lang);
    var endLineText = originalEndLine || '#+end_src';
    var fullBlockRaw = beginLineText + '\n' + rawCode + '\n' + endLineText;
    container._fullBlockRaw = fullBlockRaw;
    container._innerRaw = rawCode;

    var header = document.createElement('div');
    header.className = 'museum-org-block-header';
    header.setAttribute('role', 'button');
    header.setAttribute('tabindex', '0');
    header.setAttribute('aria-expanded', 'false');
    header.setAttribute('title', '点击折叠/展开代码块');

    header.innerHTML =
      '<div class="museum-org-block-meta">' +
      '<span class="museum-org-fold-icon">▶</span> ' +
      '<span class="museum-org-block-lang">' + escapeHtml(lang) + '</span> ' +
      '<span class="museum-org-block-count">(' + lineCount + ' 行)</span>' +
      '</div>' +
      '<div class="museum-org-block-actions">' +
      '<button type="button" class="museum-org-btn-fold" aria-expanded="false">展开</button>' +
      (isMarkdown ? '<button type="button" class="museum-org-btn-render-md" aria-pressed="false">渲染 Markdown</button>' : '') +
      '<button type="button" class="museum-org-btn-copy-full" title="复制包含 #+begin_src 和 #+end_src 的完整代码块">复制完整块</button>' +
      '<button type="button" class="museum-org-btn-copy-inner" title="仅复制代码内容 (不含标记)">复制代码</button>' +
      '</div>';

    var pre = document.createElement('pre');
    pre.className = 'museum-org-block-code';

    // Delimiter Line 1: #+begin_src lang
    var beginLineEl = document.createElement('span');
    beginLineEl.className = 'museum-org-line museum-org-block-delimiter-begin';
    beginLineEl.innerHTML = '<span class="org-face-org-block-begin-line">' + escapeHtml(beginLineText) + '</span>';

    // Body: Syntax-highlighted code
    var bodyDiv = document.createElement('div');
    bodyDiv.className = 'museum-org-block-body';
    bodyDiv.hidden = true; // Folded by default
    var codeEl = document.createElement('code');
    codeEl.className = 'language-' + escapeHtml(lang);
    codeEl.innerHTML = highlightCode(rawCode, lang);
    bodyDiv.appendChild(codeEl);

    // Fold hint (shown when folded)
    var foldHint = document.createElement('div');
    foldHint.className = 'museum-org-block-folded-hint';
    foldHint.innerHTML = '<span class="org-face-font-lock-comment-face">  ... (' + lineCount + ' 行代码已折叠，点击展开) ...</span>';

    // Delimiter Last Line: #+end_src
    var endLineEl = document.createElement('span');
    endLineEl.className = 'museum-org-line museum-org-block-delimiter-end';
    endLineEl.innerHTML = '<span class="org-face-org-block-end-line">' + escapeHtml(endLineText) + '</span>';

    pre.appendChild(beginLineEl);
    pre.appendChild(bodyDiv);
    pre.appendChild(foldHint);
    pre.appendChild(endLineEl);

    container.appendChild(header);
    container.appendChild(pre);

    var renderedDiv = null;
    var toggleBtn = null;
    if (isMarkdown) {
      renderedDiv = document.createElement('div');
      renderedDiv.className = 'museum-org-block-md-rendered';
      renderedDiv.hidden = true;
      container.appendChild(renderedDiv);
      toggleBtn = header.querySelector('.museum-org-btn-render-md');
    }

    var foldBtn = header.querySelector('.museum-org-btn-fold');
    var foldIcon = header.querySelector('.museum-org-fold-icon');

    function setFolded(folded) {
      container._isFolded = folded;
      if (folded) {
        container.classList.add('is-folded');
        header.setAttribute('aria-expanded', 'false');
        if (foldBtn) {
          foldBtn.setAttribute('aria-expanded', 'false');
          foldBtn.textContent = '展开';
        }
        if (foldIcon) foldIcon.textContent = '▶';
        bodyDiv.hidden = true;
        foldHint.hidden = false;
        if (renderedDiv) renderedDiv.hidden = true;
      } else {
        container.classList.remove('is-folded');
        header.setAttribute('aria-expanded', 'true');
        if (foldBtn) {
          foldBtn.setAttribute('aria-expanded', 'true');
          foldBtn.textContent = '折叠';
        }
        if (foldIcon) foldIcon.textContent = '▼';
        foldHint.hidden = true;
        if (container._isRendered && renderedDiv) {
          renderedDiv.hidden = false;
          pre.hidden = true;
        } else {
          pre.hidden = false;
          bodyDiv.hidden = false;
          if (renderedDiv) renderedDiv.hidden = true;
        }
      }
    }
    container._setFolded = setFolded;

    if (foldBtn) {
      foldBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        setFolded(!container._isFolded);
      });
    }

    header.addEventListener('click', function (e) {
      if (e.target.closest('.museum-org-block-actions')) return;
      setFolded(!container._isFolded);
    });
    header.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') {
        if (e.target.closest('.museum-org-block-actions')) return;
        e.preventDefault();
        setFolded(!container._isFolded);
      }
    });

    if (toggleBtn && renderedDiv) {
      toggleBtn.addEventListener('click', function (e) {
        e.stopPropagation();
        container._isRendered = !container._isRendered;
        if (container._isRendered) {
          if (!renderedDiv.dataset.rendered && window.orgMuseumMarkdown && typeof window.orgMuseumMarkdown.render === 'function') {
            window.orgMuseumMarkdown.render(renderedDiv, rawCode);
            if (window.hljs) {
              renderedDiv.querySelectorAll('pre code').forEach(function (block) {
                try { window.hljs.highlightElement(block); } catch (_) {}
              });
            }
            renderedDiv.dataset.rendered = 'true';
          } else if (!renderedDiv.dataset.rendered) {
            renderedDiv.innerHTML = '<div style="white-space:pre-wrap">' + escapeHtml(rawCode) + '</div>';
          }
          toggleBtn.setAttribute('aria-pressed', 'true');
          toggleBtn.textContent = '查看源码';
        } else {
          toggleBtn.setAttribute('aria-pressed', 'false');
          toggleBtn.textContent = '渲染 Markdown';
        }
        setFolded(false);
      });
    }

    // Copy full block (including #+begin_src and #+end_src)
    var copyFullBtn = header.querySelector('.museum-org-btn-copy-full');
    if (copyFullBtn) {
      copyFullBtn.addEventListener('click', async function (e) {
        e.stopPropagation();
        try {
          await navigator.clipboard.writeText(fullBlockRaw);
          copyFullBtn.textContent = '已复制完整块！';
          setTimeout(function () { copyFullBtn.textContent = '复制完整块'; }, 1800);
        } catch (_) {
          copyFullBtn.textContent = '复制失败';
        }
      });
    }

    // Copy inner code only
    var copyInnerBtn = header.querySelector('.museum-org-btn-copy-inner');
    if (copyInnerBtn) {
      copyInnerBtn.addEventListener('click', async function (e) {
        e.stopPropagation();
        try {
          await navigator.clipboard.writeText(rawCode);
          copyInnerBtn.textContent = '已复制代码！';
          setTimeout(function () { copyInnerBtn.textContent = '复制代码'; }, 1800);
        } catch (_) {
          copyInnerBtn.textContent = '复制失败';
        }
      });
    }

    return container;
  }

  function renderOrgSyntaxLine(line) {
    var trimmed = line.trim();

    // 1. Headings: * Level 1
    var headMatch = line.match(/^(\*+)\s+(.*)$/);
    if (headMatch) {
      var level = Math.min(8, headMatch[1].length);
      var stars = headMatch[1];
      var remaining = headMatch[2];

      var todoHtml = '';
      var todoMatch = remaining.match(/^(TODO|NEXT|WAITING|HOLD)\s+(.*)$/);
      if (todoMatch) {
        todoHtml = '<span class="org-face-org-todo">' + todoMatch[1] + '</span> ';
        remaining = todoMatch[2];
      } else {
        var doneMatch = remaining.match(/^(DONE|CANCELLED)\s+(.*)$/);
        if (doneMatch) {
          todoHtml = '<span class="org-face-org-done">' + doneMatch[1] + '</span> ';
          remaining = doneMatch[2];
        }
      }

      var priorityHtml = '';
      var prioMatch = remaining.match(/^(\[#[A-Z]\])\s+(.*)$/);
      if (prioMatch) {
        priorityHtml = '<span class="org-face-org-priority">' + escapeHtml(prioMatch[1]) + '</span> ';
        remaining = prioMatch[2];
      }

      var tagsHtml = '';
      var tagMatch = remaining.match(/^(.*?)\s+(:[\w:@#%]+:)\s*$/);
      if (tagMatch) {
        remaining = tagMatch[1];
        var tags = tagMatch[2].replace(/^:|:$/g, '').split(':');
        tagsHtml = '<span class="org-heading-tags">' + tags.map(function (t) {
          return '<span class="org-face-org-tag">' + escapeHtml(t) + '</span>';
        }).join('') + '</span>';
      }

      var hEl = document.createElement('div');
      hEl.className = 'museum-org-line museum-org-heading museum-org-heading-' + level;
      hEl.dataset.level = String(level);
      hEl.dataset.headingText = normalized(headMatch[2]);
      hEl.innerHTML =
        '<span class="org-face-org-level-' + level + '">' + escapeHtml(stars) + '</span> ' +
        todoHtml +
        priorityHtml +
        '<span class="org-heading-text org-face-org-level-' + level + '">' + highlightInline(remaining) + '</span>' +
        tagsHtml +
        '<span class="museum-org-heading-actions">' +
        '<button type="button" class="museum-org-btn-copy-section" title="复制本节 Org 源码 (含标题及子内容)">复制本节</button>' +
        '</span>';
      return hEl;
    }

    // 2. Planning keywords: DEADLINE:, SCHEDULED:, CLOSED:
    var planMatch = line.match(/^\s*(DEADLINE|SCHEDULED|CLOSED):\s*(.*)$/);
    if (planMatch) {
      var planEl = document.createElement('div');
      planEl.className = 'museum-org-line';
      var planCls = planMatch[1] === 'DEADLINE' ? 'org-face-org-deadline' :
                    (planMatch[1] === 'SCHEDULED' ? 'org-face-org-scheduled' : 'org-face-org-done');
      planEl.innerHTML = '<span class="' + planCls + '">' + planMatch[1] + ':</span> ' +
                         '<span class="org-face-org-date">' + highlightInline(planMatch[2]) + '</span>';
      return planEl;
    }

    // 3. Drawers: :PROPERTIES:, :LOGBOOK:, :END:
    var drawerMatch = line.match(/^\s*:(PROPERTIES|LOGBOOK|CLOCK|END):\s*$/i);
    if (drawerMatch) {
      var dEl = document.createElement('div');
      dEl.className = 'museum-org-line museum-org-drawer-line';
      dEl.innerHTML = '<span class="org-face-org-drawer">:' + escapeHtml(drawerMatch[1]) + ':</span>';
      return dEl;
    }

    // Property pairs inside drawers: :ID: value
    var propMatch = line.match(/^(\s*:)([A-Za-z0-9_-]+)(:)(\s+.*)?$/);
    if (propMatch) {
      var prEl = document.createElement('div');
      prEl.className = 'museum-org-line museum-org-drawer-line';
      prEl.innerHTML = escapeHtml(propMatch[1]) +
        '<span class="org-face-org-special-keyword">' + escapeHtml(propMatch[2]) + '</span>' +
        escapeHtml(propMatch[3]) +
        (propMatch[4] ? '<span class="org-face-org-property-value">' + highlightInline(propMatch[4]) + '</span>' : '');
      return prEl;
    }

    // 4. Preamble & metadata: #+TITLE:, #+AUTHOR:, etc.
    var titleMatch = line.match(/^(\s*#\+TITLE:)(.*)$/i);
    if (titleMatch) {
      var tEl = document.createElement('div');
      tEl.className = 'museum-org-line museum-org-meta-line';
      tEl.innerHTML = '<span class="org-face-org-document-info-keyword">' + escapeHtml(titleMatch[1]) + '</span>' +
                      '<span class="org-face-org-document-title">' + highlightInline(titleMatch[2]) + '</span>';
      return tEl;
    }

    var metaMatch = line.match(/^(\s*#\+[A-Za-z_-]+:)(.*)$/);
    if (metaMatch) {
      var mEl = document.createElement('div');
      mEl.className = 'museum-org-line museum-org-meta-line';
      mEl.innerHTML = '<span class="org-face-org-document-info-keyword">' + escapeHtml(metaMatch[1]) + '</span>' +
                      '<span class="org-face-org-property-value">' + highlightInline(metaMatch[2]) + '</span>';
      return mEl;
    }

    // 5. Tables: | col | col |
    if (/^\s*\|/.test(line)) {
      var tblEl = document.createElement('div');
      tblEl.className = 'museum-org-line museum-org-table-line';
      if (/^\s*\|[-+]+\|?\s*$/.test(trimmed)) {
        tblEl.innerHTML = '<span class="org-face-org-table-rule">' + escapeHtml(line) + '</span>';
      } else {
        var parts = line.split('|');
        var out = '';
        for (var p = 0; p < parts.length; p++) {
          if (p === 0 && parts[p] === '') {
            out += '<span class="org-face-org-table-pipe">|</span>';
          } else if (p === parts.length - 1 && parts[p] === '') {
            out += '<span class="org-face-org-table-pipe">|</span>';
          } else {
            out += '<span class="org-face-org-table">' + highlightInline(parts[p]) + '</span>' +
                   (p < parts.length - 1 ? '<span class="org-face-org-table-pipe">|</span>' : '');
          }
        }
        tblEl.innerHTML = out;
      }
      return tblEl;
    }

    // 6. Comments: # comment (not #+)
    var commentMatch = line.match(/^(\s*#(?![\+]))(.*)$/);
    if (commentMatch) {
      var cmEl = document.createElement('div');
      cmEl.className = 'museum-org-line museum-org-comment-line';
      cmEl.innerHTML = '<span class="org-face-font-lock-comment-face">' + escapeHtml(line) + '</span>';
      return cmEl;
    }

    // 7. Lists & Checkboxes: - [ ] item
    var listMatch = line.match(/^(\s*)([-+*]|\d+[.)])\s+(.*)$/);
    if (listMatch) {
      var liEl = document.createElement('div');
      liEl.className = 'museum-org-line';
      var prefix = escapeHtml(listMatch[1]);
      var bullet = '<span class="org-face-org-list-dt">' + escapeHtml(listMatch[2]) + '</span> ';
      var rest = listMatch[3];
      var chkMatch = rest.match(/^(\[[ Xx\-]\])\s+(.*)$/);
      var chkHtml = '';
      if (chkMatch) {
        var mark = chkMatch[1].charAt(1);
        if (mark === 'X' || mark === 'x') {
          chkHtml = '<span class="org-face-org-checkbox is-checked">[X]</span> ';
        } else if (mark === '-') {
          chkHtml = '<span class="org-face-org-checkbox is-partial">[-]</span> ';
        } else {
          chkHtml = '<span class="org-face-org-checkbox">[ ]</span> ';
        }
        rest = chkMatch[2];
      }
      liEl.innerHTML = prefix + bullet + chkHtml + highlightInline(rest);
      return liEl;
    }

    // 8. Blank line
    if (trimmed === '') {
      var bEl = document.createElement('div');
      bEl.className = 'museum-org-line museum-org-blank-line';
      bEl.innerHTML = '&nbsp;';
      return bEl;
    }

    // 9. Regular text line
    var pEl = document.createElement('div');
    pEl.className = 'museum-org-line';
    pEl.innerHTML = highlightInline(line);
    return pEl;
  }

  function enhanceSyntaxBuffer(source) {
    if (source.dataset.orgSyntaxEnhanced) return;

    var rawText = (source.querySelector('code') || source).textContent;
    source.dataset.rawOrg = rawText;

    var rawLines = rawText.split(/\r?\n/);
    var bufferEl = document.createElement('div');
    bufferEl.className = 'museum-org-source';

    var i = 0;
    while (i < rawLines.length) {
      var line = rawLines[i];
      var trimmed = line.trim();

      // Source block: #+begin_src ... #+end_src
      var srcMatch = line.match(/^\s*#\+begin_src(?:\s+([\w+-]+))?(.*)$/i);
      if (srcMatch) {
        var lang = (srcMatch[1] || 'text').toLowerCase();
        var blockLines = [];
        var beginLine = line;
        i++;
        while (i < rawLines.length && !/^\s*#\+end_src/i.test(rawLines[i])) {
          blockLines.push(rawLines[i]);
          i++;
        }
        var endLine = (i < rawLines.length) ? rawLines[i] : '#+end_src';
        if (i < rawLines.length) i++;

        var rawBlockCode = blockLines.join('\n');
        bufferEl.appendChild(createBabelBlockElement(lang, rawBlockCode, beginLine, endLine));
        continue;
      }

      // Other block delimiters: #+begin_quote, #+begin_example, etc.
      if (/^\s*#\+begin_/i.test(trimmed)) {
        var bStart = document.createElement('div');
        bStart.className = 'museum-org-line museum-org-block-delimiter';
        bStart.innerHTML = '<span class="org-face-org-block-begin-line">' + escapeHtml(line) + '</span>';
        bufferEl.appendChild(bStart);
        i++;
        while (i < rawLines.length && !/^\s*#\+end_/i.test(rawLines[i])) {
          var bBody = document.createElement('div');
          bBody.className = 'museum-org-line museum-org-block-line';
          bBody.innerHTML = escapeHtml(rawLines[i]);
          bufferEl.appendChild(bBody);
          i++;
        }
        if (i < rawLines.length) {
          var bEnd = document.createElement('div');
          bEnd.className = 'museum-org-line museum-org-block-delimiter';
          bEnd.innerHTML = '<span class="org-face-org-block-end-line">' + escapeHtml(rawLines[i]) + '</span>';
          bufferEl.appendChild(bEnd);
          i++;
        }
        continue;
      }

      // Normal line
      bufferEl.appendChild(renderOrgSyntaxLine(line));
      i++;
    }

    // Replace source content cleanly
    source.innerHTML = '';
    source.appendChild(bufferEl);
    source.dataset.orgSyntaxEnhanced = 'true';
  }

  function setupHeadingMapping(article, source) {
    var origHeadings = Array.from(article.querySelectorAll('h1, h2, h3, h4, h5, h6'))
      .filter(function (h) {
        return !h.closest('.museum-org-view, .museum-article-view-toolbar');
      });
    var orgHeadings = Array.from(source.querySelectorAll('.museum-org-heading'));
    var idMap = new Map();
    var cleanMap = new Map();

    orgHeadings.forEach(function (oh, idx) {
      var raw = oh.dataset.headingText || oh.textContent;
      var c = cleanHeadingText(raw);
      if (c && !cleanMap.has(c)) {
        cleanMap.set(c, oh);
      }
    });

    origHeadings.forEach(function (origH, idx) {
      var c = cleanHeadingText(origH.textContent);
      var match = cleanMap.get(c) || orgHeadings[idx] || null;
      if (match) {
        var origId = origH.id;
        if (origId) {
          idMap.set(origId, match);
          idMap.set(decodeURIComponent(origId), match);
          match.dataset.targetId = origId;
          match.id = 'org-anchor-' + origId;
        }
        var container = origH.closest('[id^="outline-container-"]');
        if (container && container.id) {
          idMap.set(container.id, match);
          idMap.set(container.id.replace(/^outline-container-/, ''), match);
        }
      }
    });

    // Match any TOC links
    var tocLinks = Array.from(document.querySelectorAll(
      '#org-museum-right-sidebar a[href^="#"], .museum-toc-tree a[href^="#"], #table-of-contents a[href^="#"]'
    ));
    tocLinks.forEach(function (link, idx) {
      var rawHref = link.getAttribute('href');
      if (!rawHref) return;
      var targetId = decodeURIComponent(rawHref.replace(/^#/, ''));
      if (!idMap.has(targetId)) {
        var c = cleanHeadingText(link.textContent);
        var match = cleanMap.get(c) || orgHeadings[idx] || null;
        if (match) {
          idMap.set(targetId, match);
          if (!match.dataset.targetId) match.dataset.targetId = targetId;
        }
      }
    });

    return idMap;
  }

  function initOrgSearch(toolbar, source) {
    var searchBox = toolbar.querySelector('.museum-org-search-box');
    if (!searchBox) {
      searchBox = document.createElement('div');
      searchBox.className = 'museum-org-search-box';
      searchBox.hidden = true;
      searchBox.innerHTML =
        '<input type="search" class="museum-org-search-input" placeholder="在源码中定位 (Enter 下一个)…" aria-label="搜索 Org 源码">' +
        '<span class="museum-org-search-stats" aria-live="polite"></span>' +
        '<button type="button" class="museum-org-search-btn" data-dir="prev" aria-label="上一个匹配" title="上一个匹配">▲</button>' +
        '<button type="button" class="museum-org-search-btn" data-dir="next" aria-label="下一个匹配" title="下一个匹配">▼</button>';
      var copyBtn = toolbar.querySelector('[data-org-copy]');
      toolbar.insertBefore(searchBox, copyBtn);
    }

    var input = searchBox.querySelector('.museum-org-search-input');
    var stats = searchBox.querySelector('.museum-org-search-stats');
    var btnPrev = searchBox.querySelector('[data-dir="prev"]');
    var btnNext = searchBox.querySelector('[data-dir="next"]');
    var matches = [];
    var currentIndex = -1;

    function clearSearch() {
      matches = [];
      currentIndex = -1;
      stats.textContent = '';
      source.querySelectorAll('.is-org-search-target').forEach(function (el) {
        el.classList.remove('is-org-search-target');
      });
    }

    function doSearch() {
      var query = input.value.trim().toLowerCase();
      clearSearch();
      if (!query) return;

      var allItems = Array.from(source.querySelectorAll('.museum-org-line, .museum-org-block-container'));
      allItems.forEach(function (item) {
        var txt = (item._fullBlockRaw || item.textContent || '').toLowerCase();
        if (txt.indexOf(query) !== -1) {
          matches.push(item);
        }
      });

      stats.textContent = matches.length > 0 ? (1 + ' / ' + matches.length) : '无结果';
      if (matches.length > 0) {
        jumpTo(0);
      }
    }

    function jumpTo(idx) {
      if (matches.length === 0) return;
      if (currentIndex >= 0 && matches[currentIndex]) {
        matches[currentIndex].classList.remove('is-org-search-target');
      }
      currentIndex = (idx + matches.length) % matches.length;
      var target = matches[currentIndex];
      target.classList.add('is-org-search-target');
      target.scrollIntoView({ behavior: 'smooth', block: 'center' });
      stats.textContent = (currentIndex + 1) + ' / ' + matches.length;
    }

    input.addEventListener('input', doSearch);
    input.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') {
        e.preventDefault();
        if (e.shiftKey) jumpTo(currentIndex - 1);
        else jumpTo(currentIndex + 1);
      } else if (e.key === 'Escape') {
        input.value = '';
        clearSearch();
      }
    });

    btnNext.addEventListener('click', function () { jumpTo(currentIndex + 1); });
    btnPrev.addEventListener('click', function () { jumpTo(currentIndex - 1); });

    return searchBox;
  }

  function start() {
    var article = document.querySelector('.article-container');
    var toggle = document.querySelector('[data-article-syntax]');
    var source = document.querySelector('.museum-org-view');
    if (!article || !toggle || !source) return;
    var toolbar = toggle.closest('.museum-article-view-toolbar');
    var title = article.querySelector(':scope > .title');
    if (title) title.after(toolbar, source);

    var copy = toolbar.querySelector('[data-org-copy]');
    var wrap = toolbar.querySelector('[data-org-wrap]');
    var status = toolbar.querySelector('[data-org-view-status]');

    // Toggle all code blocks button
    var toggleBlocks = toolbar.querySelector('[data-org-toggle-blocks]');
    if (!toggleBlocks) {
      toggleBlocks = document.createElement('button');
      toggleBlocks.type = 'button';
      toggleBlocks.setAttribute('data-org-toggle-blocks', '');
      toggleBlocks.setAttribute('aria-pressed', 'false');
      toggleBlocks.textContent = '展开全部代码';
      toggleBlocks.hidden = true;
      toolbar.insertBefore(toggleBlocks, copy);
    }

    // Toggle line numbers button
    var lineNumbersBtn = toolbar.querySelector('[data-org-line-numbers]');
    if (!lineNumbersBtn) {
      lineNumbersBtn = document.createElement('button');
      lineNumbersBtn.type = 'button';
      lineNumbersBtn.setAttribute('data-org-line-numbers', '');
      lineNumbersBtn.setAttribute('aria-pressed', 'false');
      lineNumbersBtn.textContent = '显示行号';
      lineNumbersBtn.hidden = true;
      toolbar.insertBefore(lineNumbersBtn, copy);
    }

    // In-buffer search box
    var searchBox = initOrgSearch(toolbar, source);

    var hidden = new Map(), mode = false;
    var idMap = null;

    function updateActiveToc(targetId, preferredLink) {
      var tocLinks = Array.from(document.querySelectorAll(
        '#org-museum-right-sidebar a[href^="#"], .museum-toc-tree a[href^="#"], #table-of-contents a[href^="#"]'
      ));
      var activeLink = preferredLink || null;
      tocLinks.forEach(function (tl) {
        var raw = decodeURIComponent((tl.getAttribute('href') || '').replace(/^#/, ''));
        var isMatch = raw === targetId || raw === 'outline-container-' + targetId;
        tl.classList.toggle('toc-active', isMatch);
        if (isMatch && !activeLink) activeLink = tl;
      });
      if (activeLink) {
        activeLink.dispatchEvent(new CustomEvent('museum:toc-active', { bubbles: true }));
        var item = activeLink.closest('li');
        while (item) {
          item.classList.add('toc-branch-open');
          item = item.parentElement ? item.parentElement.closest('li') : null;
        }
      }
    }

    toggle.addEventListener('click', function () {
      var headings = Array.from(article.querySelectorAll('h2,h3,h4,h5,h6'));
      var closest = headings.filter(function (h) { return h.getBoundingClientRect().top >= -30; })[0];
      mode = !mode;
      article.classList.toggle('is-org-syntax', mode);
      toggle.setAttribute('aria-pressed', String(mode));
      toggle.textContent = mode ? '切换为阅读视图' : '切换为 Org Mode';
      copy.hidden = !mode;
      toggleBlocks.hidden = !mode;
      lineNumbersBtn.hidden = !mode;
      if (searchBox) searchBox.hidden = !mode;
      if (wrap) {
        wrap.hidden = !mode;
        wrap.setAttribute('aria-pressed', 'true');
      }
      source.hidden = !mode;
      status.textContent = '';

      if (mode) {
        enhanceSyntaxBuffer(source);
        idMap = setupHeadingMapping(article, source);
        source.classList.add('is-wrapped');
        source.classList.remove('is-nowrap');
      }

      Array.from(article.children).forEach(function (child) {
        if (child === toolbar || child === source || child === title ||
            child.matches('.museum-article-meta-disclosure,.museum-article-meta,.museum-article-toc-trigger')) return;
        if (mode) {
          hidden.set(child, child.hidden);
          child.hidden = true;
        } else if (hidden.has(child)) {
          child.hidden = hidden.get(child);
        }
      });

      if (!mode) hidden.clear();

      if (mode && closest && idMap) {
        var line = idMap.get(closest.id);
        if (line) line.scrollIntoView({ block: 'start' });
        else toolbar.scrollIntoView({ block: 'nearest' });
      } else {
        toolbar.scrollIntoView({ block: 'nearest' });
      }
    });

    // TOC Jump interceptor
    document.addEventListener('click', function (event) {
      if (!mode) return;
      var link = event.target.closest('a[href^="#"]');
      if (!link) return;
      var rawHref = link.getAttribute('href');
      if (!rawHref || rawHref === '#') return;
      var targetId = decodeURIComponent(rawHref.replace(/^#/, ''));

      if (!idMap) idMap = setupHeadingMapping(article, source);
      var orgHeading = idMap ? idMap.get(targetId) : null;
      if (!orgHeading && idMap) {
        orgHeading = idMap.get(targetId.replace(/^outline-container-/, ''));
      }
      if (!orgHeading) {
        var clean = cleanHeadingText(link.textContent);
        orgHeading = Array.from(source.querySelectorAll('.museum-org-heading')).find(function (oh) {
          return cleanHeadingText(oh.dataset.headingText || oh.textContent) === clean;
        });
      }

      if (orgHeading) {
        event.preventDefault();
        event.stopPropagation();
        orgHeading.scrollIntoView({ behavior: 'smooth', block: 'start' });

        orgHeading.classList.add('is-jump-target');
        setTimeout(function () {
          orgHeading.classList.remove('is-jump-target');
        }, 1800);

        if (window.history && window.history.pushState) {
          window.history.pushState(null, '', '#' + targetId);
        }

        updateActiveToc(targetId, link);
      }
    }, true);

    // Section copy handler (复制本节)
    document.addEventListener('click', async function (e) {
      var copySectionBtn = e.target.closest('.museum-org-btn-copy-section');
      if (!copySectionBtn) return;
      e.preventDefault();
      e.stopPropagation();

      var headingEl = copySectionBtn.closest('.museum-org-heading');
      if (!headingEl) return;
      var level = Number(headingEl.dataset.level) || 1;

      var allItems = Array.from(source.querySelectorAll('.museum-org-line, .museum-org-block-container'));
      var startIdx = allItems.indexOf(headingEl);
      if (startIdx === -1) return;

      var sectionParts = [];
      for (var k = startIdx; k < allItems.length; k++) {
        var item = allItems[k];
        if (k > startIdx && item.classList.contains('museum-org-heading')) {
          var itemLevel = Number(item.dataset.level) || 1;
          if (itemLevel <= level) break;
        }
        if (item.classList.contains('museum-org-block-container') && item._fullBlockRaw) {
          sectionParts.push(item._fullBlockRaw);
        } else {
          var clone = item.cloneNode(true);
          var acts = clone.querySelector('.museum-org-heading-actions');
          if (acts) acts.remove();
          sectionParts.push(clone.textContent.replace(/\u00a0/g, ''));
        }
      }

      try {
        await navigator.clipboard.writeText(sectionParts.join('\n'));
        copySectionBtn.textContent = '已复制本节！';
        setTimeout(function () { copySectionBtn.textContent = '复制本节'; }, 1800);
      } catch (_) {
        copySectionBtn.textContent = '复制失败';
      }
    });

    // Scroll active tracking in Org Mode
    var scrollFrame = 0;
    function onScrollInOrg() {
      if (!mode) return;
      if (scrollFrame) return;
      scrollFrame = requestAnimationFrame(function () {
        scrollFrame = 0;
        var orgHeadings = Array.from(source.querySelectorAll('.museum-org-heading'));
        if (!orgHeadings.length) return;
        var current = null;
        var threshold = 140;
        for (var i = 0; i < orgHeadings.length; i++) {
          var top = orgHeadings[i].getBoundingClientRect().top;
          if (top <= threshold) {
            current = orgHeadings[i];
          } else {
            break;
          }
        }
        if (!current) current = orgHeadings[0];
        if (current && current.dataset.targetId) {
          updateActiveToc(current.dataset.targetId);
        }
      });
    }
    window.addEventListener('scroll', onScrollInOrg, { passive: true });

    // Toggle all code blocks button
    toggleBlocks.addEventListener('click', function () {
      var blocks = Array.from(source.querySelectorAll('.museum-org-block-container'));
      var hasFolded = blocks.some(function (b) { return b._isFolded; });
      var targetFolded = !hasFolded;
      blocks.forEach(function (b) {
        if (typeof b._setFolded === 'function') {
          b._setFolded(targetFolded);
        }
      });
      toggleBlocks.setAttribute('aria-pressed', String(!targetFolded));
      toggleBlocks.textContent = targetFolded ? '展开全部代码' : '折叠全部代码';
    });

    // Toggle line numbers button
    lineNumbersBtn.addEventListener('click', function () {
      var enabled = source.classList.toggle('has-line-numbers');
      lineNumbersBtn.setAttribute('aria-pressed', String(enabled));
      lineNumbersBtn.textContent = enabled ? '隐藏行号' : '显示行号';
    });

    // Copy raw Org content button
    copy.addEventListener('click', async function () {
      try {
        var raw = source.dataset.rawOrg || (source.querySelector('code') || source).textContent;
        await navigator.clipboard.writeText(raw);
        status.textContent = 'Org 正文已复制';
      } catch (_error) {
        status.textContent = '无法自动复制，请选中 Org 正文手动复制。';
      }
    });

    // Auto line wrapping toggle button
    if (wrap) {
      wrap.addEventListener('click', function () {
        var isNowrap = source.classList.toggle('is-nowrap');
        source.classList.toggle('is-wrapped', !isNowrap);
        wrap.setAttribute('aria-pressed', String(!isNowrap));
        wrap.textContent = isNowrap ? '开启换行' : '自动换行';
      });
    }
  }

  // Export for testing and modular invocation
  if (typeof window !== 'undefined') {
    window.orgMuseumOrgView = {
      enhanceSyntaxBuffer: enhanceSyntaxBuffer,
      renderOrgSyntaxLine: renderOrgSyntaxLine,
      createBabelBlockElement: createBabelBlockElement,
      cleanHeadingText: cleanHeadingText,
      start: start
    };
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
