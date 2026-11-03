function Get-DlpApplicability([string]$EnvironmentId,$Policy) {
    $type=Get-Field $Policy 'EnvironmentType'
    if (-not $type) {$type=Get-Field $Policy 'Internal.properties.environmentType'}
    $environments=Get-Field $Policy 'Environments'
    $hasScope=Has-Field $Policy 'Environments'
    if (-not $hasScope) {$environments=Get-Field $Policy 'Internal.properties.environments';$hasScope=$null -ne $environments}
    $ids=@(foreach ($e in @($environments)) {
        if ($e -is [string]) {$e} elseif ($e.name) {$e.name} elseif ($e.id) {([string]$e.id -split '/')[-1]}
    })
    if ($type -eq 'AllEnvironments') {return 'AplicaSegunAmbitoDeclarado'}
    if ($type -in @('OnlyEnvironments','ExceptEnvironments') -and $hasScope) {
        if ($null -eq $environments -or $ids.Count -ne @($environments).Count) {return 'Desconocido'}
        if (@($ids | Where-Object {$_ -notmatch '^(Default-)?[0-9a-fA-F-]{36}$'}).Count) {return 'Desconocido'}
        $included=$EnvironmentId -in $ids
        if (($type -eq 'OnlyEnvironments' -and $included) -or ($type -eq 'ExceptEnvironments' -and -not $included)) {return 'AplicaSegunAmbitoDeclarado'}
        return 'NoAplicaSegunAmbitoDeclarado'
    }
    return 'Desconocido'
}
