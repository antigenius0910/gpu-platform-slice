{{/*
Tier -> PriorityClass. This map is the only place a PriorityClass name appears
on the tenant path. It lives in template code, not in values, so a tenant spec
cannot override it (the schema forbids extra keys). Keep it in step with the
"tier" enum in values.schema.json and with platform/priorityclasses.yaml.
*/}}
{{- define "tenant.priorityClass" -}}
{{- get (dict "low" "tenant-low" "high" "tenant-high") .Values.tier -}}
{{- end -}}
