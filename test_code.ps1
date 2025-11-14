# --- 1. Definición de Filtros de Exclusión (Ajustado para Edge/Microsoft y Discos) ---
$SystemDrive = $env:SystemDrive

# DIRECTORIOS DE EXCLUSIÓN: Solo se excluyen si están en el disco del sistema ($SystemDrive).
$WindowsPaths = @(
    "$SystemDrive\Windows\",
    "$SystemDrive\Program Files\Windows NT\",
    "$SystemDrive\Program Files\Common Files\",
    "$SystemDrive\Program Files (x86)\Common Files\",
    "$SystemDrive\Program Files\Hyper-V",
    "$SystemDrive\Program Files\Microsoft\",
    "$SystemDrive\Program Files (x86)\Microsoft\",
    "$SystemDrive\Program Files\WindowsApps\",
    "$SystemDrive\Users\"
)

# --- 2. Recolección de Información del Servidor (Datos Fijos para CSV) ---
Write-Host "## 🌐 Recolectando Información del Servidor..." -ForegroundColor Cyan

try {
    $DomainInfo = Get-CimInstance -ClassName Win32_ComputerSystem
    $ServerName = $DomainInfo.Name
    $Domain = $DomainInfo.Domain
    if ($Domain -eq $null -or $Domain -eq "") { $Domain = "WORKGROUP (No unido a dominio)" }
    $IPAddresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "Loopback*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -ExpandProperty IPAddress -Unique
    $ServerIP = $IPAddresses -join ', '
    
    Write-Host "   - Servidor: $ServerName" -ForegroundColor Green
    Write-Host "   - Dominio: $Domain" -ForegroundColor Green
    Write-Host "   - IP(s): $ServerIP" -ForegroundColor Green

} catch {
    Write-Host "   - Error al obtener información de red: $($_.Exception.Message)" -ForegroundColor Red
    $ServerName = "Error"
    $Domain = "Error"
    $ServerIP = "Error"
}

Write-Host "`n"
Write-Host "## 🔎 Filtrando Procesos No Nativos y Buscando Puertos..." -ForegroundColor Yellow
Write-Host "---"

# --- 3. Recolección de Conexiones de Red (Compatible: netstat -ano) ---
$NetstatOutput = netstat -ano | Select-String -Pattern "TCP|UDP"
$AllProcesses = Get-Process | Select-Object -Property ProcessName, Id, Path | Where-Object {$_.Path -ne $null}
$FinalReport = @()

# --- 4. Procesamiento y Generación de Reporte ---
foreach ($Process in $AllProcesses) {
    $IsWindowsNative = $false
    
    foreach ($ExcludePath in $WindowsPaths) {
        if ($Process.Path -like "$ExcludePath*") {
            $IsWindowsNative = $true
            break
        }
    }

    if (-not $IsWindowsNative) {
        $Ports = @()
        
        $NetstatOutput | ForEach-Object {
            $Line = $_.ToString().Trim()
            $Parts = $Line -split "\s+"
            
            if ($Parts[-1] -eq $Process.Id) {
                $Protocol = $Parts[0]
                $Port = $Parts[2] -split ":" | Select-Object -Last 1
                $Ports += "$Protocol/$Port"
            }
        }
        
        $UniquePorts = $Ports | Select-Object -Unique

        # Construir el objeto de salida con el schema solicitado
        $FinalReport += [PSCustomObject]@{
            'Nombre del servidor'          = $ServerName
            'Nombre del dominio'           = $Domain
            'IP del servidor'              = $ServerIP
            'Nombre del proceso (Exe)'     = $Process.ProcessName
            'PID'                          = $Process.Id
            'Directorio Raiz Estimado'     = Split-Path -Path $Process.Path -Parent
            'Ruta completa del binario'    = $Process.Path
            'Puertos (TCP/UDP)'            = if ($UniquePorts.Count -gt 0) { $UniquePorts -join ', ' } else { "N/A o No Escuchando" }
        }
    }
}

# --- 5. Exportación a CSV (Cambio de Ruta) ---

# Define la ruta de salida a la carpeta Documentos del usuario
$OutputDirectory = "$env:USERPROFILE\Documents"
$OutputFileName = "Auditoria_Servicios_No_Nativos_$($ServerName)_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$FullOutputPath = Join-Path -Path $OutputDirectory -ChildPath $OutputFileName

# Exportar el reporte
$FinalReport | Export-Csv -Path $FullOutputPath -NoTypeInformation -Encoding UTF8 -Delimiter ';'

Write-Host "`n"
Write-Host "## ✅ Tarea Completada" -ForegroundColor Green
Write-Host "El informe de auditoría se ha guardado exitosamente." -ForegroundColor Green
Write-Host "Archivo de salida:" -ForegroundColor Yellow
Write-Host $FullOutputPath -ForegroundColor Yellow
