/**
 * Injects query_id / export_query_name into XLSX/CSV export forms.
 * The XLSX modal expands filters via query_as_hidden_field_tags but drops query_id,
 * so the server otherwise names the file "issues_xlsx_request_....csv".
 */
(function () {
  function qs(name) {
    try {
      return new URL(window.location.href).searchParams.get(name);
    } catch (e) {
      return null;
    }
  }

  function ensureHidden(form, name, value) {
    if (!form || !value) return;
    var el = form.querySelector('input[name="' + name + '"]');
    if (!el) {
      el = document.createElement('input');
      el.type = 'hidden';
      el.name = name;
      form.appendChild(el);
    }
    el.value = value;
  }

  function queryTitle() {
    var h2 = document.querySelector('#content h2');
    if (h2 && h2.textContent) return h2.textContent.trim();
    var sel = document.querySelector('#query_id, select[name="query_id"]');
    if (sel && sel.options && sel.selectedIndex >= 0) {
      return (sel.options[sel.selectedIndex].text || '').trim();
    }
    return '';
  }

  function patchForms() {
    var qid = qs('query_id');
    var qname = queryTitle();
    var forms = document.querySelectorAll(
      '#xlsx-export-form, form[action*="issues.xlsx"], form[action*="issues.csv"], form.csv-export-form'
    );
    forms.forEach(function (form) {
      if (qid) ensureHidden(form, 'query_id', qid);
      if (qname) ensureHidden(form, 'export_query_name', qname);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', patchForms);
  } else {
    patchForms();
  }
  // Modal may be shown later; re-patch on click of XLSX links
  document.addEventListener('click', function (ev) {
    var t = ev.target;
    if (!t) return;
    var a = t.closest ? t.closest('a.xlsx, a[href*="issues.xlsx"]') : null;
    if (a) setTimeout(patchForms, 0);
  });
})();
