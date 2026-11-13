{{- define "registry.env" -}}
- {name: DATABASE_URL, valueFrom: {secretKeyRef: {name: {{ .Values.databaseSecret }}, key: DATABASE_URL}}}
- {name: DEPLOY_REPO, value: {{ .Values.deployRepo | quote }}}
- {name: S3_ENDPOINT, value: {{ .Values.minio.url | quote }}}
- {name: S3_BUCKET, value: {{ .Values.minio.bucket | quote }}}
- {name: AWS_REGION, value: {{ .Values.minio.region | quote }}}
- {name: AWS_ACCESS_KEY_ID, valueFrom: {secretKeyRef: {name: {{ .Values.minio.writerSecret }}, key: AWS_ACCESS_KEY_ID}}}
- {name: AWS_SECRET_ACCESS_KEY, valueFrom: {secretKeyRef: {name: {{ .Values.minio.writerSecret }}, key: AWS_SECRET_ACCESS_KEY}}}
- {name: BUNDLE_PREFIX, value: {{ .Values.bundles.prefix | quote }}}
- {name: VAULT_ADDR, value: {{ .Values.signing.vaultAddr | quote }}}
- {name: VAULT_ROLE, value: {{ .Values.signing.vaultRole | quote }}}
- {name: TRANSIT_KEY, value: {{ .Values.signing.transitKey | quote }}}
- {name: SIGNING_KEYID, value: {{ .Values.signing.keyid | quote }}}
- {name: SIGNING_KEY_VERSION, value: {{ .Values.signing.keyVersion | quote }}}
- {name: WORKDIR, value: /work}
{{- end -}}
{{- define "registry.pod" -}}
serviceAccountName: {{ .Values.serviceAccount }}
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  seccompProfile: {type: RuntimeDefault}
volumes:
  - {name: work, emptyDir: {}}
  - {name: tmp, emptyDir: {}}
{{- end -}}
{{- define "registry.container" -}}
image: {{ .Values.image }}
securityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities: {drop: [ALL]}
volumeMounts:
  - {name: work, mountPath: /work}
  - {name: tmp, mountPath: /tmp}
{{- end -}}
