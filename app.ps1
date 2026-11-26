param([Parameter(Mandatory=$true, Position=0)][string] $InputPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Read-Text($Value, [string]$Name) {
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must be a nonempty string"
    }
    return $Value.Trim()
}

function Read-Records($Value, [string]$Name) {
    if ($Value -isnot [array]) { throw "$Name must be a JSON array" }
    foreach ($entry in $Value) {
        if ($entry -isnot [System.Collections.IDictionary]) {
            throw "$Name must contain JSON objects"
        }
    }
    return ,$Value
}

function Read-Boolean($Value, [string]$Name) {
    if ($Value -isnot [bool]) { throw "$Name must be true or false" }
    return $Value
}

function Read-Date($Value, [string]$Name) {
    $date = [datetime]::MinValue
    if ($Value -isnot [string] -or -not [datetime]::TryParseExact(
        $Value, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::None, [ref]$date)) {
        throw "$Name must be a valid date in yyyy-MM-dd format"
    }
    return $date
}

function Invoke-Analysis($data) {
    $asOf = Read-Date $data['as_of'] 'as_of'
    $loans = Read-Records $data['loans'] 'loans'
    $ids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $open = 0
    $overdue = 0
    $missingReports = 0
    $report = @(foreach ($loan in $loans) {
        $id = Read-Text $loan['id'] 'loan id'
        if (-not $ids.Add($id)) { throw "Duplicate loan id $id" }
        $work = Read-Text $loan['artwork'] "artwork for $id"
        $due = Read-Date $loan['due_on'] "due_on for $id"
        $outboundReport = Read-Boolean $loan['outbound_report'] "outbound_report for $id"
        $returnReport = Read-Boolean $loan['return_report'] "return_report for $id"
        $actualReturn = $loan['returned_on']

        if ($null -eq $actualReturn) {
            $open++
            $late = [Math]::Max(0, ($asOf - $due).Days)
            $status = if ($late) { 'overdue' } else { 'on_loan' }
            if ($late) { $overdue++ }
        } else {
            $returned = Read-Date $actualReturn "returned_on for $id"
            if ($returned -gt $asOf) { throw "returned_on for $id cannot be after as_of" }
            $late = [Math]::Max(0, ($returned - $due).Days)
            $status = if ($late) { 'returned_late' } else { 'returned' }
        }
        $paperwork = @(
            if (-not $outboundReport) { 'outbound_condition' }
            if ($null -ne $actualReturn -and -not $returnReport) { 'return_condition' }
        )
        $missingReports += $paperwork.Count
        [ordered]@{
            id = $id
            artwork = $work
            due_on = $loan['due_on']
            returned_on = $actualReturn
            status = $status
            days_late = $late
            missing_reports = $paperwork
        }
    })
    return [ordered]@{
        as_of = $data['as_of']
        open_loans = $open
        overdue_loans = $overdue
        missing_report_count = $missingReports
        loans = $report
    }
}

try {
    $payload = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json -AsHashtable
    if ($payload -isnot [System.Collections.IDictionary]) { throw 'Input must be a JSON object' }
    Invoke-Analysis $payload | ConvertTo-Json -Depth 30 -Compress
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
