function Read-TokenClaims([string]$Token) {
    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) { throw 'Se requiere un access token JWT de Power Platform.' }
    $s = $parts[1].Replace('-','+').Replace('_','/')
    $s = $s.PadRight($s.Length + ((4 - $s.Length % 4) % 4), '=')
    return ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($s)) | ConvertFrom-Json)
}
function ConvertFrom-SensitiveValue($Value) {
    if ($Value -isnot [Security.SecureString]) { return [string]$Value }
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}
function Assert-PowerPlatformToken([string]$Token, [guid]$ExpectedTenant = [guid]::Empty) {
    # Chequeo local de coherencia, no validacion criptografica. El servicio valida la firma.
    $c = Read-TokenClaims $Token
    $tokenTenant = [guid]$c.tid
    if ($tokenTenant -eq [guid]::Empty -or ($ExpectedTenant -ne [guid]::Empty -and $tokenTenant -ne $ExpectedTenant) -or
        $c.aud -notin @('https://api.powerplatform.com','https://api.powerplatform.com/','8578e004-a5c6-46e7-913e-12f58912df43') -or
        -not $c.scp -or [double]$c.exp -le ([datetimeoffset]::UtcNow.ToUnixTimeSeconds()+60)) { throw 'Token delegado, tenant, audiencia o vigencia incorrectos.' }
    return $c
}
