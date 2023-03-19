# PowerShell Script to enable MON on VMs that are not enabled with MON. This is an infinite loop but can be stopped by pressing Ctrl+C Key.

Function ConnectApi-HcxServer {
  #Authentication to run custom API calls
        Param (
            [Parameter(Mandatory=$true)][String]$Server,
            [Parameter(Mandatory=$true)][String]$Username,
            [Parameter(Mandatory=$true)][String]$Password
        )
    
        $payload = @{
            "username" = $Username
            "password" = $Password
        }
        $body = $payload | ConvertTo-Json
    
        $hcxLoginUrl = "https://$Server/hybridity/api/sessions"
    
        if($PSVersionTable.PSEdition -eq "Core") {
            $results = Invoke-WebRequest -Uri $hcxLoginUrl -Body $body -Method POST -UseBasicParsing -ContentType "application/json" -SkipCertificateCheck
        } else {
            $results = Invoke-WebRequest -Uri $hcxLoginUrl -Body $body -Method POST -UseBasicParsing -ContentType "application/json"
        }
    
        if($results.StatusCode -eq 200) {
            $hcxAuthToken = $results.Headers.'x-hm-authorization'
    
            $headers = @{
                "x-hm-authorization"="$hcxAuthToken"
                "Content-Type"="application/json"
                "Accept"="application/json"
            }
    
            $global:hcxApiConnection = new-object PSObject -Property @{
                'Server' = "https://$server/hybridity/api";
                'headers' = $headers
            }
            $global:hcxApiConnection
        } else {
            Write-Error "Failed to connect to HCX Manager, please verify your vSphere SSO credentials"
        }
    }

Function Get-HcxMonSegments {
  # Function to get MON enabled segments
    param (
        [string]$SourceEndpointID,
        [string]$DestinationEndpointID,    
        [string]$HCXServer,
        [string]$HcxUsername,
        [string]$HcxPassword
      )

    If (-Not $global:hcxApiConnection) { Write-error "HCX Auth Token not found, connecting to HcxServer "
    Connect-HcxApiServer -Server $HCXServer -Username $HcxUsername -Password $HcxPassword
    } 
    Else {
      $HcxL2Url = $global:hcxApiConnection.Server + "/l2Extensions"

      $hcxAuthToken = $global:hcxApiConnection.Headers.'x-hm-authorization'

      $headers = @{
          "x-hm-authorization"="$hcxAuthToken"
          "Content-Type"="application/json"
          "Accept"="application/json"
      }

    $payload = @{
      "hcspUUID" = $SourceEndpointID
  }
  $body = $payload | ConvertTo-Json

      Write-Output ("Getting MON enabled segments")
      if($PSVersionTable.PSEdition -eq "Core") {
          $cloudvcRequests = Invoke-WebRequest -Uri $HcxL2Url -Method GET -Headers $headers -Body $body -UseBasicParsing -SkipCertificateCheck
      } else {
          $cloudvcRequests = Invoke-WebRequest -Uri $HcxL2Url -Method GET -Headers $headers -Body $body -UseBasicParsing
      }
  
      $cloudvcData = ($cloudvcRequests.content | ConvertFrom-Json).items
  
      
foreach ($data in $cloudvcData) {
  If (($data.destination.endpointId -eq $DestinationEndpointID) -and ($data.features.mobilityOptimizedNetworking -eq "True")) {
    [Array]$MonNetworkExtensions += $data
  }
}

  if ($MonNetworkExtensions.count -eq 0) {
    Write-Host ("No networks are MON enabled") -ForegroundColor DarkRed
    }
  else {
  write-host $MonNetworkExtensions.stretchId
  $MonNwCount = $MonNetworkExtensions.count
  write-host ("Found $MonNwCount MON enabled networks") -ForegroundColor Green
  }
      
  }
  $MonNetworkExtensions
}

Function GetSet-HcxMonVms {
  <#
      .DESCRIPTION
          This cmdlet returns the VMs that are in Cloud MON enabled segment, but not MON enabled at VM level. 
          Also enables MON for those VMs if chosen
  #>
  param (
    [Array]$MonNetworkExtensionIds,
    [string]$SourceEndpointID,
    [string]$DestinationEndpointID, 
    [string]$CloudVcEndpoint,   
    [string]$HCXServer,
    [string]$HcxUsername,
    [string]$HcxPassword,
    [bool]$EnableMon
  )

  If (-Not $global:hcxApiConnection) { Write-error "HCX Auth Token not found, connecting to HcxServer "
  Connect-HcxApiServer -Server $HCXServer -Username $HcxUsername -Password $HcxPassword
  } 
  Else {
    $hcxAuthToken = $global:hcxApiConnection.Headers.'x-hm-authorization'

    $headers = @{
        "x-hm-authorization"="$hcxAuthToken"
        "Content-Type"="application/json"
        "Accept"="application/json"
    }

  $payload = @{
    "endpointId" = $DestinationEndpointID
    "hcspUUID" = $SourceEndpointID
}
$body = $payload | ConvertTo-Json
}

  ForEach ($MonNetworkExtensionId in $MonNetworkExtensionIds)
  {
    $HcxMonUrl = $global:hcxApiConnection.Server + "/l2Extensions/" + $MonNetworkExtensionId + "/vms" + "?endpointId=" + $DestinationEndpointID + "&hcspUUID=" + $SourceEndpointID
    Write-host ("Getting VMs on MON network $MonNetworkExtensionId") -ForegroundColor Green
    if($PSVersionTable.PSEdition -eq "Core") {
        $cloudvcRequests = Invoke-WebRequest -Uri $HcxMonUrl -Method GET -Headers $headers -Body $body -UseBasicParsing -SkipCertificateCheck
    } else {
        $cloudvcRequests = Invoke-WebRequest -Uri $HcxMonUrl -Method GET -Headers $headers -Body $body -UseBasicParsing
    }

    $cloudvcData = ($cloudvcRequests.content | ConvertFrom-Json).items
    
    foreach ($data in $cloudvcData) {
      If ($data.isProximityRouted -like "False") {
        [Array]$MonVmChangeList += $data
      
      #Enabling MON
      if ($EnableMon) {
        if ($MonVmChangeList.count -gt 0) {
          foreach ($MonVM in $MonVmChangeList) {
            $MonVmName = $MonVM.name
            $vmid = $MonVM.vmId
            $resourceid = $MonVM.resourceId
  
            write-host ("Enabling MON for $MonVmName") -ForegroundColor Red
$monpayload = @"
{
  "endpointId": "$DestinationEndpointID",
  "items": [
    {
      "routerEndpointId": "$DestinationEndpointID",
      "vmId": "$vmId",
      "switchoverType": "switchoverNow",
      "resourceId": "$resourceId"
    }
  ]
}
"@
            write-host ($monpayload)
            try 
            {
              Invoke-WebRequest -Uri $HcxMonUrl -Method POST -Headers $headers -Body $monpayload -UseBasicParsing -SkipCertificateCheck        
            }
            catch 
            {
              Write-Host "StatusCode:" $_.Exception.Response.StatusCode.value__ 
              Write-Host "StatusDescription:" $_.Exception.Response.StatusDescription
            }
        
          [Array]$MonVmChangeList = $null
        }
      }
        else {
          write-host ("New VMs NOT found to enable MON in the network $MonNetworkExtensionId") -ForegroundColor Green
          [Array]$MonVmChangeList = $null

          }
        
      }
    }
    
  }
}

$MonVmChangeList
}


# <<<<<<<<<<<<<<   Main code starts here  >>>>>>>>>>>>>

# Defining HCX URL, user name and password. User inputs - comment/uncomment as needed
$HcxServer = Read-Host -Prompt "Enter your On-prem HCX Connector IP Address"
$HcxUsername = Read-Host -Prompt "Enter your On-prem HCX User Name"
$HcxPassword = = Read-Host "Enter HCX Password" -AsSecureString
$CloudVcEndpoint = Read-Host -Prompt "Enter your Cloud vCenter Name"

#Defining HCX URL, user name and password. Hardcoded values - comment/uncomment as needed
$HcxServer = $HcxServer
$HcxUsername = $HcxUsername
$HcxPassword = $HcxPassword
$CloudVcEndpoint = $CloudVcEndpoint
$ChangeConfirm = [string] (Read-host "Type enable to enable MON automatically. Anything else to run in read only mode")
[int]$ProbeInterval = 10

#$ProbeInterval = Read-Host -Prompt "Enter the Isolated T1GW Static Route Probe interval in seconds"

#Authentication
Connect-HcxServer -Server $HCXServer -Username $HcxUsername -Password $HcxPassword

#Gather Endpoint IDs
Write-Host ("Collecting endpoint data") -ForegroundColor Green

[Array]$SourceHcxData = Get-HCXSite -Source
$DestinationSite = Get-HCXSite -Destination -Server $HCXServer -Name $CloudVcEndpoint

$SourceEndpointID = $SourceHcxData[0].EndpointId
$DestinationEndpointID = $DestinationSite.EndpointId

Write-Host ("Collecting Extension IDs") -ForegroundColor Green
[Array]$NetworkExtensions = (Get-HCXNetworkExtension -DestinationSite $DestinationSite)
$MonNetworkExtensionIds = @()

#Get Mon enabled segments list

#get-hcxnetworkextension doesnt get mon status, so using API method
ConnectApi-HcxServer -Server $HCXServer -Username $HcxUsername -Password $HcxPassword

[Array]$MonNetworkExtensions = Get-HcxMonSegments -SourceEndpointID $SourceEndpointID -DestinationEndpointID $DestinationEndpointID -Server $HCXServer -Username $HcxUsername -Password $HcxPassword
[Array]$MonNetworkExtensionIds = $MonNetworkExtensions.stretchId
write-host ($MonNetworkExtensionIds) -ForegroundColor Green

do 
{

#Get VMs on Mon enabled segments (and enable optionally)
if ($ChangeConfirm -like "enable") {
  write-host ("Checking to enable MON for pending VMs automatically") -ForegroundColor Green 
  [Array]$MonVmChangeList = GetSet-HcxMonVms -MonNetworkExtensionIds $MonNetworkExtensionIds -SourceEndpointID $SourceEndpointID -DestinationEndpointID $DestinationEndpointID -CloudVcEndpoint $CloudVcEndpoint -Server $HCXServer -Username $HcxUsername -Password $HcxPassword -EnableMon $true

}
else {
  write-host ("Read only mode. Not enabling MON") -ForegroundColor Green #update
  [Array]$MonVmChangeList = GetSet-HcxMonVms -MonNetworkExtensionIds $MonNetworkExtensionIds -SourceEndpointID $SourceEndpointID -DestinationEndpointID $DestinationEndpointID -CloudVcEndpoint $CloudVcEndpoint -Server $HCXServer -Username $HcxUsername -Password $HcxPassword -EnableMon $false
  $MonVmChangeCount = $MonVmChangeList.Count
  foreach ($MonVM in $MonVmChangeList) {
  [array]$MonVmName += $MonVM.name
  }
  write-host ("Found $MonVmChangeCount VMs to enable MON. Below are the VMs") -ForegroundColor Green
  write-host ($MonVmName) -ForegroundColor Red
  [array]$MonVmChangeList = $null
  [array]$MonVmName = $null
}

Start-Sleep -Seconds $ProbeInterval
} while ($true -or ([System.Console]::ReadKey($true)).Key -eq "Ctrl+C") # Run this checks in periodic loop or Run till user presses Ctrl+C Key
