function Get-ThreadContactCodexDesktop {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' |
        Where-Object { $_.PackageFamilyName -eq 'OpenAI.Codex_2p2nqsd0c76g0' -and $_.InstallLocation })
    if ($packages.Count -ne 1) {
        throw 'Expected one installed OpenAI Codex Windows package.'
    }
    $appRoot = Join-Path $packages[0].InstallLocation 'app'
    [pscustomobject]@{
        Executable = Join-Path $appRoot 'ChatGPT.exe'
        Node = Join-Path $appRoot 'resources\cua_node\bin\node.exe'
    }
}
