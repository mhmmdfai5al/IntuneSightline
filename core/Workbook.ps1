Set-StrictMode -Version Latest

<#
    Minimal OpenXML spreadsheet writer.

    An .xlsx file is a zip of XML parts. Writing them directly avoids depending
    on Excel (Windows only) or ImportExcel (a module admins would have to
    install), both of which would break the "clone and run" promise.

    Values are written as inline strings rather than a shared string table.
    Slightly larger on disk, far less to get wrong.
#>

function ConvertTo-SightlineXmlText {
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return '' }
    $text = [string]$Value

    # Control characters are illegal in XML 1.0 and will corrupt the file.
    $text = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')

    return [System.Security.SecurityElement]::Escape($text)
}

function Get-SightlineColumnRef {
    param([Parameter(Mandatory)] [int] $Index)   # 1-based

    $ref = ''
    $n   = $Index
    while ($n -gt 0) {
        $remainder = ($n - 1) % 26
        $ref = [char](65 + $remainder) + $ref
        $n = [int](($n - $remainder - 1) / 26)
    }
    return $ref
}

function Get-SightlineSafeSheetName {
    <#
        Excel rejects names over 31 characters or containing : \ / ? * [ ]
        and silently refuses to open the file rather than explaining why.
    #>
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $Existing = @()
    )

    $clean = $Name -replace '[:\\/?*\[\]]', '-'
    $clean = $clean.Trim()
    if ([string]::IsNullOrWhiteSpace($clean)) { $clean = 'Sheet' }
    if ($clean.Length -gt 31) { $clean = $clean.Substring(0, 31) }

    $candidate = $clean
    $suffix    = 2
    while ($Existing -contains $candidate) {
        $tail      = "-$suffix"
        $candidate = $clean.Substring(0, [math]::Min($clean.Length, 31 - $tail.Length)) + $tail
        $suffix++
    }

    return $candidate
}

function ConvertTo-SightlineSheetXml {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Rows,
        [string[]] $Columns
    )

    if (-not $Columns -or $Columns.Count -eq 0) {
        if ($Rows.Count -gt 0) {
            $Columns = @($Rows[0].PSObject.Properties.Name)
        } else {
            $Columns = @('(no data)')
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$sb.Append('<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">')

    # Freeze the header so a long export stays readable while scrolling.
    [void]$sb.Append('<sheetViews><sheetView workbookViewId="0">')
    [void]$sb.Append('<pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>')
    [void]$sb.Append('</sheetView></sheetViews>')

    # Width from the widest of the header and the first 200 rows.
    [void]$sb.Append('<cols>')
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $widest = $Columns[$i].Length
        $sample = [math]::Min($Rows.Count, 200)
        for ($r = 0; $r -lt $sample; $r++) {
            $value = $Rows[$r].PSObject.Properties[$Columns[$i]]
            if ($value -and $null -ne $value.Value) {
                $len = ([string]$value.Value).Length
                if ($len -gt $widest) { $widest = $len }
            }
        }
        $width = [math]::Min([math]::Max($widest + 2, 10), 70)
        [void]$sb.Append("<col min=""$($i + 1)"" max=""$($i + 1)"" width=""$width"" customWidth=""1""/>")
    }
    [void]$sb.Append('</cols>')

    [void]$sb.Append('<sheetData>')

    [void]$sb.Append('<row r="1">')
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $ref = (Get-SightlineColumnRef -Index ($i + 1)) + '1'
        [void]$sb.Append("<c r=""$ref"" t=""inlineStr"" s=""1""><is><t xml:space=""preserve"">")
        [void]$sb.Append((ConvertTo-SightlineXmlText -Value $Columns[$i]))
        [void]$sb.Append('</t></is></c>')
    }
    [void]$sb.Append('</row>')

    for ($r = 0; $r -lt $Rows.Count; $r++) {
        $rowNumber = $r + 2
        [void]$sb.Append("<row r=""$rowNumber"">")

        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $ref      = (Get-SightlineColumnRef -Index ($i + 1)) + $rowNumber
            $property = $Rows[$r].PSObject.Properties[$Columns[$i]]
            $value    = if ($property) { $property.Value } else { $null }

            if ($null -eq $value -or ($value -is [string] -and $value -eq '')) {
                continue   # an empty cell needs no element at all
            }

            $isNumber = $value -is [int] -or $value -is [long] -or
                        $value -is [double] -or $value -is [decimal]

            if ($isNumber) {
                [void]$sb.Append("<c r=""$ref""><v>$value</v></c>")
            }
            else {
                if ($value -is [bool]) { $value = if ($value) { 'TRUE' } else { 'FALSE' } }
                [void]$sb.Append("<c r=""$ref"" t=""inlineStr""><is><t xml:space=""preserve"">")
                [void]$sb.Append((ConvertTo-SightlineXmlText -Value $value))
                [void]$sb.Append('</t></is></c>')
            }
        }
        [void]$sb.Append('</row>')
    }

    [void]$sb.Append('</sheetData>')

    if ($Rows.Count -gt 0) {
        $lastCol = Get-SightlineColumnRef -Index $Columns.Count
        [void]$sb.Append("<autoFilter ref=""A1:$lastCol$($Rows.Count + 1)""/>")
    }

    [void]$sb.Append('</worksheet>')
    return $sb.ToString()
}

function New-SightlineWorkbook {
    <#
        Writes an .xlsx from an ordered list of sheets.

        Each sheet is a hashtable: @{ Name = 'Assignments'; Rows = @(...) }
        with an optional Columns array to fix ordering.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [object[]] $Sheets
    )

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $names = [System.Collections.Generic.List[string]]::new()
    $parts = [ordered]@{}

    $contentTypes = [System.Text.StringBuilder]::new()
    [void]$contentTypes.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$contentTypes.Append('<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">')
    [void]$contentTypes.Append('<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>')
    [void]$contentTypes.Append('<Default Extension="xml" ContentType="application/xml"/>')
    [void]$contentTypes.Append('<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>')
    [void]$contentTypes.Append('<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>')

    $workbookSheets = [System.Text.StringBuilder]::new()
    $workbookRels   = [System.Text.StringBuilder]::new()
    [void]$workbookRels.Append('<?xml version="1.0" encoding="UTF-8" standalone="yes"?>')
    [void]$workbookRels.Append('<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">')

    $index = 0
    foreach ($sheet in $Sheets) {
        $index++
        $name = Get-SightlineSafeSheetName -Name $sheet.Name -Existing $names
        $names.Add($name)

        $rows    = @(if ($sheet.ContainsKey('Rows'))    { $sheet.Rows }    else { @() })
        $columns = @(if ($sheet.ContainsKey('Columns')) { $sheet.Columns } else { @() })

        $parts["xl/worksheets/sheet$index.xml"] = ConvertTo-SightlineSheetXml -Rows $rows -Columns $columns

        [void]$contentTypes.Append("<Override PartName=""/xl/worksheets/sheet$index.xml"" ContentType=""application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml""/>")
        [void]$workbookSheets.Append("<sheet name=""$(ConvertTo-SightlineXmlText -Value $name)"" sheetId=""$index"" r:id=""rId$index""/>")
        [void]$workbookRels.Append("<Relationship Id=""rId$index"" Type=""http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet"" Target=""worksheets/sheet$index.xml""/>")
    }

    [void]$contentTypes.Append('</Types>')
    [void]$workbookRels.Append("<Relationship Id=""rId$($index + 1)"" Type=""http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles"" Target=""styles.xml""/>")
    [void]$workbookRels.Append('</Relationships>')

    $parts['[Content_Types].xml'] = $contentTypes.ToString()

    $parts['_rels/.rels'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">' +
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>' +
        '</Relationships>'

    $parts['xl/workbook.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' +
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">' +
        "<sheets>$($workbookSheets.ToString())</sheets></workbook>"

    $parts['xl/_rels/workbook.xml.rels'] = $workbookRels.ToString()

    # Two fonts only: normal and bold. Style index 1 is the header.
    $parts['xl/styles.xml'] = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>' +
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">' +
        '<fonts count="2">' +
        '<font><sz val="11"/><name val="Calibri"/></font>' +
        '<font><b/><sz val="11"/><name val="Calibri"/></font>' +
        '</fonts>' +
        '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>' +
        '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>' +
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>' +
        '<cellXfs count="2">' +
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>' +
        '<xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/>' +
        '</cellXfs>' +
        '</styleSheet>'

    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }

    $stream  = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew)
    $archive = $null
    try {
        $archive  = [System.IO.Compression.ZipArchive]::new($stream, [System.IO.Compression.ZipArchiveMode]::Create)
        $encoding = [System.Text.UTF8Encoding]::new($false)

        foreach ($key in $parts.Keys) {
            $entry       = $archive.CreateEntry($key, [System.IO.Compression.CompressionLevel]::Optimal)
            $entryStream = $entry.Open()
            try {
                $bytes = $encoding.GetBytes($parts[$key])
                $entryStream.Write($bytes, 0, $bytes.Length)
            }
            finally { $entryStream.Dispose() }
        }
    }
    finally {
        if ($archive) { $archive.Dispose() }
        $stream.Dispose()
    }

    return $Path
}

function ConvertTo-SightlineProvenanceRows {
    # The provenance block as sheet one, so it travels inside the workbook
    # rather than as a text file nobody opens.
    param([Parameter(Mandatory)] $Provenance)

    $rows = [System.Collections.Generic.List[object]]::new()
    $add  = { param($k, $v) $rows.Add([pscustomobject]@{ Item = $k; Value = $v }) }

    & $add 'Tool'            "$($Provenance.Tool) v$($Provenance.ToolVersion)"
    & $add 'Generated'       $Provenance.GeneratedAt
    & $add 'Tenant'          "$($Provenance.Tenant) [$($Provenance.TenantId)]"
    & $add 'Collected by'    $Provenance.CollectedBy
    & $add 'Permissions'     $Provenance.ScopesGranted
    & $add 'Host platform'   $Provenance.Platform
    & $add '' ''
    & $add 'Coverage' ''

    foreach ($entry in @($Provenance.Coverage)) {
        $state = if ($entry.Complete) { 'complete' } else { 'INCOMPLETE' }
        $detail = "$($entry.Count) item(s), $state"
        if (-not $entry.Complete -and $entry.Failure) { $detail += " - $($entry.Failure)" }
        & $add "  $($entry.Source)" $detail
    }

    & $add '' ''
    & $add 'Warnings' ''
    $warnings = @($Provenance.Warnings)
    if ($warnings.Count -eq 0) {
        & $add '  (none)' ''
    } else {
        foreach ($w in $warnings) { & $add '  •' $w }
    }

    & $add '' ''
    & $add 'Note' 'An export with any INCOMPLETE source is not a full picture of the tenant. Results absent from it may exist but were not collected.'

    return @($rows)
}

function Save-SightlineDataset {
    <#
        Single exit point for tool output.

        Tools hand over named datasets and let core decide the file format, so
        every export looks the same and no tool invents its own convention.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]   $Folder,
        [Parameter(Mandatory)] [object[]] $Sheets,
        [Parameter(Mandatory)] $Provenance,
        [ValidateSet('Workbook', 'CSV')] [string] $Format = 'Workbook',
        [string] $BaseName = 'export'
    )

    if ($Format -eq 'CSV') {
        foreach ($sheet in $Sheets) {
            $rows = @(if ($sheet.ContainsKey('Rows')) { $sheet.Rows } else { @() })
            $file = ($sheet.Name -replace '[^A-Za-z0-9\-]', '-').ToLower() + '.csv'
            Write-SightlineCsv -Path (Join-Path $Folder $file) -Rows $rows
        }
        Write-SightlineProvenanceFile -Folder $Folder -Provenance $Provenance
        return $Folder
    }

    $all = @(
        @{ Name = 'About this export'; Rows = (ConvertTo-SightlineProvenanceRows -Provenance $Provenance); Columns = @('Item', 'Value') }
    ) + $Sheets

    $path = Join-Path $Folder "$BaseName.xlsx"
    New-SightlineWorkbook -Path $path -Sheets $all | Out-Null

    # No separate text file here - it is sheet one, and two copies that can
    # drift apart is worse than one.
    return $path
}
