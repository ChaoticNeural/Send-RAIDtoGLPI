<#
    .VERSION
    0.1
    
    .SYNOPSIS
    Script for getting data from LSI RAID Controller to GLPI inventory system.
    .DESCRIPTION
    This script collects physical disks info from JSON output of StorCLI and sends it to GLPI through API
    .NOTES
	Github: https://github.com/ChaoticNeural/Send-RAIDtoGLPI/
#>

$workDir = Split-Path $MyInvocation.MyCommand.Path;

Import-Module (Join-Path $workDir "PSGLPI-master\PSGLPI")
$storCliPath = Join-Path $workDir "StorCli64.exe"

$GlpiCreds = @{
    AppURL            = "https://yourglpi.host/apirest.php"
    UserToken         = "y10Wm05pctn7kH70gbBSNb8ZYzQWHGQHsukuYlDz"
    AppToken          = "duyEsZpzYinskK2Ru8LQ0uVe1JU0L53YzIqiLPyq"
    AuthorizationType = "user_token"
}

$jsondata = & "$storCliPath" /c0 show all j | Out-String | ConvertFrom-Json
$arrayEncSlt = @()
foreach ($controller in $jsondata.Controllers) {
    foreach ($obj in $controller.'Response Data'.'PD LIST') {
        $arrayEncSlt += ([string]::Format('/c{0}/e{1}', $controller.'Response Data'.Basics.Controller, $obj."EID:Slt")).Replace(":", "/s")
    }
}

#Get GLPI computer ID by motherboard serial number
$MBserial = (Get-CimInstance win32_bios).serialnumber
$GlpiComputerID = (Search-GlpiItem -ItemType "Computer" -SearchOptions (("OR", 2, "is", ""), ("AND", 5, "is", "$MBSerial")) -Creds $GlpiCreds).2

foreach ($pathEncSlt in $arrayEncSlt) {
    $jsondataEncSl = & "$storCliPath" $pathEncSlt show all j | Out-String | ConvertFrom-Json
    # Check the presence of disk with this serial number
    $DiskSerial = [string]$jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt - Detailed Information"."Drive $pathEncSlt Device attributes"."SN".trim()
    if ($NULL -eq ($GlpiDiskItemId = (Search-GlpiItem -ItemType "Item_DeviceHardDrive" -SearchOptions (("OR", 1, "is", ""), ("AND", 10, "is", $DiskSerial)) -Range "0-0" -Creds $GlpiCreds).1)) {
        # Check the presence of the disk model in the GLPI components
        $DiskModel = [string]$jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt"."Model".trim()
        if ($NULL -eq ($GlpiDiskModelId = (Search-GlpiItem -ItemType "DeviceHardDrive" -SearchOptions (("OR", 2, "is", ""), ("AND", 1, "is", $DiskModel))  -Range "0-0" -Creds $GlpiCreds).2)) {
            # Check the presence of the disk vendor in the GLPI components
            $DiskManufacturer = [string]$jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt - Detailed Information"."Drive $pathEncSlt Device attributes"."Manufacturer Id".trim()
            if ($NULL -eq ($GlpiManufacturerID = (Search-GlpiItem -ItemType "Manufacturer" -SearchOptions (("OR", 2, "is", ""), ("AND", 1, "is", $DiskManufacturer))  -Range "0-0" -Creds $GlpiCreds).2)) {
                # Add disk vendor
                $ManufacturerDetails = @{
                    name = "$DiskManufacturer"
                }
                $GlpiManufacturerID = Add-GlpiItem -ItemType "Manufacturer" -Details $ManufacturerDetails -Creds $GlpiCreds
            }
            # Add disk model
            $InterfaceType = [string]$jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt"."Intf".trim()
            $MediaType = [string]$jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt"."Med".trim()
            $DiskCapacity = [string]($jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt"."Size" -replace " ") / 1MB
            $DiskModelDetails = @{
                designation              = $DiskModel
                manufacturers_id         = $GlpiManufacturerID
                capacity_default         = $DiskCapacity
                interfacetypes_id        = switch ($InterfaceType) { "SAS" { "9" }; "SATA" { "2" }; default { "" } }
                deviceharddrivemodels_id = switch ($MediaType) { "HDD" { "1" }; "SSD" { "2" }; default { "" } }
            }
            $GlpiDiskModelId = (Add-GlpiItem -ItemType "DeviceHardDrive" -Details $DiskModelDetails -Creds $GlpiCreds).id
        }
        # Add disk data
        $NewDiskDetails = @{
            serial              = $DiskSerial
            deviceharddrives_id = $GlpiDiskModelId
        }
        $GlpiDiskItemId = (Add-GlpiItem -ItemType "Item_DeviceHardDrive" -Details $NewDiskDetails -Creds $GlpiCreds).id
    }
    # Update disk data (computer binding, enclosure slot,  health)
    $DiskCapacity = [string]($jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt"."Size" -replace " ") / 1MB
    $MediaError = [int]$jsondataEncSl.Controllers[[Convert]::ToInt32($pathEncSlt[2], 10)]."Response Data"."Drive $pathEncSlt - Detailed Information"."Drive $pathEncSlt State"."Media Error Count"
    $DiskDetails = @{
        id        = "$GlpiDiskItemId"
        items_id  = "$GlpiComputerID"
        itemtype  = "Computer"
        states_id = switch ($MediaError) { 0 { "2" }; { $_ -gt 0 } { "1" } }
        capacity  = $DiskCapacity
        busID     = $pathEncSlt
    }
    Update-GlpiItem -ItemType "Item_DeviceHardDrive" -Details $DiskDetails -Creds $GlpiCreds
}
