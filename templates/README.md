# templates/

`new-app.ps1` copies `templates/app/` to make a new app with a dev and a prod environment.
Each `__APP__` becomes the app name.

**Keep the templates current.** When a new feature is added that every app needs
(for example a database through CloudNativePG, an ExternalSecret from OpenBao,
OpenTelemetry settings, a NetworkPolicy, a ResourceQuota), add it here and in
`new-app.ps1` in the same pull request. Otherwise a new app misses it.

| Path | Becomes |
|---|---|
| `app/base/` | `apps/base/<app>/` |
| `app/dev/` | `apps/dev/<app>/` |
| `app/prod/` | `apps/prod/<app>/` |
| `app/image-automation.yaml` | `infrastructure/image-automation/<app>.yaml` |

The app must listen on port 8080 and answer `GET /healthz`, the same as `hello-api`.
