# Verificación del sistema Nexo en AWS (evidencias para el informe y la demo).
# Uso (PowerShell, desde la carpeta del repo):
#   powershell -ExecutionPolicy Bypass -File .\scripts\verificar-aws.ps1
# La clave se lee de $HOME\.ssh\nexo-api-key.txt (no se muestra en pantalla).
param(
    [string]$Url = "https://3-215-113-161.sslip.io",
    [string]$ArchivoClave = "$HOME\.ssh\nexo-api-key.txt"
)

$ErrorActionPreference = "Stop"
if (-not (Test-Path $ArchivoClave)) { throw "No existe $ArchivoClave" }
$clave = (Get-Content $ArchivoClave -Raw).Trim()
$tmp = Join-Path $env:TEMP "nexo-verificacion"
New-Item -ItemType Directory -Force $tmp | Out-Null
$script:ok = 0; $script:fallas = 0

function Llamar([string[]]$argumentos) {
    $cuerpo = Join-Path $tmp "cuerpo.txt"
    $codigo = & curl.exe -s -o $cuerpo -w "%{http_code}" --max-time 40 @argumentos
    $texto = if (Test-Path $cuerpo) { (Get-Content $cuerpo -Raw -Encoding UTF8) } else { "" }
    return @{ codigo = "$codigo"; cuerpo = "$texto" }
}

function Revisar([string]$nombre, [string]$esperado, $r) {
    $resumen = ($r.cuerpo -replace "\s+", " ")
    if ($resumen.Length -gt 140) { $resumen = $resumen.Substring(0, 140) + "..." }
    if ($r.codigo -match "^($esperado)$") {
        $script:ok++; Write-Host ("OK    {0,-48} {1}  {2}" -f $nombre, $r.codigo, $resumen) -ForegroundColor Green
    } else {
        $script:fallas++; Write-Host ("FALLA {0,-48} {1} (esperado {2})  {3}" -f $nombre, $r.codigo, $esperado, $resumen) -ForegroundColor Red
    }
}

$H = @("-H", "X-API-Key: $clave")
$J = @("-H", "Content-Type: application/json")

Write-Host "`n== Sistema en $Url" -ForegroundColor Cyan
Revisar "GET /health (gateway)" "200" (Llamar @("$Url/health"))
Revisar "GET /api/health (pública)" "200" (Llamar @("$Url/api/health"))
Revisar "GET / (front)" "200" (Llamar @("$Url/"))
Revisar "GET /docs (OpenAPI, pública)" "200" (Llamar @("$Url/docs"))
Revisar "GET /dashboard (front)" "200" (Llamar @("$Url/dashboard"))

Write-Host "`n== Autenticación X-API-Key (401)" -ForegroundColor Cyan
Revisar "POST /api/predict sin clave" "401" (Llamar @("-X", "POST", "$Url/api/predict"))
Revisar "POST /api/predict con clave incorrecta" "401" (Llamar @("-X", "POST", "-H", "X-API-Key: clave-incorrecta-000000", "$Url/api/predict"))
Revisar "POST /api/campanas/U1 sin clave" "401" (Llamar @("-X", "POST", "$Url/api/campanas/U1"))
Revisar "GET /api/predicciones/x sin clave" "401" (Llamar @("$Url/api/predicciones/x"))

Write-Host "`n== Predicción con el modelo propio" -ForegroundColor Cyan
$usuarios = Llamar (@("$Url/api/dominio/usuarios") + $H)
$usuario = (($usuarios.cuerpo | ConvertFrom-Json) | Select-Object -First 1).usuario_id
Write-Host "Usuario de prueba: $usuario"
$cuerpo = Join-Path $tmp "predict.json"
Set-Content -Path $cuerpo -Value "{`"usuario_id`":`"$usuario`",`"categoria`":`"Audio`"}" -Encoding ascii -NoNewline
Revisar "POST /api/predict con clave" "200" (Llamar (@("-X", "POST", "--data-binary", "@$cuerpo", "$Url/api/predict") + $H + $J))
Set-Content -Path $cuerpo -Value "{}" -Encoding ascii -NoNewline
Revisar "POST /api/predict entrada inválida -> 422" "422" (Llamar (@("-X", "POST", "--data-binary", "@$cuerpo", "$Url/api/predict") + $H + $J))

Write-Host "`n== Réplicas del dominio (X-Upstream)" -ForegroundColor Cyan
Set-Content -Path $cuerpo -Value "{`"usuario_id`":`"$usuario`",`"categoria`":`"Audio`"}" -Encoding ascii -NoNewline
$replicas = 1..4 | ForEach-Object {
    (& curl.exe -s -D - -o NUL -X POST --data-binary "@$cuerpo" -H "X-API-Key: $clave" -H "Content-Type: application/json" "$Url/api/predict" |
        Select-String -Pattern "^x-upstream:" -CaseSensitive:$false | Select-Object -First 1).ToString().Trim()
}
$replicas | ForEach-Object { Write-Host "  $_" }

Write-Host "`n== Tamaño máximo (413)" -ForegroundColor Cyan
$grande = Join-Path $tmp "grande.txt"
[IO.File]::WriteAllText($grande, ("a" * 1500000))
Revisar "POST /api/predict con 1,5 MB" "413" (Llamar (@("-X", "POST", "--data-binary", "@$grande", "$Url/api/predict") + $H))

Write-Host "`n== Campaña con el LLM (worker + RabbitMQ)" -ForegroundColor Cyan
$campana = Llamar (@("-X", "POST", "$Url/api/campanas/$usuario") + $H + $J + @("-d", "{}"))
Revisar "POST /api/campanas/{usuario} con clave" "202" $campana
$job = ($campana.cuerpo | ConvertFrom-Json).job_id
if ($job) {
    $listo = $null
    for ($i = 0; $i -lt 15 -and -not $listo; $i++) {
        Start-Sleep -Seconds 2
        $r = Llamar (@("$Url/api/predicciones/$job") + $H)
        if ($r.codigo -eq "200") { $listo = $r }
    }
    if ($listo) {
        $d = $listo.cuerpo | ConvertFrom-Json
        $estado = if ($d.degradado) { "MODO DEGRADADO" } else { "texto del LLM" }
        Revisar "GET /api/predicciones/{job_id} ($estado)" "200" $listo
        Write-Host "  Asunto: $($d.asunto)"
        Write-Host "  Mensaje: $($d.mensaje)"
    } else {
        $script:fallas++; Write-Host "FALLA el mensaje del LLM no llegó en 30 s" -ForegroundColor Red
    }
}

Write-Host "`n== Rate limiting (429): 40 peticiones seguidas" -ForegroundColor Cyan
$codigos = 1..40 | ForEach-Object { & curl.exe -s -o NUL -w "%{http_code}" -H "X-API-Key: $clave" "$Url/api/predicciones/x" }
$n429 = ($codigos | Where-Object { $_ -eq "429" }).Count
if ($n429 -gt 0) { $script:ok++; Write-Host "OK    $n429 de 40 peticiones recibieron 429" -ForegroundColor Green }
else { $script:fallas++; Write-Host "FALLA ninguna petición recibió 429" -ForegroundColor Red }

Write-Host "`nResultado: $($script:ok) OK, $($script:fallas) fallas" -ForegroundColor Cyan
