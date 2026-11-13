#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Source,

    [Parameter(Mandatory = $true)]
    [string]$Destination,

    [Parameter(Mandatory = $true)]
    [int]$Id,

    [string]$Mapping,

    [string]$Checkpoint = "migration-state.json",

    [switch]$DryRun,

    [double]$Timeout = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Windows PowerShell may not auto-load System.Net.Http types.
try {
    [void][System.Net.Http.HttpClientHandler]
}
catch {
    Add-Type -AssemblyName "System.Net.Http"
}

$SCRIPT:API_VERSION = "7.1"
$SCRIPT:COMMENTS_VERSION = "7.1-preview.4"
$SCRIPT:MAX_ATTACHMENT_BYTES = 130 * 1024 * 1024
$SCRIPT:CHILD_REL = "System.LinkTypes.Hierarchy-Forward"
$SCRIPT:GENERATED_FIELDS = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@(
    "System.Id", "System.Rev", "System.WorkItemType", "System.TeamProject",
    "System.CreatedBy", "System.CreatedDate", "System.ChangedBy",
    "System.ChangedDate", "System.AuthorizedAs", "System.AuthorizedDate",
    "System.RevisedDate", "System.Watermark", "System.History", "System.Reason",
    "System.BoardColumn", "System.BoardColumnDone", "System.BoardLane"
) | ForEach-Object { [void]$SCRIPT:GENERATED_FIELDS.Add($_) }
$SCRIPT:ATTACHMENT_PATTERN = [regex]::new(
    'https://dev\.azure\.com/[^\s<>"'')]+/_apis/wit/attachments/[0-9a-fA-F-]{36}(?:\?[^\s<>"'')]+)?',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)
$SCRIPT:GENERATED_BOARD_FIELD_PATTERN = [regex]::new(
    '^WEF_[0-9A-Fa-f]{32}_Kanban\.(Column(?:\.Done)?|Lane)$',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
)

function Write-Notice {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Throw-MigrationError {
    param([string]$Message)
    throw [System.InvalidOperationException]::new($Message)
}

function Write-ExceptionDetails {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    if ($null -eq $ErrorRecord) {
        return
    }

    Write-Notice ("Error type: {0}" -f $ErrorRecord.Exception.GetType().FullName)
    if ($ErrorRecord.ScriptStackTrace) {
        Write-Notice "Script stack trace:"
        Write-Notice $ErrorRecord.ScriptStackTrace
    }

    $inner = $ErrorRecord.Exception.InnerException
    $depth = 0
    while ($inner -and $depth -lt 8) {
        Write-Notice ("Inner[{0}] {1}: {2}" -f $depth, $inner.GetType().FullName, $inner.Message)
        $inner = $inner.InnerException
        $depth += 1
    }
}

function Resolve-ScriptRelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    $basePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
    return [System.IO.Path]::GetFullPath((Join-Path -Path $basePath -ChildPath $Path))
}

function Test-IsGeneratedBoardField {
    param([string]$FieldName)
    return $SCRIPT:GENERATED_BOARD_FIELD_PATTERN.IsMatch([string]$FieldName)
}

function ConvertTo-Hashtable {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $result = @{}
        foreach ($key in $InputObject.Keys) {
            $result[$key] = ConvertTo-Hashtable -InputObject $InputObject[$key]
        }
        return $result
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $list.Add((ConvertTo-Hashtable -InputObject $item))
        }
        return $list.ToArray()
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

function ConvertTo-CanonicalObject {
    param($InputObject)

    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $keys = @($InputObject.Keys | ForEach-Object { [string]$_ } | Sort-Object)
        foreach ($key in $keys) {
            $ordered[$key] = ConvertTo-CanonicalObject -InputObject $InputObject[$key]
        }
        return $ordered
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = New-Object System.Collections.Generic.List[object]
        foreach ($item in $InputObject) {
            $list.Add((ConvertTo-CanonicalObject -InputObject $item))
        }
        return $list.ToArray()
    }

    return $InputObject
}

function Get-Sha256Hex {
    param([Parameter(Mandatory = $true)][string]$Text)

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha.ComputeHash($bytes)
    }
    finally {
        $sha.Dispose()
    }

    return ([System.BitConverter]::ToString($hashBytes)).Replace("-", "").ToLowerInvariant()
}

function Escape-UriPathSegment {
    param([Parameter(Mandatory = $true)][string]$Segment)
    return [System.Uri]::EscapeDataString($Segment)
}

function Decode-QueryComponent {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Uri]::UnescapeDataString($Value.Replace("+", " "))
}

function Encode-QueryComponent {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [System.Uri]::EscapeDataString($Value)
}

function Merge-QueryString {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [hashtable]$Query
    )

    $uri = [System.Uri]$Url
    $builder = [System.UriBuilder]::new($uri)
    $pairs = @{}
    $existing = $builder.Query
    if ($existing.StartsWith("?")) {
        $existing = $existing.Substring(1)
    }

    if ($existing) {
        foreach ($fragment in $existing.Split("&")) {
            if (-not $fragment) { continue }
            $parts = $fragment.Split("=", 2)
            $key = Decode-QueryComponent -Value $parts[0]
            $value = if ($parts.Count -gt 1) { Decode-QueryComponent -Value $parts[1] } else { "" }
            $pairs[$key] = $value
        }
    }

    if (-not $pairs.ContainsKey("api-version")) {
        $pairs["api-version"] = $SCRIPT:API_VERSION
    }

    if ($Query) {
        foreach ($key in $Query.Keys) {
            $pairs[[string]$key] = [string]$Query[$key]
        }
    }

    $encoded = @()
    foreach ($key in ($pairs.Keys | Sort-Object)) {
        $encoded += ("{0}={1}" -f (Encode-QueryComponent -Value $key), (Encode-QueryComponent -Value $pairs[$key]))
    }
    $builder.Query = ($encoded -join "&")
    return $builder.Uri.AbsoluteUri
}

function New-NoRedirectHttpClient {
    param([double]$TimeoutSeconds)

    $handler = [System.Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    return [pscustomobject]@{
        Client = $client
        Handler = $handler
    }
}

function Get-PathSegments {
    param([Parameter(Mandatory = $true)][System.Uri]$Uri)

    $segments = @()
    foreach ($segment in $Uri.AbsolutePath.Trim("/").Split("/")) {
        if ($segment) {
            $segments += [System.Uri]::UnescapeDataString($segment)
        }
    }
    return $segments
}

function New-AdoClient {
    param(
        [Parameter(Mandatory = $true)][string]$ProjectUrl,
        [Parameter(Mandatory = $true)][string]$Pat,
        [double]$TimeoutSeconds = 60
    )

    try {
        $uri = [System.Uri]$ProjectUrl
    }
    catch {
        Throw-MigrationError "Use a project URL: https://dev.azure.com/<org>/<project>"
    }

    $segments = Get-PathSegments -Uri $uri
    if (
        $uri.Scheme -ne "https" -or
        $uri.Host.ToLowerInvariant() -ne "dev.azure.com" -or
        $uri.Query -or
        $uri.Fragment -or
        $segments.Count -ne 2 -or
        ($segments | Where-Object { (-not $_) -or $_ -in @(".", "..") -or $_.Contains("/") })
    ) {
        Throw-MigrationError "Use a project URL: https://dev.azure.com/<org>/<project>"
    }

    $org = $segments[0]
    $project = $segments[1]
    $escapedSegments = @(
        (Escape-UriPathSegment -Segment $org),
        (Escape-UriPathSegment -Segment $project)
    )
    $base = "https://dev.azure.com/{0}" -f ($escapedSegments -join "/")

    $authBytes = [System.Text.Encoding]::UTF8.GetBytes((":" + $Pat))
    $authorization = "Basic " + [System.Convert]::ToBase64String($authBytes)

    $http = New-NoRedirectHttpClient -TimeoutSeconds $TimeoutSeconds

    return [pscustomobject]@{
        Org = $org
        Project = $project
        Base = $base
        Authorization = $authorization
        Timeout = $TimeoutSeconds
        HttpClient = $http.Client
        Handler = $http.Handler
    }
}

function Get-AdoApiUrl {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Path
    )
    return $Client.Base + "/_apis/wit/" + $Path
}

function Test-AdoUrl {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $uri = [System.Uri]$Url
    $segments = Get-PathSegments -Uri $uri
    $org = if ($segments.Count -gt 0) { $segments[0] } else { "" }

    if (
        $uri.Scheme -ne "https" -or
        $uri.Host.ToLowerInvariant() -ne "dev.azure.com" -or
        $org.ToLowerInvariant() -ne $Client.Org.ToLowerInvariant() -or
        $uri.Fragment
    ) {
        Throw-MigrationError ("Refusing to send credentials outside organization {0}" -f $Client.Org)
    }
}

function Read-ResponseTextLimited {
    param(
        [Parameter(Mandatory = $true)][System.Net.Http.HttpResponseMessage]$Response,
        [int]$MaxBytes = 8192
    )

    $stream = $Response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $buffer = New-Object byte[] 1024
    $bytes = New-Object System.Collections.Generic.List[byte]
    while ($true) {
        $remaining = $MaxBytes - $bytes.Count
        if ($remaining -le 0) {
            break
        }
        $read = $stream.Read($buffer, 0, [Math]::Min($buffer.Length, $remaining))
        if ($read -le 0) {
            break
        }
        for ($i = 0; $i -lt $read; $i++) {
            $bytes.Add($buffer[$i])
        }
    }
    return [System.Text.Encoding]::UTF8.GetString($bytes.ToArray())
}

function Invoke-AdoRequest {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        $Payload,
        [hashtable]$Query,
        [switch]$Patch,
        [byte[]]$Binary,
        [switch]$Download
    )

    Test-AdoUrl -Client $Client -Url $Url
    $finalUrl = Merge-QueryString -Url $Url -Query $Query

    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::new($Method), $finalUrl)
    [void]$request.Headers.TryAddWithoutValidation("Authorization", $Client.Authorization)
    [void]$request.Headers.TryAddWithoutValidation("Accept", "application/json")

    if ($null -ne $Binary) {
        $content = [System.Net.Http.ByteArrayContent]::new($Binary)
        $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("application/octet-stream")
        $request.Content = $content
    }
    elseif ($null -ne $Payload) {
        $json = ConvertTo-Json $Payload -Depth 100 -Compress
        $mediaType = if ($Patch) { "application/json-patch+json" } else { "application/json" }
        $request.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, $mediaType)
    }

    try {
        $response = $Client.HttpClient.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead
        ).GetAwaiter().GetResult()

        if (-not $response.IsSuccessStatusCode) {
            $detail = Read-ResponseTextLimited -Response $response -MaxBytes 8192
            Throw-MigrationError ("{0} failed (HTTP {1}): {2}" -f $Method, [int]$response.StatusCode, $detail)
        }

        if ($Download) {
            $stream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $memory = New-Object System.IO.MemoryStream
            try {
                $buffer = New-Object byte[] 8192
                $total = 0
                while ($true) {
                    $read = $stream.Read($buffer, 0, $buffer.Length)
                    if ($read -le 0) {
                        break
                    }
                    $total += $read
                    if ($total -gt $SCRIPT:MAX_ATTACHMENT_BYTES) {
                        Throw-MigrationError "Attachment exceeds the 130 MiB simple-upload limit"
                    }
                    $memory.Write($buffer, 0, $read)
                }
                return $memory.ToArray()
            }
            finally {
                $memory.Dispose()
                $stream.Dispose()
            }
        }

        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $body) {
            return @{}
        }

        try {
            $jsonObject = ConvertFrom-Json -InputObject $body
            if ($null -eq $jsonObject) {
                return $null
            }
            return ConvertTo-Hashtable -InputObject $jsonObject
        }
        catch {
            Throw-MigrationError ("{0} returned invalid JSON: {1}" -f $Method, $_.Exception.Message)
        }
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        Throw-MigrationError ("{0} request failed: {1}" -f $Method, $_.Exception.Message)
    }
    finally {
        if ($request) {
            $request.Dispose()
        }
    }
}

function Get-Ado {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Path,
        [hashtable]$Query
    )

    return Invoke-AdoRequest -Client $Client -Method "GET" -Url (Get-AdoApiUrl -Client $Client -Path $Path) -Query $Query
}

function Get-AdoComments {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][int]$ItemId
    )

    $result = New-Object System.Collections.Generic.List[object]
    $token = $null
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

    while ($true) {
        $query = @{
            "api-version" = $SCRIPT:COMMENTS_VERSION
            "`$top" = 200
            "order" = "asc"
            "includeDeleted" = "false"
            "`$expand" = "renderedText"
        }
        if ($null -ne $token) {
            $query["continuationToken"] = [string]$token
        }

        $page = Get-Ado -Client $Client -Path ("workitems/{0}/comments" -f $ItemId) -Query $query
        foreach ($comment in @($page["comments"])) {
            if (-not $comment["isDeleted"]) {
                [void]$result.Add($comment)
            }
        }

        $token = $page["continuationToken"]
        if (-not $token) {
            return $result.ToArray()
        }

        $tokenKey = [string]$token
        if ($seen.Contains($tokenKey)) {
            Throw-MigrationError "Comments API returned a repeated continuation token"
        }
        [void]$seen.Add($tokenKey)
    }
}

function Load-Mapping {
    param([string]$Path)

    if (-not $Path) {
        return @{}
    }

    $text = Get-Content -Path $Path -Raw -Encoding UTF8
    try {
        $mapping = ConvertTo-Hashtable -InputObject (ConvertFrom-Json -InputObject $text)
    }
    catch {
        Throw-MigrationError ("Cannot parse mapping JSON: {0}" -f $_.Exception.Message)
    }

    if ($mapping -isnot [System.Collections.IDictionary]) {
        Throw-MigrationError "Mapping must be an object containing only documented sections"
    }

    $sections = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    @("work_item_types", "fields", "values", "states", "identities", "area_paths", "iteration_paths", "defaults", "type_defaults") |
        ForEach-Object { [void]$sections.Add($_) }

    foreach ($key in @($mapping.Keys)) {
        if (-not $sections.Contains([string]$key)) {
            Throw-MigrationError "Mapping must be an object containing only documented sections"
        }
    }

    foreach ($section in @($mapping.Keys)) {
        $entries = $mapping[$section]
        if ($entries -isnot [System.Collections.IDictionary]) {
            Throw-MigrationError ("Mapping section {0} must be an object" -f $section)
        }

        if ($section -in @("values", "states", "type_defaults")) {
            foreach ($value in @($entries.Values)) {
                if ($value -isnot [System.Collections.IDictionary]) {
                    Throw-MigrationError ("Mapping section {0} must contain objects" -f $section)
                }
            }
        }
        elseif ($section -ne "defaults") {
            foreach ($value in @($entries.Values)) {
                $nullable = $section -in @("fields", "identities")
                $isGood = ($value -is [string] -and [string]$value) -or ($nullable -and $null -eq $value)
                if (-not $isGood) {
                    Throw-MigrationError ("Invalid value in mapping section {0}" -f $section)
                }
            }
        }
    }

    return $mapping
}

function Get-FieldPatch {
    param([Parameter(Mandatory = $true)][hashtable]$Fields)

    $patch = New-Object System.Collections.Generic.List[object]
    foreach ($name in $Fields.Keys) {
        $escaped = ([string]$name).Replace("~", "~0").Replace("/", "~1")
        $patch.Add(@{
            op = "add"
            path = "/fields/$escaped"
            value = $Fields[$name]
        })
    }
    return $patch.ToArray()
}

function Get-MappedFields {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Item,
        [Parameter(Mandatory = $true)][hashtable]$Mapping,
        [Parameter(Mandatory = $true)][hashtable]$Definitions,
        [Parameter(Mandatory = $true)][System.Collections.Generic.HashSet[string]]$Allowed,
        [Parameter(Mandatory = $true)][string]$TargetProject
    )

    $sourceType = [string]$Item["fields"]["System.WorkItemType"]
    $targetType = if ($Mapping.ContainsKey("work_item_types") -and $Mapping["work_item_types"].ContainsKey($sourceType)) {
        [string]$Mapping["work_item_types"][$sourceType]
    }
    else {
        $sourceType
    }

    $renames = if ($Mapping.ContainsKey("fields")) { $Mapping["fields"] } else { @{} }
    $fields = @{}

    foreach ($sourceName in @($Item["fields"].Keys)) {
        $value = $Item["fields"][$sourceName]
        $name = if ($renames.ContainsKey($sourceName)) { $renames[$sourceName] } else { $sourceName }

        if ($null -eq $name -or $null -eq $value) {
            continue
        }

        if (
            ($SCRIPT:GENERATED_FIELDS.Contains([string]$sourceName) -or (Test-IsGeneratedBoardField -FieldName $sourceName)) -and
            -not $renames.ContainsKey($sourceName)
        ) {
            continue
        }

        $definition = if ($Definitions.ContainsKey([string]$name)) { $Definitions[[string]$name] } else { $null }

        if ($definition -and $definition["readOnly"] -and -not $renames.ContainsKey($sourceName)) {
            Write-Notice ("Item {0}: skipping read-only field {1}" -f $Item["id"], $sourceName)
            continue
        }

        if (-not $Allowed.Contains([string]$name) -or -not $definition) {
            Throw-MigrationError (
                "Item {0}: {1} -> {2} is not in {3}; map it to a destination field or explicitly set its fields mapping to null" -f
                $Item["id"], $sourceName, $name, $targetType
            )
        }

        if ($definition["readOnly"] -or $SCRIPT:GENERATED_FIELDS.Contains([string]$name)) {
            Throw-MigrationError ("Cannot write generated/read-only destination field {0}" -f $name)
        }

        if ($fields.ContainsKey([string]$name)) {
            Throw-MigrationError ("Multiple source fields map to {0}" -f $name)
        }

        if ($definition["isIdentity"]) {
            if ($value -is [System.Collections.IDictionary]) {
                $value = $value["uniqueName"]
                if (-not $value) {
                    Throw-MigrationError ("Identity in {0} has no uniqueName" -f $sourceName)
                }
            }

            if ($Mapping.ContainsKey("identities") -and $Mapping["identities"].ContainsKey([string]$value)) {
                $value = $Mapping["identities"][[string]$value]
            }

            if ($null -eq $value) {
                continue
            }
        }

        if ($name -in @("System.AreaPath", "System.IterationPath")) {
            $section = if ($name -eq "System.AreaPath") { "area_paths" } else { "iteration_paths" }
            $mapped = $TargetProject
            if ($Mapping.ContainsKey($section) -and $Mapping[$section].ContainsKey([string]$value)) {
                $mapped = $Mapping[$section][[string]$value]
            }
            if ([string]$mapped -ne [string]$value) {
                Write-Notice ("Item {0}: {1}: {2} -> {3}" -f $Item["id"], $name, $value, $mapped)
            }
            $value = $mapped
        }

        if ($name -eq "System.State") {
            if ($Mapping.ContainsKey("states") -and $Mapping["states"].ContainsKey($sourceType)) {
                $stateMap = $Mapping["states"][$sourceType]
                if ($stateMap.ContainsKey([string]$value)) {
                    $value = $stateMap[[string]$value]
                }
            }
        }

        if ($Mapping.ContainsKey("values") -and $Mapping["values"].ContainsKey($name)) {
            $valueMap = $Mapping["values"][$name]
            if ($valueMap.ContainsKey([string]$value)) {
                $value = $valueMap[[string]$value]
            }
        }

        if ($null -ne $value) {
            $fields[[string]$name] = $value
        }
    }

    $overrides = @{}
    if ($Mapping.ContainsKey("defaults")) {
        foreach ($key in $Mapping["defaults"].Keys) {
            $overrides[$key] = $Mapping["defaults"][$key]
        }
    }

    if ($Mapping.ContainsKey("type_defaults") -and $Mapping["type_defaults"].ContainsKey($targetType)) {
        foreach ($key in $Mapping["type_defaults"][$targetType].Keys) {
            $overrides[$key] = $Mapping["type_defaults"][$targetType][$key]
        }
    }

    foreach ($name in @($overrides.Keys)) {
        if (
            -not $Allowed.Contains([string]$name) -or
            -not $Definitions.ContainsKey([string]$name) -or
            $Definitions[[string]$name]["readOnly"] -or
            $SCRIPT:GENERATED_FIELDS.Contains([string]$name)
        ) {
            Throw-MigrationError ("Invalid default destination field {0} for {1}" -f $name, $targetType)
        }

        $value = $overrides[$name]
        if ($null -eq $value) {
            if ($fields.ContainsKey([string]$name)) {
                $fields.Remove([string]$name)
            }
        }
        else {
            $fields[[string]$name] = $value
        }
    }

    return [pscustomobject]@{
        TargetType = $targetType
        Fields = $fields
    }
}

function Get-AttachmentKey {
    param(
        [Parameter(Mandatory = $true)]$Client,
        [Parameter(Mandatory = $true)][string]$Url
    )

    $decoded = [System.Net.WebUtility]::HtmlDecode($Url)
    Test-AdoUrl -Client $Client -Url $decoded

    $uri = [System.Uri]$decoded
    if (-not [regex]::IsMatch($uri.AbsolutePath, "/_apis/wit/attachments/[0-9a-fA-F-]{36}$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
        Throw-MigrationError ("Not an Azure DevOps attachment URL: {0}" -f $decoded)
    }

    $parts = $uri.AbsolutePath.Trim("/").Split("/")
    return $parts[$parts.Count - 1].ToLowerInvariant()
}

function Get-QueryDictionary {
    param([Parameter(Mandatory = $true)][string]$Query)

    $result = @{}
    if (-not $Query) {
        return $result
    }

    $text = if ($Query.StartsWith("?")) { $Query.Substring(1) } else { $Query }
    if (-not $text) {
        return $result
    }

    foreach ($pair in $text.Split("&")) {
        if (-not $pair) { continue }
        $parts = $pair.Split("=", 2)
        $key = Decode-QueryComponent -Value $parts[0]
        $value = if ($parts.Count -gt 1) { Decode-QueryComponent -Value $parts[1] } else { "" }
        if (-not $result.ContainsKey($key)) {
            $result[$key] = @()
        }
        $result[$key] += $value
    }

    return $result
}

function Get-OrgFromAttachmentPath {
    param([Parameter(Mandatory = $true)][System.Uri]$Uri)

    $segments = $Uri.AbsolutePath.Split("/", [System.StringSplitOptions]::None)
    if ($segments.Count -gt 1) {
        return [System.Uri]::UnescapeDataString($segments[1])
    }
    return ""
}

function Get-SourceItems {
    param(
        [Parameter(Mandatory = $true)]$Source,
        [Parameter(Mandatory = $true)][int]$RootId
    )

    $items = New-Object System.Collections.Generic.List[object]
    $pending = New-Object System.Collections.Generic.List[int]
    $seen = [System.Collections.Generic.HashSet[int]]::new()
    $pending.Add($RootId)

    while ($pending.Count -gt 0) {
        $index = $pending.Count - 1
        $itemId = $pending[$index]
        $pending.RemoveAt($index)

        if ($seen.Contains($itemId)) {
            Throw-MigrationError ("Repeated child {0}: source hierarchy is not a tree" -f $itemId)
        }
        [void]$seen.Add($itemId)

        $item = Get-Ado -Client $Source -Path ("workitems/{0}" -f $itemId) -Query @{"`$expand" = "relations"}

        $project = [string]$item["fields"]["System.TeamProject"]
        if ($project.ToLowerInvariant() -ne $Source.Project.ToLowerInvariant()) {
            Throw-MigrationError ("Child {0} is outside source project {1}" -f $itemId, $Source.Project)
        }

        $item["migration_comments"] = Get-AdoComments -Client $Source -ItemId $itemId

        $children = New-Object System.Collections.Generic.List[int]
        foreach ($relation in @($item["relations"])) {
            if ($relation["rel"] -eq $SCRIPT:CHILD_REL) {
                Test-AdoUrl -Client $Source -Url $relation["url"]
                $path = ([System.Uri]$relation["url"]).AbsolutePath
                $match = [regex]::Match($path, "/_apis/wit/workitems/([0-9]+)$", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $match.Success) {
                    Throw-MigrationError ("Invalid child URL: {0}" -f $relation["url"])
                }
                $children.Add([int]$match.Groups[1].Value)
            }
            elseif ($relation["rel"] -ne "AttachedFile") {
                Write-Notice ("Item {0}: not copying relation {1}" -f $itemId, $relation["rel"])
            }
        }

        $item["migration_children"] = $children.ToArray()
        $items.Add($item)

        for ($i = $children.Count - 1; $i -ge 0; $i--) {
            $pending.Add($children[$i])
        }
    }

    return $items.ToArray()
}

function Get-AttachmentsForItem {
    param(
        [Parameter(Mandatory = $true)]$Source,
        [Parameter(Mandatory = $true)][hashtable]$Item,
        [Parameter(Mandatory = $true)][hashtable]$Fields
    )

    $attachments = @{}

    foreach ($relation in @($Item["relations"])) {
        if ($relation["rel"] -eq "AttachedFile") {
            $url = [string]$relation["url"]
            $key = Get-AttachmentKey -Client $Source -Url $url
            $attrs = if ($relation.ContainsKey("attributes")) { $relation["attributes"] } else { @{} }
            $name = if ($attrs.ContainsKey("name")) { [string]$attrs["name"] } else { $key }
            $comment = if ($attrs.ContainsKey("comment")) { [string]$attrs["comment"] } else { "" }
            $attachments[$key] = @{
                url = $url
                name = $name
                comment = $comment
            }
        }
    }

    $texts = New-Object System.Collections.Generic.List[string]
    foreach ($value in $Fields.Values) {
        if ($value -is [string]) {
            $texts.Add($value)
        }
    }

    foreach ($comment in @($Item["migration_comments"])) {
        $textValue = if ($comment.ContainsKey("text") -and $null -ne $comment["text"]) { [string]$comment["text"] } else { "" }
        $renderedTextValue = if ($comment.ContainsKey("renderedText") -and $null -ne $comment["renderedText"]) { [string]$comment["renderedText"] } else { "" }
        $texts.Add($textValue)
        $texts.Add($renderedTextValue)
    }

    foreach ($text in $texts) {
        foreach ($match in $SCRIPT:ATTACHMENT_PATTERN.Matches($text)) {
            $url = [System.Net.WebUtility]::HtmlDecode($match.Value)
            $uri = [System.Uri]$url
            $org = Get-OrgFromAttachmentPath -Uri $uri

            if ($org.ToLowerInvariant() -ne $Source.Org.ToLowerInvariant()) {
                Write-Notice ("Item {0}: leaving external attachment URL unchanged" -f $Item["id"])
                continue
            }

            $key = Get-AttachmentKey -Client $Source -Url $url
            $query = Get-QueryDictionary -Query $uri.Query
            $fileName = if ($query.ContainsKey("fileName") -and $query["fileName"].Count -gt 0) {
                [string]$query["fileName"][0]
            }
            else {
                $key
            }

            if (-not $attachments.ContainsKey($key)) {
                $attachments[$key] = @{
                    url = $url
                    name = $fileName
                    comment = ""
                }
            }
        }
    }

    return $attachments
}

function Rewrite-AttachmentsInText {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [Parameter(Mandatory = $true)][hashtable]$Replacements
    )

    $matches = $SCRIPT:ATTACHMENT_PATTERN.Matches($Text)
    if ($matches.Count -eq 0) {
        return $Text
    }

    $builder = New-Object System.Text.StringBuilder
    $lastIndex = 0

    foreach ($match in $matches) {
        if ($match.Index -gt $lastIndex) {
            [void]$builder.Append($Text.Substring($lastIndex, $match.Index - $lastIndex))
        }

        $original = [System.Net.WebUtility]::HtmlDecode($match.Value)
        $key = ([System.Uri]$original).AbsolutePath.Trim("/").Split("/")[-1].ToLowerInvariant()

        $replacementText = $match.Value
        if ($Replacements.ContainsKey($key)) {
            $replacement = [string]$Replacements[$key]
            if ($match.Value.Contains("&amp;")) {
                $replacementText = $replacement.Replace("&", "&amp;")
            }
            else {
                $replacementText = $replacement
            }
        }

        [void]$builder.Append($replacementText)
        $lastIndex = $match.Index + $match.Length
    }

    if ($lastIndex -lt $Text.Length) {
        [void]$builder.Append($Text.Substring($lastIndex))
    }

    return $builder.ToString()
}

function Get-RenderedComment {
    param([Parameter(Mandatory = $true)][hashtable]$Comment)

    if ($Comment.ContainsKey("renderedText") -and $null -ne $Comment["renderedText"]) {
        return [string]$Comment["renderedText"]
    }

    $format = if ($Comment.ContainsKey("format")) { [string]$Comment["format"] } else { "" }
    if ($format.ToLowerInvariant() -in @("markdown", "0")) {
        Throw-MigrationError "Source Markdown comment has no renderedText"
    }

    return [string]$Comment["text"]
}

function Save-Checkpoint {
    param([Parameter(Mandatory = $true)]$Checkpoint)

    $path = [string]$Checkpoint.Path
    $temporary = "$path.tmp"

    $directory = [System.IO.Path]::GetDirectoryName($path)
    if ($directory -and -not (Test-Path -Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    try {
        $json = ConvertTo-Json $Checkpoint.Data -Depth 100
        [System.IO.File]::WriteAllText($temporary, $json, [System.Text.Encoding]::UTF8)
        Move-Item -Path $temporary -Destination $path -Force
    }
    catch {
        Throw-MigrationError ("Cannot save checkpoint {0}: {1}" -f $path, $_.Exception.Message)
    }
}

function New-Checkpoint {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][hashtable]$Binding
    )

    $data = @{
        version = 1
        binding = $Binding
        items = @{}
        attachments = @{}
        comments = @{}
        links = @()
        pending = $null
    }

    if (Test-Path -Path $Path) {
        $content = Get-Content -Path $Path -Raw -Encoding UTF8
        $parsed = ConvertTo-Hashtable -InputObject (ConvertFrom-Json -InputObject $content)
        $data = $parsed

        if ($data["version"] -ne 1 -or (ConvertTo-Json (ConvertTo-CanonicalObject $data["binding"]) -Compress -Depth 100) -ne (ConvertTo-Json (ConvertTo-CanonicalObject $Binding) -Compress -Depth 100)) {
            Throw-MigrationError "Checkpoint does not match these URLs, root, mapping, or source snapshot"
        }

        if ($data["pending"]) {
            Throw-MigrationError (
                "Uncertain write in checkpoint: {0}. Inspect the destination and reconcile the checkpoint before resuming; see README." -f
                (ConvertTo-Json $data["pending"] -Compress -Depth 10)
            )
        }
    }

    $checkpoint = [pscustomobject]@{
        Path = $Path
        Data = $data
    }

    Save-Checkpoint -Checkpoint $checkpoint
    return $checkpoint
}

function Invoke-CheckpointWrite {
    param(
        [Parameter(Mandatory = $true)]$Checkpoint,
        [Parameter(Mandatory = $true)]$Destination,
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$ResultField,
        $Payload,
        [hashtable]$Query,
        [switch]$Patch,
        [byte[]]$Binary
    )

    $Checkpoint.Data["pending"] = @{
        section = $Section
        key = $Key
        method = $Method
        url = $Url
    }
    Save-Checkpoint -Checkpoint $Checkpoint

    $result = Invoke-AdoRequest -Client $Destination -Method $Method -Url $Url -Payload $Payload -Query $Query -Patch:$Patch -Binary $Binary

    $value = if ($ResultField) { $result[$ResultField] } else { $true }

    if ($Section -eq "links") {
        $Checkpoint.Data[$Section] += $Key
    }
    else {
        $Checkpoint.Data[$Section][$Key] = $value
    }

    $Checkpoint.Data["pending"] = $null
    Save-Checkpoint -Checkpoint $Checkpoint

    return $value
}

function Invoke-Migration {
    param(
        [Parameter(Mandatory = $true)]$SourceClient,
        [Parameter(Mandatory = $true)]$DestinationClient,
        [Parameter(Mandatory = $true)][int]$RootId,
        [Parameter(Mandatory = $true)][hashtable]$MappingObject,
        [Parameter(Mandatory = $true)][string]$CheckpointPath,
        [switch]$DryRun
    )

    if ($SourceClient.Base.ToLowerInvariant() -eq $DestinationClient.Base.ToLowerInvariant()) {
        Throw-MigrationError "Source and destination projects must differ"
    }

    $items = Get-SourceItems -Source $SourceClient -RootId $RootId
    $definitionsResponse = Get-Ado -Client $DestinationClient -Path "fields"

    $definitions = @{}
    foreach ($field in @($definitionsResponse["value"])) {
        $definitions[[string]$field["referenceName"]] = $field
    }

    $typeFields = @{}
    $plan = New-Object System.Collections.Generic.List[object]

    foreach ($item in $items) {
        $sourceType = [string]$item["fields"]["System.WorkItemType"]
        $targetType = if ($MappingObject.ContainsKey("work_item_types") -and $MappingObject["work_item_types"].ContainsKey($sourceType)) {
            [string]$MappingObject["work_item_types"][$sourceType]
        }
        else {
            $sourceType
        }

        if (-not $typeFields.ContainsKey($targetType)) {
            $escapedType = Escape-UriPathSegment -Segment $targetType
            $result = Get-Ado -Client $DestinationClient -Path ("workitemtypes/{0}/fields" -f $escapedType)
            $allowed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($f in @($result["value"])) {
                [void]$allowed.Add([string]$f["referenceName"])
            }
            $typeFields[$targetType] = $allowed
        }

        $mapped = Get-MappedFields -Item $item -Mapping $MappingObject -Definitions $definitions -Allowed $typeFields[$targetType] -TargetProject $DestinationClient.Project
        $targetType = $mapped.TargetType
        $fields = $mapped.Fields

        foreach ($comment in @($item["migration_comments"])) {
            $cid = if ($comment.ContainsKey("id")) { $comment["id"] } else { $comment["commentId"] }
            if ($null -eq $cid) {
                Throw-MigrationError ("Source {0} has a comment without an ID" -f $item["id"])
            }
            [void](Get-RenderedComment -Comment $comment)
        }

        $attachments = Get-AttachmentsForItem -Source $SourceClient -Item $item -Fields $fields

        [void](Invoke-AdoRequest -Client $DestinationClient -Method "POST" -Url (Get-AdoApiUrl -Client $DestinationClient -Path ("workitems/$" + (Escape-UriPathSegment -Segment $targetType))) -Payload (Get-FieldPatch -Fields $fields) -Patch -Query @{ validateOnly = "true" })

        $plan.Add(@{
            item = $item
            type = $targetType
            fields = $fields
            attachments = $attachments
        })

        Write-Notice (
            "Validated source {0} -> {1}: {2} comments, {3} attachments" -f
            $item["id"], $targetType, @($item["migration_comments"]).Count, @($attachments.Keys).Count
        )
    }

    if ($DryRun) {
        return @{
            dry_run = $true
            work_items = @($plan | ForEach-Object { $_["item"]["id"] })
        }
    }

    # Build a serialization-safe snapshot for checkpoint binding.
    $planFingerprint = @()
    foreach ($entry in $plan) {
        $item = $entry["item"]
        $commentIds = @()
        foreach ($comment in @($item["migration_comments"])) {
            if ($comment.ContainsKey("id") -and $null -ne $comment["id"]) {
                $commentIds += $comment["id"]
            }
            elseif ($comment.ContainsKey("commentId") -and $null -ne $comment["commentId"]) {
                $commentIds += $comment["commentId"]
            }
        }

        $planFingerprint += @{
            id = $item["id"]
            rev = $item["rev"]
            source_type = $item["fields"]["System.WorkItemType"]
            target_type = $entry["type"]
            fields = ConvertTo-CanonicalObject -InputObject $entry["fields"]
            children = @($item["migration_children"])
            comment_ids = @($commentIds)
            attachment_keys = @($entry["attachments"].Keys | Sort-Object)
        }
    }

    $fingerprintObject = @{
        mapping = ConvertTo-CanonicalObject -InputObject $MappingObject
        plan = @($planFingerprint)
    }
    $canonical = ConvertTo-CanonicalObject -InputObject $fingerprintObject
    $fingerprint = Get-Sha256Hex -Text (ConvertTo-Json $canonical -Compress -Depth 100)

    $binding = @{
        source = $SourceClient.Base
        destination = $DestinationClient.Base
        root_id = $RootId
        fingerprint = $fingerprint
    }

    $checkpoint = New-Checkpoint -Path $CheckpointPath -Binding $binding
    $state = $checkpoint.Data

    foreach ($entry in $plan) {
        $item = $entry["item"]
        $fields = $entry["fields"]
        $sourceId = [string]$item["id"]
        $replacements = @{}

        foreach ($key in @($entry["attachments"].Keys)) {
            $attachment = $entry["attachments"][$key]
            if (-not $state["attachments"].ContainsKey($key)) {
                $content = Invoke-AdoRequest -Client $SourceClient -Method "GET" -Url $attachment["url"] -Download
                [void](Invoke-CheckpointWrite -Checkpoint $checkpoint -Destination $DestinationClient -Section "attachments" -Key $key -Method "POST" -Url (Get-AdoApiUrl -Client $DestinationClient -Path "attachments") -ResultField "url" -Binary $content -Query @{ fileName = $attachment["name"]; uploadType = "Simple" })
            }
            $replacements[$key] = $state["attachments"][$key]
        }

        $rewritten = @{}
        foreach ($name in @($fields.Keys)) {
            $value = $fields[$name]
            if ($value -is [string]) {
                $rewritten[$name] = Rewrite-AttachmentsInText -Text $value -Replacements $replacements
            }
            else {
                $rewritten[$name] = $value
            }
        }

        if (-not $state["items"].ContainsKey($sourceId)) {
            $patch = New-Object System.Collections.Generic.List[object]
            foreach ($operation in @(Get-FieldPatch -Fields $rewritten)) {
                $patch.Add($operation)
            }

            foreach ($key in @($entry["attachments"].Keys)) {
                $attachment = $entry["attachments"][$key]
                $patch.Add(@{
                    op = "add"
                    path = "/relations/-"
                    value = @{
                        rel = "AttachedFile"
                        url = $replacements[$key]
                        attributes = @{
                            comment = $attachment["comment"]
                        }
                    }
                })
            }

            [void](Invoke-CheckpointWrite -Checkpoint $checkpoint -Destination $DestinationClient -Section "items" -Key $sourceId -Method "POST" -Url (Get-AdoApiUrl -Client $DestinationClient -Path ("workitems/$" + (Escape-UriPathSegment -Segment $entry["type"]))) -ResultField "id" -Payload $patch.ToArray() -Patch)
        }

        $destinationId = $state["items"][$sourceId]

        foreach ($comment in @($item["migration_comments"])) {
            $commentId = if ($comment.ContainsKey("id")) { $comment["id"] } else { $comment["commentId"] }
            if ($null -eq $commentId) {
                Throw-MigrationError ("Source {0} has a comment without an ID" -f $sourceId)
            }

            $key = "{0}:{1}" -f $sourceId, $commentId
            if ($state["comments"].ContainsKey($key)) {
                continue
            }

            $author = if ($comment.ContainsKey("createdBy")) { $comment["createdBy"] } else { @{} }
            $authorName = if ($author.ContainsKey("displayName")) {
                [string]$author["displayName"]
            }
            elseif ($author.ContainsKey("uniqueName")) {
                [string]$author["uniqueName"]
            }
            else {
                "unknown"
            }

            $createdDate = if ($comment.ContainsKey("createdDate")) { [string]$comment["createdDate"] } else { "unknown" }
            $attribution = "Copied from {0}/_workitems/edit/{1}; author: {2}; created: {3}" -f $SourceClient.Base, $sourceId, $authorName, $createdDate
            $rendered = Get-RenderedComment -Comment $comment
            $text = "<p>{0}</p>`n{1}" -f ([System.Net.WebUtility]::HtmlEncode($attribution)), (Rewrite-AttachmentsInText -Text $rendered -Replacements $replacements)

            [void](Invoke-CheckpointWrite -Checkpoint $checkpoint -Destination $DestinationClient -Section "comments" -Key $key -Method "POST" -Url (Get-AdoApiUrl -Client $DestinationClient -Path ("workitems/{0}/comments" -f $destinationId)) -Payload @{ text = $text } -Query @{ "api-version" = $SCRIPT:COMMENTS_VERSION; format = "html" })
        }

        Write-Notice ("Copied {0} -> {1}" -f $sourceId, $destinationId)
    }

    foreach ($entry in $plan) {
        $parent = [string]$entry["item"]["id"]
        foreach ($childId in @($entry["item"]["migration_children"])) {
            $child = [string]$childId
            $key = "{0}:{1}" -f $parent, $child
            if ($state["links"] -contains $key) {
                continue
            }

            [void](Invoke-CheckpointWrite -Checkpoint $checkpoint -Destination $DestinationClient -Section "links" -Key $key -Method "PATCH" -Url (Get-AdoApiUrl -Client $DestinationClient -Path ("workitems/{0}" -f $state["items"][$parent])) -Payload @(@{
                op = "add"
                path = "/relations/-"
                value = @{
                    rel = $SCRIPT:CHILD_REL
                    url = Get-AdoApiUrl -Client $DestinationClient -Path ("workitems/{0}" -f $state["items"][$child])
                }
            }) -Patch)
        }
    }

    return @{
        dry_run = $false
        items = $state["items"]
        checkpoint = $CheckpointPath
    }
}

function Invoke-Main {
    param(
        [string]$SourceUrl,
        [string]$DestinationUrl,
        [int]$RootId,
        [string]$MappingPath,
        [string]$CheckpointFile,
        [switch]$ShouldDryRun,
        [double]$TimeoutSeconds
    )

    if ($RootId -le 0 -or $TimeoutSeconds -le 0 -or [double]::IsInfinity($TimeoutSeconds) -or [double]::IsNaN($TimeoutSeconds)) {
        Throw-MigrationError "--id and --timeout must be positive finite values"
    }

    $sourcePat = [Environment]::GetEnvironmentVariable("ADO_SOURCE_PAT")
    $destinationPat = [Environment]::GetEnvironmentVariable("ADO_DEST_PAT")
    if (-not $sourcePat -or -not $destinationPat) {
        Throw-MigrationError "Set ADO_SOURCE_PAT and ADO_DEST_PAT environment variables"
    }

    $sourceClient = $null
    $destinationClient = $null

    try {
        $resolvedMappingPath = $null
        if ($MappingPath) {
            $resolvedMappingPath = Resolve-ScriptRelativePath -Path $MappingPath
        }
        $resolvedCheckpointFile = Resolve-ScriptRelativePath -Path $CheckpointFile

        $mappingObject = Load-Mapping -Path $resolvedMappingPath
        $sourceClient = New-AdoClient -ProjectUrl $SourceUrl -Pat $sourcePat -TimeoutSeconds $TimeoutSeconds
        $destinationClient = New-AdoClient -ProjectUrl $DestinationUrl -Pat $destinationPat -TimeoutSeconds $TimeoutSeconds

        $result = Invoke-Migration -SourceClient $sourceClient -DestinationClient $destinationClient -RootId $RootId -MappingObject $mappingObject -CheckpointPath $resolvedCheckpointFile -DryRun:$ShouldDryRun
        $resultJson = ConvertTo-Json $result -Depth 100
        [Console]::Out.WriteLine($resultJson)
        return 0
    }
    catch {
        Write-ExceptionDetails -ErrorRecord $_
        throw
    }
    finally {
        if ($sourceClient) {
            if ($sourceClient.HttpClient) { $sourceClient.HttpClient.Dispose() }
            if ($sourceClient.Handler) { $sourceClient.Handler.Dispose() }
        }
        if ($destinationClient) {
            if ($destinationClient.HttpClient) { $destinationClient.HttpClient.Dispose() }
            if ($destinationClient.Handler) { $destinationClient.Handler.Dispose() }
        }
    }
}

try {
    $exitCode = Invoke-Main -SourceUrl $Source -DestinationUrl $Destination -RootId $Id -MappingPath $Mapping -CheckpointFile $Checkpoint -ShouldDryRun:$DryRun -TimeoutSeconds $Timeout
    exit $exitCode
}
catch {
    Write-Notice ("Migration failed: {0}" -f $_.Exception.Message)
    Write-ExceptionDetails -ErrorRecord $_
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Notice $_.InvocationInfo.PositionMessage
    }
    Write-Notice "Any completed destination writes remain. Check the checkpoint before retrying."
    exit 1
}
