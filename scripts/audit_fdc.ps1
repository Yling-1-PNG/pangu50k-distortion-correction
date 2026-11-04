param(
    [Parameter(Mandatory = $true)]
    [string]$Path,
    [ValidateSet('mes50hp-ddr-bist', 'mes50hp-camera-reference')]
    [string]$BoardProfile = 'mes50hp-ddr-bist'
)

$resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
$attributes = @{}
$errors = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$pattern = '^\s*define_attribute\s+\{p:([^}]+)\}\s+\{(PAP_IO_LOC|PAP_IO_VCCIO|PAP_IO_STANDARD)\}\s+\{([^}]+)\}'

foreach ($line in Get-Content -LiteralPath $resolved.Path) {
    if ($line -notmatch $pattern) { continue }
    $port = $Matches[1]
    $key = $Matches[2]
    $value = $Matches[3]
    if (-not $attributes.ContainsKey($port)) { $attributes[$port] = @{} }
    if ($attributes[$port].ContainsKey($key) -and $attributes[$port][$key] -ne $value) {
        $errors.Add("$port has conflicting $key values: $($attributes[$port][$key]) and $value")
    }
    $attributes[$port][$key] = $value
}

if ($attributes.Count -eq 0) { $errors.Add('No PAP_IO_LOC/VCCIO/STANDARD port attributes found') }

# Profiles describe known vendor top-level pin maps; absent ports are not an error.
$expected = @{
    'clk' = 'P20'; 'ref_clk' = 'P20'; 'sys_clk' = 'P20'
    'rstn' = 'K18'; 'rst_board' = 'K18'
    'uart_rxd' = 'R8'; 'uart_txd' = 'R9'
}
$strictPorts = @('clk', 'ref_clk', 'sys_clk', 'rstn', 'rst_board', 'uart_rxd', 'uart_txd')
if ($BoardProfile -eq 'mes50hp-ddr-bist') {
    $expected += @{
        'ddr_init_done' = 'B2'; 'err_flag_led' = 'A2'
        'heart_beat_led' = 'B3'; 'pll_lock' = 'A3'
    }
} else {
    # The camera reference reuses these pins for different top-level status ports.
    $expected += @{
        'hdmi_int_led' = 'B2'; 'cmos_init_done[1]' = 'A2'
        'cmos_init_done[0]' = 'B3'; 'ddr_init_done' = 'A3'
        'heart_beat_led' = 'C5'
    }
    $strictPorts += @('hdmi_int_led', 'cmos_init_done[1]', 'cmos_init_done[0]',
        'ddr_init_done', 'heart_beat_led')
}
foreach ($port in $expected.Keys) {
    if (-not $attributes.ContainsKey($port)) { continue }
    $actual = $attributes[$port]['PAP_IO_LOC']
    if ($actual -and $actual -ne $expected[$port]) {
        $message = "$port LOC=$actual; profile $BoardProfile expects $($expected[$port])"
        if ($port -in $strictPorts) {
            $errors.Add($message)
        } else {
            $warnings.Add($message)
        }
    }
}

foreach ($port in $attributes.Keys) {
    $item = $attributes[$port]
    if (-not $item.ContainsKey('PAP_IO_LOC') -or -not $item.ContainsKey('PAP_IO_VCCIO') -or -not $item.ContainsKey('PAP_IO_STANDARD')) {
        $warnings.Add("$port is missing LOC, VCCIO, or IO_STANDARD")
        continue
    }
    $loc = $item['PAP_IO_LOC']
    $vcc = $item['PAP_IO_VCCIO']
    $standard = $item['PAP_IO_STANDARD']
    if ($loc -in @('P20', 'K18', 'R8', 'R9') -and ($vcc -ne '3.3' -or $standard -ne 'LVCMOS33')) {
        $errors.Add("$port at $loc uses $vcc/$standard; MES50HP board example requires 3.3/LVCMOS33")
    }
    if ($port -match '^mem_' -and $vcc -ne '1.5') {
        $errors.Add("$port DDR3 signal uses VCCIO=$vcc; expected 1.5 for MES50HP Bank 3")
    }
}

Write-Output "FDC: $($resolved.Path)"
Write-Output "Board profile: $BoardProfile"
Write-Output "Ports with checked attributes: $($attributes.Count)"
foreach ($warning in $warnings) { Write-Warning $warning }
foreach ($errorText in $errors) { Write-Output "ERROR: $errorText" }
if ($errors.Count -gt 0) { exit 1 }
Write-Output 'Static FDC checks passed; verify schematic, bank mapping, clocks, and post-IP-generation diff separately.'
exit 0
