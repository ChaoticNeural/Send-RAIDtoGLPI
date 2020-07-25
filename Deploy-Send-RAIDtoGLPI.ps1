param(
    [Parameter(Mandatory = $true, HelpMessage = 'List of hosts:')] [string[]] $hosts,
    [Parameter(HelpMessage = 'Credential to common user:')] [PSCredential] $credential = (Get-Credential),
    [Parameter(HelpMessage = 'Path to GLPI-agent files zip:')] [string] $GLPIfilesURI = "https://yourglpi.host/distr/GLPI-agent.zip",
    [Parameter(HelpMessage = 'Path to install:')] [string] $pathToInstall = "C:\GLPI-Agent",
    [Parameter(HelpMessage = 'FusionInventory exe filename:')] [string] $FIAgentExe = 'fusioninventory-agent_windows-x64_2.5.2.exe',
    [Parameter(HelpMessage = 'FusionInventory plugin URI:')] [string] $FIpluginURI = '"https://yourglpi.host/plugins/fusioninventory/"'
)

if (-not [System.IO.Path]::IsPathRooted($pathToInstall)) {
    Write-Host "PathToInstall is not absolute. Aborting";
    exit(1);
}

ForEach ($serverAddr in $hosts) {
    Invoke-Command -ScriptBlock {
        param(
            [Parameter(Mandatory = $true)] [string] $serverIP,
            [Parameter(Mandatory = $true)] [string] $GLPIfilesURI,
            [Parameter(Mandatory = $true)] [string] $pathToInstall,
            [Parameter(Mandatory = $true)] [string] $FIAgentExe,
            [Parameter(Mandatory = $true)] [string] $FIpluginURI
        )
        # Func unzip with overwrite
        function Unzip($zipfile, $outdir) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $archive = [System.IO.Compression.ZipFile]::OpenRead($zipfile)
            foreach ($entry in $archive.Entries) {
                Remove-Item (Join-Path $outdir $entry.FullName) -Recurse -ErrorAction SilentlyContinue
            }
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zipfile, $outdir)
            $archive.Dispose()
        }


        try {
            if (-not (Test-Path $pathToInstall)) {
                New-Item -Path $pathToInstall -ItemType Directory
            }
            # Download archive, unpack it, remove archive
            $archive = Join-Path $pathToInstall "data.zip"
            Remove-Item $archive -Force -ErrorAction SilentlyContinue
            $progressPreference = 'silentlyContinue'
            Invoke-WebRequest -Uri $GLPIfilesURI -OutFile $archive
            $progressPreference = 'Continue'
            Unzip $archive $pathToInstall
            Remove-Item $archive;
            
            # Install or reinstall FusionInventory
            $args = @(
                '/S', '/acceptlicense', "/server=$FIpluginURI", '/ssl-check', '/no-firewall-exception',
                '/execmode=Task', "/installdir=$(Join-path $pathToInstall 'FusionInventory-Agent')",
                '/installtasks=Inventory', '/no-start-menu', '/task-frequency=Daily', '/runnow'
            )
            Start-Process (Join-Path $pathToInstall $FIAgentExe) -ArgumentList $args -Wait


            # Delete old and create new scheduled task for Send-RAIDtoGLPI.ps1
            Unregister-ScheduledTask -TaskName "Send-RAIDToGLPI" -Confirm:$false -ErrorAction SilentlyContinue
            $action = New-ScheduledTaskAction -Execute 'Powershell.exe' `
                -Argument "-File $(Join-Path $PathToInstall Send-RAIDtoGLPI.ps1) -ExecutionPolicy Bypass -NonInteractive"
            $trigger = New-ScheduledTaskTrigger -Daily -At "23:00" -RandomDelay "01:00"
            $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit "01:00"
            $principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
                -TaskName "Send-RAIDToGLPI" -Description "Collect RAID-info and send to GLPI" 
		
        }
        Catch {
            $errMsg = "$(Get-Date -format "yyyy.MM.dd hh:mm:ss"): $($ServerIP): $($_.Exception)"
            $errMsg >> (Join-Path $pathToInstall "error.txt")
            Write-Output $errMsg
        }
    } -ComputerName $serverAddr -Credential $credential -AsJob -Args $serverAddr, $GLPIfilesURI, $pathToInstall, $FIAgentExe, $FIpluginURI
}
