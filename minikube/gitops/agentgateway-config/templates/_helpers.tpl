{{/* The OPA ext_authz call, shared by the gRPC and HTTP branches of the
     gateway's OPA policy (policies.yaml). */}}
{{- define "agentgateway-config.opaExtAuth" -}}
backendRef:
  name: {{ .extAuth.service }}
  port: {{ .extAuth.port }}
failureMode: FailClosed
grpc:
  # Each entry becomes one metadata_context.filter_metadata struct, so
  # the value has to be a CEL map, not a bare string.
  requestMetadata:
    agentgateway: '{"project": apiKey.project, "key_id": apiKey.key_id}'
{{- end }}
