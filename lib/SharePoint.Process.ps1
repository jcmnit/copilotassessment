function Start-SharePointWorker([string]$ConfigPath,[int]$TimeoutMilliseconds) {
    $executable=Join-Path $PSHOME $(if ($IsWindows) {'pwsh.exe'} else {'pwsh'})
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=$executable
    $start.UseShellExecute=$false
    foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-SharePointWorker.ps1'),'-ConfigurationFile',$ConfigPath)) {$start.ArgumentList.Add($argument)}
    $process=[Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            $process.Kill()
            $process.WaitForExit()
            return [pscustomobject]@{ExitCode=$null;TimedOut=$true}
        }
        return [pscustomobject]@{ExitCode=$process.ExitCode;TimedOut=$false}
    } finally {$process.Dispose()}
}
function Collect-SharePointIsolated {
    if ($SkipSharePoint) {Add-Status 'SharePointInventario' 'Omitido' 0 'SkipSharePoint solicitado.';return}
    if (-not $SharePointAdminUrl -or $SharePointClientId -eq [guid]::Empty) {Add-Status 'SharePointInventario' 'No obtenido' 0 'Se requiere URL administrativa y ClientId PnP autorizado.';return}
    if ($NoInteractive) {Add-Status 'SharePointInventario' 'No obtenido' 0 'NoInteractive: no se inicia autenticacion PnP interactiva.';return}
    $workerRoot=Join-Path $script:runPath 'sharepoint-worker'
    $null=New-Item -ItemType Directory -Path $workerRoot
    $config=[ordered]@{TenantId=$TenantId.ToString();RunId=$script:runId;RunDirectory=$script:runPath;WorkerDirectory=$workerRoot;InicioUTC=$script:started.ToString('o');DeadlineUTC=$script:deadline.ToString('o');SharePointAdminUrl=[string]$SharePointAdminUrl;SharePointClientId=$SharePointClientId.ToString();SharePointSiteUrls=$SharePointSiteUrls;PreflightOnly=[bool]$PreflightOnly;NoInteractive=[bool]$NoInteractive;MaxSites=$MaxSites;MaxItemsPerSite=$MaxItemsPerSite;MaxUniqueScopesPerSite=$MaxUniqueScopesPerSite;MaxSubWebsPerSite=$MaxSubWebsPerSite}
    Save-Json 'sharepoint-worker-config' $config
    $configPath=Join-Path $script:evidencePath 'sharepoint-worker-config.json'
    Write-Host 'SharePoint: iniciando proceso aislado de Graph, Azure y PowerApps.'
    $outcome=$null
    try {
        Assert-Deadline
        $timeout=[int][math]::Max(1,($script:deadline-[datetime]::UtcNow).TotalMilliseconds)
        $outcome=Start-SharePointWorker $configPath $timeout
    } catch {Add-Status 'SharePointProceso' 'ErrorDeServicio' 0 ('No fue posible iniciar/completar el proceso; tipo='+$_.Exception.GetType().Name)}
    # Importar solo datos propios del worker, sin cargar ningun modulo PnP en el padre.
    $workerEvidence=Join-Path $workerRoot 'evidencias'
    if (Test-Path -LiteralPath $workerEvidence) {
        foreach ($file in Get-ChildItem -LiteralPath $workerEvidence -Filter 'SharePoint*.json' -File) {
            if ($file.LinkType) {throw 'Archivo de worker no regular.'}
            Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $script:evidencePath $file.Name)
        }
        $coveragePath=Join-Path $workerEvidence 'cobertura.json'
        if (Test-Path -LiteralPath $coveragePath) {
            foreach ($row in @(Get-Content -LiteralPath $coveragePath -Raw | ConvertFrom-Json)) {
                if (-not $row) {continue}
                if ($row.TenantId -ne $TenantId.ToString() -or $row.RunId -ne $script:runId -or $row.Fuente -notlike 'SharePoint*') {throw 'Cobertura de worker incompatible.'}
                Add-Status $row.Fuente $row.Estado ([int]$row.Registros) $row.Detalle
            }
        }
        $diagnosticPath=Join-Path $workerEvidence 'diagnostico.json'
        if (Test-Path -LiteralPath $diagnosticPath) {foreach ($row in @(Get-Content -LiteralPath $diagnosticPath -Raw | ConvertFrom-Json)) {if ($row) {$script:diagnostics.Add($row)}}}
    }
    foreach ($name in @('sharepoint-sitios.csv','sharepoint-permisos.csv','sharepoint-enlaces.csv')) {
        $file=Join-Path $workerRoot $name
        if (Test-Path -LiteralPath $file) {Copy-Item -LiteralPath $file -Destination (Join-Path $script:runPath $name)}
    }
    $resultPath=Join-Path $workerRoot 'resultado.json'
    $validResult=$false
    if (Test-Path -LiteralPath $resultPath) {
        $result=Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
        $validResult=$result.TenantId -eq $TenantId.ToString() -and $result.RunId -eq $script:runId -and $result.Terminado -eq $true
        Save-Json 'SharePointProceso' $result
    }
    if (-not $outcome -or $outcome.TimedOut -or $outcome.ExitCode -ne 0 -or -not $validResult) {
        $state=if ($outcome -and $outcome.TimedOut) {'TiempoAgotado'} else {'ErrorDeRuntime'}
        Add-Status 'SharePointProceso' $state 0 ('El proceso aislado no termino normalmente; exit='+$outcome.ExitCode+'. No se acredita inventario completo; el padre conserva cobertura y manifiesto.')
    } else {Add-Status 'SharePointProceso' 'Obtenido' 1 'Proceso aislado finalizado. Revisar resultados individuales; esto no acredita exito de todas las consultas.'}
}
