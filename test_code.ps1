# ------------------------------------------------------------------------------------------------
# EJEMPLO: Conexión a SQL Server usando el Proveedor Nativo .NET (SqlClient)
# ------------------------------------------------------------------------------------------------

# --- 1. Definición de Parámetros ---

# *********************************************************************************************
# IMPORTANTE: Modifica estos valores con tu configuración.
# *********************************************************************************************
$SqlServerInstance = "TU_SERVIDOR\NOMBRE_DE_INSTANCIA" 
$DatabaseName = "master" 
$UseWindowsAuth = $true # Establecer a $false si usas Autenticación SQL
$SqlUser = "usuario_sql" # Solo necesario si $UseWindowsAuth es $false
$SqlPass = "tu_contraseña"  # Solo necesario si $UseWindowsAuth es $false
$Query = "SELECT name AS NombreBD, state_desc AS Estado FROM sys.databases WHERE database_id > 4;" 

# --- 2. Cargar el Assembly de .NET ---

# Esto hace que las clases de conexión a datos de SQL Server estén disponibles.
Add-Type -AssemblyName System.Data

# --- 3. Crear la Cadena de Conexión ---

if ($UseWindowsAuth) {
    # Usar la identidad actual de Windows (Autenticación Integrada)
    $ConnectionString = "Server=$SqlServerInstance;Database=$DatabaseName;Integrated Security=True;"
} else {
    # Usar Autenticación de SQL Server
    $ConnectionString = "Server=$SqlServerInstance;Database=$DatabaseName;User ID=$SqlUser;Password=$SqlPass;"
}

# --- 4. Inicializar y Ejecutar la Conexión ---

# Crear el objeto de conexión
$SqlConnection = New-Object System.Data.SqlClient.SqlConnection
$SqlConnection.ConnectionString = $ConnectionString

try {
    Write-Host "Intentando conectar a la instancia $SqlServerInstance..." -ForegroundColor Cyan
    
    # Abrir la conexión
    $SqlConnection.Open()
    Write-Host "Conexión establecida con éxito." -ForegroundColor Green
    
    # Crear el objeto de comando
    $SqlCommand = New-Object System.Data.SqlClient.SqlCommand
    $SqlCommand.Connection = $SqlConnection
    $SqlCommand.CommandText = $Query
    
    # Ejecutar el lector de datos
    $SqlReader = $SqlCommand.ExecuteReader()
    
    # --- 5. Procesar los Resultados ---
    
    $Results = @()
    while ($SqlReader.Read()) {
        $Row = New-Object PSObject
        # Obtener los datos por el nombre de la columna o el índice
        $Row | Add-Member -MemberType NoteProperty -Name "NombreBD" -Value $SqlReader.Item("NombreBD")
        $Row | Add-Member -MemberType NoteProperty -Name "Estado" -Value $SqlReader.Item("Estado")
        $Results += $Row
    }
    
    $SqlReader.Close()
    
    # Mostrar el resultado en formato de tabla de PowerShell
    if ($Results) {
        Write-Host "`nResultados de la consulta:" -ForegroundColor Yellow
        $Results | Format-Table -AutoSize
    } else {
        Write-Warning "La consulta no devolvió resultados."
    }

} catch {
    Write-Error "Error de conexión o consulta: $($_.Exception.Message)"
} finally {
    # Cerrar y liberar la conexión siempre
    if ($SqlConnection -ne $null -and $SqlConnection.State -eq [System.Data.ConnectionState]::Open) {
        $SqlConnection.Close()
    }
}
