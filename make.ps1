[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('install-operator','deploy','run','logs','status','clean','uninstall-operator','help')]
    [string]$Action = 'help',

    [int]$Parallelism   = 4,
    [string]$Namespace  = 'k6-load-tests',
    [string]$TestName   = 'load-test',
    [string]$TargetUrl  = 'https://test.k6.io',
    [string]$ArgoNs     = 'argocd'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

function Test-Kubectl {
    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw "kubectl no esta en PATH. Instalalo antes de continuar."
    }
}

function Assert-Success($message) {
    if ($LASTEXITCODE -ne 0) { throw $message }
}

function Install-Operator {
    Test-Kubectl

    $rootPath = Join-Path $root 'argocd\root-application.yaml'
    Write-Host "Aplicando App-of-Apps root desde $rootPath ..."
    kubectl apply -f $rootPath
    Assert-Success "Fallo aplicando la root Application."

    Write-Host "Esperando que la root sincronice y propague el operator (Synced + Healthy)..."
    kubectl -n $ArgoNs wait --for=jsonpath='{.status.sync.status}'=Synced application/k6-operator-root --timeout=5m
    Assert-Success "Timeout esperando 'Synced' en root."
    kubectl -n $ArgoNs wait --for=jsonpath='{.status.health.status}'=Healthy application/k6-operator-root --timeout=10m
    Assert-Success "Timeout esperando 'Healthy' en root (esto incluye al child k6-operator)."

    Write-Host ""
    Write-Host "Bootstrap completo. Estado actual en ArgoCD:"
    kubectl -n $ArgoNs get applications
}

function Uninstall-Operator {
    Test-Kubectl
    $rootPath = Join-Path $root 'argocd\root-application.yaml'
    Write-Host "Borrando root Application..."
    kubectl delete -f $rootPath --ignore-not-found
    Write-Host "El finalizer borra en cascada las child Applications y todos sus recursos."
    Write-Host "Nota: los CRDs (testruns.k6.io, etc.) no se borran automaticamente."
    Write-Host "Para removerlos: kubectl delete crd testruns.k6.io testjobs.k6.io privateloadzones.k6.io"
}

function Initialize-Namespace {
    $existing = kubectl get namespace $Namespace --ignore-not-found -o name 2>$null
    if (-not $existing) {
        Write-Host "Namespace '$Namespace' no existe. Intentando crearlo..."
        kubectl create namespace $Namespace
        Assert-Success "No se pudo crear el namespace '$Namespace' (permisos?)."
    } else {
        Write-Host "Namespace '$Namespace' ya existe."
    }
}

function Publish-Script {
    Test-Kubectl
    Initialize-Namespace

    $scriptPath = Join-Path $root 'scripts\load-test.js'
    Write-Host "Creando/actualizando ConfigMap k6-load-test-script en '$Namespace' desde $scriptPath ..."
    $cmYaml = kubectl create configmap k6-load-test-script `
        --from-file=$scriptPath `
        -n $Namespace `
        --dry-run=client -o yaml
    Assert-Success "Fallo generando el ConfigMap (dry-run)."
    $cmYaml | kubectl apply -f -
    Assert-Success "Fallo aplicando el ConfigMap."
}

function Invoke-Run {
    Publish-Script

    $template = Get-Content (Join-Path $root 'manifests\testrun.yaml') -Raw
    $rendered = $template `
        -replace '\$\{PARALLELISM\}', $Parallelism `
        -replace '\$\{TEST_NAME\}',   $TestName `
        -replace '\$\{NAMESPACE\}',   $Namespace `
        -replace '\$\{TARGET_URL\}',  $TargetUrl

    $tmp = New-TemporaryFile
    try {
        Set-Content -Path $tmp.FullName -Value $rendered -Encoding utf8
        kubectl apply -f $tmp.FullName
    } finally {
        Remove-Item $tmp.FullName -ErrorAction SilentlyContinue
    }

    Write-Host ""
    Write-Host "TestRun '$TestName' aplicado en namespace '$Namespace' con parallelism=$Parallelism."
    Write-Host "Cada pod recibira aproximadamente $([Math]::Ceiling(300 / $Parallelism)) VU pico (300 VU / $Parallelism pods)."
    Write-Host ""
    Write-Host "Siguiente:"
    Write-Host "  .\make.ps1 status   # ver pods"
    Write-Host "  .\make.ps1 logs     # seguir logs"
}

function Get-Logs {
    Test-Kubectl
    Write-Host "Tailing logs de runners (label k6_cr=$TestName) ..."
    kubectl -n $Namespace logs -l "k6_cr=$TestName" -f --tail=100 --max-log-requests=20
}

function Get-Status {
    Test-Kubectl
    kubectl -n $Namespace get testruns 2>$null
    Write-Host ""
    kubectl -n $Namespace get pods -o wide
}

function Remove-Test {
    Test-Kubectl
    kubectl -n $Namespace delete testrun $TestName --ignore-not-found
    kubectl -n $Namespace delete configmap k6-load-test-script --ignore-not-found
}

function Show-Help {
    @"
Uso: .\make.ps1 <accion> [opciones]

Modelo:
  - El operator se gestiona via ArgoCD (Application en argocd\applications\k6-operator.yaml).
  - Los TestRuns se lanzan a demanda imperativamente desde este script.

Acciones:
  install-operator     Aplica la Application de ArgoCD y espera Synced+Healthy
  deploy               Aplica namespace + ConfigMap del script (sin lanzar test)
  run                  Renderiza y aplica el TestRun (ad-hoc, fuera de Argo)
  logs                 Sigue logs de todos los pods runner
  status               Muestra TestRun y pods
  clean                Borra el TestRun y el ConfigMap
  uninstall-operator   Borra la Application de ArgoCD (cascade-delete via finalizer)

Opciones:
  -Parallelism <int>   Numero de pods runner (default: 4)
  -TestName    <name>  Nombre del TestRun (default: load-test)
  -Namespace   <ns>    Namespace donde corre el test (default: k6-load-tests)
  -TargetUrl   <url>   URL bajo prueba, expuesta como TARGET_URL al script (default: https://test.k6.io)
  -ArgoNs      <ns>    Namespace de ArgoCD (default: argocd)

Ejemplos:
  .\make.ps1 install-operator
  .\make.ps1 run -Namespace compute-resources-area-calidad-dev -Parallelism 4
  .\make.ps1 run -Parallelism 6 -TargetUrl https://mi-app.example.com
  .\make.ps1 logs    -Namespace compute-resources-area-calidad-dev
  .\make.ps1 status  -Namespace compute-resources-area-calidad-dev
  .\make.ps1 clean   -Namespace compute-resources-area-calidad-dev

Notas:
  - El script en scripts\load-test.js usa ramping-vus hasta 300 VU.
  - k6-operator divide automaticamente esos 300 VU entre los pods (parallelism).
"@
}

switch ($Action) {
    'install-operator'   { Install-Operator }
    'uninstall-operator' { Uninstall-Operator }
    'deploy'             { Publish-Script }
    'run'                { Invoke-Run }
    'logs'               { Get-Logs }
    'status'             { Get-Status }
    'clean'              { Remove-Test }
    default              { Show-Help }
}
