# ------------------------------------------------------------------------------------------------
# SQL SERVER INVENTORY SCRIPT (Using native .NET Provider: SqlClient)
# ------------------------------------------------------------------------------------------------

# --- 1. CONFIGURATION ---
# *********************************************************************************************
# IMPORTANTE: Modifica estos valores
# *********************************************************************************************
$SqlServerInstance = "TU_SERVIDOR\NOMBRE_DE_INSTANCIA" 
$UseWindowsAuth = $true # Set to $false if using SQL Authentication
$SqlUser = "usuario_sql" # Only needed if $UseWindowsAuth is $false
$SqlPass = "tu_contraseña"  # Only needed if $UseWindowsAuth is $false
$MasterDbName = "master" # Connection entry point
$OutputFile = "C:\Users\YourUser\Documents\SQLServer_Inventory_$(Get-Date -Format yyyyMMdd_HHmmss).csv"

# Variable to store all results
$GlobalInventory = @()

# Load the .NET Assembly for SQL Server connectivity
Add-Type -AssemblyName System.Data


# --- 2. SQL CLIENT QUERY FUNCTION ---

function Invoke-SqlClientQuery {
    param(
        [Parameter(Mandatory=$true)][string]$DatabaseName,
        [Parameter(Mandatory=$true)][string]$Query,
        [Parameter(Mandatory=$false)][switch]$IsCountQuery
    )

    # Building the connection string based on global parameters
    if ($global:UseWindowsAuth) {
        $ConnectionString = "Server=$global:SqlServerInstance;Database=$DatabaseName;Integrated Security=True;Connection Timeout=10;"
    } else {
        $ConnectionString = "Server=$global:SqlServerInstance;Database=$DatabaseName;User ID=$global:SqlUser;Password=$global:SqlPass;Connection Timeout=10;"
    }
    
    $SqlConnection = New-Object System.Data.SqlClient.SqlConnection
    $SqlConnection.ConnectionString = $ConnectionString

    try {
        $SqlConnection.Open()
        $SqlCommand = New-Object System.Data.SqlClient.SqlCommand($Query, $SqlConnection)
        
        # If it's a simple count, return the scalar result
        if ($IsCountQuery) {
            # ExecuteScalar is faster for a single value (like COUNT)
            $result = $SqlCommand.ExecuteScalar()
            return $result
        }
        
        # Otherwise, return a dataset reader
        $SqlReader = $SqlCommand.ExecuteReader()
        $results = @()
        while ($SqlReader.Read()) {
            $row = New-Object PSObject
            # Dynamically add properties based on the query result
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
        # Return the error message or a specific string for the main script to handle status
        return "ERROR: $($_.Exception.Message)"
    } finally {
        if ($SqlConnection -ne $null -and $SqlConnection.State -eq [System.Data.ConnectionState]::Open) {
            $SqlConnection.Close()
        }
    }
}


# --- 3. MAIN INVENTORY EXECUTION ---

Write-Host "Starting SQL Server inventory for: $SqlServerInstance" -ForegroundColor Cyan

# 3.1. Get Server Version and Initial Status
$VersionQuery = "SELECT @@VERSION AS Version"
$ServerInfo = Invoke-SqlClientQuery -DatabaseName $MasterDbName -Query $VersionQuery

if ($ServerInfo -is [string] -and $ServerInfo.StartsWith("ERROR:")) {
    Write-Error "Server connection failed: $($ServerInfo)"
    $GlobalInventory += New-Object PSObject -Property @{
        Technology = "SQL Server";
        Version = "N/A";
        DatabaseName = $MasterDbName;
        Status = "Server Disconnected";
        TableName = "N/A";
        SchemaName = "N/A";
        HasData = "N/A"
    }
    # Exit script if server connection fails
    return
}

# Extract SQL Version (first line of the result)
$SqlServerVersion = ($ServerInfo[0].Version.Split("`n"))[0].Trim() 
Write-Host "Found SQL Server Version: $SqlServerVersion" -ForegroundColor Yellow


# 3.2. Get List of User Databases
$DBListQuery = "SELECT name FROM sys.databases WHERE database_id > 4 AND state_desc = 'ONLINE';" 
$UserDatabases = Invoke-SqlClientQuery -DatabaseName $MasterDbName -Query $DBListQuery

if ($UserDatabases -is [string] -and $UserDatabases.StartsWith("ERROR:")) {
    Write-Error "Failed to retrieve database list."
    return
}

# 3.3. Iterate over each Database
foreach ($DB in $UserDatabases) {
    $CurrentDBName = $DB.name
    Write-Host "  -> Processing Database: $CurrentDBName" -ForegroundColor Green

    # Query 1: Get all tables and schemas in the current database
    $TablesQuery = @"
    SELECT
        s.name AS SchemaName,
        t.name AS TableName
    FROM
        $CurrentDBName.sys.tables t
    INNER JOIN
        $CurrentDBName.sys.schemas s ON t.schema_id = s.schema_id
    WHERE
        t.is_ms_shipped = 0 
    ORDER BY SchemaName, TableName;
"@

    $Tables = Invoke-SqlClientQuery -DatabaseName $CurrentDBName -Query $TablesQuery
    
    if ($Tables -is [string] -and $Tables.StartsWith("ERROR:")) {
        Write-Error "   Error querying tables in $CurrentDBName: $($Tables)"
        $GlobalInventory += New-Object PSObject -Property @{
            Technology = "SQL Server";
            Version = $SqlServerVersion;
            DatabaseName = $CurrentDBName;
            Status = "Database Disconnected";
            TableName = "N/A";
            SchemaName = "N/A";
            HasData = "N/A"
        }
        continue # Skip to the next database
    }

    # Iterate over each Table in the current Database
    foreach ($Table in $Tables) {
        $Schema = $Table.SchemaName
        $TableName = $Table.TableName

        # Query 2: Check for data (Row Count)
        $CountQuery = "SELECT COUNT_BIG(*) FROM [$Schema].[$TableName];"
        $RowCount = Invoke-SqlClientQuery -DatabaseName $CurrentDBName -Query $CountQuery -IsCountQuery
        
        $HasData = if ($RowCount -gt 0) { "Yes" } else { "No" }
        
        # Create the final object with English properties
        $TableObject = New-Object PSObject -Property @{
            Technology = "SQL Server";
            Version = $SqlServerVersion;
            DatabaseName = $CurrentDBName;
            Status = "Connected"; # Assuming connection succeeded here
            TableName = $TableName;
            SchemaName = $Schema;
            HasData = $HasData
        }
        
        $GlobalInventory += $TableObject
        # Write-Host "     -> Table: $Schema.$TableName (Data: $HasData)" -ForegroundColor DarkGray
    }
}


# --- 4. EXPORT RESULTS TO CSV ---

if ($GlobalInventory.Count -gt 0) {
    $OutputDir = Split-Path $OutputFile -Parent
    if (-not (Test-Path $OutputDir)) {
        New-Item -Path $OutputDir -ItemType Directory | Out-Null
    }
    
    # Export to CSV with required English headers
    $GlobalInventory | Select-Object Technology, Version, DatabaseName, Status, TableName, SchemaName, HasData | Export-Csv -Path $OutputFile -NoTypeInformation -Delimiter ';'
    
    Write-Host "`n✅ Success! SQL Server Inventory completed." -ForegroundColor Green
    Write-Host "Total records exported: $($GlobalInventory.Count)" -ForegroundColor Green
    Write-Host "The CSV file was saved to: $OutputFile" -ForegroundColor Green
} else {
    Write-Warning "`n⚠️ Warning: No table records were found to export."
}
