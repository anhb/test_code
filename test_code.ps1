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
$Timestamp = Get-Date -Format yyyyMMdd_HHmmss
$TableOutputFile = "C:\InventarioBD\SQLServer_Inventory_Tables_$Timestamp.csv"
$ColumnOutputFile = "C:\InventarioBD\SQLServer_Inventory_Columns_$Timestamp.csv"
$LogFile = "C:\InventarioBD\SQLServer_Inventory_$Timestamp.log"

# Variables to store results
$GlobalTableInventory = @()
$GlobalColumnInventory = @()

# Load the .NET Assembly for SQL Server connectivity
Add-Type -AssemblyName System.Data


# --- 2. SQL CLIENT QUERY & LOGGING FUNCTIONS ---

function Write-InventoryLog {
    param([string]$Message)
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$Timestamp - $Message" | Out-File -FilePath $LogFile -Append
}

function Invoke-SqlClientQuery {
    param(
        [Parameter(Mandatory=$true)][string]$CurrentDB, 
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][switch]$IsCountQuery
    )
    
    # Building the connection string
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
            return $SqlCommand.ExecuteScalar()
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
        return "ERROR: Connection or Query failed. Full Message: $($_.Exception.Message)"
    } finally {
        if ($SqlConnection -ne $null -and $SqlConnection.State -eq [System.Data.ConnectionState]::Open) {
            $SqlConnection.Close()
        }
    }
}


# --- 3. MAIN INVENTORY EXECUTION ---

# Create log directory if it doesn't exist
$OutputDir = Split-Path $TableOutputFile -Parent
if (-not (Test-Path $OutputDir)) {
    New-Item -Path $OutputDir -ItemType Directory | Out-Null
}
Write-InventoryLog "--- Inventory started for $SqlServerInstance ---"

# 3.1. Get Server Version and Initial Status
$VersionQuery = "SELECT @@VERSION AS Version"
$ServerInfo = Invoke-SqlClientQuery -CurrentDB $DatabaseName -Query $VersionQuery

if ($ServerInfo -is [string] -and $ServerInfo.StartsWith("ERROR:")) {
    Write-Error "Server connection failed. Check log file for details."
    Write-InventoryLog "FATAL: Server connection failed to $SqlServerInstance. Error: $($ServerInfo)"
    return
}

$SqlServerVersion = ($ServerInfo[0].Version.Split("`n"))[0].Trim() 
$ServerInstanceName = $SqlServerInstance # Storing the instance name for CSV
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

    # Query 1: Get all tables and schemas, including type (BASE TABLE, VIEW, etc.)
    $TablesQuery = @"
    SELECT
        t.TABLE_SCHEMA AS SchemaName,
        t.TABLE_NAME AS TableName,
        t.TABLE_TYPE AS TableType
    FROM
        INFORMATION_SCHEMA.TABLES t
    WHERE
        t.TABLE_SCHEMA NOT IN ('INFORMATION_SCHEMA', 'sys', 'guest', 'cdc')
    ORDER BY SchemaName, TableName;
"@

    $Tables = Invoke-SqlClientQuery -CurrentDB $CurrentDBName -Query $TablesQuery
    
    if ($Tables -is [string] -and $Tables.StartsWith("ERROR:")) {
        Write-Warning "   Skipping database $CurrentDBName due to error. Details logged."
        Write-InventoryLog "ERROR: Skipping database $CurrentDBName. Likely permissions issue. Error: $($Tables)"
        
        $GlobalTableInventory += New-Object PSObject -Property @{
            Version = $SqlServerVersion; ServerName = $ServerInstanceName; DatabaseName = $CurrentDBName; Status = "Access Denied";
            HasData = "N/A"; TableType = "N/A"; TableName = "N/A"; SchemaName = "N/A"
        }
        continue 
    }

    # Query 2: Get all column information for the current database
    # Added Version and ServerName to the SELECT query output for the Column Inventory
    $ColumnsQuery = @"
    SELECT
        '$SqlServerVersion' AS Version,
        '$ServerInstanceName' AS ServerName,
        '$CurrentDBName' AS DatabaseName,
        c.TABLE_SCHEMA AS SchemaName,
        c.TABLE_NAME AS TableName,
        c.COLUMN_NAME AS ColumnName,
        c.ORDINAL_POSITION AS OrdinalPosition,
        c.DATA_TYPE AS DataType,
        c.CHARACTER_MAXIMUM_LENGTH AS MaxLength,
        c.IS_NULLABLE AS IsNullable
    FROM
        INFORMATION_SCHEMA.COLUMNS c
    WHERE
        c.TABLE_SCHEMA NOT IN ('INFORMATION_SCHEMA', 'sys', 'guest', 'cdc')
    ORDER BY SchemaName, TableName, OrdinalPosition;
"@
    $Columns = Invoke-SqlClientQuery -CurrentDB $CurrentDBName -Query $ColumnsQuery
    
    if ($Columns -is [string] -and $Columns.StartsWith("ERROR:")) {
         Write-InventoryLog "WARNING: Could not retrieve column details for $CurrentDBName. Error: $($Columns)"
    } else {
        $GlobalColumnInventory += $Columns
    }


    # Iterate over each Table for row count (only for BASE TABLE)
    foreach ($Table in $Tables) {
        $Schema = $Table.SchemaName
        $TableName = $Table.TableName
        $TableType = $Table.TableType
        $Status = "Connected"
        $HasData = "N/A"

        if ($TableType -eq 'BASE TABLE') {
            # Query 3: Check for data (Row Count)
            $CountQuery = "SELECT COUNT_BIG(*) FROM [$Schema].[$TableName];"
            $RowCount = Invoke-SqlClientQuery -CurrentDB $CurrentDBName -Query $CountQuery -IsCountQuery
            
            if ($RowCount -is [string] -and $RowCount.StartsWith("ERROR:")) {
                Write-InventoryLog "WARNING: Could not count rows in $CurrentDBName.$Schema.$TableName. Skipping row count. Error: $($RowCount)"
                $Status = "Connected (No Count Permission)"
            } else {
                $HasData = if ($RowCount -gt 0) { "Yes" } else { "No" }
            }
        }
        
        # Create the final table object with new ServerName property
        $TableObject = New-Object PSObject -Property @{
            Version = $SqlServerVersion;
            ServerName = $ServerInstanceName; # New property
            DatabaseName = $CurrentDBName;
            Status = $Status;
            TableType = $TableType; 
            SchemaName = $Schema;
            TableName = $TableName;
            HasData = $HasData;
        }
        
        $GlobalTableInventory += $TableObject
    }
}


# --- 4. EXPORT RESULTS TO CSV ---

if ($GlobalTableInventory.Count -gt 0) {
    
    # 4.1 Export TABLES Inventory: ServerName added after Version
    $TableCsvProperties = @(
        'Version', 
        'ServerName', # New position
        'DatabaseName', 
        'Status', 
        'TableType', 
        'SchemaName', 
        'TableName',
        'HasData'
    )
    $GlobalTableInventory | Select-Object -Property $TableCsvProperties | Export-Csv -Path $TableOutputFile -NoTypeInformation -Delimiter ','
    Write-InventoryLog "SUCCESS: Tables inventory exported to $TableOutputFile."
    Write-Host "`n✅ Tables Inventory exported to: $TableOutputFile" -ForegroundColor Green

    # 4.2 Export COLUMNS Inventory: Version and ServerName are included in the SELECT query and implicitly ordered here
    if ($GlobalColumnInventory.Count -gt 0) {
        $ColumnCsvProperties = @(
            'Version', # New position
            'ServerName', # New position
            'DatabaseName',
            'SchemaName',
            'TableName',
            'ColumnName',
            'OrdinalPosition',
            'DataType',
            'MaxLength',
            'IsNullable'
        )
        $GlobalColumnInventory | Select-Object -Property $ColumnCsvProperties | Export-Csv -Path $ColumnOutputFile -NoTypeInformation -Delimiter ','
        Write-InventoryLog "SUCCESS: Columns inventory exported to $ColumnOutputFile."
        Write-Host "✅ Columns Inventory exported to: $ColumnOutputFile" -ForegroundColor Green
    } else {
        Write-Warning "⚠️ Warning: No column records were found to export."
        Write-InventoryLog "WARNING: No column records were found to export."
    }

    Write-InventoryLog "--- Inventory finished. Total table records: $($GlobalTableInventory.Count) ---"
    Write-Host "Check log file for errors: $LogFile" -ForegroundColor Yellow

} else {
    Write-Warning "`n⚠️ Warning: No table records were found to export."
    Write-InventoryLog "WARNING: No table records were found to export."
}
