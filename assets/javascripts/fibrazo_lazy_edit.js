(function () {
  // Lazy-load del #update: menos HTML en show.
  // Debe: Editar/Responder, pegar capturas en notas, sin romper handlers nativos de Redmine.

  function runScripts(container) {
    var scripts = Array.prototype.slice.call(container.querySelectorAll('script'));
    scripts.forEach(function (old) {
      // No recargar scripts externos ya presentes (wizard/AI/etc. se rompen al reiniciar).
      if (old.src) {
        var already = Array.prototype.some.call(document.scripts, function (s) {
          return s.src && s.src === old.src;
        });
        if (already) {
          if (old.parentNode) old.parentNode.removeChild(old);
          return;
        }
      }
      try {
        var s = document.createElement('script');
        if (old.src) {
          s.src = old.src;
          s.async = false;
        } else {
          s.text = old.textContent;
        }
        if (old.parentNode) old.parentNode.replaceChild(s, old);
      } catch (err) {
        if (window.console && console.warn) {
          console.warn('fibrazo_lazy_edit: script error', err);
        }
      }
    });
  }

  function clipboardImageFiles(clipboardData) {
    var out = [];
    if (!clipboardData) return out;

    var files = clipboardData.files || [];
    for (var i = 0; i < files.length; i++) {
      if (files[i] && String(files[i].type || '').indexOf('image') !== -1) {
        out.push(files[i]);
      }
    }
    if (out.length) return out;

    // Snipping Tool / PrintScreen: a veces solo en items[]
    var items = clipboardData.items || [];
    for (var j = 0; j < items.length; j++) {
      var item = items[j];
      if (!item || String(item.type || '').indexOf('image') === -1) continue;
      if (typeof item.getAsFile !== 'function') continue;
      var file = item.getAsFile();
      if (file) out.push(file);
    }
    return out;
  }

  function clipboardHasTextPlain(clipboardData) {
    try {
      var types = clipboardData.types || [];
      for (var i = 0; i < types.length; i++) {
        if (String(types[i]).toLowerCase() === 'text/plain') return true;
      }
    } catch (e) {}
    return false;
  }

  function clipboardFilename(file) {
    var date = new Date();
    var ext = (file && file.name && file.name.split('.').pop()) || 'png';
    return 'clipboard-'
      + date.getFullYear()
      + ('0' + (date.getMonth() + 1)).slice(-2)
      + ('0' + date.getDate()).slice(-2)
      + ('0' + date.getHours()).slice(-2)
      + ('0' + date.getMinutes()).slice(-2)
      + '-' + (typeof randomKey === 'function' ? randomKey(5).toLocaleLowerCase() : String(Math.random()).slice(2, 7))
      + '.' + ext;
  }

  function isNotesPasteTarget(el) {
    if (!el || !el.closest) return false;
    if (!(el.classList && el.classList.contains('wiki-edit')) && el.id !== 'issue_notes') return false;
    return !!el.closest('#update, #issue-form, form.edit_issue, form#issue-form');
  }

  function uploadClipboardImages(target, clipboardData) {
    if (typeof window.addFile !== 'function') return false;
    if (!isNotesPasteTarget(target)) return false;

    var images = clipboardImageFiles(clipboardData);
    if (!images.length) return false;

    var form = target.closest('form') || document.getElementById('issue-form');
    if (!form) return false;
    // Prefer visible filedrop inside attachments box; lazy form may re-render.
    var inputEl = form.querySelector('input.filedrop[type="file"], input:file.filedrop');
    if (!inputEl) {
      inputEl = document.querySelector('#update input.filedrop[type="file"], #issue-form input.filedrop[type="file"]');
    }
    if (!inputEl) return false;

    if (typeof handleFileDropEvent !== 'undefined') {
      handleFileDropEvent.target = target;
    }

    var $input = (typeof window.jQuery !== 'undefined') ? window.jQuery(inputEl) : null;
    var uploaded = 0;
    for (var i = 0; i < images.length; i++) {
      var file = images[i];
      var filename = clipboardFilename(file);
      var wrapped = new File([file], filename, { type: file.type || 'image/png' });
      try {
        if ($input && $input.length) {
          addFile($input, wrapped, true);
        } else {
          addFile(inputEl, wrapped, true);
        }
        uploaded += 1;
      } catch (err) {
        if (window.console && console.warn) {
          console.warn('fibrazo_lazy_edit: addFile failed', err);
        }
      }
    }
    return uploaded > 0;
  }

  function patchCopyImageFromClipboard() {
    if (typeof window.copyImageFromClipboard !== 'function') return;
    if (window.copyImageFromClipboard.__fibrazoPatched) return;

    var orig = window.copyImageFromClipboard;
    window.copyImageFromClipboard = function (e) {
      var clipboardData = e.clipboardData || (e.originalEvent && e.originalEvent.clipboardData);
      // Solo interceptar el caso que Redmine aborta (imagen + text/plain, Snipping Tool).
      if (clipboardData && clipboardHasTextPlain(clipboardData) && uploadClipboardImages(e.target, clipboardData)) {
        e.preventDefault();
        if (typeof e.stopImmediatePropagation === 'function') e.stopImmediatePropagation();
        if (typeof e.stopPropagation === 'function') e.stopPropagation();
        return;
      }
      // Fallback al handler nativo de Redmine (pegar imagen pura, etc.).
      return orig.apply(this, arguments);
    };
    window.copyImageFromClipboard.__fibrazoPatched = true;
    window.copyImageFromClipboard.__fibrazoOrig = orig;
  }

  function rebindAttachmentPaste() {
    patchCopyImageFromClipboard();

    // NO quitar filedroplistner / off(paste): eso deshabilita el pegado nativo
    // si setupFileDrop no reengancha a tiempo tras el lazy-load.
    // Solo re-ejecutar setupFileDrop de forma idempotente.
    if (typeof window.setupFileDrop === 'function') {
      try { window.setupFileDrop(); } catch (e2) {}
    }
  }

  function installDocumentPasteCapture() {
    if (window.__fibrazoDocumentPasteCapture) return;
    window.__fibrazoDocumentPasteCapture = true;
    // Capture solo para Snipping Tool (text/plain+image). Si falla, deja pasar al nativo.
    document.addEventListener('paste', function (e) {
      if (!e.clipboardData) return;
      if (!isNotesPasteTarget(e.target)) return;
      if (!clipboardHasTextPlain(e.clipboardData)) return;
      if (uploadClipboardImages(e.target, e.clipboardData)) {
        e.preventDefault();
        e.stopImmediatePropagation();
        e.stopPropagation();
      }
    }, true);
  }

  function afterLazyReady(done) {
    rebindAttachmentPaste();
    window.setTimeout(rebindAttachmentPaste, 50);
    window.setTimeout(rebindAttachmentPaste, 250);
    if (typeof window.jQuery !== 'undefined') {
      try { window.jQuery(document).trigger('ajax:complete'); } catch (e) {}
    }
    try {
      document.dispatchEvent(new Event('ajax:complete', { bubbles: true }));
    } catch (eNative) {}
    try {
      document.dispatchEvent(new CustomEvent('fibrazo:lazy-edit-ready'));
    } catch (e2) {}
    if (done) done(true);
  }

  function loadLazyEdit(done) {
    var el = document.getElementById('update');
    if (!el) {
      if (done) done(false);
      return;
    }
    if (el.getAttribute('data-lazy-loaded') === '1' || el.querySelector('#issue-form')) {
      afterLazyReady(done);
      return;
    }
    var url = el.getAttribute('data-lazy-edit-url');
    if (!url) {
      if (done) done(false);
      return;
    }
    if (window.__fibrazoLazyEditLoading) return;
    window.__fibrazoLazyEditLoading = true;
    var loading = document.getElementById('fibrazo-lazy-edit-loading');
    if (loading) loading.style.display = 'block';
    el.style.display = 'block';

    var xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
    xhr.setRequestHeader('Accept', 'text/html');
    xhr.onload = function () {
      window.__fibrazoLazyEditLoading = false;
      if (loading) loading.style.display = 'none';
      if (xhr.status >= 200 && xhr.status < 300) {
        var slot = document.getElementById('fibrazo-lazy-edit-slot') || el;
        slot.innerHTML = xhr.responseText;
        runScripts(slot);
        el.setAttribute('data-lazy-loaded', '1');
        afterLazyReady(done);
      } else {
        var failSlot = document.getElementById('fibrazo-lazy-edit-slot') || el;
        failSlot.innerHTML = '<p class="nodata">No se pudo cargar el formulario (' + xhr.status + ').</p>';
        if (done) done(false);
      }
    };
    xhr.onerror = function () {
      window.__fibrazoLazyEditLoading = false;
      if (loading) loading.style.display = 'none';
      if (done) done(false);
    };
    xhr.send();
  }

  function install() {
    installDocumentPasteCapture();
    patchCopyImageFromClipboard();
    if (typeof window.showAndScrollTo !== 'function') return false;
    if (window.showAndScrollTo.__fibrazoLazyWrapped) return true;
    var orig = window.showAndScrollTo;
    window.showAndScrollTo = function (elementId, focusId) {
      if (elementId !== 'update') {
        return orig.apply(this, arguments);
      }
      var el = document.getElementById('update');
      if (!el || el.getAttribute('data-lazy-edit') !== '1') {
        return orig.apply(this, arguments);
      }
      loadLazyEdit(function (ok) {
        if (ok) orig.call(window, elementId, focusId);
      });
      return false;
    };
    window.showAndScrollTo.__fibrazoLazyWrapped = true;
    return true;
  }

  if (!install()) {
    document.addEventListener('DOMContentLoaded', install);
    setTimeout(install, 0);
    setTimeout(install, 500);
    setTimeout(install, 1500);
  }
})();
