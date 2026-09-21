# Fibrazo Issue Perf

Lazy-load **split** del formulario en issue show + guard de exports + listados solo-abiertos.

- **Siempre en HTML:** notas + adjuntos (`filedrop`) → pegar capturas con Redmine nativo.
- **AJAX:** propiedades / custom fields (`GET /issues/:id/lazy_edit_attributes`).
- **Exports:** guard contra XLSX masivos (evita 504/ALB 60s).
- **Listados/API:** sin filtro de estado → solo abiertos (el ~94% cerrado de la tabla
  no se escanea en index/API/auto-refresh). Con filtro explícito del usuario
  (Cerrado/Todos) se respeta. Bypass puntual: admin + `?allow_closed=1`.
- **Queries 16 y 17** (Comparar Odoo I&M, Issues sin partner): solo visibles para admin.

## Permisos

Ninguno propio: respeta los permisos estándar de ver casos. Es presentación + rendimiento.

## Instalación

Viene en el árbol de plugins. Tras actualizar, reiniciar app (sin migraciones).

## Versiones

Ver `version` en `init.rb` (actual 0.2.8).
