[CmdletBinding()]
param(
    [string]$Namespace      = 'compute-resources-area-calidad-dev',
    [string]$ServiceAccount = 'k6-test-runner',
    [string]$TokenSecret    = 'k6-test-runner-token',
    [switch]$Base64
)

# Genera el kubeconfig para que el CI de perfomanceTestingK6 hable con el cluster
# usando el ServiceAccount creado por la Application k6-tests-rbac.
#
# Uso:
#   .\scripts\build-runner-kubeconfig.ps1 > runner-kubeconfig.yaml
#   .\scripts\build-runner-kubeconfig.ps1 -Base64 > runner-kubeconfig.b64.txt
#
# Despues subir el contenido como GH Secret KUBECONFIG_DATA en
# https://github.com/Juancastro14/perfomanceTestingK6/settings/secrets/actions
# (el secret debe ser el contenido base64 del kubeconfig).

$ErrorActionPreference = 'Stop'

function Assert-Found($value, $what) {
    if (-not $value) { throw "No se encontro $what en el cluster. Verificar que la Application k6-tests-rbac este Synced." }
}

# 1) Token del SA (ya lo populariza k8s en data.token cuando se crea el Secret de tipo SA-token)
$tokenB64 = (kubectl -n $Namespace get secret $TokenSecret -o jsonpath='{.data.token}' 2>$null)
Assert-Found $tokenB64 "el data.token del Secret $TokenSecret"
$token = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($tokenB64))

# 2) Server + CA del cluster actual (los toma del kubeconfig local activo)
$ctxName     = (kubectl config current-context)
$ctxJson     = (kubectl config view --raw -o json | ConvertFrom-Json)
$contextEntry = $ctxJson.contexts | Where-Object { $_.name -eq $ctxName }
$clusterName  = $contextEntry.context.cluster
$clusterEntry = $ctxJson.clusters | Where-Object { $_.name -eq $clusterName }

$server = $clusterEntry.cluster.server
$ca     = $clusterEntry.cluster.'certificate-authority-data'
Assert-Found $server "el server del cluster"
Assert-Found $ca     "el certificate-authority-data del cluster"

$kubeconfig = @"
apiVersion: v1
kind: Config
clusters:
  - name: target
    cluster:
      server: $server
      certificate-authority-data: $ca
contexts:
  - name: k6-runner
    context:
      cluster: target
      namespace: $Namespace
      user: $ServiceAccount
current-context: k6-runner
users:
  - name: $ServiceAccount
    user:
      token: $token
"@

if ($Base64) {
    [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($kubeconfig))
} else {
    $kubeconfig
}
