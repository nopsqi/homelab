{{- define "assistant.pod" -}}
imagePullSecrets:
  - name: ghcr-pull
automountServiceAccountToken: false
{{- end }}
{{- define "assistant.container" -}}
image: {{ .root.Values.image.repository }}:{{ .root.Values.image.tag }}
env:
  - name: ROLE
    value: {{ .role | quote }}
  - name: TZ
    value: {{ .root.Values.tz | quote }}
{{- end }}
