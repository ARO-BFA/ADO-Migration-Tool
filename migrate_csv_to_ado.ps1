#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProjectUrl,

    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    [string]$Pat,

    [double]$Timeout = 60,

    [switch]$DryRun,

    [switch]$StopOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$API_VERSION = "7.1"
$COMMENTS_VERSION = "7.1-preview.4"
$CHILD_REL = "System.LinkTypes.Hierarchy-Forward"

function Write-Notice {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Throw-MigrationError {
    param([string]$Message)
    throw [System.InvalidOperationException]::new($Message)
}

function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[[string]$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += @(ConvertTo-Hashtable -InputObject $item)
        }
        return $list
    }

    if ($InputObject -is [pscustomobject]) {
        $result = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
        }
        return $result
    }

    return $InputObject
}

function Resolve-ScriptRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $basePath -ChildPath $Path))
}

function Get-UniqueCsvHeaders {
    param([Parameter(Mandatory = $true)][string[]]$Headers)

    $counts = @{}
    $unique = @()

    for ($i = 0; $i -lt $Headers.Count; $i++) {
        $raw = [string]$Headers[$i]
        $name = $raw.Trim()
        if ($i -eq 0) {
            $name = $name.TrimStart([char]0xFEFF)
        }
        if (-not $name) {
            $name = "Column{0}" -f ($i + 1)
        }

        if (-not $counts.ContainsKey($name)) {
            $counts[$name] = 1
            $unique += $name
            continue
        }

        $counts[$name] = [int]$counts[$name] + 1
        $resolved = "{0}_{1}" -f $name, $counts[$name]
        while ($counts.ContainsKey($resolved)) {
            $counts[$name] = [int]$counts[$name] + 1
            $resolved = "{0}_{1}" -f $name, $counts[$name]
        }
        $counts[$resolved] = 1
        $unique += $resolved
        Write-Notice ("Duplicate CSV column '{0}' renamed to '{1}'" -f $name, $resolved)
    }

    return $unique
}

function Read-CsvRows {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        Throw-MigrationError ("CSV file not found: {0}" -f $Path)
    }

    Add-Type -AssemblyName Microsoft.VisualBasic
    $parser = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Path)
    $parser.TextFieldType = [Microsoft.VisualBasic.FileIO.FieldType]::Delimited
    $parser.SetDelimiters(",")
    $parser.HasFieldsEnclosedInQuotes = $true
    $parser.TrimWhiteSpace = $false

    try {
        if ($parser.EndOfData) {
            return @()
        }

        $rawHeaders = $parser.ReadFields()
        if (-not $rawHeaders -or $rawHeaders.Count -eq 0) {
            Throw-MigrationError "CSV header row is empty"
        }

        $headers = Get-UniqueCsvHeaders -Headers $rawHeaders
        $rows = @()

        while (-not $parser.EndOfData) {
            $fields = $parser.ReadFields()
            if ($null -eq $fields) {
                continue
            }

            $row = @{}
            for ($i = 0; $i -lt $headers.Count; $i++) {
                $value = if ($i -lt $fields.Count) { $fields[$i] } else { "" }
                $row[$headers[$i]] = $value
            }
            $rows += $row
        }

        return $rows
    }
    finally {
        $parser.Close()
    }
}

function New-AdoClient {
    param(
        [Parameter(Mandatory = $true)][string]$TargetProjectUrl,
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][double]$TimeoutSeconds
    )

    try {
        $uri = [System.Uri]$TargetProjectUrl
    }
    catch {
        Throw-MigrationError "ProjectUrl must be https://dev.azure.com/<org>/<project>"
    }

    $segments = @()
    foreach ($segment in $uri.AbsolutePath.Trim("/").Split("/")) {
        if ($segment) {
            $segments += [System.Uri]::UnescapeDataString($segment)
        }
    }

    if (
        $uri.Scheme -ne "https" -or
        $uri.Host.ToLowerInvariant() -ne "dev.azure.com" -or
        $uri.Query -or
        $uri.Fragment -or
        $segments.Count -ne 2
    ) {
        Throw-MigrationError "ProjectUrl must be https://dev.azure.com/<org>/<project>"
    }

    $org = $segments[0]
    $project = $segments[1]
    $base = "https://dev.azure.com/{0}/{1}" -f [System.Uri]::EscapeDataString($org), [System.Uri]::EscapeDataString($project)

    $authBytes = [System.Text.Encoding]::UTF8.GetBytes((":" + $Token))
    $authHeader = "Basic " + [System.Convert]::ToBase64String($authBytes)

    return [pscustomobject]@{
        Org = $org
        Project = $project
        Base = $base
        TimeoutSeconds = $TimeoutSeconds
        Headers = @{
            Authorization = $authHeader
            Accept = "application/json"
        }
    }
}

function Get-JsonConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -Path $Path)) {
        Throw-MigrationError ("Config file not found: {0}" -f $Path)
    }

    $json = Get-Content -Path $Path -Raw -Encoding UTF8
    try {
        $parsed = ConvertFrom-Json -InputObject $json
        return ConvertTo-Hashtable -InputObject $parsed
    }
    catch {
        Throw-MigrationError ("Config JSON is invalid: {0}" -f $_.Exception.Message)
    }
}

function Get-ApiUrl {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Query
    )

    $baseUrl = $Client.Base + "/_apis/wit/" + $Path
    $pairs = @{}
    $pairs["api-version"] = $API_VERSION

    if ($Query) {
        foreach ($key in $Query.Keys) {
            $pairs[[string]$key] = [string]$Query[$key]
        }
    }

    $encoded = @()
    foreach ($key in ($pairs.Keys | Sort-Object)) {
        $encoded += ("{0}={1}" -f [System.Uri]::EscapeDataString($key), [System.Uri]::EscapeDataString($pairs[$key]))
    }

    return $baseUrl + "?" + ($encoded -join "&")
}

function Invoke-AdoRequest {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Query,
        $Body,
        [string]$ContentType = "application/json"
    )

    $url = Get-ApiUrl -Client $Client -Path $Path -Query $Query
    $params = @{
        Method = $Method
        Uri = $url
        Headers = $Client.Headers
        TimeoutSec = [int][Math]::Ceiling($Client.TimeoutSeconds)
        ErrorAction = "Stop"
    }

    if ($null -ne $Body) {
        $params["ContentType"] = $ContentType
        $params["Body"] = if ($Body -is [string]) { $Body } else { (ConvertTo-Json $Body -Depth 100) }
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        $message = $_.Exception.Message
        if ($_.Exception.Response) {
            try {
                $stream = $_.Exception.Response.GetResponseStream()
                if ($stream) {
                    $reader = New-Object System.IO.StreamReader($stream)
                    $details = $reader.ReadToEnd()
                    if ($details) {
                        $message = "{0}: {1}" -f $message, $details
                    }
                }
            }
            catch {
                # Keep original message when response body cannot be read.
            }
        }
        Throw-MigrationError ("{0} failed: {1}" -f $Method, $message)
    }
}

function Get-MappedWorkItemType {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][hashtable]$Row,
        [Parameter(Mandatory = $true)][int]$RowNumber
    )

    $typeConfig = if ($Config.ContainsKey("work_item_type")) { $Config["work_item_type"] } else { @{} }
    $columnName = if ($typeConfig.ContainsKey("column")) { [string]$typeConfig["column"] } else { "" }
    $defaultType = if ($typeConfig.ContainsKey("default")) { [string]$typeConfig["default"] } else { "Task" }

    $sourceType = $defaultType
    if ($columnName) {
        if (-not $Row.ContainsKey($columnName)) {
            Throw-MigrationError ("Row {0}: missing work item type column '{1}'" -f $RowNumber, $columnName)
        }
        $candidate = [string]$Row[$columnName]
        if ($candidate) {
            $sourceType = $candidate
        }
    }

    if ($typeConfig.ContainsKey("map") -and $typeConfig["map"].ContainsKey($sourceType)) {
        $sourceType = [string]$typeConfig["map"][$sourceType]
    }

    if (-not $sourceType) {
        Throw-MigrationError ("Row {0}: resolved work item type is empty" -f $RowNumber)
    }

    return $sourceType
}

function Get-MappedFields {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][hashtable]$Row,
        [Parameter(Mandatory = $true)][string]$WorkItemType,
        [Parameter(Mandatory = $true)][int]$RowNumber
    )

    if (-not $Config.ContainsKey("field_map") -or $Config["field_map"] -isnot [System.Collections.IDictionary]) {
        Throw-MigrationError "Config requires a 'field_map' object"
    }

    $skipEmpty = $true
    if ($Config.ContainsKey("skip_empty_fields")) {
        $skipEmpty = [bool]$Config["skip_empty_fields"]
    }

    $valueMaps = if ($Config.ContainsKey("value_map")) { $Config["value_map"] } else { @{} }
    $result = @{}

    foreach ($csvColumn in $Config["field_map"].Keys) {
        $adoField = $Config["field_map"][$csvColumn]
        if ($null -eq $adoField -or -not [string]$adoField) {
            continue
        }

        if (-not $Row.ContainsKey([string]$csvColumn)) {
            Throw-MigrationError ("Row {0}: missing CSV column '{1}' required by field_map" -f $RowNumber, $csvColumn)
        }

        $value = $Row[[string]$csvColumn]
        if ($value -is [string]) {
            $value = $value.Trim()
        }

        if ($skipEmpty -and (($null -eq $value) -or ($value -is [string] -and -not $value))) {
            continue
        }

        $fieldName = [string]$adoField
        if ($valueMaps.ContainsKey($fieldName)) {
            $fieldValueMap = $valueMaps[$fieldName]
            $lookup = [string]$value
            if ($fieldValueMap.ContainsKey($lookup)) {
                $value = $fieldValueMap[$lookup]
            }
        }

        if ($null -ne $value) {
            $result[$fieldName] = $value
        }
    }

    if ($Config.ContainsKey("defaults")) {
        foreach ($key in $Config["defaults"].Keys) {
            $value = $Config["defaults"][$key]
            if ($null -eq $value) {
                if ($result.ContainsKey([string]$key)) {
                    $result.Remove([string]$key)
                }
            }
            else {
                $result[[string]$key] = $value
            }
        }
    }

    if ($Config.ContainsKey("type_defaults") -and $Config["type_defaults"].ContainsKey($WorkItemType)) {
        foreach ($key in $Config["type_defaults"][$WorkItemType].Keys) {
            $value = $Config["type_defaults"][$WorkItemType][$key]
            if ($null -eq $value) {
                if ($result.ContainsKey([string]$key)) {
                    $result.Remove([string]$key)
                }
            }
            else {
                $result[[string]$key] = $value
            }
        }
    }

    return $result
}

function Get-CommentsForRow {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][hashtable]$Row,
        [Parameter(Mandatory = $true)][int]$RowNumber
    )

    if (-not $Config.ContainsKey("comment_columns")) {
        return @()
    }

    $columns = @($Config["comment_columns"])
    $splitPattern = if ($Config.ContainsKey("comment_split_pattern")) { [string]$Config["comment_split_pattern"] } else { "" }

    $comments = @()
    foreach ($column in $columns) {
        $name = [string]$column
        if (-not $Row.ContainsKey($name)) {
            Throw-MigrationError ("Row {0}: missing comment column '{1}'" -f $RowNumber, $name)
        }

        $text = [string]$Row[$name]
        if (-not $text) {
            continue
        }

        if ($splitPattern) {
            foreach ($part in ($text -split $splitPattern)) {
                $candidate = $part.Trim()
                if ($candidate) {
                    $comments += $candidate
                }
            }
        }
        else {
            $candidate = $text.Trim()
            if ($candidate) {
                $comments += $candidate
            }
        }
    }

    return $comments
}

function New-WorkItemPatch {
    param([Parameter(Mandatory = $true)][hashtable]$Fields)

    $patch = @()
    foreach ($fieldName in $Fields.Keys) {
        $escaped = ([string]$fieldName).Replace("~", "~0").Replace("/", "~1")
        $patch += @{
            op = "add"
            path = "/fields/$escaped"
            value = $Fields[$fieldName]
        }
    }

    return $patch
}

function Test-IsStatusUpdateEnabled {
    param([Parameter(Mandatory = $true)][hashtable]$Config)

    if (-not $Config.ContainsKey("status_update")) {
        return $true
    }

    $statusConfig = $Config["status_update"]
    if ($statusConfig -is [System.Collections.IDictionary] -and $statusConfig.ContainsKey("enabled")) {
        return [bool]$statusConfig["enabled"]
    }

    return $true
}

function Get-DesiredStateFromRow {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][hashtable]$Row,
        [Parameter(Mandatory = $true)][int]$RowNumber
    )

    if (-not $Config.ContainsKey("field_map") -or $Config["field_map"] -isnot [System.Collections.IDictionary]) {
        return $null
    }

    $stateColumn = $null
    foreach ($csvColumn in $Config["field_map"].Keys) {
        $adoField = [string]$Config["field_map"][$csvColumn]
        if ($adoField -and $adoField.ToLowerInvariant() -eq "system.state") {
            $stateColumn = [string]$csvColumn
            break
        }
    }

    if (-not $stateColumn) {
        return $null
    }

    if (-not $Row.ContainsKey($stateColumn)) {
        Throw-MigrationError ("Row {0}: missing CSV column '{1}' required for state update" -f $RowNumber, $stateColumn)
    }

    $stateValue = [string]$Row[$stateColumn]
    if ($stateValue) {
        $stateValue = $stateValue.Trim()
    }
    if (-not $stateValue) {
        return $null
    }

    if ($Config.ContainsKey("value_map") -and $Config["value_map"].ContainsKey("System.State")) {
        $stateMap = $Config["value_map"]["System.State"]
        if ($stateMap -is [System.Collections.IDictionary] -and $stateMap.ContainsKey($stateValue)) {
            $stateValue = [string]$stateMap[$stateValue]
        }
    }

    if (-not $stateValue) {
        return $null
    }

    return $stateValue
}

function Get-ParentChildInfo {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][hashtable]$Row,
        [Parameter(Mandatory = $true)][int]$RowNumber
    )

    if (-not $Config.ContainsKey("parent_child")) {
        return $null
    }

    $pc = $Config["parent_child"]
    if ($pc -isnot [System.Collections.IDictionary]) {
        Throw-MigrationError "Config section 'parent_child' must be an object"
    }

    $idColumn = if ($pc.ContainsKey("id_column")) {
        [string]$pc["id_column"]
    }
    elseif ($pc.ContainsKey("issue_key_column")) {
        [string]$pc["issue_key_column"]
    }
    else {
        ""
    }

    $parentKeyColumn = if ($pc.ContainsKey("parent_key_column")) {
        [string]$pc["parent_key_column"]
    }
    elseif ($pc.ContainsKey("parent_id_column")) {
        [string]$pc["parent_id_column"]
    }
    else {
        ""
    }

    if (-not $idColumn -or -not $parentKeyColumn) {
        Throw-MigrationError "Config 'parent_child' requires both id_column (or issue_key_column) and parent_key_column"
    }

    if (-not $Row.ContainsKey($idColumn)) {
        Throw-MigrationError ("Row {0}: missing parent-child id column '{1}'" -f $RowNumber, $idColumn)
    }
    if (-not $Row.ContainsKey($parentKeyColumn)) {
        Throw-MigrationError ("Row {0}: missing parent-child parent column '{1}'" -f $RowNumber, $parentKeyColumn)
    }

    $sourceKey = [string]$Row[$idColumn]
    if ($sourceKey) {
        $sourceKey = $sourceKey.Trim()
    }
    if (-not $sourceKey) {
        Throw-MigrationError ("Row {0}: parent-child id column '{1}' is empty" -f $RowNumber, $idColumn)
    }

    $parentKey = [string]$Row[$parentKeyColumn]
    if ($parentKey) {
        $parentKey = $parentKey.Trim()
    }

    if ($parentKey -and $parentKey -eq $sourceKey) {
        Throw-MigrationError ("Row {0}: source id and parent id are identical ({1})" -f $RowNumber, $sourceKey)
    }

    return @{
        source_key = $sourceKey
        parent_key = $parentKey
        id_column = $idColumn
        parent_key_column = $parentKeyColumn
    }
}

function Invoke-Migration {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$CsvFile,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [switch]$ValidateOnly,
        [switch]$FailFast
    )

    $rows = Read-CsvRows -Path $CsvFile
    $results = @()
    $created = 0
    $failed = 0
    $linked = 0
    $link_failed = 0
    $createdBySourceKey = @{}
    $seenSourceKeys = @{}
    $pendingLinks = @()
    $hasParentChild = $Config.ContainsKey("parent_child")
    $statusUpdateEnabled = Test-IsStatusUpdateEnabled -Config $Config

    $index = 0
    foreach ($rowHash in $rows) {
        $index += 1

        try {
            $pcInfo = Get-ParentChildInfo -Config $Config -Row $rowHash -RowNumber $index
            $sourceKey = $null
            $parentKey = $null
            if ($pcInfo) {
                $sourceKey = [string]$pcInfo["source_key"]
                $parentKey = [string]$pcInfo["parent_key"]

                if ($seenSourceKeys.ContainsKey($sourceKey)) {
                    Throw-MigrationError (
                        "Row {0}: duplicate parent-child id '{1}' already used by row {2}" -f
                        $index, $sourceKey, $seenSourceKeys[$sourceKey]
                    )
                }
                $seenSourceKeys[$sourceKey] = $index

                if ($parentKey) {
                    $pendingLinks += @{
                        row = $index
                        source_key = $sourceKey
                        parent_key = $parentKey
                    }
                }
            }

            $workItemType = Get-MappedWorkItemType -Config $Config -Row $rowHash -RowNumber $index
            $desiredState = Get-DesiredStateFromRow -Config $Config -Row $rowHash -RowNumber $index
            $fields = Get-MappedFields -Config $Config -Row $rowHash -WorkItemType $workItemType -RowNumber $index
            $comments = Get-CommentsForRow -Config $Config -Row $rowHash -RowNumber $index

            $stateDeferred = $false
            if ($statusUpdateEnabled -and $desiredState -and $fields.ContainsKey("System.State")) {
                # Create first, then apply the final state in a second step.
                $fields.Remove("System.State")
                $stateDeferred = $true
            }

            if (-not $fields.ContainsKey("System.Title") -or -not [string]$fields["System.Title"]) {
                Throw-MigrationError ("Row {0}: mapped fields must include non-empty System.Title" -f $index)
            }

            $patchBody = New-WorkItemPatch -Fields $fields
            $escapedType = [System.Uri]::EscapeDataString($workItemType)

            if ($ValidateOnly) {
                [void](Invoke-AdoRequest -Client $Client -Method "POST" -Path ("workitems/$" + $escapedType) -Body $patchBody -ContentType "application/json-patch+json" -Query @{ validateOnly = "true" })
                $results += @{
                    row = $index
                    dry_run = $true
                    work_item_type = $workItemType
                    title = [string]$fields["System.Title"]
                    comments = @($comments).Count
                    source_key = $sourceKey
                    parent_key = $parentKey
                    desired_state = $desiredState
                    status_update_planned = $stateDeferred
                    status = "validated"
                }
                Write-Notice ("Validated row {0} as {1}" -f $index, $workItemType)
                continue
            }

            $createdItem = Invoke-AdoRequest -Client $Client -Method "POST" -Path ("workitems/$" + $escapedType) -Body $patchBody -ContentType "application/json-patch+json"
            $destinationId = [int]$createdItem.id

            foreach ($commentText in $comments) {
                [void](Invoke-AdoRequest -Client $Client -Method "POST" -Path ("workitems/{0}/comments" -f $destinationId) -Query @{ "api-version" = $COMMENTS_VERSION; format = "markdown" } -Body @{ text = $commentText })
            }

            $statusUpdated = $false
            if ($stateDeferred -and $desiredState) {
                [void](Invoke-AdoRequest -Client $Client -Method "PATCH" -Path ("workitems/{0}" -f $destinationId) -Body @(@{
                    op = "add"
                    path = "/fields/System.State"
                    value = $desiredState
                }) -ContentType "application/json-patch+json")
                $statusUpdated = $true
                Write-Notice ("Updated work item {0} state to {1}" -f $destinationId, $desiredState)
            }

            $created += 1
            if ($sourceKey) {
                $createdBySourceKey[$sourceKey] = $destinationId
            }
            $results += @{
                row = $index
                dry_run = $false
                source_title = [string]$fields["System.Title"]
                work_item_type = $workItemType
                destination_id = $destinationId
                comments_added = @($comments).Count
                source_key = $sourceKey
                parent_key = $parentKey
                desired_state = $desiredState
                status_updated = $statusUpdated
                status = "created"
            }
            Write-Notice ("Created row {0} -> work item {1}" -f $index, $destinationId)
        }
        catch {
            $failed += 1
            $results += @{
                row = $index
                status = "failed"
                error = $_.Exception.Message
            }
            Write-Notice ("Row {0} failed: {1}" -f $index, $_.Exception.Message)
            if ($FailFast) {
                throw
            }
        }
    }

    if ($hasParentChild) {
        foreach ($link in $pendingLinks) {
            if ($seenSourceKeys.ContainsKey($link["parent_key"])) {
                continue
            }

            $failed += 1
            $link_failed += 1
            $results += @{
                row = $link["row"]
                source_key = $link["source_key"]
                parent_key = $link["parent_key"]
                status = "link_failed"
                error = ("Parent key '{0}' not found in CSV id_column values" -f $link["parent_key"])
            }
            Write-Notice ("Row {0} link failed: parent key '{1}' not found in CSV" -f $link["row"], $link["parent_key"])

            if ($FailFast) {
                Throw-MigrationError ("Row {0}: parent key '{1}' not found in CSV id_column values" -f $link["row"], $link["parent_key"])
            }
        }
    }

    if ($hasParentChild -and -not $ValidateOnly) {
        foreach ($link in $pendingLinks) {
            $sourceKey = [string]$link["source_key"]
            $parentKey = [string]$link["parent_key"]
            if (-not $parentKey) {
                continue
            }

            if (-not $createdBySourceKey.ContainsKey($sourceKey)) {
                continue
            }
            $parentId = $null

            if ($createdBySourceKey.ContainsKey($parentKey)) {
                $parentId = [int]$createdBySourceKey[$parentKey]
            }

            if ($null -eq $parentId) {
                $failed += 1
                $link_failed += 1
                $results += @{
                    row = $link["row"]
                    source_key = $sourceKey
                    parent_key = $parentKey
                    status = "link_failed"
                    error = ("Cannot create link because parent row for key '{0}' did not create successfully" -f $parentKey)
                }
                Write-Notice ("Row {0} link failed: parent key '{1}' was not created" -f $link["row"], $parentKey)
                if ($FailFast) {
                    Throw-MigrationError ("Row {0}: cannot create parent-child link; parent key '{1}' was not created" -f $link["row"], $parentKey)
                }
                continue
            }

            $childId = [int]$createdBySourceKey[$sourceKey]

            try {
                [void](Invoke-AdoRequest -Client $Client -Method "PATCH" -Path ("workitems/{0}" -f $parentId) -Body @(@{
                    op = "add"
                    path = "/relations/-"
                    value = @{
                        rel = $CHILD_REL
                        url = ($Client.Base + "/_apis/wit/workitems/" + $childId)
                    }
                }) -ContentType "application/json-patch+json")

                $linked += 1
                $results += @{
                    row = $link["row"]
                    source_key = $sourceKey
                    parent_key = $parentKey
                    parent_id = $parentId
                    child_id = $childId
                    status = "linked"
                }
                Write-Notice ("Linked parent {0} -> child {1}" -f $parentId, $childId)
            }
            catch {
                $failed += 1
                $link_failed += 1
                $results += @{
                    row = $link["row"]
                    source_key = $sourceKey
                    parent_key = $parentKey
                    parent_id = $parentId
                    child_id = $childId
                    status = "link_failed"
                    error = $_.Exception.Message
                }
                Write-Notice ("Row {0} link failed: {1}" -f $link["row"], $_.Exception.Message)
                if ($FailFast) {
                    throw
                }
            }
        }
    }

    return @{
        dry_run = [bool]$ValidateOnly
        total_rows = $index
        created = $created
        linked = $linked
        failed = $failed
        link_failed = $link_failed
        results = $results
    }
}

try {
    if ($Timeout -le 0 -or [double]::IsNaN($Timeout) -or [double]::IsInfinity($Timeout)) {
        Throw-MigrationError "Timeout must be a positive finite number"
    }

    $resolvedCsvPath = Resolve-ScriptRelativePath -Path $CsvPath
    $resolvedConfigPath = Resolve-ScriptRelativePath -Path $ConfigPath

    $token = if ($Pat) { $Pat } else { [Environment]::GetEnvironmentVariable("ADO_DEST_PAT") }
    if (-not $token) {
        $token = [Environment]::GetEnvironmentVariable("ADO_PAT")
    }
    if (-not $token) {
        Throw-MigrationError "Provide -Pat or set ADO_DEST_PAT (or ADO_PAT)"
    }

    $config = Get-JsonConfig -Path $resolvedConfigPath
    $client = New-AdoClient -TargetProjectUrl $ProjectUrl -Token $token -TimeoutSeconds $Timeout

    $result = Invoke-Migration -Client $client -CsvFile $resolvedCsvPath -Config $config -ValidateOnly:$DryRun -FailFast:$StopOnError
    [Console]::Out.WriteLine((ConvertTo-Json $result -Depth 100))
    exit 0
}
catch {
    Write-Notice ("Migration failed: {0}" -f $_.Exception.Message)
    exit 1
}
