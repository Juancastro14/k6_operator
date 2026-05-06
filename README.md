# k6 distribuido sobre Kubernetes (k6-operator) — modelo GitOps

Pruebas de carga distribuidas con [grafana/k6-operator](https://github.com/grafana/k6-operator). El script de k6 modela una rampa hasta **300 VU** y el operator divide esa carga entre los pods runner que se le indiquen via `parallelism`.

## Modelo de despliegue

| Componente | Como se gestiona |
|---|---|
| **k6-operator** (controller, CRDs, RBAC) | **GitOps** — ArgoCD `Application` apunta al chart `grafana/k6-operator`. Auto-sync + self-heal. |
| **TestRun + ConfigMap del script** | **Imperativo a demanda** — `make.ps1 run` los crea cuando querés correr una prueba. No los gestiona ArgoCD (deliberado: el TestRun es ruidoso para GitOps porque muta de estado y se borra al terminar). |

## Estructura

```
k6_operator/
├── make.ps1                                 # entrypoint imperativo (run, logs, clean, install-operator)
├── argocd/
│   └── applications/
│       └── k6-operator.yaml                 # ArgoCD Application (chart Helm v4.4.1)
├── manifests/
│   ├── namespace.yaml                       # namespace por defecto (k6-load-tests, no usado en argo)
│   └── testrun.yaml                         # TestRun template (vars ${...})
└── scripts/
    └── load-test.js                         # k6 script: ramping-vus 0->300->0
```

## Prerequisitos

- Cluster de Kubernetes accesible (kubectl context apuntando al cluster destino).
- ArgoCD instalado en el cluster (namespace `argocd` por defecto).
- `kubectl` en PATH.
- PowerShell 5.1+ (Windows) o PowerShell Core.

> Helm **no** es necesario para usar este proyecto: ArgoCD descarga el chart por su cuenta. Se requiere helm sólo si quisieras usar el chart fuera de ArgoCD.

## Quickstart

```powershell
# 1. Instalar el operator via ArgoCD (una sola vez por cluster)
.\make.ps1 install-operator

# 2. Lanzar un test ad-hoc (4 pods, default)
.\make.ps1 run -Namespace compute-resources-area-calidad-dev

# 3. Seguir logs
.\make.ps1 logs -Namespace compute-resources-area-calidad-dev

# 4. Ver estado
.\make.ps1 status -Namespace compute-resources-area-calidad-dev

# 5. Limpiar el TestRun cuando termine
.\make.ps1 clean -Namespace compute-resources-area-calidad-dev
```

`install-operator`:
- Aplica [argocd/applications/k6-operator.yaml](argocd/applications/k6-operator.yaml) en el namespace de ArgoCD.
- Espera `Synced` + `Healthy`.
- A partir de ahí ArgoCD se encarga (auto-sync, self-heal). La Application aparece en la UI.

## Parametrizacion del TestRun

```powershell
# Numero de pods
.\make.ps1 run -Parallelism 6

# URL bajo prueba
.\make.ps1 run -TargetUrl https://mi-app.example.com

# Cambiar nombre del TestRun (util para correr varias pruebas en paralelo)
.\make.ps1 run -TestName checkout-load -Namespace qa
```

## Como se reparten los 300 VU

`k6-operator` no escala pods dinamicamente segun la rampa: el numero de pods (`parallelism`) es fijo al crear el `TestRun`. Lo que hace es **dividir el modelo de carga** entre los pods inyectando el flag `--execution-segment` en cada uno.

Con `parallelism: 4` y un script que rampea hasta 300 VU:

| Pods | VU pico por pod |
|------|-----------------|
| 4    | 75              |
| 6    | 50              |
| 10   | 30              |

El script declara `300 VU` totales; cada pod corre su segmento (1/N) sincronizado. El comportamiento agregado equivale a un k6 monolitico de 300 VU.

## Modificar el modelo de carga

Edita [scripts/load-test.js](scripts/load-test.js). Stages actuales:

```javascript
stages: [
  { duration: '30s', target: 50 },
  { duration: '1m',  target: 150 },
  { duration: '1m',  target: 300 },
  { duration: '2m',  target: 300 },
  { duration: '30s', target: 0 },
]
```

Despues de editar, `.\make.ps1 run` recrea el ConfigMap y relanza el TestRun.

## Recursos por pod

Definidos en [manifests/testrun.yaml](manifests/testrun.yaml): `200m`/`256Mi` request, `1`/`512Mi` limit. Suficiente para ~75 VU haciendo HTTP simple. Si subis VU/pod o el script es CPU-intenso, ajustalos.

## Cambiar la version del chart

La version del chart esta pineada en [argocd/applications/k6-operator.yaml](argocd/applications/k6-operator.yaml) (`spec.source.targetRevision`). Para subir de version, editar ese campo y commitear — ArgoCD aplicara el upgrade en el siguiente sync.

## Resultados / metricas

`spec.cleanup: post` borra los pods runner cuando el test termina pero deja el `TestRun` para inspeccion. Para metricas centralizadas (Prometheus, InfluxDB, Cloud) agregar un output a `arguments` en el TestRun, por ejemplo:

```yaml
arguments: --out experimental-prometheus-rw
```

y configurar la URL via env vars del runner.

## Troubleshooting

```powershell
# Estado de la Application en ArgoCD
kubectl -n argocd get application k6-operator
kubectl -n argocd describe application k6-operator

# El operator no esta listo
kubectl -n k6-operator-system get pods

# El TestRun se queda en estado "initialization" o "created"
kubectl -n compute-resources-area-calidad-dev describe testrun load-test

# Un pod runner crashea
kubectl -n compute-resources-area-calidad-dev logs <pod-name>
```
