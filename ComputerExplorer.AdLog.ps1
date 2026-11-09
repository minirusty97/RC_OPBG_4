#requires -version 5.1

function Write-ExplorerSearchLog {
    param(
        [hashtable]$Context, [string]$Event, [hashtable]$Data=@{},
        [System.Management.Automation.ErrorRecord]$Failure
    )
    if ($null -eq $Context) { return }

    $mutex=$null
    $locked=$false
    try {
        $entry=[ordered]@{Utc=[datetime]::UtcNow.ToString('o'); Event=$Event; Pid=$PID}
        if ($Context.ContainsKey('Dc')) { $entry.Dc=$Context.Dc; $entry.Attempt=$Context.Attempt }
        foreach ($key in $Data.Keys) { $entry[$key]=$Data[$key] }
        if ($null -ne $Failure) {
            # Messages, invocation data and targets can contain device names or credentials.
            $exception=$Failure.Exception
            $errorData=[ordered]@{Category=[string]$Failure.CategoryInfo.Category; Type=$exception.GetType().FullName; HResult=$exception.HResult}
            $id=[string]$Failure.FullyQualifiedErrorId
            if ($id -match '^[A-Za-z][A-Za-z0-9_.:,+-]{0,249}$' -and ($id -split ',',2)[0] -cne $exception.Message) {
                $errorData.Id=$id
            }
            if ($null -ne $exception.InnerException) { $errorData.InnerType=$exception.InnerException.GetType().FullName }
            $nativeCode=$exception.PSObject.Properties['ErrorCode']
            if ($null -ne $nativeCode -and $nativeCode.Value -is [int]) { $errorData.Code=$nativeCode.Value }
            $entry.Error=$errorData
        }
        $line=($entry | ConvertTo-Json -Depth 5 -Compress) + [Environment]::NewLine
        # Every process prepares its row independently. Only the append is serialized.
        $mutex=[Threading.Mutex]::new($false, ('AssistenteIT.SearchLog.' + [IO.Path]::GetFileNameWithoutExtension($Context.Path)))
        try { $locked=$mutex.WaitOne(250) }
        catch [Threading.AbandonedMutexException] { $locked=$true }
        if (-not $locked) { throw 'Log di ricerca occupato.' }
        [IO.File]::AppendAllText($Context.Path,$line,[Text.UTF8Encoding]::new($false))
    }
    catch { Write-Warning 'Impossibile aggiungere una riga al log di ricerca.' }
    finally {
        if ($locked) { $mutex.ReleaseMutex() }
        if ($null -ne $mutex) { $mutex.Dispose() }
    }
}
