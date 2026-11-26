{{/* The OPA ext_authz call, shared by the gRPC and HTTP branches of the
     gateway's OPA policy (policies.yaml). */}}
{{- define "agentgateway-config.opaExtAuth" -}}
# group and kind spelled out: the API server defaults them in a conditional
# policy, and Argo CD would otherwise report it as OutOfSync.
backendRef:
  group: ""
  kind: Service
  name: {{ .extAuth.service }}
  port: {{ .extAuth.port }}
failureMode: FailClosed
grpc:
  # Each entry becomes one metadata_context.filter_metadata struct, so
  # the value has to be a CEL map, not a bare string.
  requestMetadata:
    agentgateway: '{"project": apiKey.project, "key_id": apiKey.key_id}'
{{- end }}
