param(
    [Parameter(Mandatory = $true)]
    [string]$ReferenceProject,
    [Parameter(Mandatory = $true)]
    [string]$PdsShell,
    [ValidateSet('Brown', 'Fisheye')]
    [string]$Model = 'Fisheye',
    [ValidateRange(1, 16)]
    [int]$ReadDepth = 2,
    [string]$OutputDirectory,
    [string]$BrownRegistersJson,
    [switch]$PrepareOnly,
    [switch]$SynthesizeOnly,
    [switch]$IdentityMapDiagnostic,
    [switch]$DiagnosticOverlay,
    [switch]$DiagnosticPatternWriter,
    [switch]$DisplayPrefetchBursts,
    [ValidateRange(1, 255)]
    [int]$DisplayPrefetchTriggerPixels = 128,
    [ValidateSet(1, 3)]
    [int]$HmicFenceCheckPoints = 1,
    [switch]$UseSccbOwnerCameraConfig,
    [switch]$OptimizeHoldTiming,
    [ValidateRange(0, 1000)]
    [int]$HoldThresholdPs = 0,
    [ValidateRange(0, 2147483647)]
    [int]$PlacementSeed = 0,
    [ValidateRange(1, 64)]
    [int]$PlacementRuns = 1,
    [ValidateRange(1, 64)]
    [int]$ParallelPlacementRuns = 1,
    [ValidateRange(1, 64)]
    [int]$SaveBestPlacementRuns = 1,
    [ValidateRange(1, 2147483647)]
    [int]$PlacementSeedStep = 1,
    [ValidateRange(0, 600)]
    [int]$ActionTimeoutMinutes = 0,
    [switch]$DumpRouterCongestionPlot,
    [ValidateRange(0, 1000)]
    [int]$CongestOverlapLimit = 0,
    [switch]$ConstrainCameraConfigClock
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$referenceRoot = (Resolve-Path -LiteralPath $ReferenceProject).Path
$pdsShellPath = (Resolve-Path -LiteralPath $PdsShell).Path
if ($HoldThresholdPs -gt 0 -and -not $OptimizeHoldTiming) {
    throw 'HoldThresholdPs requires OptimizeHoldTiming.'
}
if ($ParallelPlacementRuns -gt $PlacementRuns -or
    $SaveBestPlacementRuns -gt $PlacementRuns) {
    throw 'ParallelPlacementRuns and SaveBestPlacementRuns cannot exceed PlacementRuns.'
}
$buildRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'build'))
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputDirectory = Join-Path $buildRoot "pgl50h_formal_$($Model.ToLowerInvariant())_rd$ReadDepth`_$stamp"
}
if (-not [IO.Path]::IsPathRooted($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot $OutputDirectory
}
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
if (-not $outputRoot.StartsWith($buildRoot + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Build output must be a new isolated directory under $buildRoot"
}
if (Test-Path -LiteralPath $outputRoot) {
    throw "Refusing to overwrite existing build output: $outputRoot"
}

$brownRegisters = [ordered]@{}
if ($BrownRegistersJson) {
    if ($Model -ne 'Brown') { throw 'BrownRegistersJson requires Model=Brown.' }
    $brownProfilePath = (Resolve-Path -LiteralPath $BrownRegistersJson).Path
    $profile = Get-Content -LiteralPath $brownProfilePath -Raw | ConvertFrom-Json
    $registerNames = @('CAMERA_FX_Q8', 'CAMERA_FY_Q8', 'CAMERA_CX_Q8', 'CAMERA_CY_Q8',
        'INV_CAMERA_FX_Q22', 'INV_CAMERA_FY_Q22', 'BROWN_K1_Q18', 'BROWN_K2_Q18',
        'BROWN_P1_Q18', 'BROWN_P2_Q18')
    $keys = @($profile.PSObject.Properties.Name)
    if ($keys.Count -ne 10 -or @($keys | Where-Object { $_ -notin $registerNames }).Count) {
        throw 'Brown register profile must contain exactly the ten supported registers.'
    }
    foreach ($name in $registerNames) {
        $value = $profile.$name
        if ($null -eq $value -or $value -is [bool] -or $value -is [string] -or
            $value -isnot [ValueType]) { throw "Register $name requires a numeric integer." }
        $number = [double]$value
        $unsigned = $name.StartsWith('INV_')
        $bits = if ($name.EndsWith('_Q8')) { 20 } else { 22 }
        $lower = if ($unsigned) { 1 } else { -(1L -shl ($bits - 1)) }
        $upper = if ($unsigned) { (1L -shl $bits) - 1 } else { (1L -shl ($bits - 1)) - 1 }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
            $number -ne [math]::Truncate($number) -or $number -lt $lower -or
            $number -gt $upper -or ($name -in @('CAMERA_FX_Q8', 'CAMERA_FY_Q8') -and $number -le 0)) {
            throw "Register $name is not an in-range integer."
        }
        $brownRegisters[$name] = [long]$number
    }
}

$projectFiles = @(Get-ChildItem -LiteralPath $referenceRoot -File -Filter '*.pds' |
    Where-Object {
        $text = Get-Content -LiteralPath $_.FullName -Raw
        $text -match '\(_device PGL50H\)' -and
        $text -match 'source/rtl/DDR3_50H/DDR3_50H\.idf'
    })
if ($projectFiles.Count -ne 1) {
    throw "Expected exactly one reference PDS project; found $($projectFiles.Count)"
}
$projectFile = $projectFiles[0]
$projectText = Get-Content -LiteralPath $projectFile.FullName -Raw
if ($projectText -notmatch '\(_device PGL50H\)' -or
    $projectText -notmatch 'source/rtl/DDR3_50H/DDR3_50H\.idf') {
    throw 'Reference PDS project is not the expected PGL50H + DDR3_50H design.'
}
foreach ($required in @(
        (Join-Path $referenceRoot 'source\rtl\hdmi_ddr_ov5640_top.v'),
        (Join-Path $referenceRoot 'source\rtl\pll\pll.idf'),
        (Join-Path $referenceRoot 'source\rtl\DDR3_50H\DDR3_50H.idf'),
        (Join-Path $referenceRoot 'hdmi_ddr_ov5640_top.fdc'))) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Reference project is missing required input: $required"
    }
}

New-Item -ItemType Directory -Path $outputRoot | Out-Null
Copy-Item -LiteralPath (Join-Path $referenceRoot 'source') -Destination $outputRoot -Recurse
Copy-Item -LiteralPath $projectFile.FullName -Destination $outputRoot
Copy-Item -LiteralPath (Join-Path $referenceRoot 'hdmi_ddr_ov5640_top.fdc') -Destination $outputRoot

if ($UseSccbOwnerCameraConfig) {
    $candidate = Join-Path $repoRoot 'scripts\pds_reg_config_sccb_owner_candidate.v'
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "SCCB owner candidate adapter is missing: $candidate"
    }
    $vendorConfig = Join-Path $outputRoot 'source\rtl\reg_config.v'
    Copy-Item -LiteralPath $candidate -Destination $vendorConfig -Force

    $initTable = Join-Path $repoRoot 'rtl\data\ov5640_720p30_init_2023.mem'
    if (-not (Test-Path -LiteralPath $initTable -PathType Leaf)) {
        throw "OV5640 initialization table is missing: $initTable"
    }
    $cameraMemoryDirectory = Join-Path $outputRoot 'source\rtl\data'
    New-Item -ItemType Directory -Path $cameraMemoryDirectory -Force | Out-Null
    Copy-Item -LiteralPath $initTable -Destination (Join-Path $cameraMemoryDirectory 'ov5640_720p30_init_2023.mem') -Force
}

$rtlFiles = @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'rtl\correction') -File -Filter '*.v' |
    Where-Object { $_.Name -notin @('hmic_ddr_diag_board_top.v',
        'pgl50h_camera_distortion_top.v') } | Sort-Object Name)
if ($rtlFiles.Count -lt 30) {
    throw "Only found $($rtlFiles.Count) RTL files; refusing a partial top integration."
}
$targetRtl = Join-Path $outputRoot 'source\rtl\correction'
# A reference project cloned from an earlier isolated build may already carry
# this directory. Reuse it; the maintained RTL files below are copied over and
# explicitly registered in the fresh PDS project file.
New-Item -ItemType Directory -Path $targetRtl -Force | Out-Null
foreach ($file in $rtlFiles) {
    Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $targetRtl $file.Name)
}
$memoryDirectory = Join-Path $outputRoot 'source\rtl\data'
New-Item -ItemType Directory -Path $memoryDirectory -Force | Out-Null
foreach ($memory in @(Get-ChildItem -LiteralPath (Join-Path $repoRoot 'rtl\data') -File -Filter '*.mem')) {
    Copy-Item -LiteralPath $memory.FullName -Destination (Join-Path $memoryDirectory $memory.Name) -Force
}

$topSource = Get-Content -LiteralPath (Join-Path $repoRoot 'rtl\pgl50h_camera_distortion_top.v') -Raw
foreach ($boardPort in @('cmos1_pclk', 'cmos1_data', 'r_out', 'g_out', 'b_out')) {
    if ($topSource -notmatch "(?m)^\s*(?:input|output|inout)\b[^;]*\b$boardPort\b") {
        throw "Maintained board top is missing FDC-required port: $boardPort"
    }
}
$modelValue = if ($Model -eq 'Fisheye') { 1 } else { 0 }
$identityMapValue = if ($IdentityMapDiagnostic) { 1 } else { 0 }
$diagnosticOverlayValue = if ($DiagnosticOverlay) { 1 } else { 0 }
$diagnosticPatternWriterValue = if ($DiagnosticPatternWriter) { 1 } else { 0 }
$displayPrefetchBurstsValue = if ($DisplayPrefetchBursts) { 1 } else { 0 }
$hmicFenceCheckPointsValue = $HmicFenceCheckPoints
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer READ_DEPTH\s*=\s*)\d+(\s*,)', "`${1}$ReadDepth`${2}", 1)
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer USE_FISHEYE\s*=\s*)\d+(\s*,)', "`${1}$modelValue`${2}", 1)
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer IDENTITY_MAP_DIAGNOSTIC\s*=\s*)\d+(\s*,)',
    "`${1}$identityMapValue`${2}", 1)
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer DIAGNOSTIC_OVERLAY\s*=\s*)\d+(\s*,)',
    "`${1}$diagnosticOverlayValue`${2}", 1)
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer DIAGNOSTIC_PATTERN_WRITER\s*=\s*)\d+(\s*,)',
    "`${1}$diagnosticPatternWriterValue`${2}", 1)
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer DISPLAY_PREFETCH_BURSTS\s*=\s*)\d+(\s*,)',
    "`${1}$displayPrefetchBurstsValue`${2}", 1)
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer DISPLAY_PREFETCH_TRIGGER_PIXELS\s*=\s*)\d+(\s*,)',
    "`${1}$DisplayPrefetchTriggerPixels`${2}", 1)
$topSource = [regex]::Replace($topSource,
    '(?m)(parameter integer HMIC_FENCE_CHECK_POINTS\s*=\s*)\d+(\s*,)',
    "`${1}$hmicFenceCheckPointsValue`${2}", 1)
if ($Model -eq 'Fisheye') {
    $topSource = [regex]::Replace($topSource,
        'parameter FISHEYE_INIT_FILE\s*=\s*"[^"]+"',
        'parameter FISHEYE_INIT_FILE = "source/rtl/data/fisheye_candidate_2026-10-16_q16_low16.mem"', 1)
    $topSource = [regex]::Replace($topSource,
        'parameter FISHEYE_INIT_FILE_HI\s*=\s*"[^"]+"',
        'parameter FISHEYE_INIT_FILE_HI = "source/rtl/data/fisheye_candidate_2026-10-16_q16_high2.mem"', 1)
    $topSource = [regex]::Replace($topSource,
        'parameter FISHEYE_INIT_FILE_DELTA\s*=\s*"[^"]+"',
        'parameter FISHEYE_INIT_FILE_DELTA = "source/rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem"', 1)
    foreach ($name in @('fisheye_candidate_2026-10-16_q16_low16.mem',
            'fisheye_candidate_2026-10-16_q16_high2.mem',
            'fisheye_candidate_2026-10-16_q16_delta_s12.mem')) {
        $memorySource = Join-Path (Join-Path $repoRoot 'rtl\data') $name
        if (-not (Test-Path -LiteralPath $memorySource -PathType Leaf)) {
            throw "Required fish-eye ROM is missing: $memorySource"
        }
        $memoryDirectory = Join-Path $outputRoot 'source\rtl\data'
        New-Item -ItemType Directory -Path $memoryDirectory -Force | Out-Null
        Copy-Item -LiteralPath $memorySource -Destination (Join-Path $memoryDirectory $name)
    }
}
if ($topSource -notmatch "parameter integer READ_DEPTH\s*=\s*$ReadDepth\s*," -or
    $topSource -notmatch "parameter integer USE_FISHEYE\s*=\s*$modelValue\s*," -or
    $topSource -notmatch "parameter integer IDENTITY_MAP_DIAGNOSTIC\s*=\s*$identityMapValue\s*," -or
    $topSource -notmatch "parameter integer DIAGNOSTIC_OVERLAY\s*=\s*$diagnosticOverlayValue\s*," -or
    $topSource -notmatch "parameter integer DIAGNOSTIC_PATTERN_WRITER\s*=\s*$diagnosticPatternWriterValue\s*,") {
    throw 'The isolated top did not select the requested model/read depth.'
}
if ($topSource -notmatch "parameter integer DISPLAY_PREFETCH_BURSTS\s*=\s*$displayPrefetchBurstsValue\s*," -or
    $topSource -notmatch "parameter integer DISPLAY_PREFETCH_TRIGGER_PIXELS\s*=\s*$DisplayPrefetchTriggerPixels\s*,") {
    throw 'The isolated top did not select the requested display prefetch setting.'
}
if ($topSource -notmatch "parameter integer HMIC_FENCE_CHECK_POINTS\s*=\s*$hmicFenceCheckPointsValue\s*,") {
    throw 'The isolated top did not select the requested HMIC fence check-point setting.'
}
if ($Model -eq 'Fisheye' -and
    $topSource -notmatch [regex]::Escape('parameter FISHEYE_INIT_FILE_DELTA = "source/rtl/data/fisheye_candidate_2026-10-16_q16_delta_s12.mem"')) {
    throw 'The isolated fish-eye top did not select the signed-delta ROM asset.'
}
$topPath = Join-Path $outputRoot 'source\rtl\hdmi_ddr_ov5640_top.v'
foreach ($name in $brownRegisters.Keys) {
    $unsigned = $name.StartsWith('INV_')
    $bits = if ($name.EndsWith('_Q8')) { 20 } else { 22 }
    $value = $brownRegisters[$name]
    $literal = "{0}{1}'{2}{3}" -f $(if ($value -lt 0) { '-' } else { '' }),
        $bits, $(if ($unsigned) { 'd' } else { 'sd' }), [math]::Abs($value)
    $pattern = '(?m)(\bparameter[^\r\n]*\b' + $name + '\s*=\s*)-?\d+''s?d\d+'
    if ([regex]::Matches($topSource, $pattern).Count -ne 1) {
        throw "Expected exactly one literal parameter binding for $name."
    }
    $topSource = [regex]::Replace($topSource, $pattern, "`${1}$literal")
}
[IO.File]::WriteAllText($topPath, $topSource, [Text.UTF8Encoding]::new($false))
if ($BrownRegistersJson) {
    $profileCopy = Join-Path $outputRoot 'brown_register_profile.json'
    Copy-Item -LiteralPath $brownProfilePath -Destination $profileCopy
    [ordered]@{
        model = 'Brown'
        registers = $brownRegisters
        profile_sha256 = (Get-FileHash -LiteralPath $profileCopy -Algorithm SHA256).Hash
        top_sha256 = (Get-FileHash -LiteralPath $topPath -Algorithm SHA256).Hash
        scope = 'Compile-time register profile; calibration validation and board signoff are separate.'
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $outputRoot 'brown_parameter_manifest.json') -Encoding utf8
}

$projectPath = Join-Path $outputRoot $projectFile.Name
$projectText = Get-Content -LiteralPath $projectPath -Raw
$marker = '                (_file "source/rtl/cmos_8_16bit.v"'
if ([regex]::Matches($projectText, [regex]::Escape($marker)).Count -ne 1) {
    throw 'Could not find the unique PDS RTL source-list insertion point.'
}
$now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
$entries = ($rtlFiles | ForEach-Object {
    "                (_file `"source/rtl/correction/$($_.Name)`"`n" +
    "                    (_format verilog)`n" +
    "                    (_timespec `"$now`")`n" +
    "                )`n"
}) -join ''
$projectText = $projectText.Replace($marker, $entries + $marker)
if ($OptimizeHoldTiming -or $PlacementSeed -gt 0 -or
    $ActionTimeoutMinutes -gt 0 -or $DumpRouterCongestionPlot -or
    $CongestOverlapLimit -gt 0 -or $PlacementRuns -gt 1 -or
    $ParallelPlacementRuns -gt 1 -or $SaveBestPlacementRuns -gt 1 -or
    $PlacementSeedStep -gt 1) {
    # Official PDS 2022.2-SP1-Lite examples encode these GUI PNR options in
    # cmd_pnr. Enable both corners; leave the vendor source and default runs
    # untouched so this remains a controlled physical-strategy A/B.
    $pnrStatePattern = '\(_command cmd_pnr\s*\r?\n\s*\(_gci_state \(_integer (\d+)\)\)\s*\r?\n'
    $pnrStateMatches = [regex]::Matches($projectText, $pnrStatePattern)
    if ($pnrStateMatches.Count -ne 1) {
        throw 'Expected one PDS PNR command state in the isolated project.'
    }
    # The vendor reference may itself have completed an earlier P&R. This
    # isolated copy has no inherited P&R database, so reset only its task
    # state before injecting the requested physical options.
    $pnrStateMatch = $pnrStateMatches[0]
    $pnrStateValue = [int]$pnrStateMatch.Groups[1].Value
    $pnrPattern = '\(_command cmd_pnr\s*\r?\n\s*\(_gci_state \(_integer 0\)\)\s*\r?\n'
    $projectText = [regex]::Replace($projectText, $pnrStatePattern, {
        param($match)
        $match.Value.Replace("(_integer $pnrStateValue)", '(_integer 0)')
    }, 1)
    $pnrMatches = [regex]::Matches($projectText, $pnrPattern)
    if ($pnrMatches.Count -ne 1 -or $projectText -match
        'fix_hold_violation|optimize_multi_corner_timing|gplace_seed|gplace_times|seed_step|saved_outcome|parallel|action_timeout|dump_router_congestion_plot|congest_overlap_limit') {
        throw 'Expected one unconfigured PDS PNR command in the isolated project.'
    }
    $pnrOptions = ''
    if ($ActionTimeoutMinutes -gt 0) {
        $pnrOptions += "            (_option action_timeout (_integer $ActionTimeoutMinutes))`n"
    }
    if ($DumpRouterCongestionPlot) {
        $pnrOptions += "            (_option dump_router_congestion_plot (_boolean TRUE))`n"
    }
    if ($CongestOverlapLimit -gt 0) {
        $pnrOptions += "            (_option congest_overlap_limit (_integer $CongestOverlapLimit))`n"
    }
    if ($OptimizeHoldTiming) {
        $pnrOptions += "            (_option optimize_multi_corner_timing (_switch ON))`n" +
                       "            (_option fix_hold_violation (_switch ON))`n"
        if ($HoldThresholdPs -gt 0) {
            # PDS GUI's command preview uses -fix_hold_violation_threshold N.
            $pnrOptions += "            (_option fix_hold_violation_threshold (_integer $HoldThresholdPs))`n"
        }
    }
    if ($PlacementSeed -gt 0) {
        # Official PDS User Guide section 9.12 names this PNR option -gplace_seed.
        $pnrOptions += "            (_option gplace_seed (_integer $PlacementSeed))`n"
    }
    if ($PlacementRuns -gt 1 -or $ParallelPlacementRuns -gt 1 -or
        $SaveBestPlacementRuns -gt 1 -or $PlacementSeedStep -gt 1) {
        # PDS User Guide section 9.12: run distinct placement seeds in parallel.
        $pnrOptions += "            (_option gplace_times (_integer $PlacementRuns))`n" +
                       "            (_option seed_step (_integer $PlacementSeedStep))`n" +
                       "            (_option saved_outcome (_integer $SaveBestPlacementRuns))`n" +
                       "            (_option parallel (_integer $ParallelPlacementRuns))`n"
    }
    $projectText = $projectText.Insert($pnrMatches[0].Index + $pnrMatches[0].Length,
                                       $pnrOptions)
}
[IO.File]::WriteAllText($projectPath, $projectText, [Text.UTF8Encoding]::new($false))

$fdcPath = Join-Path $outputRoot 'hdmi_ddr_ov5640_top.fdc'
$fdcText = Get-Content -LiteralPath $fdcPath -Raw
if ($fdcText.Contains('u_DDR3_50H')) {
$fdcText = [regex]::Replace($fdcText, '(?m)^.*cmos2_[^\r\n]*(?:\r?\n|$)', '')
$fdcText = $fdcText.Replace('u_DDR3_50H', 'u_correction_core.ddr3')
if ([regex]::Matches($fdcText, [regex]::Escape('-multiply_by {27} -divide_by {20}')).Count -ne 1 -or
    [regex]::Matches($fdcText, [regex]::Escape('[get_nets {u_pll.clkout3}]')).Count -ne 1) {
    throw 'Expected the known stale pixel/25 MHz PLL constraints exactly once.'
}
$fdcText = $fdcText.Replace('-multiply_by {27} -divide_by {20}',
    '-multiply_by {297} -divide_by {400}')
$fdcText = $fdcText.Replace('[get_nets {u_pll.clkout3}]',
    '[get_nets {u_pll.clkout2}]')
# The MES50HP J3/BANK B2 pins are a 3.3 V bank (board manual PDF pp. 15-16),
# while the bundled OV5640 module schematic routes CAM1_DOVDD from CAM1_2V8
# through a 0-ohm link.  OV5640 datasheet v2.01 specifies 1.8/2.8 V I/O;
# the old vendor FDC's LVCMOS12 on a 3.3 V B2 bank is therefore not the
# electrical interface used by this camera path.  Promote only the eight
# CMOS1 data pins in the isolated formal copy; keep the vendor project intact.
$cameraDataStandardPattern = '(?m)^define_attribute \{p:cmos1_data\[[0-7]\]\} \{PAP_IO_STANDARD\} \{LVCMOS12\}\r?$'
$cameraDataStandardMatches = [regex]::Matches($fdcText, $cameraDataStandardPattern)
if ($cameraDataStandardMatches.Count -ne 8) {
    throw "Expected exactly eight legacy LVCMOS12 CMOS1 data attributes; found $($cameraDataStandardMatches.Count)."
}
$fdcText = [regex]::Replace(
    $fdcText,
    '(?m)^(define_attribute \{p:cmos1_data\[[0-7]\]\} \{PAP_IO_STANDARD\} \{)LVCMOS12(\})\r?$',
    '${1}LVCMOS33${2}')
if ([regex]::Matches($fdcText, '(?m)^define_attribute \{p:cmos1_data\[[0-7]\]\} \{PAP_IO_STANDARD\} \{LVCMOS33\}\r?$').Count -ne 8) {
    throw 'CMOS1 data IO standard promotion to LVCMOS33 did not produce eight attributes.'
}
if ($fdcText -match 'cmos2_') {
    throw 'Unused CMOS2 pin/clock constraints remain in the single-camera project.'
}
# KEY1 is the active-low MES50HP user button from the board manual (K18).
# Add it only to the isolated formal copy; the vendor reference FDC remains
# untouched. LED1/LED2 already reuse the maintained hdmi_int_led and
# cmos_init_done[1] ports, so no extra LED constraints are needed.
if ($fdcText -match 'p:key1') {
    throw 'KEY1 constraint unexpectedly already exists in the isolated FDC.'
}
$fdcText += @'

# MES50HP KEY1, active-low user button
define_attribute {p:key1} {PAP_IO_DIRECTION} {INPUT}
define_attribute {p:key1} {PAP_IO_LOC} {K18}
define_attribute {p:key1} {PAP_IO_VCCIO} {3.3}
define_attribute {p:key1} {PAP_IO_STANDARD} {LVCMOS33}
define_attribute {p:key1} {PAP_IO_NONE} {TRUE}
'@
if ($fdcText -notmatch 'create_generated_clock -name \{pix_clk\}[^\r\n]*u_pll\.clkout0[^\r\n]*-multiply_by \{297\} -divide_by \{400\}' -or
    $fdcText -notmatch 'create_generated_clock -name \{clk_25M\}[^\r\n]*u_pll\.clkout2[^\r\n]*-multiply_by \{1\} -divide_by \{2\}' -or
    $fdcText -match 'u_pll\.clkout3') {
    throw 'PLL output clock constraints do not match the official 37.125/10/25 MHz configuration.'
}
} elseif (-not $fdcText.Contains('u_correction_core.ddr3') -or
          $fdcText -notmatch 'p:key1' -or
          $fdcText -notmatch 'create_generated_clock -name \{pix_clk\}[^\r\n]*u_pll\.clkout0[^\r\n]*-multiply_by \{297\} -divide_by \{400\}') {
    throw 'Reference FDC is neither the expected vendor baseline nor the prepared board FDC.'
}
if ($ConstrainCameraConfigClock) {
    # Vendor counter 0..1249 takes 1250 edges per toggle. The optional owner
    # uses HALF_PERIOD-1 as its terminal count, so derive its different ratio
    # from the copied adapter rather than reusing the vendor ratio.
    $cameraConfigDivide = 2500
    if ($UseSccbOwnerCameraConfig) {
        $ownerDividerMatch = [regex]::Match([IO.File]::ReadAllText($vendorConfig), '\.I2C_HALF_PERIOD\(\s*(\d+)\s*\)')
        $ownerRtl = [IO.File]::ReadAllText((Join-Path $targetRtl 'ov5640_sccb_init_owner.v'))
        if (-not $ownerDividerMatch.Success -or $ownerRtl -notmatch 'i2c_div_count\s*==\s*I2C_HALF_PERIOD\s*-\s*1') {
            throw 'SCCB owner divider changed; audit its generated clock before constraining it.'
        }
        $cameraConfigDivide = 2 * [int]$ownerDividerMatch.Groups[1].Value
    }
    $cameraConfigClock = 'create_generated_clock -name {camera1_cfg_10k} -source [get_pins {camera1_config/clk_25M}] [get_pins {camera1_config/clock_20k}] -master_clock [get_clocks {clk_25M}] -divide_by {' + $cameraConfigDivide + '}'
    if ($fdcText -match 'camera1_cfg_10k') {
        throw 'camera1_cfg_10k was unexpectedly already present in the isolated FDC.'
    }
    $fdcText += "`n$cameraConfigClock`n"
}
[IO.File]::WriteAllText($fdcPath, $fdcText, [Text.UTF8Encoding]::new($false))

$auditScript = Join-Path $repoRoot 'scripts\audit_fdc.ps1'
& $auditScript -Path $fdcPath -BoardProfile 'mes50hp-camera-reference'
if ($LASTEXITCODE -ne 0) { throw 'Board-pin FDC static audit failed.' }

# Verify all maintained RTL files were copied byte-for-byte and registered.
foreach ($file in $rtlFiles) {
    $copy = Join-Path $targetRtl $file.Name
    & fc.exe /b $file.FullName $copy | Out-Null
    $compareExitCode = $LASTEXITCODE
    if ($compareExitCode -ne 0 -or
        -not $projectText.Contains("source/rtl/correction/$($file.Name)")) {
        throw "RTL synchronization/registration check failed for $($file.Name)"
    }
}
$rom = Get-ChildItem -LiteralPath (Join-Path $repoRoot 'rtl\data') -File -Filter '*.mem'
if ($Model -eq 'Fisheye' -and $rom.Count -lt 2) {
    throw 'Fish-eye ROM inputs were not copied into the isolated project.'
}

Write-Output "Prepared PGL50H board-level project: $outputRoot"
Write-Output "Model=$Model READ_DEPTH=$ReadDepth IDENTITY_MAP_DIAGNOSTIC=$identityMapValue DIAGNOSTIC_OVERLAY=$diagnosticOverlayValue DIAGNOSTIC_PATTERN_WRITER=$diagnosticPatternWriterValue DISPLAY_PREFETCH_BURSTS=$displayPrefetchBurstsValue DISPLAY_PREFETCH_TRIGGER_PIXELS=$DisplayPrefetchTriggerPixels HMIC_FENCE_CHECK_POINTS=$hmicFenceCheckPointsValue SCCB_OWNER_CAMERA_CONFIG=$UseSccbOwnerCameraConfig; placement seed=$PlacementSeed runs=$PlacementRuns parallel=$ParallelPlacementRuns save-best=$SaveBestPlacementRuns step=$PlacementSeedStep; synchronized $($rtlFiles.Count) maintained RTL sources."
Write-Output 'The original vendor reference project and repository sources were not modified.'
if ($PrepareOnly) {
    Write-Output 'PREPARE_ONLY: source/profile/FDC preparation complete; PDS was not invoked.'
    return
}

$startTime = Get-Date
Push-Location $outputRoot
try {
    $runStage = if ($SynthesizeOnly) { 'synthesize' } else { 'gen_bit_stream' }
    & $pdsShellPath -project $projectPath -run $runStage 2>&1 |
        Tee-Object -FilePath (Join-Path $outputRoot 'pds_console.log')
    $pdsExit = $LASTEXITCODE
} finally {
    Pop-Location
}
if ($pdsExit -ne 0) {
    throw "PDS exited with code $pdsExit; preserve and inspect $outputRoot"
}

$stageLogs = if ($SynthesizeOnly) {
    @('compile\run.log', 'synthesize\run.log')
} else {
    @('compile\run.log', 'synthesize\run.log', 'place_route\run.log',
        'report_timing\run.log', 'generate_bitstream\run.log')
}
foreach ($relative in $stageLogs) {
    $log = Join-Path $outputRoot $relative
    if (-not (Test-Path -LiteralPath $log -PathType Leaf)) {
        throw "PDS did not produce required stage log: $log"
    }
    if (Select-String -LiteralPath $log -Pattern 'Program Error Out\.|\bE:' -Quiet) {
        throw "PDS stage log contains an error: $log"
    }
}
if ($SynthesizeOnly) {
    $reports = @(Get-ChildItem -LiteralPath (Join-Path $outputRoot 'synthesize') -File -Filter '*.snr' |
        Where-Object { $_.LastWriteTime -ge $startTime })
    if ($reports.Count -eq 0) {
        throw "PDS synthesis did not produce a fresh .snr report under $outputRoot"
    }
    Write-Output "PDS_SYNTHESIS_PASS: $($reports[0].FullName)"
} else {
    # A generated .sbit is not a timing-qualified deliverable.  Use the
    # final Report Timing .rtr as the authoritative gate.  PDS also emits a
    # place_route/*timing_summary_after_hold_fix.txt snapshot, but that file
    # can be written before the router's final hold-fix result; using it here
    # would reject a final .rtr that reports All Constraints Met.
    $timingReports = @(Get-ChildItem -LiteralPath (Join-Path $outputRoot 'report_timing') -File -Filter '*.rtr' -ErrorAction SilentlyContinue)
    if ($timingReports.Count -eq 0) {
        $fallbackReports = @(Get-ChildItem -LiteralPath (Join-Path $outputRoot 'place_route') -File -Filter '*timing_summary_after_hold_fix.txt' -ErrorAction SilentlyContinue)
        if ($fallbackReports.Count -eq 0) {
            throw "PDS did not produce a timing gate report under $outputRoot"
        }
        $timingGateReport = $fallbackReports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    } else {
        $timingGateReport = $timingReports | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    $timingGateText = Get-Content -LiteralPath $timingGateReport.FullName -Raw
    if ($timingGateText -notmatch 'Design Summary\s*:\s*All Constraints Met\.') {
        throw "PDS timing gate failed; inspect $($timingGateReport.FullName). A .sbit may exist, but it is not eligible for download."
    }
    Write-Output "PDS_TIMING_GATE_PASS: $($timingGateReport.FullName)"
    $bitstreams = @(Get-ChildItem -LiteralPath $outputRoot -Recurse -File -Filter '*.sbit' |
        Where-Object { $_.LastWriteTime -ge $startTime })
    if ($bitstreams.Count -eq 0) {
        throw "No fresh .sbit generated by PDS under $outputRoot"
    }
    Write-Output "PDS_BUILD_PASS: $($bitstreams[0].FullName)"
}
Write-Output "PDS output preserved under ignored build directory: $outputRoot"
