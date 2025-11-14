# --- 1. Definición de Filtros ---
$ExcludeAccounts = "LocalSystem", "NT Authority", "NetworkService", "LocalService", "System"
$WindowsPath = "C:\Windows\"

# --- 2. Recolección de Información del Servidor (IP y Dominio) ---
Write-Host "## 🌐 Información del Servidor" -ForegroundColor Cyan
try {
    # Obtener el nombre de dominio (si está unido a uno)
    $DomainInfo = Get-CimInstance -ClassName Win32_ComputerSystem
    $Domain = $DomainInfo.Domain
    if ($Domain -eq $null -or $Domain -eq "") {
        $Domain = "WORKGROUP (No unido a dominio)"
    }

    # Obtener la(s) dirección(es) IP
    $IPAddresses = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notlike "Loopback*" -and $_.IPAddress -notlike "169.254.*" } | Select-Object -ExpandProperty IPAddress -Unique

    Write-Host "   - Nombre del Servidor: $($DomainInfo.Name)" -ForegroundColor Green
    Write-Host "   - Dominio/Grupo: $Domain" -ForegroundColor Green
    Write-Host "   - IP(s) Activa(s): $($IPAddresses -join ', ')" -ForegroundColor Green

} catch {
    Write-Host "   - Error al obtener información de red: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host "`n"
Write-Host "## ⚙️ Servicios No Nativos con Detalle de Ejecución y Puertos" -ForegroundColor Yellow
Write-Host "---"

# --- 3. Recolección y Filtrado de Servicios ---

# Obtener todos los servicios junto con su PathName (Comando de Ejecución)
$AllServices = Get-Service |
    Select-Object -Property Name, DisplayName, ServiceAccount, Status, @{Name='PathName';Expression={(Get-WmiObject -Class Win32_Service -Filter "Name='$($_.Name)'").PathName}},
                                                                    @{Name='PID';Expression={(Get-WmiObject -Class Win32_Service -Filter "Name='$($_.Name)'").ProcessId}} |
    Where-Object {
        # Filtro: NO es una cuenta de sistema Y NO está en la ruta de Windows
        -not ($ExcludeAccounts | Where-Object { $_ -eq $_.PathName -or $_ -like "*$($_.ServiceAccount)*" }) -and ($null -ne $_.PathName -and $_.PathName -notlike "*$WindowsPath*")
    }

# --- 4. Procesamiento y Salida de Puertos (Requiere elevación, que ya se debe tener) ---

$NonWindowsServicesDetails = @()

foreach ($Service in $AllServices) {
    $Ports = @()

    if ($Service.PID -ne 0) {
        # Usar Get-NetTCPConnection y Get-NetUDPConnection para encontrar los puertos asociados al PID
        $Connections = Get-NetTCPConnection -OwningProcess $Service.PID -ErrorAction SilentlyContinue
        $Connections += Get-NetUDPConnection -OwningProcess $Service.PID -ErrorAction SilentlyContinue

        if ($Connections.Count -gt 0) {
            $Connections | ForEach-Object {
                $Protocol = $_.Protocol
                $LocalPort = $_.LocalPort
                $Ports += "$Protocol/$LocalPort"
            }
        }
    }

    # Construir el objeto de salida
    $NonWindowsServicesDetails += [PSCustomObject]@{
        'Nombre del Servicio'        = $Service.Name
        'Comando de Ejecución'       = $Service.PathName
        'PID'                        = $Service.PID
        'Puertos (TCP/UDP)'          = if ($Ports.Count -gt 0) { $Ports -join ', ' } else { "N/A o No Escuchando" }
        'Directorio Raíz Estimado'   = Split-Path -Path $Service.PathName -Parent
    }
}

# Mostrar los resultados
$NonWindowsServicesDetails | Format-Table -AutoSize
