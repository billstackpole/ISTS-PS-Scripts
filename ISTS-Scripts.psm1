﻿if ( (Get-PSSnapin -Name VMware.VimAutomation.Core -ErrorAction SilentlyContinue) -eq $null ){
    Write-Error "Make sure vmware.vimautomation.core is added. Import in PowerCLI shell or just Add-PSSnapin"
}

#### Global Variables ####
$ISTS_ModulePath = Split-Path -parent $PSCommandPath

#### External Includes ####


#### Functions ####
function Remove-ISTSVars {
    Remove-Variable -Name ISTS_* -Scope Global
}

function Connect-ISTSVCenter {
    try { #make sure we aren't already connected
        $server = (Get-VIAccount)[0].Server.Name
        Write-Warning "It looks like you are already connected to the server at `"$server`", disconnect with Disconnect-VIServer and then try again"
    } catch { 
        if ($ISTS_VCenterUser -and $ISTS_VCenterPassword){
            Write-Warning "These credentials are stored in memory in plain text, just so you know"
            Connect-VIServer -Server $ISTS_VCenterServerAddress -Protocol Https -Force -ErrorAction Stop -User $ISTS_VCenterUser -Password $ISTS_VCenterPassword
        } else {
            Connect-VIServer -Server $ISTS_VCenterServerAddress -Protocol Https -Force -ErrorAction Stop
        }
    }
}

function Import-ISTSConfig {
    param (
        [string]$ConfigFile
    )
    Remove-ISTSVars
    foreach ($line in Get-Content $ConfigFile){
        if ($line[0] -ne "#"){
            $splitline = $line.split("=")
            $varName = $splitline[0].Trim()
            $varValue = $splitline[1..($splitline.length - 1)].TrimStart() -join "="
            Set-Variable -Name ISTS_$varName -Value $varValue -Scope Global
        }
    }
}

# Deploys ISTS domain controller
function Invoke-DeployISTSDomainController {
    param ( 
        [Parameter(Mandatory=$true)][int]$TeamNumber,
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VM,
        [String]$GuestUser = "Administrator",
        [String]$GuestPassword = "Student1",
        [switch]$RunAsync = $false
    )

    process {
        foreach ($V in $VM){
            Copy-VMGuestFile -Source $ISTS_ModulePath\resource\Deploy-ISTSDomainController.ps1 -Destination C:\Windows\Temp -VM $V -GuestUser $GuestUser -GuestPassword $GuestPassword -LocalToGuest -Confirm:$false -Force
            $DomainName = "$ISTS_BottomLevelDomainNamePrefix$TeamNumber.$ISTS_DomainNameSuffix"
            $NetBiosName = "$ISTS_NetBiosName$TeamNumber".ToUpper()
            Invoke-VMScript -ScriptText "\Windows\Temp\Deploy-ISTSDomainController.ps1 -DomainName $DomainName -NetBiosName $NetBiosName -InstallRoles; Remove-Item -Path \Windows\Temp\Deploy-ISTSDomainController.ps1" -VM $V -RunAsync:$RunAsync -Confirm:$false -GuestUser $GuestUser -GuestPassword $GuestPassword
        }
    }
}

function Install-PBIS {
    param (
        [Parameter(Mandatory=$true)][String]$OSString,
        [Parameter(Mandatory=$true)][VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VM
    )
    Write-Host "Trying to match $($VM.Name)"
    if ($OSString -imatch "ubuntu" -or $OSString -imatch "debian"){
        Write-Host "Matched Debian/Ubuntu"
        $URL = $ISTS_PbisDebURL
    } elseif ($OSString -imatch "suse" -or $OSString -imatch "centos" -or $OSString -imatch "fedora" -or $OSString -imatch ".el") {
        Write-Host "Matched RHEL-based distribution"
        $URL = $ISTS_PbisRpmURL
    } else {
        Write-Warning "Host not matched"
        return $false
    }

    $Filename = $URL.Split("/")[-1]
    if (!(Test-Path .\data\$Filename)){
        New-Item -ItemType Directory -Force -Path $ISTS_ModulePath\data\$Filename
        Invoke-WebRequest $URL -OutFile $ISTS_ModulePath\data\$Filename
    }
    Copy-VMGuestFile -Source $ISTS_ModulePath\data\$Filename -Destination /tmp -LocalToGuest -VM $VM -GuestUser $GuestUser -GuestPassword $GuestPassword
    Invoke-VMScript -ScriptText "chmod +x /tmp/$Filename;/tmp/$Filename -- --dont-join --no-legacy install;rm /tmp/$Filename" -GuestUser $GuestUser -GuestPassword $GuestPassword -VM $VM
    return $true
}

function Invoke-JoinLinuxHostsToDomain {
    param (
        [Parameter(Mandatory=$true)][int]$TeamNumber,
        [Parameter(Mandatory=$true,ValueFromPipeline=$true)][VMware.VimAutomation.ViCore.Impl.V1.Inventory.VirtualMachineImpl]$VM,
        [String]$GuestUser = "root",
        [String]$GuestPassword = "student",
        [String]$DomainAdminUser = "Administrator",
        [String]$DomainAdminPassword = "Student1!",
        [String]$DNSServerIP = "172.20.15.38", #change this later, maybe make global
        [switch]$RunAsync = $false
    )
    process {
        foreach ($V in $VM){
            $OSString = (Invoke-VMScript -ScriptText "uname -a;cat /etc/issue" -GuestUser $GuestUser -GuestPassword $GuestPassword -VM $V).ScriptOutput
            if (Install-PBIS -OSString $OSString -VM $V){
                $domain = "$ISTS_BottomLevelDomainNamePrefix$TeamNumber.$ISTS_DomainNameSuffix".ToUpper()
                Invoke-VMScript -ScriptText "echo nameserver $DNSServerIP > /etc/resolv.conf; /opt/pbis/bin/domainjoin-cli join $domain $DomainAdminUser $DomainAdminPassword" -VM $V -GuestUser $GuestUser -GuestPassword $GuestPassword
            }
        }
    }
}

#### Initial config and startup ####
Import-ISTSConfig $ISTS_ModulePath\ISTS-Scripts.conf