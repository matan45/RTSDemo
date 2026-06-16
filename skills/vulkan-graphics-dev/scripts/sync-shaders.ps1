<#
.SYNOPSIS
  Copy edited GLSL from the source tree to the Editor (or Runtime) runtime shader path.

.DESCRIPTION
  The engine reads shaders from bin/<Target>/resources/shaders/, NOT the source
  resources/shaders/ tree. Editing source GLSL alone has no runtime effect until copied.
  This script closes that gap.

.PARAMETER Shader
  Optional. A path to a single shader, given relative to resources/shaders/
  (e.g. "gpudriven/mesh_shader_gpudriven.glsl"), or an absolute/source path.
  If omitted, the entire resources/shaders/ tree is mirrored.

.PARAMETER Runtime
  Switch. Sync into bin/Runtime/resources/shaders/ instead of bin/Editor/... .
  (Runtime path is documented-but-unverified in project memory; default is Editor.)

.EXAMPLE
  pwsh sync-shaders.ps1 gpudriven/mesh_shader_gpudriven.glsl
.EXAMPLE
  pwsh sync-shaders.ps1            # mirror the whole tree into bin/Editor
#>
param(
    [string]$Shader,
    [switch]$Runtime
)

$ErrorActionPreference = 'Stop'

# Repo root = three levels up from .claude/skills/vulkan-graphics-dev/scripts/
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$srcRoot  = Join-Path $repoRoot 'resources\shaders'
$target   = if ($Runtime) { 'Runtime' } else { 'Editor' }
$dstRoot  = Join-Path $repoRoot "bin\$target\resources\shaders"

if (-not (Test-Path $srcRoot)) {
    Write-Error "Source shader tree not found: $srcRoot"
}

function Copy-One([string]$relPath) {
    $src = Join-Path $srcRoot $relPath
    if (-not (Test-Path $src)) { Write-Error "Shader not found: $src" }
    $dst = Join-Path $dstRoot $relPath
    $dstDir = Split-Path $dst -Parent
    if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
    Copy-Item -Path $src -Destination $dst -Force
    Write-Host "  $relPath"
}

Write-Host "Syncing shaders -> bin\$target\resources\shaders"

if ($Shader) {
    # Normalize: accept rel path, absolute path, or source-tree path.
    $rel = $Shader
    if (Test-Path $Shader) {
        $full = (Resolve-Path $Shader).Path
        if ($full.StartsWith($srcRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $full.Substring($srcRoot.Length).TrimStart('\','/')
        }
    }
    $rel = $rel -replace '/', '\'
    Copy-One $rel
} else {
    $count = 0
    Get-ChildItem -Path $srcRoot -Recurse -Filter *.glsl | ForEach-Object {
        $rel = $_.FullName.Substring($srcRoot.Length).TrimStart('\','/')
        Copy-One $rel
        $count++
    }
    Write-Host "Mirrored $count shader file(s)."
}

Write-Host "Done. Relaunch the Editor for changes to take effect."
