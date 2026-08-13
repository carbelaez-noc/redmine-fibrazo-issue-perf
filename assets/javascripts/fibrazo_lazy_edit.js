(function () {
  function runScripts(container) {
    var scripts = container.querySelectorAll('script');
    scripts.forEach(function (old) {
      var s = document.createElement('script');
      if (old.src) {
        s.src = old.src;
        s.async = false;
      } else {
        s.text = old.textContent;
      }
      old.parentNode.replaceChild(s, old);
    });
  }

  function loadLazyEdit(done) {
    var el = document.getElementById('update');
    if (!el) {
      if (done) done(false);
      return;
    }
    if (el.getAttribute('data-lazy-loaded') === '1' || el.querySelector('#issue-form')) {
      if (done) done(true);
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
        if (typeof window.jQuery !== 'undefined') {
          try { window.jQuery(document).trigger('ajax:complete'); } catch (e) {}
        }
        if (done) done(true);
      } else {
        slot = document.getElementById('fibrazo-lazy-edit-slot') || el;
        slot.innerHTML = '<p class="nodata">No se pudo cargar el formulario (' + xhr.status + ').</p>';
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
  }
})();
