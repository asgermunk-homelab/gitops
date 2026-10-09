<#
.SYNOPSIS
  Adds a new app with a dev and a prod environment to this gitops repository.

.DESCRIPTION
  Copies templates/app/ with __APP__ replaced by the app name:
    apps/base/<app>/, apps/dev/<app>/, apps/prod/<app>/,
    infrastructure/image-automation/<app>.yaml
  and adds the app to the three kustomization.yaml lists.

  Dev:  https://<app>-dev.lab.munkcloud.dk  (tailnet only)
  Prod: https://<app>.lab.munkcloud.dk      (tailnet only)
        https://<app>.munkcloud.dk          (public, only with -Public, set up in Cloudflare)

  KEEP THIS SCRIPT AND templates/app/ CURRENT. When a feature is added that every
  app needs (database, ExternalSecret, OpenTelemetry, NetworkPolicy, ...), add it
  to the templates in the same pull request. See templates/README.md.

.EXAMPLE
  ./new-app.ps1 orders-api
  ./new-app.ps1 orders-api -Public
#>
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidatePattern('^[a-z][a-z0-9-]{1,40}[a-z0-9]$')]
    [string]$Name,

    # Print the Cloudflare steps that make prod public through the tunnel.
    [switch]$Public
)

$ErrorActionPreference = 'Stop'
$Org = 'asgermunk-homelab'
$Root = $PSScriptRoot
$Templates = Join-Path $Root 'templates/app'
$Utf8 = New-Object System.Text.UTF8Encoding($false)   # no BOM

function Write-Text([string]$Path, [string]$Text) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}

# Adds "  - <entry>" to the resources list at the end of a kustomization.yaml.
function Add-Resource([string]$File, [string]$Entry) {
    $text = [IO.File]::ReadAllText($File)
    if ($text -match "(?m)^\s+-\s+$([regex]::Escape($Entry))\s*$") { return }
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    [IO.File]::WriteAllText($File, $text + "  - $Entry`n", $Utf8)
}

# Finds the newest <run>-<sha>-<unix time>-<env> tag on GHCR (anonymous, public packages only).
function Get-NewestTag([string]$Env) {
    try {
        $token = (Invoke-RestMethod "https://ghcr.io/token?scope=repository:${Org}/${Name}:pull").token
        $tags = (Invoke-RestMethod "https://ghcr.io/v2/$Org/$Name/tags/list" -Headers @{ Authorization = "Bearer $token" }).tags
        $tags | Where-Object { $_ -match "^\d+-[a-f0-9]+-(\d+)-$Env$" } |
            Sort-Object { [long]($_ -replace "^\d+-[a-f0-9]+-(\d+)-$Env$", '$1') } |
            Select-Object -Last 1
    } catch { $null }
}

# 1. Stop if the app exists.
$targets = @(
    "apps/base/$Name", "apps/dev/$Name", "apps/prod/$Name",
    "infrastructure/image-automation/$Name.yaml"
) | ForEach-Object { Join-Path $Root $_ }
$existing = $targets | Where-Object { Test-Path $_ }
if ($existing) { throw "The app '$Name' exists already: $($existing -join ', ')" }

# 2. Find the image tags. A placeholder works too: Flux replaces it after the first build.
$tags = @{}
foreach ($env in 'dev', 'prod') {
    $tag = Get-NewestTag $env
    if ($tag) {
        Write-Host "Found $env tag on GHCR: $tag"
    } else {
        $tag = "0-00000000-0-$env"
        Write-Warning "No $env tag on GHCR for $Name. Placeholder '$tag' is used. The $env pod cannot start until the first $env image exists; then Flux writes the real tag."
    }
    $tags[$env] = $tag
}

# 3. Copy the templates.
$map = @{
    'base'                    = "apps/base/$Name"
    'dev'                     = "apps/dev/$Name"
    'prod'                    = "apps/prod/$Name"
    'image-automation.yaml'   = "infrastructure/image-automation/$Name.yaml"
}
foreach ($src in $map.Keys) {
    $from = Join-Path $Templates $src
    $to = Join-Path $Root $map[$src]
    $files = if (Test-Path $from -PathType Container) { Get-ChildItem $from -File } else { Get-Item $from }
    foreach ($f in $files) {
        $text = [IO.File]::ReadAllText($f.FullName)
        $text = $text.Replace('__APP__', $Name).Replace('__DEV_TAG__', $tags['dev']).Replace('__PROD_TAG__', $tags['prod'])
        $dest = if (Test-Path $from -PathType Container) { Join-Path $to $f.Name } else { $to }
        Write-Text $dest $text
        Write-Host "Wrote $($dest.Substring($Root.Length + 1))"
    }
}

# 4. Add the app to the lists.
Add-Resource (Join-Path $Root 'apps/dev/kustomization.yaml') $Name
Add-Resource (Join-Path $Root 'apps/prod/kustomization.yaml') $Name
Add-Resource (Join-Path $Root 'infrastructure/image-automation/kustomization.yaml') "$Name.yaml"

# 5. Check that everything builds.
if (Get-Command kubectl -ErrorAction SilentlyContinue) {
    foreach ($dir in 'apps/dev', 'apps/prod', 'infrastructure/image-automation') {
        kubectl kustomize (Join-Path $Root $dir) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "kubectl kustomize failed for $dir" }
    }
    Write-Host "kubectl kustomize: OK"
}

# 6. The manual steps.
Write-Host ""
Write-Host "Done. Next steps:" -ForegroundColor Green
Write-Host "  1. Commit on a branch, open a PR, squash merge."
Write-Host "  2. Repo $Org/$Name : copy .github/workflows/build.yml from hello-api, import the main ruleset,"
Write-Host "     and create the Environment 'prod' with yourself as the required reviewer."
Write-Host "  3. After the first build: set the GHCR package $Name to PUBLIC (Package settings)."
Write-Host "  4. Dev:  https://$Name-dev.lab.munkcloud.dk   Prod: https://$Name.lab.munkcloud.dk  (tailnet, no DNS step)"
if ($Public) {
    Write-Host "  5. Public prod (Cloudflare, ask Claude to do it through the MCP):" -ForegroundColor Yellow
    Write-Host "     - Tunnel 'homelab': add  $Name.munkcloud.dk -> http://$Name.prod.svc.cluster.local:80  before the 404 rule"
    Write-Host "     - DNS: CNAME $Name -> 42f50a96-91f8-43e9-bf83-175dee81b4e6.cfargotunnel.com, proxied"
    Write-Host "     - Never route a dev Service through the tunnel."
}
