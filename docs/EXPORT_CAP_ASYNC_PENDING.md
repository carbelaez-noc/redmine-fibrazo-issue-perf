# Export async diferido — PENDIENTE (no implementado)

## Estado

NO implementado. El guard actual (`lib/fibrazo_issue_perf/export_guard_patch.rb`)
sirve exports hasta `MAX_EXPORT_ROWS` (2000) en la request síncrona:

- CSV por streaming (Enumerator + batches de 500): memoria acotada.
- XLSX con lecturas por batches (el ZIP se bufferiza: limitación de `write_xlsx`).
- Headers `X-Export-Rows` / `X-Export-Truncated` avisan del recorte.

## Propuesta cuando se retome (202 + job)

1. Umbral: si `query.issue_count > MAX_EXPORT_ROWS`, responder `202 Accepted`
   con `{ "status": "queued", "job_id": ..., "status_url": ... }` en vez de
   truncar en silencio.
2. Job en background (el worker `fibrazo_redmine_worker` ya existe en DEV):
   genera el archivo completo o por partes y lo deja descargable
   (attachment temporal o objeto en `files/`), con expiración.
3. Endpoint de estado: `GET /export_jobs/:id` → `pending|done|failed` +
   URL de descarga al terminar.
4. Notificación al usuario (email Redmine o banner) cuando el archivo esté listo.
5. Mantener el tope síncrono como fallback si la cola está caída.

## Criterios de aceptación (futuros)

- Export de 10k filas retorna 202 en < 2s y el job completa sin OOM del worker.
- Descarga final con el total de filas (sin truncate) o truncado documentado.
- Sin regresión en exports ≤ 2000 (siguen síncronos con headers actuales).
