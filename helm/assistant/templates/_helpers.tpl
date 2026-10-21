{{- define "assistant.pod" -}}
imagePullSecrets:
  - name: ghcr-pull
automountServiceAccountToken: false
securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  runAsGroup: 1000
  fsGroup: 1000
  seccompProfile: { type: RuntimeDefault }
{{- end }}
{{- define "assistant.container" -}}
image: {{ .root.Values.image.repository }}:{{ .root.Values.image.tag }}
securityContext:
  allowPrivilegeEscalation: false
  capabilities: { drop: [ALL] }
env:
  - name: ROLE
    value: {{ .role | quote }}
  - name: TZ
    value: {{ .root.Values.tz | quote }}
{{- end }}
