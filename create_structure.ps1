$ErrorActionPreference = "Stop"

$projectRoot = Join-Path $PSScriptRoot "saas_ecommerce_backend"
$directories = @(
    "app",
    "app\routers",
    "app\services"
)
$files = @(
    "app\__init__.py",
    "app\main.py",
    "app\config.py",
    "app\database.py",
    "app\models.py",
    "app\schemas.py",
    "app\deps.py",
    "app\routers\__init__.py",
    "app\routers\auth.py",
    "app\routers\tenants.py",
    "app\routers\products.py",
    "app\services\tenant_service.py",
    "app\services\product_service.py",
    ".env",
    "requirements.txt",
    "README.md"
)

foreach ($directory in $directories) {
    $path = Join-Path $projectRoot $directory
    New-Item -ItemType Directory -Path $path -Force | Out-Null
}

foreach ($file in $files) {
    $path = Join-Path $projectRoot $file
    if (-not (Test-Path $path)) {
        New-Item -ItemType File -Path $path | Out-Null
    }
}

Write-Host "Project structure created at $projectRoot"
