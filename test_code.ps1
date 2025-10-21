# ------------------------------------------------------------------------------------------------
# SQL SERVER INVENTORY SCRIPT (Using native .NET Provider: SqlClient)
# ------------------------------------------------------------------------------------------------

# --- 1. CONFIGURATION ---
# *********************************************************************************************
# IMPORTANT: Modify these values
# *********************************************************************************************
$SqlServerInstance = "TU_SERVIDOR\NOMBRE_DE_INSTANCIA" 
$DatabaseName = "master" # Base database name for the initial connection (Fixed the name here)
$UseWindowsAuth = $true # Set to $false if using SQL Authentication
$SqlUser = "usuario_sql" # Only needed if $UseWindowsAuth is $false
$SqlPass = "tu_contraseña"  # Only needed if $UseWindowsAuth is $false
$OutputFile = "C:\InventarioBD\SQLServer_Inventory_$(Get-Date -Format yyyyMMdd_HHmmss).csv"
$LogFile = "C:\InventarioBD\SQLServer_Inventory_$(Get-Date -Format yyyyMMdd_HHmmss).log"

# Variable to store all results
$GlobalInventory = @()

# Load the .NET Assembly for SQL Server connectivity
Add-Type -AssemblyName System.Data


# --- 2. SQL CLIENT QUERY FUNCTION ---

function Invoke-SqlClientQuery {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentDB, 
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][switch]$IsCountQuery
    )

    if ($global:UseWindowsAuth) {
        $ConnectionString = "Server=$global:SqlServerInstance;Database=$CurrentDB;Integrated Security=True;Connection Timeout=10;"
    } else {
        $ConnectionString = "Server=$global:SqlServerInstance;Database=$CurrentDB;User ID=$global:SqlUser;Password=$global:SqlPass;Connection Timeout=10;"
    }
    
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString

    try {
        $SqlConnection.Open()
        $SqlCommand = New-Object System.Data.SqlClient.SqlCommand($Query, $SqlConnection)
        
        if ($IsCountQuery) {
            $result = $SqlCommand.ExecuteScalar()
            return $result
        }
        
        $SqlReader = $SqlCommand.ExecuteReader()
        $results = @()
        while ($SqlReader.Read()) {
            $row = New-Object PSObject
            $SqlReader.GetSchemaTable().Rows | ForEach-Object {
                $propertyName = $_.ColumnName
                $propertyValue = $SqlReader.Item($propertyName)
                $row | Add-Member -MemberType NoteProperty -Name $propertyName -Value $propertyValue -Force
            }
            $results += $row
        }
        $SqlReader.Close()
        return $results

    } catch {
        # Return a simplified error message string
        return "ERROR: Connection or Query failed. Full Message: $($_.Exception.Message)"
    } finally {
        if ($SqlConnection -ne $null -and $SqlConnection.State -eq [System.Data.ConnectionState]::Open) {
            $SqlConnection.Close()
        }
    }
}


# --- 3. MAIN INVENTORY EXECUTION ---

# Create log directory if it doesn't exist
$OutputDir = Split-Path $OutputFile -Parent
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}

function Write-InventoryLog {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp - $Message" | Out-File -FilePath $LogFile -Append
}

Write-Host "Starting SQL Server inventory for: $SqlServerInstance" -ForegroundColor Cyan
Write-InventoryLog "--- Inventory started for $SqlServerInstance ---"


# 3.1. Get Server Version and Initial Status
$VersionQuery = "SELECT @@VERSION AS Version"
$ServerInfo = Invoke-SqlClientQuery -CurrentDB $DatabaseName -Query $VersionQuery

if ($ServerInfo -is [string] -and $ServerInfo.StartsWith("ERROR:")) {
    Write-Error "Server connection failed. Check log file for details."
    Write-InventoryLog "FATAL: Server connection failed to $SqlServerInstance. Error: $($ServerInfo)"
    $GlobalInventory += New-Object PSObject -Property @{
        Technology = "SQL Server"; Version = "N/A"; DatabaseName = $DatabaseName; Status = "Server Disconnected";
        HasData = "N/A"; TableName = "N/A"; SchemaName = "N/A"
    }
    return
}

$SqlServerVersion = ($ServerInfo[0].Version.Split("`n"))[0].Trim() 
Write-Host "Found SQL Server Version: $SqlServerVersion" -ForegroundColor Yellow
Write-InventoryLog "SUCCESS: Server connected. Version: $SqlServerVersion"


# 3.2. Get List of User Databases
$DBListQuery = "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE';" 
$UserDatabases = Invoke-SqlClientQuery -CurrentDB $DatabaseName -Query $DBListQuery

if ($UserDatabases -is [string] -and $UserDatabases.StartsWith("ERROR:")) {
    Write-Error "Failed to retrieve database list."
    Write-InventoryLog "ERROR: Failed to retrieve database list from $DatabaseName. Error: $($UserDatabases)"
    return
}

# 3.3. Iterate over each Database
foreach ($DB in $UserDatabases) {
    $CurrentDBName = $DB.name
    Write-Host "  -> Processing Database: $CurrentDBName" -ForegroundColor Green

    # Query 1: Get all tables and schemas in the current database
    # The SchemaName (s.name) will explicitly return 'dbo', 'guest', or custom schema names.
    $TablesQuery = @"
    SELECT
        s.name AS SchemaName,
        t.name AS TableName
    FROM
        sys.tables t
    INNER JOIN
        sys.schemas s ON t.schema_id = s.schema_id
    WHERE
        t.is_ms_shipped = 0 
    ORDER BY SchemaName, TableName;
"@

    $Tables = Invoke-SqlClientQuery -CurrentDB $CurrentDBName -Query $TablesQuery
    
    if ($Tables -is [string] -and $Tables.StartsWith("ERROR:")) {
        Write-Warning "   Skipping database $CurrentDBName due to error. Details logged."
        Write-InventoryLog "ERROR: Skipping database $CurrentDBName. Likely permissions issue. Error: $($Tables)"
        
        $GlobalInventory += New-Object PSObject -Property @{
            Technology = "SQL Server";
            Version = $SqlServerVersion;
            DatabaseName = $CurrentDBName;
            Status = "Access Denied";
            HasData = "N/A";
            TableName = "N/A";
            SchemaName = "N/A"
        }
        continue 
    }

    # Iterate over each Table in the current Database
    foreach ($Table in $Tables) {
        $Schema = $Table.SchemaName
        $TableName = $Table.TableName

        # Query 2: Check for data (Row Count)
        $CountQuery = "SELECT COUNT_BIG(*) FROM [$Schema].[$TableName];"
        $RowCount = Invoke-SqlClientQuery -CurrentDB $CurrentDBName -Query $CountQuery -IsCountQuery
        
        # Check if CountQuery failed (e.g., table access denied)
        if ($RowCount -is [string] -and $RowCount.StartsWith("ERROR:")) {
            Write-InventoryLog "WARNING: Could not count rows in $CurrentDBName.$Schema.$TableName. Skipping row count. Error: $($RowCount)"
            $Status = "Connected (No Count Permission)"
            $HasData = "N/A"
        } else {
            $Status = "Connected"
            $HasData = if ($RowCount -gt 0) { "Yes" } else { "No" }
        }

        # Create the final object with properties in the correct order
        $TableObject = New-Object PSObject -Property @{
            Technology = "SQL Server";
            Version = $SqlServerVersion;
            DatabaseName = $CurrentDBName;
            Status = $Status;
            HasData = $HasData; # Changed order
            TableName = $TableName;
            SchemaName = $Schema # 'dbo' or custom schema
        }
        
        $GlobalInventory += $TableObject
    }
}


# --- 4. EXPORT RESULTS TO CSV ---

if ($GlobalInventory.Count -gt 0) {
    
    # Define the final property order for the CSV
    $CsvProperties = @(
        'Technology', 
        'Version', 
        'DatabaseName', 
        'Status',  
        'HasData',
        'TableName',
        'SchemaName'
    )

    # Use comma delimiter (standard for CSV) and select properties in the correct order
    $GlobalInventory | Select-Object -Property $CsvProperties | Export-Csv -Path $OutputFile -NoTypeInformation -Delimiter ','
    
    Write-InventoryLog "--- Inventory finished. Total records exported: $($GlobalInventory.Count) ---"
    Write-Host "`n✅ Success! SQL Server Inventory completed." -ForegroundColor Green
    Write-Host "Total records exported: $($GlobalInventory.Count)" -ForegroundColor Green
    Write-Host "The CSV file was saved to: $OutputFile" -ForegroundColor Green
    Write-Host "Check log file for errors: $LogFile" -ForegroundColor Yellow

} else {
    Write-Warning "`n⚠️ Warning: No table records were found to export."
    Write-InventoryLog "WARNING: No table records were found to export."
