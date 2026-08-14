# Optimización de vistas Redmine (Helpdesk Fibrazo)

Guía práctica: qué hincha las páginas, qué medimos, y cómo optimizar **por módulo** sin romper pegar capturas ni flujos NOC.

Última medición: **2026-08-13** — issue `IMS0000135` / id `3225`, usuario `qa_traslados`.

| Estado | HTML show | Bloque desde `#update` | Notas+filedrop en show | Atributos AJAX |
|--------|-----------|------------------------|------------------------|----------------|
| Sin perf (form completo) | ~175 KB | ~102 KB | sí (todo el form) | n/a |
| **perf 0.2.0 split** | **~115 KB** | **~42 KB** | **sí** | **~58 KB** |

Ahorro en show: **~60 KB HTML (~34%)** por ticket abierto; propiedades se cargan aparte.

## Resumen ejecutivo

| Vista / bloque | Peso aprox. | Impacto en 200 usuarios | Estrategia |
|----------------|-------------|-------------------------|------------|
| `GET /issues/:id` HTML total | **~175 KB** | Alto (cada apertura de ticket) | Reducir `#update` y defer JS |
| Bloque `#update` (form edit completo) | **~102 KB** (~58% del HTML) | Muy alto | Split: notas+adjuntos siempre; propiedades lazy |
| Scripts en show (39 tags) | Variable (muchos plugins) | Alto en CPU/red del browser | Cargar solo en la acción que los usa |
| `fibrazo_issue_contacts.js` | ~155 KB | Medio-alto en show | Mantener; no maplibre en show |
| `maplibre-gl.js` (contacts) | **~1.0 MB** | Crítico si se incluye en show | Solo al abrir mapa |
| `scalar-api-reference.js` | **~3.7 MB** | Crítico | Nunca en issue show |
| Select2 full min | ~75 KB | Medio | Una sola copia; no jquery duplicado |
| View Customize (habilitados) | Bajo hoy (~16 KB en login) | Bajo en issue | Revisar VCs globales |

Conclusión: el cuello de botella del **show de issue** no es “Redmine lento en general”, sino el **formulario de edición embebido** (`#update`) + JS de plugins que no hacen falta hasta Editar/Contención/IA.

## Arquitectura del fix (`fibrazo_issue_perf` ≥ 0.2.0)

### Antes (0.1.x — problemático)

- `#update` vacío → AJAX traía **todo** `issues/_edit`.
- Notas y `input.filedrop` nacían tarde → `setupFileDrop` / paste frágil.
- Intentos de polyfill de clipboard rompieron pegar recortes.

### Ahora (split)

```
show (HTML inicial)
├── issue details / journals / tabs     (siempre)
└── #update (hidden)
    ├── #all_attributes                 ← placeholder; AJAX GET .../lazy_edit_attributes
    ├── #add_notes + wiki-edit          ← SIEMPRE (Responder / pegar)
    └── #add_attachments + filedrop     ← SIEMPRE (paste nativo Redmine)
```

- **Responder / Editar**: muestran `#update` al instante; propiedades se rellenan (prefetch idle o al abrir).
- **Pegar capturas**: handler nativo (`attachments.js` → `setupFileDrop` / `copyImageFromClipboard`) porque notes+filedrop están en el DOM del show.
- Endpoint: `GET /issues/:id/lazy_edit_attributes` → partial `issues/_form`.

No reintroducir lazy del formulario **entero**.

## Vistas y hooks que más pesan

### 1. Issue show — `IssuesController#show`

- Partial crítico: `issues/_action_menu_edit` → `issues/_edit` (core) o `_edit_fast` (perf).
- Dentro de `_edit` → `_form` → `_attributes` + custom fields + descripción wiki.
- En este entorno: **~21 CFs editables**, **~29 assignable**, **~258 `<option>`** en el form completo.

### 2. Hooks `view_layouts_base_html_head` (cada HTML)

Plugins que inyectan CSS/JS en issues (revisar siempre `issues_related_page?`):

| Plugin | Qué carga | Regla |
|--------|-----------|--------|
| `fibrazo_contacts` | contacts + issue_contacts + wizard | Solo show/edit/new; **no** index |
| `redmine_ai_helper` | ai_helper (+ typo/autocomplete) | Ideal: al expandir UI IA |
| `redmine_indicator` | Chart.min | Solo pantallas con gráficos |
| `redmine_datetime_custom_field` | datetimepicker | Solo si hay CF fecha/hora visible |
| `redmine_depending_custom_fields` | depending JS | OK si hay CFs dependientes en form |
| `fibrazo_traslados` | modal traslados | Bind al form; no bloquear show |
| `fibrazo_n0_noc` | panel flotante | Poll ya optimizado; no meter Krill en HTML |
| `redmine_olt_carrier_inventory` | assets OLT | Solo pestaña/inventario |
| `redmine__select2` | select2 | Evitar 2ª copia de jQuery |

### 3. Hooks en el cuerpo del issue

| Hook | Plugins típicos | Nota |
|------|-----------------|------|
| `view_issues_show_details_bottom` | contacts, krill, mops, clock_stop, tabs | Mantener livianos; datos pesados por XHR |
| `view_issues_form_details_top` | contacts wizard, CX intake | Va con `_form` → queda en lazy attributes |
| `view_issues_show_description_bottom` | krill, case quality, periodictask | Preferir resumen + fetch |

### 4. Assets “bomba” en disco (no deben ir al show)

Ruta base: `data/redmine/plugins/*/assets/javascripts/`

1. `fibrazo_contacts/.../scalar-api-reference.js` (~3.7 MB)
2. `fibrazo_contacts/.../maplibre-gl.js` (~1.0 MB)
3. `fibrazo_contacts/.../leaflet.js` (~148 KB)
4. `fibrazo_contacts/.../fibrazo_issue_contacts.js` (~155 KB) — sí en show, OK
5. `redmine__select2/.../select2.full.js` sin minificar (~162 KB) — preferir `.min`

## Cómo medir (operación)

```bash
# Login + tamaño HTML show
curl -sS -b "$COOKIE" -o /tmp/issue.html -w 'time=%{time_total} size=%{size_download}\n' \
  'https://helpdesk.soporte24.cloud/issues/3225'

# Peso del bloque update
python3 - <<'PY'
from pathlib import Path
html = Path('/tmp/issue.html').read_text(errors='replace')
i = html.find('id="update"')
print('from_update_bytes', len(html[i:].encode()) if i>=0 else None)
print('has_issue_notes', 'id="issue_notes"' in html)
print('has_filedrop', 'filedrop' in html)
print('has_all_attributes_placeholder', 'data-lazy-attrs-url' in html)
PY

# Endpoint lazy attributes
curl -sS -b "$COOKIE" -b "$COOKIE" -o /tmp/attrs.html -w 'attrs=%{size_download} time=%{time_total}\n' \
  'https://helpdesk.soporte24.cloud/issues/3225/lazy_edit_attributes'
```

Objetivo con perf 0.2.x:

- Show HTML **claramente menor** que ~175 KB (sin `_form` completo).
- `issue_notes` + `filedrop` presentes **sin** esperar AJAX.
- `lazy_edit_attributes` ~ tamaño del `_form` (CFs/propiedades).

## Checklist por módulo (dueños)

### `fibrazo_issue_perf`

- [x] Split notes/attachments vs attributes
- [x] AssetSync Propshaft (`fibrazo_lazy_edit-*.js`)
- [ ] No interceptar `paste` (dejar core)
- [ ] Test manual: Responder → pegar PNG → adjunto + markup

### `fibrazo_contacts`

- [ ] Wizard/mapa solo al abrir Contención / Estado ONTs
- [ ] Nunca incluir maplibre/leaflet/scalar en `html_head` del show
- [ ] Seguir excluyendo index de issues del JS pesado

### `redmine_ai_helper`

- [ ] Defer de `ai_helper*.js` hasta abrir panel/borrador

### `redmine_indicator`

- [ ] Chart solo donde hay canvas/dashboard

### `redmine_datetime_custom_field` / depending CF

- [ ] Inicializar pickers tras `fibrazo:lazy-attrs-ready` (evento que dispara perf)

### Custom fields / producto

- [ ] Revisar CFs poco usados: no “editable on all statuses” si no hace falta
- [ ] Preferir grupos de CF / pestañas a 20+ campos en un solo fieldset

### Infra

- [ ] Nginx cache de `/assets/*` (ya típico)
- [ ] No medir “lentitud” solo por TTFB: mirar **bytes HTML** y **JS parse** en DevTools

## Anti-patrones (no repetir)

1. Lazy-load del **formulario completo** `#issue-form` (rompe paste / setupFileDrop).
2. `document.querySelector('input:file...')` — `:file` es jQuery, no CSS → `SyntaxError`.
3. Parchear clipboard “por si acaso” cuando el DOM ya tiene filedrop.
4. Meter librerías de mapa/OpenAPI en el head global.
5. Desactivar perf sin plan: vuelve el `#update` de ~100 KB en cada show.

## Referencias de código

- Plugin: `data/redmine/plugins/fibrazo_issue_perf/`
- Partial show: `app/views/issues/_edit_fast.html.erb`
- JS: `assets/javascripts/fibrazo_lazy_edit.js`
- Endpoint: `IssuesController#lazy_edit_attributes`
- Evento post-CFs: `fibrazo:lazy-attrs-ready` (+ `ajax:complete`)

## Resultados prueba ardua 2026-08-14

Ver detalle: [`docs/perf_runs/COMPARE_20260814_before_after.md`](perf_runs/COMPARE_20260814_before_after.md)

Resumen:
- Show HTML −34% a −42% con perf 0.2.0 (p.ej. 175→115 KB en 3225; 156→91 KB en 3103 con **408** contenidos).
- Contención masiva no infla el show; panel Contención ~90 KB / 0.3–1.1 s.
- Browser 3103: DCL ~3.9 s dominado por JS (contacts 155 KB + AI + tabs); consola sin errores; paste nativo OK (`filedroplistner`).

## Historial breve

| Versión | Cambio |
|---------|--------|
| 0.1.x | Lazy formulario completo — rápido pero paste roto |
| 0.1.11 | Intentos de polyfill paste — fallidos en prod |
| **0.2.0** | Split: notas+adjuntos en show; atributos AJAX |
