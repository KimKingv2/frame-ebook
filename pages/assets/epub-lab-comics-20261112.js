/* FRAME Reader Reading Room — Foliate.js adapter.
 * Source archives are fetched from the configured Alist/OpenList server proxy.
 * Reading state and appearance are persisted in user-scoped Cloudflare D1.
 */
(function () {
  'use strict';
  var view = null;
  var restoreCfi = null;
  var restorePageIndex = null;
  var restoring = false;
  var currentBookId = null;
  var progressSaveTimer = null;
  var pendingProgress = null;
  var pendingProgressBookId = null;
  var activeAnnotations = [];
  var currentLocation = null;
  var selectedTextState = null;
  var editingAnnotation = null;
  var Overlayer = null;
  var annotationBusy = false;
  var libraryStorePromise = import('/assets/library-store.js?v=20261118-metadata-reconnect-r1');
  var readingTrackerPromise = import('/assets/reading-tracker.js?v=20261117-autoscan-r1');
  var cloudBookSourcePromise = import('/assets/cloud-book-source.js?v=20261117-webdav-ram-r1');
  var overlayerModulePromise = import('/vendor/foliate-js/overlayer.js');
  var THEMES = {
    paper: { background: '#fffefa', foreground: '#29262d', colorScheme: 'light' },
    sepia: { background: '#f1e7d5', foreground: '#40362b', colorScheme: 'light' },
    night: { background: '#191821', foreground: '#e5dfed', colorScheme: 'dark' }
  };
  var appearance = {
    fontScale: '1',
    lineHeight: '1.65',
    verticalMargin: '16',
    horizontalMargin: '7',
    fontFamily: 'original',
    fontWeight: 'original',
    paragraphSpacing: 'original',
    textAlign: 'original',
    readingMode: 'paginated',
    pageLayout: '2',
    comicReadingMode: 'paginated',
    comicPageLayout: '2',
    comicImageFit: 'fit-page',
    backdrop: 'wood',
    theme: 'paper'
  };
  var el = function (id) { return document.getElementById(id); };
  var setText = function (id, value) { var node = el(id); if (node) node.textContent = value; };
  var pageTapBoundDocuments = new WeakSet();

  function isReaderFullscreen() {
    var workspace = el('reading-workspace');
    return !!workspace && (
      document.fullscreenElement === workspace ||
      document.webkitFullscreenElement === workspace
    );
  }

  function isControlOrLinkTarget(target) {
    return !!(target && typeof target.closest === 'function' &&
      target.closest('button,a,area[href],input,select,textarea,video,audio,[contenteditable]:not([contenteditable="false"]),[role="button"],[data-no-page-turn]'));
  }

  function getReaderWindowPoint(event, sourceDoc) {
    var viewport = el('reader-viewport');
    if (!viewport || !event) return null;
    var rect = viewport.getBoundingClientRect();
    if (!rect.width || !rect.height) return null;
    var x = event.clientX;
    var y = event.clientY;
    if (sourceDoc && sourceDoc.defaultView && sourceDoc.defaultView.frameElement) {
      var frameRect = sourceDoc.defaultView.frameElement.getBoundingClientRect();
      var sourceWidth = sourceDoc.documentElement && sourceDoc.documentElement.clientWidth ||
        sourceDoc.defaultView.innerWidth || 0;
      var sourceHeight = sourceDoc.documentElement && sourceDoc.documentElement.clientHeight ||
        sourceDoc.defaultView.innerHeight || 0;
      if (sourceWidth && sourceHeight && frameRect.width && frameRect.height) {
        x = frameRect.left + (event.clientX / sourceWidth) * frameRect.width;
        y = frameRect.top + (event.clientY / sourceHeight) * frameRect.height;
      }
    }
    if (!Number.isFinite(x) || !Number.isFinite(y) ||
        x < rect.left || x > rect.right || y < rect.top || y > rect.bottom) return null;
    return { x:x, y:y, rect:rect, relativeY:y - rect.top };
  }

  function handleReaderWindowTap(event, sourceDoc) {
    if (!view || !event || event.defaultPrevented ||
        event.button !== 0 || event.detail === 0 ||
        event.metaKey || event.ctrlKey || event.altKey || event.shiftKey ||
        isControlOrLinkTarget(event.target)) return false;

    try {
      var selection = sourceDoc && sourceDoc.getSelection
        ? sourceDoc.getSelection()
        : (document.getSelection ? document.getSelection() : null);
      if (selection && !selection.isCollapsed && String(selection).trim()) return false;
    } catch (error) {}

    var point = getReaderWindowPoint(event, sourceDoc);
    if (!point) return false;

    // Top 0–20% is reserved for switching between normal and immersive fullscreen.
    // The remaining 20–100% is split into left/right page-turn zones.
    if (point.relativeY < point.rect.height * 0.2) {
      if (isReaderFullscreen()) toggleImmersiveFullscreen();
    } else {
      turnReaderPage(point.x < point.rect.left + point.rect.width / 2 ? -1 : 1);
    }

    event.preventDefault();
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
    return true;
  }

  function turnReaderPage(direction) {
    if (!view) return;
    try {
      var result = direction < 0 ? view.prev() : view.next();
      if (result && typeof result.catch === 'function') {
        result.catch(function (error) { console.error('FRAME Reader page tap failed:', error); });
      }
    } catch (error) {
      console.error('FRAME Reader page tap failed:', error);
    }
  }

  function epubTypeTokens(node) {
    if (!node || !node.getAttribute) return [];
    var value = '';
    try { value = node.getAttributeNS('http://www.idpf.org/2007/ops', 'type') || ''; } catch (error) {}
    value = value || node.getAttribute('epub:type') || '';
    return String(value).toLowerCase().split(/\s+/).filter(Boolean);
  }

  function isFootnoteReference(anchor) {
    if (!anchor || !anchor.getAttribute) return false;
    var tokens = epubTypeTokens(anchor);
    var role = String(anchor.getAttribute('role') || '').toLowerCase();
    var rel = String(anchor.getAttribute('rel') || '').toLowerCase();
    var classes = String(anchor.className && anchor.className.baseVal !== undefined
      ? anchor.className.baseVal : anchor.className || '').toLowerCase();
    if (tokens.some(function (token) { return token === 'noteref' || token === 'footnote-ref' || token === 'endnote-ref'; })) return true;
    if (role.indexOf('doc-noteref') >= 0 || rel.indexOf('footnote') >= 0 || rel.indexOf('endnote') >= 0) return true;
    if (/noteref|footnote[-_ ]?ref|endnote[-_ ]?ref/.test(classes)) return true;
    return !!(anchor.closest && (anchor.closest('sup') || anchor.querySelector('sup')) &&
      String(anchor.getAttribute('href') || '').indexOf('#') >= 0);
  }

  function isFootnoteTarget(node) {
    if (!node || node.nodeType !== 1) return false;
    var candidates = [node, node.parentElement];
    for (var i = 0; i < candidates.length; i++) {
      var item = candidates[i];
      if (!item || !item.getAttribute) continue;
      var types = epubTypeTokens(item);
      var role = String(item.getAttribute('role') || '').toLowerCase();
      var classes = String(item.className && item.className.baseVal !== undefined
        ? item.className.baseVal : item.className || '').toLowerCase();
      var id = String(item.id || item.getAttribute('name') || '').toLowerCase();
      if (types.some(function (token) { return token === 'footnote' || token === 'endnote' || token === 'rearnote'; })) return true;
      if (/doc-(footnote|endnote)/.test(role) || /footnote|endnote/.test(classes) ||
          /^(?:_?ftn|_?fn|footnote|endnote)[-_]?\\w*/.test(id)) return true;
    }
    return false;
  }

  function cloneFootnoteContent(source) {
    function clone(node) {
      if (!node) return null;
      if (node.nodeType === 3) return document.createTextNode(node.nodeValue || '');
      if (node.nodeType !== 1) return null;
      var types = epubTypeTokens(node);
      var role = String(node.getAttribute('role') || '').toLowerCase();
      var rel = String(node.getAttribute('rel') || '').toLowerCase();
      if (types.indexOf('backlink') >= 0 || role.indexOf('doc-backlink') >= 0 || rel.indexOf('back') >= 0) return null;
      var tag = String(node.localName || node.tagName || 'span').toLowerCase();
      var allowed = ['p','div','span','em','strong','b','i','u','sup','sub','br','ul','ol','li','blockquote','code'];
      var output = document.createElement(allowed.indexOf(tag) >= 0 ? tag : 'span');
      Array.prototype.forEach.call(node.childNodes || [], function (child) {
        var copied = clone(child);
        if (copied) output.appendChild(copied);
      });
      return output;
    }
    var wrapper = document.createElement('div');
    if (source && source.nodeType === 1) {
      Array.prototype.forEach.call(source.childNodes || [], function (child) {
        var copied = clone(child);
        if (copied) wrapper.appendChild(copied);
      });
    }
    return wrapper;
  }

  function closeFootnotePopover() {
    var popover = el('reader-footnote-popover');
    if (popover) popover.hidden = true;
  }

  async function showFootnotePopover(anchor, sourceDoc, sourceIndex, href, explicitReference) {
    if (!view || !view.book || !view.book.sections) return;
    var sourceSection = view.book.sections[sourceIndex];
    var resolvedHref = sourceSection && sourceSection.resolveHref
      ? sourceSection.resolveHref(href) : href;
    var resolved = view.resolveNavigation(resolvedHref);
    if (!resolved || !Number.isInteger(Number(resolved.index))) {
      await view.goTo(resolvedHref);
      return;
    }
    var targetSection = view.book.sections[Number(resolved.index)];
    if (!targetSection || typeof targetSection.createDocument !== 'function') {
      await view.goTo(resolvedHref);
      return;
    }
    var targetDoc = await targetSection.createDocument();
    var targetNode = resolved.anchor ? resolved.anchor(targetDoc) : null;
    if (targetNode && targetNode.startContainer) {
      targetNode = targetNode.startContainer.nodeType === 1
        ? targetNode.startContainer : targetNode.startContainer.parentElement;
    }
    if (!targetNode || targetNode.nodeType !== 1) {
      await view.goTo(resolvedHref);
      return;
    }
    if (!explicitReference && !isFootnoteTarget(targetNode)) {
      await view.goTo(resolvedHref);
      return;
    }
    var targetText = String(targetNode.textContent || '').trim();
    var targetTag = String(targetNode.localName || targetNode.tagName || '').toLowerCase();
    var parentText = String(targetNode.parentElement && targetNode.parentElement.textContent || '').trim();
    if ((!targetText || ((targetTag === 'a' || targetTag === 'span' || targetTag === 'sup') &&
        parentText.length > targetText.length + 8)) && targetNode.parentElement) {
      targetNode = targetNode.parentElement;
    }
    if (!targetNode.textContent || !targetNode.textContent.trim()) {
      var nextNote = targetNode.nextElementSibling;
      if (nextNote && nextNote.textContent && nextNote.textContent.trim()) targetNode = nextNote;
    }
    var content = cloneFootnoteContent(targetNode);
    if (!content.textContent || !content.textContent.trim()) {
      await view.goTo(resolvedHref);
      return;
    }
    var popover = el('reader-footnote-popover');
    var body = el('reader-footnote-content');
    var host = el('reader-frame');
    if (!popover || !body || !host) return;
    body.textContent = '';
    body.appendChild(content);
    popover.hidden = false;

    var anchorRect = anchor.getBoundingClientRect();
    var frameElement = sourceDoc && sourceDoc.defaultView && sourceDoc.defaultView.frameElement;
    var frameRect = frameElement ? frameElement.getBoundingClientRect() : { left:0, top:0 };
    var hostRect = host.getBoundingClientRect();
    var anchorX = frameRect.left + anchorRect.left + anchorRect.width / 2 - hostRect.left;
    var anchorY = frameRect.top + anchorRect.top - hostRect.top;
    var popoverWidth = Math.min(480, Math.max(240, hostRect.width - 28));
    var left = Math.max(popoverWidth / 2 + 12, Math.min(hostRect.width - popoverWidth / 2 - 12, anchorX));
    popover.style.left = left + 'px';
    popover.style.top = '12px';
    var popoverHeight = popover.offsetHeight || 180;
    var top = anchorY + 18;
    if (top + popoverHeight > hostRect.height - 12) top = anchorY - popoverHeight - 12;
    top = Math.max(10, Math.min(hostRect.height - popoverHeight - 10, top));
    popover.style.top = top + 'px';
  }

  function handleFootnoteReference(event, sourceDoc, sourceIndex) {
    if (!event || event.defaultPrevented || !event.target || !event.target.closest) return false;
    var anchor = event.target.closest('a[href]');
    if (!anchor) return false;
    var href = String(anchor.getAttribute('href') || '').trim();
    var explicitReference = isFootnoteReference(anchor);
    if (!href || (!explicitReference && href.indexOf('#') < 0) ||
        /^(https?:|mailto:|tel:|javascript:)/i.test(href)) return false;
    event.preventDefault();
    event.stopPropagation();
    if (typeof event.stopImmediatePropagation === 'function') event.stopImmediatePropagation();
    closeFootnotePopover();
    showFootnotePopover(anchor, sourceDoc, sourceIndex, href, explicitReference).catch(function (error) {
      console.warn('FRAME Reader could not display footnote:', error);
      if (view) view.goTo(href).catch(function () {});
    });
    return true;
  }

  function bindPageTapNavigation(doc, index) {
    if (!doc || !doc.addEventListener || pageTapBoundDocuments.has(doc)) return;
    pageTapBoundDocuments.add(doc);
    doc.addEventListener('click', function (event) {
      if (handleFootnoteReference(event, doc, index)) return;
      closeFootnotePopover();
      handleReaderWindowTap(event, doc);
    }, true);
  }

  function bindReaderRoomControls() {
    var workspace = el('reading-workspace');
    var sidebar = el('reader-sidebar');
    var sidebarToggle = el('reader-sidebar-toggle');
    var sidebarClose = el('reader-sidebar-close');
    var sidebarBackdrop = el('reader-sidebar-backdrop');
    var appearancePanel = el('reader-appearance-panel');
    var appearanceToggle = el('reader-appearance-toggle');
    var settingsBackdrop = el('reader-settings-backdrop');
    var quickActions = el('reader-quick-actions');
    var quickActionsHome = quickActions ? quickActions.parentNode : null;
    var tocSelect = el('toc-select');
    var paneButtons = Array.prototype.slice.call(document.querySelectorAll('[data-reader-pane]'));

    // Move both layers to the end of the workspace so they paint above the
    // reading surface in native fullscreen as well as in the regular page.
    if (workspace) {
      if (settingsBackdrop) workspace.appendChild(settingsBackdrop);
      if (appearancePanel) workspace.appendChild(appearancePanel);
    }

    // Keep the three primary actions independent of the heading and reading
    // surface while native fullscreen is active. Restore their original home
    // when fullscreen closes.
    function syncFullscreenActionDock() {
      if (!workspace || !quickActions || !quickActionsHome) return;
      var active = document.fullscreenElement === workspace ||
        document.webkitFullscreenElement === workspace;
      if (active) {
        if (quickActions.parentNode !== workspace) workspace.appendChild(quickActions);
      } else if (quickActions.parentNode !== quickActionsHome) {
        quickActionsHome.appendChild(quickActions);
      }
    }
    document.addEventListener('fullscreenchange', syncFullscreenActionDock);
    document.addEventListener('webkitfullscreenchange', syncFullscreenActionDock);
    syncFullscreenActionDock();

    function isMobile() {
      return !!(window.matchMedia && window.matchMedia('(max-width: 820px)').matches);
    }
    function setSidebar(open) {
      if (!sidebar || !sidebarToggle || !workspace) return;
      if (isMobile()) {
        sidebar.classList.toggle('is-open', !!open);
        if (sidebarBackdrop) sidebarBackdrop.hidden = !open;
        sidebarToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
        document.body.classList.toggle('reader-drawer-open', !!open);
      } else {
        workspace.classList.toggle('reader-sidebar-collapsed', !open);
        sidebarToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      }
    }
    function closeSidebar() {
      if (isMobile()) setSidebar(false);
    }
    function selectPane(name) {
      if (!sidebar) return;
      var pane = name === 'notes' ? 'notes' : (name === 'bookmarks' ? 'bookmarks' : 'toc');
      sidebar.classList.toggle('mobile-pane-notes', pane === 'notes');
      sidebar.classList.toggle('mobile-pane-toc', pane === 'toc');
      sidebar.classList.toggle('mobile-pane-bookmarks', pane === 'bookmarks');
      paneButtons.forEach(function (button) {
        var active = button.getAttribute('data-reader-pane') === pane;
        button.classList.toggle('is-active', active);
        button.setAttribute('aria-pressed', active ? 'true' : 'false');
      });
      if (pane === 'notes') {
        var panel = el('annotation-panel');
        var toggle = el('annotation-list-toggle');
        if (panel) panel.hidden = false;
        if (toggle) toggle.setAttribute('aria-expanded', 'true');
      }
    }
    function syncSettings() {
      var open = !!(appearancePanel && appearancePanel.open);
      if (settingsBackdrop) settingsBackdrop.hidden = !open;
      if (appearanceToggle) appearanceToggle.setAttribute('aria-expanded', open ? 'true' : 'false');
      document.body.classList.toggle('reader-settings-open', open);
      // The stylesheet owns drawer placement; clear legacy inline coordinates.
      if (appearancePanel) {
        ['position', 'top', 'right', 'bottom', 'left', 'max-height'].forEach(function (property) {
          appearancePanel.style.removeProperty(property);
        });
      }
    }
    function toggleSidebar(event) {
      if (event) {
        event.preventDefault();
        event.stopPropagation();
      }
      if (!sidebar || !workspace) return;
      if (isMobile()) {
        var nextOpen = !sidebar.classList.contains('is-open');
        setSidebar(nextOpen);
        if (nextOpen) selectPane('toc');
      } else {
        setSidebar(workspace.classList.contains('reader-sidebar-collapsed'));
      }
    }
    function toggleSettings(event) {
      if (event) {
        event.preventDefault();
        event.stopPropagation();
      }
      if (!appearancePanel) return;
      if (isMobile()) closeSidebar();
      appearancePanel.open = !appearancePanel.open;
      syncSettings();
    }

    // Expose a single close path for TOC navigation and the drawer controls.
    window.frameReaderCloseSidebar = closeSidebar;
    selectPane('toc');
    if (isMobile() && sidebarToggle) sidebarToggle.setAttribute('aria-expanded', 'false');

    // Capture clicks at document level so another nested listener cannot swallow
    // taps on these two primary controls.
    document.addEventListener('click', function (event) {
      var target = event.target && event.target.closest
        ? event.target.closest('#reader-sidebar-toggle, #reader-appearance-toggle')
        : null;
      if (!target) return;
      if (target.id === 'reader-sidebar-toggle') toggleSidebar(event);
      else if (target.id === 'reader-appearance-toggle') toggleSettings(event);
    }, true);

    if (sidebarClose) sidebarClose.addEventListener('click', closeSidebar);
    if (sidebarBackdrop) sidebarBackdrop.addEventListener('click', closeSidebar);
    paneButtons.forEach(function (button) {
      button.addEventListener('click', function () {
        selectPane(button.getAttribute('data-reader-pane'));
      });
    });
    if (appearancePanel) appearancePanel.addEventListener('toggle', syncSettings);
    if (settingsBackdrop) {
      settingsBackdrop.addEventListener('click', function () {
        if (appearancePanel) appearancePanel.open = false;
        syncSettings();
      });
    }
    if (tocSelect) {
      tocSelect.addEventListener('change', function () {
        if (isMobile()) closeSidebar();
      });
    }
    document.addEventListener('keydown', function (event) {
      if (event.key !== 'Escape') return;
      closeSidebar();
      if (appearancePanel) appearancePanel.open = false;
      syncSettings();
    });
    window.addEventListener('resize', function () {
      if (!isMobile()) {
        if (sidebar) sidebar.classList.remove('is-open');
        if (sidebarBackdrop) sidebarBackdrop.hidden = true;
        if (sidebarToggle) sidebarToggle.setAttribute('aria-expanded', 'true');
        if (workspace) workspace.classList.remove('reader-sidebar-collapsed');
        document.body.classList.remove('reader-drawer-open');
      }
      syncSettings();
    });
    syncSettings();
  }

  var ANNOTATION_COLORS = {
    yellow: '#F2C94C',
    violet: '#A78BFA',
    mint: '#65C9A5',
    rose: '#E88EAF',
    sky: '#6FB9E8',
    underline: '#A78BFA'
  };

  function annotationColor(name) {
    return ANNOTATION_COLORS[String(name || '')] || ANNOTATION_COLORS.yellow;
  }

  function makeAnnotationId() {
    return window.crypto && typeof window.crypto.randomUUID === 'function'
      ? window.crypto.randomUUID()
      : 'ann-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 10);
  }

  function annotationToolbar() {
    return el('annotation-selection-toolbar');
  }

  function hideSelectionToolbar(clearSelection) {
    var toolbar = annotationToolbar();
    if (toolbar) toolbar.hidden = true;
    if (clearSelection) {
      selectedTextState = null;
      if (view && typeof view.deselect === 'function') view.deselect();
    }
  }

  function captureTextSelection(doc, index) {
    if (!view || view.isFixedLayout || annotationBusy) return;
    var win = doc && doc.defaultView;
    var selection = win && win.getSelection ? win.getSelection() : null;
    if (!selection || !selection.rangeCount || selection.isCollapsed) {
      hideSelectionToolbar(false);
      return;
    }
    var quote = String(selection.toString() || '').replace(/\s+/g, ' ').trim();
    if (!quote || quote.length > 12000) {
      hideSelectionToolbar(false);
      return;
    }
    var range;
    var cfi;
    try {
      range = selection.getRangeAt(0).cloneRange();
      cfi = view.getCFI(index, range);
    } catch (error) {
      console.warn('FRAME Reader could not create a CFI for this selection:', error);
      hideSelectionToolbar(false);
      return;
    }
    var rect = range.getBoundingClientRect();
    if ((!rect || (!rect.width && !rect.height)) && range.getClientRects().length) {
      rect = range.getClientRects()[0];
    }
    if (!rect) return;
    var frame = win.frameElement;
    var frameRect = frame ? frame.getBoundingClientRect() : { left: 0, top: 0 };
    var readerFrame = el('reader-frame');
    var hostRect = readerFrame ? readerFrame.getBoundingClientRect() : { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
    var left = frameRect.left + rect.left + Math.max(0, rect.width / 2) - hostRect.left;
    var top = frameRect.top + rect.top - hostRect.top - 48;
    var toolbar = annotationToolbar();
    if (!toolbar) return;
    toolbar.hidden = false;
    var toolbarWidth = toolbar.offsetWidth || 270;
    var toolbarHeight = toolbar.offsetHeight || 46;
    left = Math.max(12 + toolbarWidth / 2, Math.min(hostRect.width - 12 - toolbarWidth / 2, left));
    top = Math.max(8, Math.min(hostRect.height - toolbarHeight - 8, top));
    toolbar.style.left = left + 'px';
    toolbar.style.top = top + 'px';
    selectedTextState = {
      cfi: cfi,
      quote: quote,
      range: range,
      index: index,
      doc: doc,
      createdAt: Date.now()
    };
  }

  function bindSelectionEvents(doc, index) {
    if (!doc || doc.documentElement.dataset.frameReaderSelectionBound === '1') return;
    doc.documentElement.dataset.frameReaderSelectionBound = '1';
    var schedule = function (delay) {
      window.setTimeout(function () { captureTextSelection(doc, index); }, delay);
    };
    doc.addEventListener('mouseup', function () { schedule(20); });
    doc.addEventListener('keyup', function () { schedule(20); });
    doc.addEventListener('touchend', function () { schedule(100); }, { passive: true });
  }

  function renderAnnotationList() {
    var list = el('annotation-list');
    var count = el('annotation-count');
    if (!list || !count) return;
    var annotations = activeAnnotations.filter(function (item) { return item.type !== 'bookmark'; });
    count.textContent = String(annotations.length);
    list.textContent = '';
    if (!annotations.length) {
      var empty = document.createElement('p');
      empty.className = 'annotation-empty';
      empty.textContent = '這本書還沒有筆記或高亮。選取正文中的文字即可新增。';
      list.appendChild(empty);
      return;
    }
    annotations.slice().sort(function (a, b) {
      return (Number(b.createdAt) || 0) - (Number(a.createdAt) || 0);
    }).forEach(function (annotation) {
      var item = document.createElement('article');
      item.className = 'annotation-item';
      var marker = document.createElement('span');
      marker.className = 'annotation-marker ' + (annotation.type === 'note' ? 'is-note' : (annotation.type === 'highlight' && annotation.color === 'underline' ? 'is-underline' : 'is-highlight'));
      marker.style.setProperty('--annotation-color', annotationColor(annotation.color));
      marker.setAttribute('aria-hidden', 'true');

      var content = document.createElement('button');
      content.type = 'button';
      content.className = 'annotation-item-content';
      content.title = '跳回這段文字';
      var kind = document.createElement('span');
      kind.className = 'annotation-kind';
      kind.textContent = annotation.type === 'note' ? '筆記' : (annotation.color === 'underline' ? '下劃線' : '高亮');
      var quote = document.createElement('span');
      quote.className = 'annotation-quote';
      quote.textContent = annotation.quote || '未附選取文字';
      content.append(kind, quote);
      if (annotation.text) {
        var note = document.createElement('span');
        note.className = 'annotation-note-preview';
        note.textContent = annotation.text;
        content.appendChild(note);
      }
      content.addEventListener('click', async function () {
        if (!view) return;
        try {
          await view.goTo(annotation.cfi);
          if (annotation.type === 'note') openNoteComposer(annotation);
        } catch (error) {
          setText('reader-status', '無法跳回這筆標註：' + (error.message || String(error)));
        }
      });

      var remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'annotation-delete';
      remove.textContent = '刪除';
      remove.setAttribute('aria-label', '刪除這筆標註');
      remove.addEventListener('click', function () { deleteAnnotationRecord(annotation); });
      item.append(marker, content, remove);
      list.appendChild(item);
    });
  }

  function bookmarkTarget(bookmark) {
    var fixed = String(bookmark && bookmark.cfi || '').match(/^frame-fixed:(\d+)$/);
    return fixed ? Number(fixed[1]) : String(bookmark && bookmark.cfi || '');
  }

  function syncBookmarkButton() {
    var button = el('reader-bookmark-toggle');
    if (!button) return;
    var cfi = currentLocation && currentLocation.cfi;
    var bookmarked = !!cfi && activeAnnotations.some(function (item) {
      return item.type === 'bookmark' && item.cfi === cfi;
    });
    button.disabled = !cfi || !currentBookId;
    button.setAttribute('aria-pressed', bookmarked ? 'true' : 'false');
    button.textContent = bookmarked ? '★ 書籤' : '☆ 書籤';
    button.title = bookmarked ? '移除此頁書籤' : '將目前閱讀位置加入書籤';
  }

  function renderBookmarkList() {
    var list = el('bookmark-list');
    var count = el('bookmark-count');
    var tabCount = el('bookmark-tab-count');
    if (!list || !count) return;
    var bookmarks = activeAnnotations.filter(function (item) { return item.type === 'bookmark'; });
    count.textContent = String(bookmarks.length);
    if (tabCount) tabCount.textContent = String(bookmarks.length);
    list.textContent = '';
    if (!bookmarks.length) {
      var empty = document.createElement('p');
      empty.className = 'annotation-empty';
      empty.textContent = '尚無書籤。閱讀到想記住的位置時，點擊書頁右上角的書籤按鈕。';
      list.appendChild(empty);
      syncBookmarkButton();
      return;
    }
    bookmarks.slice().sort(function (a, b) {
      return (Number(b.createdAt) || 0) - (Number(a.createdAt) || 0);
    }).forEach(function (bookmark) {
      var item = document.createElement('article');
      item.className = 'annotation-item bookmark-item';
      var marker = document.createElement('span');
      marker.className = 'bookmark-marker';
      marker.textContent = '★';
      marker.setAttribute('aria-hidden', 'true');
      var content = document.createElement('button');
      content.type = 'button';
      content.className = 'annotation-item-content';
      content.title = '跳回這個書籤';
      var kind = document.createElement('span');
      kind.className = 'annotation-kind';
      kind.textContent = '書籤';
      var quote = document.createElement('span');
      quote.className = 'annotation-quote';
      quote.textContent = bookmark.quote || '已保存的閱讀位置';
      content.append(kind, quote);
      content.addEventListener('click', async function () {
        if (!view) return;
        try {
          await view.goTo(bookmarkTarget(bookmark));
          closeFootnotePopover();
          if (window.matchMedia('(max-width: 820px)').matches && typeof window.frameReaderCloseSidebar === 'function') {
            window.frameReaderCloseSidebar();
          }
        } catch (error) {
          setText('reader-status', '無法開啟這個書籤：' + (error.message || String(error)));
        }
      });
      var remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'annotation-delete';
      remove.textContent = '刪除';
      remove.setAttribute('aria-label', '刪除這個書籤');
      remove.addEventListener('click', function () { deleteAnnotationRecord(bookmark); });
      item.append(marker, content, remove);
      list.appendChild(item);
    });
    syncBookmarkButton();
  }

  async function toggleCurrentBookmark() {
    if (annotationBusy || !currentBookId || !currentLocation || !currentLocation.cfi) return;
    var existing = activeAnnotations.find(function (item) {
      return item.type === 'bookmark' && item.cfi === currentLocation.cfi;
    });
    if (existing) {
      await deleteAnnotationRecord(existing);
      return;
    }
    annotationBusy = true;
    var button = el('reader-bookmark-toggle');
    if (button) button.disabled = true;
    try {
      var store = await libraryStorePromise;
      var saved = await store.saveAnnotation({
        id: makeAnnotationId(),
        bookId: currentBookId,
        type: 'bookmark',
        cfi: currentLocation.cfi,
        quote: currentLocation.label || (currentLocation.percent + '% 閱讀位置'),
        text: '',
        color: 'violet',
        createdAt: Date.now()
      });
      saved.sectionIndex = currentLocation.index;
      activeAnnotations.push(saved);
      renderBookmarkList();
      setText('reader-status', '書籤已保存至雲端 D1。');
    } catch (error) {
      setText('reader-status', '書籤保存失敗：' + (error.message || String(error)));
    } finally {
      annotationBusy = false;
      syncBookmarkButton();
    }
  }

  function upsertAnnotation(annotation) {
    var index = activeAnnotations.findIndex(function (item) { return item.id === annotation.id; });
    if (index >= 0) activeAnnotations[index] = annotation;
    else activeAnnotations.push(annotation);
    renderAnnotationList();
    renderBookmarkList();
  }

  function drawAnnotation(annotation) {
    if (!view || !annotation || !annotation.cfi) return Promise.resolve();
    return view.addAnnotation({
      value: annotation.cfi,
      type: annotation.type,
      color: annotation.color,
      id: annotation.id
    }).catch(function (error) {
      console.warn('FRAME Reader could not draw annotation:', error);
    });
  }

  function openNoteComposer(annotation) {
    var dialog = el('annotation-note-dialog');
    if (!dialog) return;
    editingAnnotation = annotation || null;
    var quote = annotation ? annotation.quote : (selectedTextState && selectedTextState.quote || '');
    setText('annotation-note-quote', quote || '未取得選取文字');
    el('annotation-note-text').value = annotation ? String(annotation.text || '') : '';
    setText('annotation-note-title', annotation ? '編輯筆記' : '為這段文字寫筆記');
    el('annotation-note-delete').hidden = !annotation;
    hideSelectionToolbar(false);
    if (!dialog.open) dialog.showModal();
    if (!annotation) window.setTimeout(function () { el('annotation-note-text').focus(); }, 20);
  }

  function closeNoteComposer() {
    var dialog = el('annotation-note-dialog');
    if (dialog && dialog.open) dialog.close();
    editingAnnotation = null;
  }

  async function saveNoteFromComposer() {
    if (annotationBusy) {
      setText('annotation-note-status', '上一筆標註仍在保存，請稍候。');
      return;
    }
    var text = String(el('annotation-note-text').value || '').trim();
    if (!text) {
      setText('annotation-note-status', '請先輸入筆記內容。');
      return;
    }
    var base = editingAnnotation || selectedTextState;
    if (!base || !base.cfi || !currentBookId) {
      setText('annotation-note-status', '找不到原文定位，請重新選取文字後再新增筆記。');
      return;
    }
    annotationBusy = true;
    el('annotation-note-save').disabled = true;
    setText('annotation-note-status', '正在保存至雲端 D1……');
    try {
      var store = await libraryStorePromise;
      var saved = await store.saveAnnotation({
        id: editingAnnotation ? editingAnnotation.id : makeAnnotationId(),
        bookId: currentBookId,
        type: 'note',
        cfi: base.cfi,
        quote: base.quote || '',
        text: text,
        color: editingAnnotation ? editingAnnotation.color : 'violet',
        createdAt: editingAnnotation ? editingAnnotation.createdAt : Date.now()
      });
      var navigation = view.resolveNavigation(saved.cfi);
      saved.sectionIndex = navigation && navigation.index;
      upsertAnnotation(saved);
      await drawAnnotation(saved);
      setText('reader-status', '筆記已保存至雲端 D1。');
      closeNoteComposer();
      hideSelectionToolbar(true);
    } catch (error) {
      setText('annotation-note-status', '保存失敗：' + (error.message || String(error)));
    } finally {
      annotationBusy = false;
      el('annotation-note-save').disabled = false;
    }
  }

  async function addHighlight(color, asUnderline) {
    if (annotationBusy) {
      setText('reader-status', '上一筆標註仍在保存，請稍候。');
      return;
    }
    if (!selectedTextState || !selectedTextState.cfi) {
      setText('reader-status', '沒有取得選取文字的位置。請重新選取 EPUB 正文後再試。');
      return;
    }
    if (!currentBookId) {
      setText('reader-status', '書籍尚未載入完成，暫時無法保存標註。');
      return;
    }
    annotationBusy = true;
    var toolbar = annotationToolbar();
    if (toolbar) toolbar.querySelectorAll('button').forEach(function (button) { button.disabled = true; });
    try {
      var store = await libraryStorePromise;
      var saved = await store.saveAnnotation({
        id: makeAnnotationId(),
        bookId: currentBookId,
        type: 'highlight',
        cfi: selectedTextState.cfi,
        quote: selectedTextState.quote,
        text: '',
        color: asUnderline ? 'underline' : color,
        createdAt: Date.now()
      });
      var navigation = view.resolveNavigation(saved.cfi);
      saved.sectionIndex = navigation && navigation.index;
      upsertAnnotation(saved);
      await drawAnnotation(saved);
      setText('reader-status', asUnderline ? '已新增下劃線，並保存至雲端 D1。' : '已新增高亮，並保存至雲端 D1。');
      hideSelectionToolbar(true);
    } catch (error) {
      setText('reader-status', '高亮保存失敗：' + (error.message || String(error)));
    } finally {
      annotationBusy = false;
      if (toolbar) toolbar.querySelectorAll('button').forEach(function (button) { button.disabled = false; });
    }
  }

  async function deleteAnnotationRecord(annotation) {
    if (!annotation || annotationBusy || !currentBookId) return;
    if (!window.confirm(annotation.type === 'bookmark' ? '確定刪除這個書籤嗎？' : '確定刪除這筆標註嗎？')) return;
    annotationBusy = true;
    try {
      var store = await libraryStorePromise;
      await store.deleteAnnotation(annotation.id, currentBookId);
      activeAnnotations = activeAnnotations.filter(function (item) { return item.id !== annotation.id; });
      if (view && annotation.type !== 'bookmark') await view.deleteAnnotation({ value: annotation.cfi });
      renderAnnotationList();
      renderBookmarkList();
      syncBookmarkButton();
      setText('reader-status', annotation.type === 'bookmark' ? '書籤已從雲端 D1 刪除。' : '標註已從雲端 D1 刪除。');
    } catch (error) {
      setText('reader-status', '刪除標註失敗：' + (error.message || String(error)));
    } finally {
      annotationBusy = false;
    }
  }

  function bindAnnotationControls() {
    var toolbar = annotationToolbar();
    if (!toolbar) return;
    var bookmarkButton = el('reader-bookmark-toggle');
    var footnoteClose = el('reader-footnote-close');
    if (bookmarkButton) bookmarkButton.addEventListener('click', toggleCurrentBookmark);
    if (footnoteClose) footnoteClose.addEventListener('click', closeFootnotePopover);
    // Do not cancel pointerdown here: cancelling it suppresses compatibility
    // mouse events and can prevent the buttons' click handlers from firing.
    // Selection CFI/quote are already captured before the toolbar is shown.
    toolbar.addEventListener('pointerdown', function (event) { event.stopPropagation(); });
    toolbar.querySelectorAll('[data-highlight-color]').forEach(function (button) {
      button.addEventListener('click', function () { addHighlight(button.getAttribute('data-highlight-color')); });
    });
    el('selection-add-underline').addEventListener('click', function () { addHighlight('underline', true); });
    el('selection-add-note').addEventListener('click', function () { openNoteComposer(null); });
    el('selection-dismiss').addEventListener('click', function () { hideSelectionToolbar(true); });
    el('annotation-note-cancel').addEventListener('click', closeNoteComposer);
    el('annotation-note-save').addEventListener('click', saveNoteFromComposer);
    el('annotation-note-delete').addEventListener('click', function () {
      var item = editingAnnotation;
      closeNoteComposer();
      if (item) deleteAnnotationRecord(item);
    });
    el('annotation-list-toggle').addEventListener('click', function () {
      var panel = el('annotation-panel');
      panel.hidden = !panel.hidden;
      el('annotation-list-toggle').setAttribute('aria-expanded', panel.hidden ? 'false' : 'true');
    });
    el('annotation-refresh').addEventListener('click', async function () {
      if (!currentBookId) return;
      try {
        var store = await libraryStorePromise;
        activeAnnotations = await store.listAnnotations(currentBookId);
        activeAnnotations.forEach(function (annotation) {
          if (annotation.type === 'bookmark' && /^frame-fixed:\d+$/.test(annotation.cfi)) {
            annotation.sectionIndex = Number(annotation.cfi.split(':')[1]);
          } else {
            var nav = view && view.resolveNavigation(annotation.cfi);
            annotation.sectionIndex = nav && nav.index;
          }
        });
        renderAnnotationList();
        renderBookmarkList();
        syncBookmarkButton();
        setText('reader-status', '已重新整理本書標註與書籤。');
      } catch (error) {
        setText('reader-status', '讀取標註失敗：' + (error.message || String(error)));
      }
    });
  }

  function titleText(value) {
    if (typeof value === 'string') return value;
    if (value && typeof value === 'object') {
      return value['zh-Hant'] || value.zh || value.en || value[Object.keys(value)[0]] || '未命名書籍';
    }
    return '未命名書籍';
  }
  function tocChildren(item) {
    if (!item || typeof item !== 'object') return [];
    if (Array.isArray(item.subitems)) return item.subitems;
    if (Array.isArray(item.children)) return item.children;
    return [];
  }
  function flattenTOC(items, output, depth) {
    output = output || [];
    depth = Number(depth) || 0;
    (items || []).forEach(function (item) {
      if (!item || typeof item !== 'object') return;
      if (item.href) output.push({ label: titleText(item.label), href: String(item.href), depth: depth });
      flattenTOC(tocChildren(item), output, depth + 1);
    });
    return output;
  }
  function populateTOC(items) {
    var select = el('toc-select');
    var tree = el('toc-tree');
    if (!select || !tree) return;
    select.innerHTML = '';
    tree.textContent = '';
    var roots = Array.isArray(items) ? items : [];
    var flat = flattenTOC(roots);
    if (!flat.length) {
      var empty = document.createElement('p');
      empty.className = 'toc-tree-empty';
      empty.textContent = '這本書沒有可用目錄';
      tree.appendChild(empty);
      var option = document.createElement('option');
      option.value = '';
      option.textContent = '這本書沒有可用目錄';
      select.appendChild(option);
      select.disabled = true;
      return;
    }

    flat.forEach(function (item) {
      var option = document.createElement('option');
      option.value = item.href;
      option.textContent = item.label;
      select.appendChild(option);
    });
    select.disabled = false;

    function appendItems(source, parent, depth) {
      (source || []).forEach(function (item, itemIndex) {
        if (!item || typeof item !== 'object') return;
        var children = tocChildren(item);
        var href = item.href ? String(item.href) : '';
        var label = titleText(item.label);
        var entry = document.createElement('li');
        entry.className = 'toc-tree-item';
        entry.dataset.depth = String(depth);

        var row = document.createElement('div');
        row.className = 'toc-tree-row';

        if (children.length) {
          var disclosure = document.createElement('button');
          disclosure.type = 'button';
          disclosure.className = 'toc-tree-disclosure';
          disclosure.textContent = '›';
          disclosure.setAttribute('aria-expanded', 'false');
          disclosure.setAttribute('aria-label', '展開「' + label + '」子目錄');
          disclosure.addEventListener('click', function () {
            var expanded = entry.classList.toggle('is-expanded');
            disclosure.setAttribute('aria-expanded', expanded ? 'true' : 'false');
            disclosure.textContent = expanded ? '⌄' : '›';
            disclosure.setAttribute('aria-label', (expanded ? '收合「' : '展開「') + label + '」子目錄');
          });
          row.appendChild(disclosure);
        } else {
          var spacer = document.createElement('span');
          spacer.className = 'toc-tree-disclosure-spacer';
          row.appendChild(spacer);
        }

        var chapter = href ? document.createElement('button') : document.createElement('span');
        if (href) {
          chapter.type = 'button';
          chapter.className = 'toc-tree-link';
          chapter.addEventListener('click', function () {
            tree.querySelectorAll('.toc-tree-link.is-current').forEach(function (node) {
              node.classList.remove('is-current');
              node.removeAttribute('aria-current');
            });
            chapter.classList.add('is-current');
            chapter.setAttribute('aria-current', 'location');
            select.value = href;
            if (view) {
              view.goTo(href).catch(function (error) {
                setText('reader-status', '無法開啟這個章節：' + (error.message || String(error)));
              });
            }
            if (window.matchMedia('(max-width: 820px)').matches) {
              if (typeof window.frameReaderCloseSidebar === 'function') {
                window.frameReaderCloseSidebar();
              } else {
                var sidebar = el('reader-sidebar');
                var toggle = el('reader-sidebar-toggle');
                var backdrop = el('reader-sidebar-backdrop');
                if (sidebar) sidebar.classList.remove('is-open');
                if (toggle) toggle.setAttribute('aria-expanded', 'false');
                if (backdrop) backdrop.hidden = true;
              }
            }
          });
        } else {
          chapter.className = 'toc-tree-label';
        }
        chapter.textContent = label;
        chapter.title = label;
        row.appendChild(chapter);
        entry.appendChild(row);

        if (children.length) {
          var nested = document.createElement('ul');
          nested.className = 'toc-tree-children';
          var expandAtStart = depth === 0 && roots.length === 1 && itemIndex === 0;
          nested.hidden = !expandAtStart;
          if (expandAtStart) {
            entry.classList.add('is-expanded');
            var button = row.querySelector('.toc-tree-disclosure');
            if (button) {
              button.textContent = '⌄';
              button.setAttribute('aria-expanded', 'true');
              button.setAttribute('aria-label', '收合「' + label + '」子目錄');
            }
          }
          appendItems(children, nested, depth + 1);
          entry.appendChild(nested);
        }
        parent.appendChild(entry);
      });
    }

    var list = document.createElement('ul');
    list.className = 'toc-tree-list';
    appendItems(roots, list, 0);
    tree.appendChild(list);
  }
  async function flushLibraryProgress() {
    if (progressSaveTimer) {
      clearTimeout(progressSaveTimer);
      progressSaveTimer = null;
    }
    if (!pendingProgress || !pendingProgressBookId) return;
    var bookId = pendingProgressBookId;
    var patch = pendingProgress;
    pendingProgress = null;
    pendingProgressBookId = null;
    try {
      var store = await libraryStorePromise;
      var book = await store.getBook(bookId);
      if (book) {
        await store.updateBook(bookId, {
          progress: Object.assign({}, book.progress || {}, patch),
          lastOpenedAt: Date.now()
        });
      }
    } catch (error) {
      console.warn('FRAME Reader could not save cloud progress:', error);
      setText('reader-status', '雲端閱讀位置保存失敗，請檢查連線後重新載入。');
    }
  }
  function queueLibraryProgress(patch) {
    if (!currentBookId) return;
    pendingProgressBookId = currentBookId;
    pendingProgress = Object.assign({}, pendingProgress || {}, patch);
    if (progressSaveTimer) clearTimeout(progressSaveTimer);
    progressSaveTimer = setTimeout(function () {
      flushLibraryProgress();
    }, 5000);
  }
  function updateLocation(detail) {
    if (!detail || restoring) return;
    var progressPatch = {};
    if (typeof detail.fraction === 'number' && isFinite(detail.fraction)) {
      var percent = Math.max(0, Math.min(100, Math.round(detail.fraction * 100)));
      setText('progress-percent', percent + '%');
      var section = detail.section;
      var label = section && section.total
        ? '章節 ' + (section.current + 1) + ' / ' + section.total
        : (typeof detail.index === 'number' ? '第 ' + (detail.index + 1) + ' 頁' : '閱讀位置已更新');
      setText('progress-detail', label);
      progressPatch.percent = percent;
      progressPatch.label = label;
    }
    if (detail.cfi) {
      progressPatch.cfi = detail.cfi;
      setText('reader-status', '閱讀位置正在保存至雲端 D1……');
    }
    if (typeof detail.index === 'number') progressPatch.index = detail.index;
    currentLocation = {
      cfi: detail.cfi || (view && view.isFixedLayout && Number.isInteger(detail.index)
        ? 'frame-fixed:' + detail.index : ''),
      index: Number.isInteger(detail.index) ? detail.index : null,
      percent: typeof detail.fraction === 'number' ? Math.round(detail.fraction * 100) : 0,
      label: (progressPatch.label || '閱讀位置') + (typeof detail.fraction === 'number'
        ? ' · ' + Math.round(detail.fraction * 100) + '%' : '')
    };
    syncBookmarkButton();
    if (Object.keys(progressPatch).length) queueLibraryProgress(progressPatch);
  }
  function makeLoader(zip) {
    return {
      loadText: function (name) {
        var entry = zip.file(name);
        return entry ? entry.async('string') : Promise.resolve(null);
      },
      loadBlob: function (name, type) {
        var entry = zip.file(name);
        if (!entry) return Promise.resolve(null);
        return entry.async('uint8array').then(function (bytes) {
          return new Blob([bytes], { type: type || 'application/octet-stream' });
        });
      },
      getSize: function (name) {
        var entry = zip.file(name);
        return entry && entry._data && typeof entry._data.uncompressedSize === 'number' ? entry._data.uncompressedSize : 0;
      }
    };
  }
  function loadAppearance(savedValue) {
    Object.assign(appearance, {
      fontScale: '1', lineHeight: '1.65', verticalMargin: '16', horizontalMargin: '7',
      fontFamily: 'original', fontWeight: 'original', paragraphSpacing: 'original', textAlign: 'original',
      readingMode: 'paginated', pageLayout: '2', comicReadingMode: 'paginated',
      comicPageLayout: '2', comicImageFit: 'fit-page', backdrop: 'wood', theme: 'paper'
    });
    var value = savedValue && typeof savedValue === 'object' ? savedValue : {};
    if (value && typeof value === 'object') {
      if (['0.9', '1', '1.1', '1.2', '1.3'].indexOf(String(value.fontScale)) !== -1) appearance.fontScale = String(value.fontScale);
      if (['1.45', '1.65', '1.85', '2'].indexOf(String(value.lineHeight)) !== -1) appearance.lineHeight = String(value.lineHeight);
      if (['8', '16', '24', '32', '40', '48', '64'].indexOf(String(value.verticalMargin)) !== -1) appearance.verticalMargin = String(value.verticalMargin);
      if (['4', '7', '10', '13', '16', '20'].indexOf(String(value.horizontalMargin)) !== -1) appearance.horizontalMargin = String(value.horizontalMargin);
      if (['original', 'serif', 'sans'].indexOf(String(value.fontFamily)) !== -1) appearance.fontFamily = String(value.fontFamily);
      if (['original', 'normal', 'medium'].indexOf(String(value.fontWeight)) !== -1) appearance.fontWeight = String(value.fontWeight);
      if (['original', 'compact', 'standard', 'loose'].indexOf(String(value.paragraphSpacing)) !== -1) appearance.paragraphSpacing = String(value.paragraphSpacing);
      if (['original', 'left', 'justify'].indexOf(String(value.textAlign)) !== -1) appearance.textAlign = String(value.textAlign);
      if (['paginated', 'scrolled'].indexOf(String(value.readingMode)) !== -1) appearance.readingMode = String(value.readingMode);
      if (['1', '2'].indexOf(String(value.pageLayout)) !== -1) appearance.pageLayout = String(value.pageLayout);
      if (['paginated', 'scrolled'].indexOf(String(value.comicReadingMode)) !== -1) appearance.comicReadingMode = String(value.comicReadingMode);
      if (['1', '2'].indexOf(String(value.comicPageLayout)) !== -1) appearance.comicPageLayout = String(value.comicPageLayout);
      if (['fit-page', 'fit-width'].indexOf(String(value.comicImageFit)) !== -1) appearance.comicImageFit = String(value.comicImageFit);
      if (['wood', 'linen', 'slate'].indexOf(String(value.backdrop)) !== -1) appearance.backdrop = String(value.backdrop);
      if (!value.verticalMargin && !value.horizontalMargin && ['8', '16', '24'].indexOf(String(value.margin)) !== -1) {
        appearance.verticalMargin = String(value.margin);
        appearance.horizontalMargin = ({ '8': '4', '16': '7', '24': '10' })[String(value.margin)];
      }
      if (Object.prototype.hasOwnProperty.call(THEMES, value.theme)) appearance.theme = value.theme;
    }
    el('font-scale').value = appearance.fontScale;
    el('line-height').value = appearance.lineHeight;
    el('vertical-margin').value = appearance.verticalMargin;
    el('horizontal-margin').value = appearance.horizontalMargin;
    el('font-family').value = appearance.fontFamily;
    el('font-weight').value = appearance.fontWeight;
    el('paragraph-spacing').value = appearance.paragraphSpacing;
    el('text-align').value = appearance.textAlign;
    el('reading-mode').value = appearance.readingMode;
    el('page-layout').value = appearance.pageLayout;
    el('comic-reading-mode').value = appearance.comicReadingMode;
    el('comic-page-layout').value = appearance.comicPageLayout;
    el('comic-image-fit').value = appearance.comicImageFit;
    updateThemeButtons();
    updateBackdropButtons();
    updateLayoutControlState();
  }
  function saveAppearance() {
    if (!currentBookId) {
      setText('appearance-status', '請從雲端書架開啟已索引的書籍。');
      return;
    }
    setText('appearance-status', '外觀設定正在保存至雲端 D1……');
    libraryStorePromise.then(function (store) {
      return store.updateBook(currentBookId, { appearance: Object.assign({}, appearance) });
    }).then(function () {
      setText('appearance-status', '外觀設定已保存至雲端，可在其他裝置繼續使用。');
    }).catch(function (error) {
      setText('appearance-status', '雲端保存失敗：' + (error && error.message ? error.message : String(error)));
      console.error(error);
    });
  }
  function updateThemeButtons() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-theme]'), function (button) {
      button.setAttribute('aria-pressed', button.getAttribute('data-theme') === appearance.theme ? 'true' : 'false');
    });
  }
  function updateBackdropButtons() {
    Array.prototype.forEach.call(document.querySelectorAll('[data-backdrop]'), function (button) {
      button.setAttribute('aria-pressed', button.getAttribute('data-backdrop') === appearance.backdrop ? 'true' : 'false');
    });
  }
  function documentStyleText() {
    var theme = THEMES[appearance.theme];
    var scale = Number(appearance.fontScale);
    var line = Number(appearance.lineHeight);
    var rules = [
      ':root { color-scheme: ' + theme.colorScheme + ' !important; font-size: ' + Math.round(scale * 100) + '% !important; background-color: ' + theme.background + ' !important; color: ' + theme.foreground + ' !important; }',
      'html, body { background-color: ' + theme.background + ' !important; color: ' + theme.foreground + ' !important; }',
      'body { line-height: ' + line + ' !important; }',
      'body p, body li, body blockquote, body dd, body dt { line-height: ' + line + ' !important; }',
      'body, body *:not(img):not(svg):not(video):not(canvas):not(iframe) { color: ' + theme.foreground + ' !important; }',
      'body *:not(img):not(svg):not(video):not(canvas):not(iframe) { background-color: transparent !important; }',
      'img, svg, video, canvas { max-width: 100%; }'
    ];

    var fontFamilies = {
      serif: 'ui-serif, "Songti TC", "Songti SC", "Noto Serif CJK TC", "PMingLiU", serif',
      sans: '-apple-system, BlinkMacSystemFont, "PingFang TC", "Noto Sans CJK TC", sans-serif'
    };
    if (fontFamilies[appearance.fontFamily]) {
      rules.push('body, body p, body h1, body h2, body h3, body h4, body h5, body h6, body li, body blockquote, body dd, body dt { font-family: ' + fontFamilies[appearance.fontFamily] + ' !important; }');
    }

    if (appearance.fontWeight !== 'original') {
      var weight = appearance.fontWeight === 'medium' ? '500' : '400';
      rules.push('body p, body li, body blockquote, body dd, body dt { font-weight: ' + weight + ' !important; }');
    }

    var paragraphSpacing = {
      compact: '0.4em',
      standard: '0.8em',
      loose: '1.2em'
    };
    if (paragraphSpacing[appearance.paragraphSpacing]) {
      rules.push('body p { margin-block-end: ' + paragraphSpacing[appearance.paragraphSpacing] + ' !important; }');
    }

    if (appearance.textAlign !== 'original') {
      var alignment = appearance.textAlign === 'justify' ? 'justify' : 'left';
      rules.push('body p, body li, body blockquote, body dd, body dt { text-align: ' + alignment + ' !important; }');
    }

    return rules.join('\n');
  }
  function applyDocumentAppearance(doc) {
    if (!doc || !doc.documentElement || !doc.head) return;
    var style = doc.getElementById('frame-reader-user-appearance');
    if (!style) {
      style = doc.createElement('style');
      style.id = 'frame-reader-user-appearance';
      doc.head.appendChild(style);
    }
    style.textContent = documentStyleText();
  }
  function updateReadingModeNote() {
    var note = el('reading-mode-note');
    if (!note) return;
    if (view && view.isFixedLayout) {
      if (appearance.comicReadingMode === 'scrolled') {
        note.textContent = '直式長卷：圖片依螢幕寬度垂直串接，接近可視區時才載入頁面。';
      } else if (appearance.comicPageLayout === '2') {
        note.textContent = '雙頁優先：桌面與平板橫向呈現跨頁，手機直向自動切回單頁。';
      } else {
        note.textContent = '單頁翻頁：所有裝置一次顯示一頁，適合逐頁閱讀。';
      }
    } else if (!view) {
      note.textContent = '圖像閱讀設定會在載入 CBZ 或固定版面 EPUB 後啟用。';
    } else if (appearance.readingMode === 'scrolled') {
      note.textContent = '連續捲動模式；頁面欄數與上下留白會在切回分頁時恢復。';
    } else if (appearance.pageLayout === '2') {
      note.textContent = '雙頁優先：橫向寬螢幕呈現雙頁，直向畫面自動切回單頁。';
    } else {
      note.textContent = '單頁翻頁模式，適合窄螢幕或逐頁專注閱讀。';
    }
  }
  function updateLayoutControlState() {
    var fixed = !!(view && view.isFixedLayout);
    el('reading-mode').disabled = fixed;
    el('page-layout').disabled = fixed;
    el('comic-reading-mode').disabled = !fixed;
    el('comic-page-layout').disabled = !fixed;
    el('comic-image-fit').disabled = !fixed || appearance.comicReadingMode === 'scrolled';
    updateReadingModeNote();
  }
  function applyAppearance() {
    var theme = THEMES[appearance.theme];
    var viewport = el('reader-viewport');
    viewport.dataset.theme = appearance.theme;
    viewport.dataset.backdrop = appearance.backdrop;
    viewport.dataset.comicFlow = appearance.comicReadingMode;
    viewport.style.backgroundColor = theme.background;
    viewport.style.color = theme.foreground;

    if (view) {
      view.style.setProperty('--frame-reader-page-background', theme.background);
      view.style.setProperty('--frame-reader-page-foreground', theme.foreground);
    }

    if (view && view.renderer && !view.isFixedLayout) {
      // Keep the two axes independent. Foliate expects a CSS length for
      // vertical margin and a percentage for horizontal page gap.
      view.renderer.setAttribute('margin', appearance.verticalMargin + 'px');
      view.renderer.setAttribute('gap', appearance.horizontalMargin + '%');
      if (appearance.readingMode === 'scrolled') {
        view.renderer.setAttribute('flow', 'scrolled');
      } else {
        view.renderer.removeAttribute('flow');
      }
      view.renderer.setAttribute('max-column-count', appearance.pageLayout);
      try {
        view.renderer.getContents().forEach(function (item) {
          applyDocumentAppearance(item.doc);
        });
      } catch (e) {}
      if (typeof view.renderer.render === 'function') {
        view.renderer.render();
      }
    } else if (view && view.renderer && view.isFixedLayout) {
      if (typeof view.renderer.setPageLayout === 'function') {
        Promise.resolve(view.renderer.setPageLayout(appearance.comicPageLayout)).catch(console.error);
      }
      if (typeof view.renderer.setFlow === 'function') {
        view.renderer.setFlow(appearance.comicReadingMode);
      }
      view.renderer.setAttribute('zoom', appearance.comicImageFit);
    }
    updateThemeButtons();
    updateBackdropButtons();
    updateReadingModeNote();
  }
  function setAppearance(name, value) {
    appearance[name] = String(value);
    saveAppearance();
    applyAppearance();
    updateLayoutControlState();
  }
  function normalizedZipPath(base, href) {
    var raw = String(href || '').split('#')[0].split('?')[0].replace(/\\/g, '/');
    try { raw = decodeURIComponent(raw); } catch (error) {}
    var parts = (String(base || '') + raw).split('/');
    var clean = [];
    parts.forEach(function (part) {
      if (!part || part === '.') return;
      if (part === '..') clean.pop();
      else clean.push(part);
    });
    return clean.join('/');
  }

  async function makeMacCoverThumbnail(blob) {
    if (!(blob instanceof Blob) || !blob.size || blob.size > 15 * 1024 * 1024) return null;
    var bitmap;
    try {
      bitmap = await createImageBitmap(blob);
      var width = bitmap.width || bitmap.displayWidth;
      var height = bitmap.height || bitmap.displayHeight;
      if (!width || !height || width * height > 150000000) return null;
      var scale = Math.min(1, 480 / Math.max(width, height));
      var canvas = document.createElement('canvas');
      canvas.width = Math.max(1, Math.round(width * scale));
      canvas.height = Math.max(1, Math.round(height * scale));
      var context = canvas.getContext('2d', { alpha: false });
      if (!context) return null;
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      var output = await new Promise(function (resolve) { canvas.toBlob(resolve, 'image/webp', 0.82); });
      if (!output || !output.size || output.size > 2 * 1024 * 1024) {
        output = await new Promise(function (resolve) { canvas.toBlob(resolve, 'image/jpeg', 0.82); });
      }
      return output && output.size && output.size <= 2 * 1024 * 1024 ? output : null;
    } catch (error) {
      console.info('[FRAME Ebook] EPUB 封面縮圖略過：', error);
      return null;
    } finally {
      try { if (bitmap) bitmap.close(); } catch (error) {}
    }
  }

  async function saveMacEpubCover(zip, bookId, initialRecord) {
    if (!window.FRAME_LOCAL_APP || !bookId || (initialRecord && initialRecord.coverBlob)) return;
    try {
      var containerEntry = zip.file('META-INF/container.xml');
      if (!containerEntry) return;
      var containerText = await containerEntry.async('string');
      var containerXml = new DOMParser().parseFromString(containerText, 'application/xml');
      var rootfile = containerXml.getElementsByTagName('rootfile')[0];
      var opfPath = String(rootfile && rootfile.getAttribute('full-path') || '');
      if (!opfPath || containerXml.getElementsByTagName('parsererror').length) return;
      var opfEntry = zip.file(opfPath);
      if (!opfEntry) return;
      var opfText = await opfEntry.async('string');
      var opfXml = new DOMParser().parseFromString(opfText, 'application/xml');
      if (opfXml.getElementsByTagName('parsererror').length) return;
      var elements = Array.from(opfXml.getElementsByTagName('*'));
      var manifest = elements.filter(function (node) { return node.localName === 'item'; });
      var metas = elements.filter(function (node) { return node.localName === 'meta'; });
      var coverId = '';
      metas.some(function (meta) {
        var name = String(meta.getAttribute('name') || '').toLowerCase();
        var property = String(meta.getAttribute('property') || '').toLowerCase();
        if (name === 'cover' || property === 'cover-image') {
          coverId = String(meta.getAttribute('content') || '').trim();
          return !!coverId;
        }
        return false;
      });
      var coverItem = coverId ? manifest.find(function (item) { return item.getAttribute('id') === coverId; }) : null;
      if (!coverItem) coverItem = manifest.find(function (item) {
        return String(item.getAttribute('properties') || '').split(/\s+/).includes('cover-image');
      });
      if (!coverItem) coverItem = manifest.find(function (item) {
        return /^image\//i.test(item.getAttribute('media-type') || '') &&
          /cover|front/i.test(item.getAttribute('href') || '');
      });
      var base = opfPath.includes('/') ? opfPath.slice(0, opfPath.lastIndexOf('/') + 1) : '';
      var coverPath = coverItem ? normalizedZipPath(base, coverItem.getAttribute('href')) : '';
      var coverEntry = coverPath ? zip.file(coverPath) : null;
      if (!coverEntry) {
        var names = Object.keys(zip.files || {}).filter(function (name) {
          return /\.(?:jpe?g|png|webp|gif|bmp)$/i.test(name) && !zip.files[name].dir;
        });
        var chosen = names.find(function (name) { return /(^|[/_-])(cover|front)([/_.-]|$)/i.test(name); }) || names[0];
        if (chosen) coverEntry = zip.file(chosen);
      }
      if (!coverEntry) return;
      var coverBlob = await coverEntry.async('blob');
      var thumbnail = await makeMacCoverThumbnail(coverBlob);
      if (!thumbnail) return;
      var store = await libraryStorePromise;
      await store.saveLocalBookCover(bookId, thumbnail);
      console.info('[FRAME Ebook] 已保存 EPUB 封面縮圖至本機書架：' + thumbnail.size + ' bytes');
    } catch (error) {
      console.info('[FRAME Ebook] EPUB 封面擷取失敗：', error);
    }
  }

  async function openEpub(source, name, bookId, initialRecord) {
    await flushLibraryProgress();
    await readingTrackerPromise.then(function (tracker) { return tracker.stop(); });
    currentLocation = null;
    activeAnnotations = [];
    closeFootnotePopover();
    renderAnnotationList();
    renderBookmarkList();
    syncBookmarkButton();
    if (!window.JSZip) throw new Error('JSZip 尚未載入，請重新整理頁面。');
    setText('reader-status', '正在讀取書籍封裝與目錄……');
    setText('engine-status', '正在解析書籍');
    el('prev-page').disabled = true;
    el('next-page').disabled = true;
    el('toc-select').disabled = true;
    var isCbz = /\.cbz$/i.test(String(source && source.name || name || ''));
    var parsedBook;
    if (isCbz) {
      await import('/vendor/foliate-js/view.js');
    } else {
      var archiveData = source && source.frameMemoryBytes instanceof Uint8Array
        ? source.frameMemoryBytes
        : source;
      var zip = await window.JSZip.loadAsync(archiveData, { checkCRC32: false });
      var epubModule = await import('/vendor/foliate-js/epub.js');
      parsedBook = await new epubModule.EPUB(makeLoader(zip)).init();
    }
    if (view) { try { view.close(); } catch (e) {} }
    var viewport = el('reader-viewport');
    viewport.innerHTML = '';
    view = document.createElement('foliate-view');
    view.style.display = 'block';
    view.style.width = '100%';
    view.style.height = '100%';
    view.addEventListener('load', function (event) {
      var detail = event.detail || {};
      bindPageTapNavigation(detail.doc, detail.index);
      if (!view.isFixedLayout) applyDocumentAppearance(detail.doc);
    });
    view.addEventListener('relocate', function (event) {
      updateLocation(event.detail || {});
    });
    viewport.appendChild(view);
    await view.open(isCbz ? source : parsedBook);
    parsedBook = view.book;
    if (!isCbz && window.FRAME_LOCAL_APP) {
      void saveMacEpubCover(zip, bookId, initialRecord);
    }

    var overlayModule = await overlayerModulePromise;
    Overlayer = overlayModule.Overlayer;
    view.addEventListener('draw-annotation', function (event) {
      var detail = event.detail || {};
      var annotation = detail.annotation || {};
      if (annotation.type === 'highlight' && annotation.color === 'underline') {
        var writingMode = 'horizontal-tb';
        try { writingMode = detail.doc.defaultView.getComputedStyle(detail.doc.documentElement).writingMode || writingMode; } catch (error) {}
        detail.draw(Overlayer.underline, { color: annotationColor('underline'), width: 2.2, writingMode: writingMode });
      } else if (annotation.type === 'highlight') {
        detail.draw(Overlayer.highlight, { color: annotationColor(annotation.color) });
      } else if (annotation.type === 'note') {
        var writingMode = 'horizontal-tb';
        try { writingMode = detail.doc.defaultView.getComputedStyle(detail.doc.documentElement).writingMode || writingMode; } catch (error) {}
        detail.draw(Overlayer.squiggly, {
          color: '#9873D6',
          width: 1.5,
          writingMode: writingMode
        });
      }
    });
    view.addEventListener('load', function (event) {
      var detail = event.detail || {};
      bindSelectionEvents(detail.doc, detail.index);
    });
    view.addEventListener('create-overlay', function (event) {
      var index = Number(event.detail && event.detail.index);
      window.setTimeout(function () {
        if (!view || !Array.isArray(activeAnnotations)) return;
        activeAnnotations.forEach(function (annotation) {
          if (annotation.type !== 'bookmark' && Number(annotation.sectionIndex) === index) drawAnnotation(annotation);
        });
      }, 0);
    });
    view.addEventListener('show-annotation', function (event) {
      var value = event.detail && event.detail.value;
      var annotation = activeAnnotations.find(function (item) { return item.cfi === value; });
      if (!annotation) return;
      if (annotation.type === 'note') openNoteComposer(annotation);
      else setText('reader-status', (annotation.color === 'underline' ? '下劃線原文：' : '高亮原文：') + (annotation.quote || '已定位到標記文字'));
    });

    var metadata = parsedBook.metadata || {};
    currentBookId = String(bookId || '');
    if (!/^cloud:[a-f0-9]{64}$/.test(currentBookId)) {
      throw new Error('閱讀室只接受從 Alist／OpenList 掃描索引導入的雲端書籍。');
    }
    var libraryStore = await libraryStorePromise;
    var libraryRecord = initialRecord || await libraryStore.getBook(currentBookId);
    if (!libraryRecord) throw new Error('無法讀取這本書的雲端索引與閱讀資料，請返回書架重新開啟。');
    loadAppearance(libraryRecord.appearance || {});
    var annotationLoadWarning = '';
    try {
      activeAnnotations = await libraryStore.listAnnotations(currentBookId);
      activeAnnotations.forEach(function (annotation) {
        if (annotation.type === 'bookmark' && /^frame-fixed:\d+$/.test(annotation.cfi)) {
          annotation.sectionIndex = Number(annotation.cfi.split(':')[1]);
        } else {
          var navigation = view.resolveNavigation(annotation.cfi);
          annotation.sectionIndex = navigation && navigation.index;
        }
      });
    } catch (annotationError) {
      // A temporary annotation API/D1 issue must never prevent the book itself
      // from opening. The user can retry from the annotations panel afterward.
      activeAnnotations = [];
      annotationLoadWarning = '（標註暫時無法讀取，可在「筆記與標註」中重新整理）';
      console.warn('FRAME Reader could not restore annotations:', annotationError);
    }
    renderAnnotationList();
    renderBookmarkList();
    var savedProgress = libraryRecord.progress || {};
    restoreCfi = !view.isFixedLayout && savedProgress.cfi ? savedProgress.cfi : null;
    restorePageIndex = view.isFixedLayout && Number.isInteger(savedProgress.index) && savedProgress.index >= 0
      ? savedProgress.index : null;
    restoring = !!restoreCfi || restorePageIndex !== null;
    setText('book-title', libraryRecord.manualTitle && libraryRecord.title
      ? libraryRecord.title : (titleText(metadata.title) || libraryRecord.title || name));
    setText('book-author', libraryRecord.manualAuthor && libraryRecord.author
      ? libraryRecord.author : (titleText(metadata.author) || libraryRecord.author || (isCbz ? '漫畫圖像檔' : name)));
    populateTOC(parsedBook.toc || []);
    var metadataPatch = { lastOpenedAt: Date.now() };
    if (!libraryRecord.manualTitle && titleText(metadata.title)) metadataPatch.title = titleText(metadata.title);
    if (!libraryRecord.manualAuthor && titleText(metadata.author)) metadataPatch.author = titleText(metadata.author);
    if (metadata.language) metadataPatch.language = String(metadata.language);
    if (!Number(libraryRecord.pageCount) && parsedBook.sections) metadataPatch.pageCount = parsedBook.sections.length;
    await libraryStore.updateBook(currentBookId, metadataPatch);

    if (view.isFixedLayout) {
      if (typeof view.renderer.setPageLayout === 'function') await view.renderer.setPageLayout(appearance.comicPageLayout);
      view.renderer.setAttribute('zoom', appearance.comicImageFit);
      if (typeof view.renderer.setFlow === 'function') view.renderer.setFlow(appearance.comicReadingMode);
    }

    var locationMessage = (isCbz
      ? 'CBZ 漫畫已載入。閱讀位置會自動保存至雲端。'
      : 'EPUB 已載入。閱讀位置會自動保存至雲端。') +
      (source.frameDeliveryMode === 'redirect' ? ' 已使用瀏覽器 302 直連。' :
        source.frameDeliveryMode === 'stream-fallback' ? ' 漫畫來源不支援瀏覽器跨來源讀取，已自動回退串流。' : '');
    try {
      if (restoreCfi) {
        await view.init({ lastLocation: restoreCfi, showTextStart: true });
        locationMessage = '已從雲端恢復上次的閱讀位置。';
      } else {
        await view.init({ showTextStart: true });
        if (restorePageIndex !== null && view.isFixedLayout && parsedBook.sections?.length) {
          await view.goTo(Math.min(restorePageIndex, parsedBook.sections.length - 1));
          locationMessage = '已從雲端恢復漫畫上次的閱讀頁面。';
        }
      }
    } catch (navigationError) {
      if (restoreCfi) {
        try {
          await view.goToTextStart();
          locationMessage = '舊閱讀位置無法恢復，已從正文開頭開始。';
        } catch (fallbackError) {
          throw fallbackError;
        }
      } else {
        throw navigationError;
      }
    }
    restoring = false;
    if (view && view.lastLocation) updateLocation(view.lastLocation);
    restoreCfi = null;
    restorePageIndex = null;
    updateLayoutControlState();
    applyAppearance();
    syncBookmarkButton();
    el('prev-page').disabled = false;
    el('next-page').disabled = false;
    setText('reader-status', locationMessage + annotationLoadWarning);
    setText('engine-status', isCbz
      ? 'CBZ 漫畫閱讀引擎已就緒'
      : (view.isFixedLayout ? '固定版面 EPUB 已載入' : 'EPUB 閱讀引擎已就緒'));
    var trackerTitle = libraryRecord.title || titleText(metadata.title) || name || '未命名書籍';
    await readingTrackerPromise.then(function (tracker) {
      return tracker.start({ id: currentBookId, title: trackerTitle, format: isCbz ? 'CBZ' : 'EPUB' });
    });
  }
  function featureSummary() {
    var features = [
      ['Custom Elements', !!window.customElements],
      ['Shadow DOM', !!(window.Element && Element.prototype.attachShadow)],
      ['ResizeObserver', !!window.ResizeObserver],
      ['matchMedia', typeof window.matchMedia === 'function'],
      ['Blob.arrayBuffer', !!(window.Blob && Blob.prototype.arrayBuffer)],
      ['JSZip', !!window.JSZip]
    ];
    var missing = features.filter(function (item) { return !item[1]; }).map(function (item) { return item[0]; });
    return missing.length ? '相容性提示：未檢出 ' + missing.join('、') : '閱讀引擎基礎 API 已檢出';
  }

  window.addEventListener('frame-reader-reading-time', function (event) {
    var detail = event.detail || {};
    var seconds = Math.max(0, Number(detail.seconds) || 0);
    var hours = Math.floor(seconds / 3600);
    var minutes = Math.floor((seconds % 3600) / 60);
    var remainder = seconds % 60;
    var label = hours
      ? String(hours).padStart(2, '0') + ':' + String(minutes).padStart(2, '0') + ':' + String(remainder).padStart(2, '0')
      : String(minutes).padStart(2, '0') + ':' + String(remainder).padStart(2, '0');
    setText('reading-live-duration', label);
    setText('reading-live-label', detail.stopped ? '本次閱讀已暫停' : '正在記錄本次閱讀');
  });

  bindReaderRoomControls();
  loadAppearance({});
  bindAnnotationControls();
  window.addEventListener('frame-reader-cloud-save-error', function (event) {
    var message = event && event.detail && event.detail.message;
    setText('reader-status', '雲端閱讀統計保存失敗：' + String(message || '請檢查網路連線。'));
  });
  el('font-scale').addEventListener('change', function (event) { setAppearance('fontScale', event.target.value); });
  el('line-height').addEventListener('change', function (event) { setAppearance('lineHeight', event.target.value); });
  el('vertical-margin').addEventListener('change', function (event) { setAppearance('verticalMargin', event.target.value); });
  el('horizontal-margin').addEventListener('change', function (event) { setAppearance('horizontalMargin', event.target.value); });
  el('font-family').addEventListener('change', function (event) { setAppearance('fontFamily', event.target.value); });
  el('font-weight').addEventListener('change', function (event) { setAppearance('fontWeight', event.target.value); });
  el('paragraph-spacing').addEventListener('change', function (event) { setAppearance('paragraphSpacing', event.target.value); });
  el('text-align').addEventListener('change', function (event) { setAppearance('textAlign', event.target.value); });
  el('reading-mode').addEventListener('change', function (event) { setAppearance('readingMode', event.target.value); });
  el('page-layout').addEventListener('change', function (event) { setAppearance('pageLayout', event.target.value); });
  el('comic-reading-mode').addEventListener('change', function (event) { setAppearance('comicReadingMode', event.target.value); });
  el('comic-page-layout').addEventListener('change', function (event) { setAppearance('comicPageLayout', event.target.value); });
  el('comic-image-fit').addEventListener('change', function (event) { setAppearance('comicImageFit', event.target.value); });
  Array.prototype.forEach.call(document.querySelectorAll('[data-theme]'), function (button) {
    button.addEventListener('click', function () { setAppearance('theme', button.getAttribute('data-theme')); });
  });
  Array.prototype.forEach.call(document.querySelectorAll('[data-backdrop]'), function (button) {
    button.addEventListener('click', function () { setAppearance('backdrop', button.getAttribute('data-backdrop')); });
  });
  el('prev-page').addEventListener('click', function () {
    if (view) view.prev().catch(function (error) { console.error(error); });
  });
  el('next-page').addEventListener('click', function () {
    if (view) view.next().catch(function (error) { console.error(error); });
  });
  var readerViewport = el('reader-viewport');
  if (readerViewport) {
    readerViewport.addEventListener('click', function (event) {
      if (event.target !== readerViewport && event.target !== view) return;
      handleReaderWindowTap(event, null);
    });
  }
  el('toc-select').addEventListener('change', function (event) {
    if (view && event.target.value) view.goTo(event.target.value).catch(function (error) { console.error(error); });
  });

  var immersiveExitTimer = 0;
  function updateReaderFullscreenButton() {
    var workspace = el('reading-workspace');
    var button = el('reader-fullscreen');
    if (!workspace || !button) return;
    var active = document.fullscreenElement === workspace ||
      document.webkitFullscreenElement === workspace;
    if (!active) {
      workspace.classList.remove('reader-immersive-mode', 'reader-immersive-exiting');
      if (immersiveExitTimer) {
        window.clearTimeout(immersiveExitTimer);
        immersiveExitTimer = 0;
      }
    }
    button.textContent = active ? '↙ 退出全螢幕' : '⛶ 全螢幕';
    button.setAttribute('aria-pressed', active ? 'true' : 'false');
    button.title = active ? '退出全螢幕閱讀' : '進入全螢幕閱讀';
  }
  function toggleImmersiveFullscreen() {
    var workspace = el('reading-workspace');
    if (!workspace || !isReaderFullscreen()) return;

    if (immersiveExitTimer) {
      window.clearTimeout(immersiveExitTimer);
      immersiveExitTimer = 0;
    }
    var wasImmersive = workspace.classList.contains('reader-immersive-mode');
    if (wasImmersive) {
      workspace.classList.remove('reader-immersive-mode');
      workspace.classList.add('reader-immersive-exiting');
      immersiveExitTimer = window.setTimeout(function () {
        workspace.classList.remove('reader-immersive-exiting');
        immersiveExitTimer = 0;
      }, 420);
    } else {
      workspace.classList.remove('reader-immersive-exiting');
      workspace.classList.add('reader-immersive-mode');
    }
    // Foliate's paginator and fixed-layout renderer already observe their
    // container size. Avoid forcing a second render while the layout changes.
  }
  async function toggleReaderFullscreen() {
    var workspace = el('reading-workspace');
    if (!workspace) return;
    var active = document.fullscreenElement || document.webkitFullscreenElement;
    try {
      if (active) {
        if (document.exitFullscreen) await document.exitFullscreen();
        else if (document.webkitExitFullscreen) document.webkitExitFullscreen();
      } else {
        var request = workspace.requestFullscreen || workspace.webkitRequestFullscreen;
        if (!request) {
          setText('reader-status', '目前瀏覽器不支援頁面全螢幕，請使用瀏覽器的全螢幕功能。');
          return;
        }
        var result = request.call(workspace);
        if (result && typeof result.then === 'function') await result;
      }
    } catch (error) {
      setText('reader-status', '無法切換全螢幕：' + (error && error.message ? error.message : String(error)));
      console.warn('FRAME Reader fullscreen request failed:', error);
    }
    updateReaderFullscreenButton();
  }
  el('reader-fullscreen').addEventListener('click', toggleReaderFullscreen);
  document.addEventListener('fullscreenchange', updateReaderFullscreenButton);
  document.addEventListener('webkitfullscreenchange', updateReaderFullscreenButton);
  updateReaderFullscreenButton();


  window.addEventListener('pagehide', function () {
    flushLibraryProgress();
    readingTrackerPromise.then(function (tracker) { return tracker.stop(); });
  });
  document.addEventListener('visibilitychange', function () {
    if (document.hidden) flushLibraryProgress();
  });
  async function ensureLocalReaderLogin() {
    var local = await import('/assets/local-openlist.js?v=20261116-local-r2');
    if (local.isLocalOpenListReady()) return;
    var panel = el('local-reader-login');
    var baseInput = el('reader-local-base-url');
    var userInput = el('reader-local-username');
    var passwordInput = el('reader-local-password');
    var button = el('reader-local-login');
    var status = el('reader-local-login-status');
    baseInput.value = local.getSavedLocalOpenListBaseUrl();
    panel.hidden = false;
    status.textContent = '請登入本地 OpenList。登入 Token 只會保留在目前閱讀頁面的記憶體。';
    await new Promise(function (resolve) {
      button.onclick = async function () {
        button.disabled = true;
        status.textContent = '正在登入本地 OpenList……';
        try {
          await local.loginLocalOpenList({
            baseUrl: baseInput.value,
            username: userInput.value,
            password: passwordInput.value
          });
          passwordInput.value = '';
          status.textContent = '登入成功，正在載入書籍……';
          button.onclick = null;
          panel.hidden = true;
          resolve();
        } catch (error) {
          status.textContent = '登入失敗：' + (error && error.message ? error.message : String(error));
        } finally {
          button.disabled = false;
        }
      };
    });
  }

  setText('engine-status', featureSummary());
  import('/vendor/foliate-js/view.js').then(async function () {
    setText('engine-status', featureSummary() + ' · Foliate ready');
    var params = new URLSearchParams(window.location.search);
    var bookId = params.get('book');
    if (!bookId) throw new Error('請回到我的書架，從已掃描索引的雲端書籍開啟閱讀室。');
    var descriptor = {
      id: bookId,
      provider: params.get('provider'),
      library: params.get('library'),
      rootPath: params.get('root_path'),
      path: params.get('path'),
      profileId: params.get('profile_id'),
      sourceId: params.get('source_id')
    };
    var store = await libraryStorePromise;
    var record = await store.getBook(descriptor);
    if (!record) throw new Error('找不到這本書的雲端索引與閱讀資料。請確認 Alist／OpenList 索引仍存在。');
    if (record.cloudSource && record.cloudSource.provider === 'local') {
      setText('reader-status', '本地端口需在閱讀室重新登入一次。');
      await ensureLocalReaderLogin();
    }
    setText('reader-status', record.cloudSource && record.cloudSource.provider === 'webdav'
      ? '正在透過 Mac 原生 WebDAV 通道讀取書檔……'
      : (record.cloudSource && record.cloudSource.provider === 'local'
        ? '正在透過本地 OpenList 讀取書檔……'
        : '正在透過伺服器端 Alist／OpenList 讀取書檔……'));
    setText('engine-status', '正在載入雲端書籍');
    var sourceModule = await cloudBookSourcePromise;
    var source = await sourceModule.fetchCloudBookFile(record);
    await openEpub(source, record.fileName, record.id, record);
  }).catch(function (error) {
    setText('engine-status', '書籍或閱讀引擎載入失敗');
    setText('reader-status', '錯誤：' + (error && error.message ? error.message : String(error)));
    console.error(error);
  });
}());
