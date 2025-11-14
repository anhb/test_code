# --- 1. Definición de Filtros de Exclusión (Compatibilidad y Exclusión de Edge) ---

# Obtener la letra del disco donde está instalado Windows (e.g., C:)
$SystemDrive = $env:SystemDrive

# DIRECTORIOS DE EXCLUSIÓN: Solo se excluyen si están en el disco del sistema ($SystemDrive).
$WindowsPaths = @(
    "$SystemDrive\Windows\",
    "$SystemDrive\Program Files\Windows NT\",
    "$SystemDrive\Program Files\Common Files\",
    "$SystemDrive\Program Files (x86)\Common Files\",
    "$SystemDrive\Program Files\Hyper-V",
    "$SystemDrive\Program Files\Microsoft\", # Excluye Edge, Visual Studio, etc.
    "$SystemDrive\Program Files (x86)\Microsoft\", # Excluye Edge, Visual Studio, etc.
    # Excluir la carpeta de la Tienda de Windows y Apps de usuario
    "$SystemDrive\Program Files\WindowsApps\",
    "$SystemDrive\Users\"
)

# --- 2. Recolección de Información del Servidor (IP y Dominio) ---
Write-Host "## 🌐 Información del Servidor" -ForegroundColor Cyan
try {
    $DomainInfo = Get-CimInstance -ClassName Win32_ComputerSystem
    $Domain = $DomainInfo.Domain
    if ($Domain -eq $null -or $Domain -eq "") { $Domain = "WORKGROUP (No unido a dominio)" }
    $IPAddresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "Loopback*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -ExpandProperty IPAddress -Unique

    Write-Host "   - Nombre del Servidor: $($DomainInfo.Name)" -ForegroundColor Green
    Write-Host "   - Dominio/Grupo: $Domain" -ForegroundColor Green
    Write-Host "   - IP(s) Activa(s): $($IPAddresses -join ', ')" -ForegroundColor Green

} catch {
    Write-Host "   - Error al obtener información de red: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n"
Write-Host "## 🔎 Procesos / Aplicaciones / Servicios No Nativos Encontrados" -ForegroundColor Yellow
Write-Host "---"

# --- 3. Recolección de Conexiones de Red (Compatible: netstat -ano) ---

# Ejecutar netstat -ano una sola vez y guardar la tabla de conexiones activas
$NetstatOutput = netstat -ano | Select-String -Pattern "TCP|UDP"

# --- 4. Recolección y Filtrado de Procesos ---

# Obtener todos los procesos con su ruta de archivo (Path)
$AllProcesses = Get-Process | Select-Object -Property ProcessName, Id, Path | Where-Object {$_.Path -ne $null}
$NonNativeProcessesDetails = @()

foreach ($Process in $AllProcesses) {
    $IsWindowsNative = $false
    
    # Comprobar si el PathName se encuentra en alguno de los directorios de exclusión de Windows (en el disco del sistema)
    foreach ($ExcludePath in $WindowsPaths) {
        if ($Process.Path -like "$ExcludePath*") {
            $IsWindowsNative = $true
            break
        }
    }

    # Si NO es nativo, procesar
    if (-not $IsWindowsNative) {
        $Ports = @()
        
        # Buscar el PID del proceso en la salida de netstat -ano
        $NetstatOutput | ForEach-Object {
            $Line = $_.ToString().Trim()
            $Parts = $Line -split "\s+"
            
            # El último elemento del array Parts es el PID
            if ($Parts[-1] -eq $Process.Id) {
                $Protocol = $Parts[0] # TCP o UDP
                
                # El tercer elemento es la dirección local y el puerto (ej: 0.0.0.0:80)
                $Port = $Parts[2] -split ":" | Select-Object -Last 1
                
                $Ports += "$Protocol/$Port"
            }
        }
        
        # Eliminar duplicados de puertos (si un mismo PID tiene varias conexiones)
        $UniquePorts = $Ports | Select-Object -Unique

        # Construir el objeto de salida
        $NonNativeProcessesDetails += [PSCustomObject]@{
            'Nombre del Proceso (EXE)'   = $Process.ProcessName
            'PID'                        = $Process.Id
            'Directorio Raíz Estimado'   = Split-Path -Path $Process.Path -Parent
            'Ruta Completa del Binario'  = $Process.Path
            'Puertos (TCP/UDP)'          = if ($UniquePorts.Count -gt 0) { $UniquePorts -join ', ' } else { "N/A o No Escuchando" }
        }
    }
}

# Mostrar los resultados ordenados y formateados
$NonNativeProcessesDetails | Sort-Object -Property 'Nombre del Proceso (EXE)' | Format-Table -AutoSize
