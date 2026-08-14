(function () {
  // Split lazy-edit:
  // - Notas + filedrop viven en el HTML del show → pegar capturas = Redmine nativo.
  // - Solo propiedades/CFs (#all_attributes) se cargan por AJAX.

  function runScripts(container) {
    var scripts = Array.prototype.slice.call(container.querySelectorAll('script'));
    scripts.forEach(function (old) {
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

  function attrsRoot() {
    return document.getElementById('all_attributes');
  }

  function afterAttrsReady() {
    if (typeof window.setupFileDrop === 'function') {
      try { window.setupFileDrop(); } catch (e) {}
    }
    // Datetime CFs inyectados por AJAX: re-bind si el plugin dejó helpers globales.
    try {
      if (typeof window.jQuery !== 'undefined' && window.jQuery.fn && window.jQuery.fn.datetimepicker) {
        window.jQuery('#all_attributes input.date, #all_attributes input[id*="custom_field_values"]').each(function () {
          var $el = window.jQuery(this);
          if ($el.data('xdsoft_datetimepicker')) return;
          if (typeof window.datetimepickerCreate === 'function') {
            window.datetimepickerCreate('#' + this.id);
          }
        });
      }
    } catch (eDt) {}
    if (typeof window.jQuery !== 'undefined') {
      try { window.jQuery(document).trigger('ajax:complete'); } catch (e2) {}
    }
    try {
      document.dispatchEvent(new Event('ajax:complete', { bubbles: true }));
    } catch (e3) {}
    try {
      document.dispatchEvent(new CustomEvent('fibrazo:lazy-attrs-ready'));
    } catch (e4) {}
  }

  function loadAttributes(done) {
    var root = attrsRoot();
    if (!root) {
      if (done) done(true);
      return;
    }
    if (root.getAttribute('data-lazy-attrs-loaded') === '1') {
      if (done) done(true);
      return;
    }
    if (window.__fibrazoLazyAttrsLoading) {
      if (done) {
        var wait = setInterval(function () {
          if (root.getAttribute('data-lazy-attrs-loaded') === '1' || !window.__fibrazoLazyAttrsLoading) {
            clearInterval(wait);
            done(root.getAttribute('data-lazy-attrs-loaded') === '1');
          }
        }, 50);
      }
      return;
    }

    var url = root.getAttribute('data-lazy-attrs-url');
    if (!url) {
      if (done) done(false);
      return;
    }

    window.__fibrazoLazyAttrsLoading = true;
    var placeholder = document.getElementById('fibrazo-lazy-attrs-placeholder');
    if (placeholder) {
      placeholder.style.display = 'block';
      placeholder.textContent = 'Cargando propiedades…';
    }

    var xhr = new XMLHttpRequest();
    xhr.open('GET', url, true);
    xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
    xhr.setRequestHeader('Accept', 'text/html');
    xhr.onload = function () {
      window.__fibrazoLazyAttrsLoading = false;
      if (xhr.status >= 200 && xhr.status < 300) {
        root.innerHTML = xhr.responseText;
        root.setAttribute('data-lazy-attrs-loaded', '1');
        var update = document.getElementById('update');
        if (update) update.setAttribute('data-lazy-loaded', '1');
        runScripts(root);
        afterAttrsReady();
        if (done) done(true);
      } else {
        if (placeholder) {
          placeholder.textContent = 'No se pudieron cargar las propiedades (' + xhr.status + ').';
        }
        if (done) done(false);
      }
    };
    xhr.onerror = function () {
      window.__fibrazoLazyAttrsLoading = false;
      if (placeholder) placeholder.textContent = 'No se pudieron cargar las propiedades.';
      if (done) done(false);
    };
    xhr.send();
  }

  function prefetchAttributes() {
    var root = attrsRoot();
    if (!root || root.getAttribute('data-lazy-attrs-loaded') === '1') return;
    loadAttributes(null);
  }

  function install() {
    // Formulario de notas+adjuntos ya está en DOM: binder paste nativo.
    if (typeof window.setupFileDrop === 'function') {
      try { window.setupFileDrop(); } catch (e) {}
    }

    var update = document.getElementById('update');
    if (!update || update.getAttribute('data-lazy-edit') !== '1') {
      return typeof window.showAndScrollTo === 'function';
    }

    // Prefetch en idle para que Editar/Responder ya tengan CFs listos.
    if (window.requestIdleCallback) {
      window.requestIdleCallback(function () { prefetchAttributes(); }, { timeout: 2500 });
    } else {
      window.setTimeout(prefetchAttributes, 800);
    }

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
      // Mostrar notas de inmediato (pegar captura no espera AJAX).
      var result = orig.call(window, elementId, focusId);
      loadAttributes(null);
      return result;
    };
    window.showAndScrollTo.__fibrazoLazyWrapped = true;
    return true;
  }

  if (!install()) {
    document.addEventListener('DOMContentLoaded', install);
    setTimeout(install, 0);
    setTimeout(install, 500);
  }
})();
