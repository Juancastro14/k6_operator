# k6_operator (plataforma)

Repositorio **de plataforma** para el setup de pruebas de carga distribuidas con k6 en BHD. Contiene:

- ArgoCD `Application`s que instalan y mantienen el k6-operator y el RBAC del runner de CI.
- `Dockerfile` de la imagen custom de k6 (con la extension `xk6-output-influxdb`) + GitHub Action que la builda y publica en GHCR.
- Script para generar el kubeconfig que el CI del repo de tests guarda como secret.

**Las pruebas no se ejecutan desde aqui.** Las dispara el equipo de QA via GitHub Actions en [perfomanceTestingK6](https://github.com/Juancastro14/perfomanceTestingK6).

## Arquitectura de los dos repos

```
┌──────────────────────────────────────┐         ┌──────────────────────────────────────┐
│  k6_operator  (plataforma / SRE)     │         │  perfomanceTestingK6  (QA)           │
│  ─ ArgoCD: operator + RBAC + chart   │         │  ─ scripts/*.js                      │
│  ─ Dockerfile + CI -> GHCR image     │ ──────▶ │  ─ TestRun template                  │
│  ─ kubeconfig builder (PS)           │  image  │  ─ workflow_dispatch (QA UI)         │
└──────────────────────────────────────┘         └──────────────────────────────────────┘
                  │                                                  │
                  │ ArgoCD Apps (sincronizado)                       │ kubectl con SA token
                  ▼                                                  ▼
          ┌───────────────────────────────────────────────────────────────┐
          │  Cluster AKS                                                  │
          │   k6-operator-system     compute-resources-area-calidad-dev   │
          │     k6-operator              k6-test-runner SA                │
          │                              influxdb (v3)                    │
          │                              grafana                          │
          └───────────────────────────────────────────────────────────────┘
```

## Estructura

```
k6_operator/
├── argocd/
│   ├── root-application.yaml           # App-of-Apps root, bootstrap manual
│   ├── applications/
│   │   ├── k6-operator.yaml            # instala chart grafana/k6-operator
│   │   └── k6-tests-rbac.yaml          # apunta a argocd/manifests/k6-tests-rbac/
│   └── manifests/
│       └── k6-tests-rbac/              # SA + Role + RoleBinding + token Secret
├── docker/
│   └── Dockerfile                      # k6 + xk6-output-influxdb
├── scripts/
│   └── build-runner-kubeconfig.ps1     # genera el kubeconfig para el CI de tests
├── .github/workflows/
│   └── build-image.yml                 # CI: build + push a ghcr.io/<owner>/k6-influxdb
├── make.ps1                            # install/uninstall/status del bootstrap
└── README.md
```

## Bootstrap (una sola vez por cluster)

```powershell
# 1) Aplica la App-of-Apps root, instala el operator + RBAC, espera Synced+Healthy
.\make.ps1 install-operator

# 2) Genera el kubeconfig que el CI de QA usara para hablar con el cluster
.\scripts\build-runner-kubeconfig.ps1 -Base64 > runner-kubeconfig.b64.txt

# 3) Pegar el contenido de runner-kubeconfig.b64.txt como secret
#    KUBECONFIG_DATA en el repo de tests:
#    https://github.com/Juancastro14/perfomanceTestingK6/settings/secrets/actions
```

Despues de eso, **QA ya puede correr pruebas** desde Actions del repo de tests.

## Imagen custom (CI -> GHCR)

El push a `main` que toque `docker/**` dispara `.github/workflows/build-image.yml` que builda y publica:

- `ghcr.io/juancastro14/k6-influxdb:latest`
- `ghcr.io/juancastro14/k6-influxdb:<git-sha>`

**Despues del primer push**, hacer la package publica una sola vez en GitHub:
- https://github.com/Juancastro14?tab=packages -> click en `k6-influxdb` -> Package settings -> **Change visibility** -> Public.
- Si no, el cluster necesita un `imagePullSecret` para autenticar al pull.

## Que hace cada Application en ArgoCD

| Application | Que despliega | Donde |
|---|---|---|
| `k6-operator-root` | Esta misma carpeta `argocd/applications/` | `argocd/` |
| `k6-operator` | Chart Helm `grafana/k6-operator` | `k6-operator-system/` |
| `k6-tests-rbac` | ServiceAccount + Role + RoleBinding + token Secret para el CI | `compute-resources-area-calidad-dev/` |

## Make.ps1

Solo operaciones de plataforma. Las pruebas no se lanzan desde aqui.

| Accion | Descripcion |
|---|---|
| `install-operator` | Aplica root + espera bootstrap completo |
| `uninstall-operator` | Borra root (cascade) |
| `status` | Estado de Applications, operator pod, TestRuns activos |
| `help` | (default) |
