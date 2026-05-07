[CmdletBinding()]
param(
    [Parameter(Position=0)]
    [ValidateSet('install-operator','uninstall-operator','status','help')]
    [string]$Action = 'help',

    [string]$ArgoNs = 'argocd'
)

# Operaciones de plataforma para el k6-operator + RBAC del CI de tests.
# La ejecucion de pruebas (TestRun) NO vive aqui: la dispara el workflow
# en https://github.com/Juancastro14/perfomanceTestingK6 (Actions > Run k6 load test).

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

    Write-Host "Esperando que la root sincronice y propague todo (Synced + Healthy)..."
    kubectl -n $ArgoNs wait --for=jsonpath='{.status.sync.status}'=Synced application/k6-operator-root --timeout=5m
    Assert-Success "Timeout esperando 'Synced' en root."
    kubectl -n $ArgoNs wait --for=jsonpath='{.status.health.status}'=Healthy application/k6-operator-root --timeout=10m
    Assert-Success "Timeout esperando 'Healthy' en root."

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

function Get-Status {
    Test-Kubectl
    Write-Host "== ArgoCD Applications =="
    kubectl -n $ArgoNs get applications
    Write-Host ""
    Write-Host "== Operator pod =="
    kubectl -n k6-operator-system get pods 2>$null
    Write-Host ""
    Write-Host "== TestRuns activos en area-calidad-dev =="
    kubectl -n compute-resources-area-calidad-dev get testruns 2>$null
}

function Show-Help {
    @"
Uso: .\make.ps1 <accion> [opciones]

Operaciones de plataforma. La ejecucion de tests vive en
https://github.com/Juancastro14/perfomanceTestingK6 (workflow_dispatch).

Acciones:
  install-operator     Aplica la App-of-Apps root y espera Synced+Healthy
  uninstall-operator   Borra la root (cascade-delete via finalizer)
  status               Muestra estado de Applications + operator + TestRuns activos

Opciones:
  -ArgoNs <ns>         Namespace de ArgoCD (default: argocd)

Bootstrap del kubeconfig para el CI de QA:
  .\scripts\build-runner-kubeconfig.ps1 -Base64 > runner-kubeconfig.b64.txt
  Subir el contenido a GH Secret KUBECONFIG_DATA en
  https://github.com/Juancastro14/perfomanceTestingK6/settings/secrets/actions
"@
}

switch ($Action) {
    'install-operator'   { Install-Operator }
    'uninstall-operator' { Uninstall-Operator }
    'status'             { Get-Status }
    default              { Show-Help }
}
