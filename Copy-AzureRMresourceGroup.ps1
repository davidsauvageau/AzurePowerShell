<#
.SYNOPSIS
    Copies Az V2 (ARM) resources from one Az Subscription to another.  
    Unlike the Move-Azresource cmdlet, this script allows you to move between subscriptions in different Tenants and 
    different Az Environments. Requires Az module version 6.7 or later.
    
.DESCRIPTION
   Copies configurations of a resource group in one subscription and provisions them in the target subscription.
   This is intended mostly for Az V2 virtual machines and will include copying virtual disks, virtual
   network, load balancers, Public IPs and other associated storage accounts and blob files.

   The VHD copies can take several hours depending on how many and the sizes so the script can be executed in two parts.  
   It will break with the copy status that can be refreshed - or you can exit at that point and use the -resume switch to 
   continue with the VM provisioning after the file copies are complete.

  Due to uniqueness requirements DNS names of source and targets, the following renaming occurs during reprovisioning within the same environment
  ** Storage accounts will be renamed by appending an 8 character GUID to the original storage account name
  ** DNS Labels on Public IPs will be renamed by appending 'new' to the DNS name



.EXAMPLE
   .\Copy-AzresourceGroup.ps1 -ResourceGroupName 'CONTOSO'

Using the script without explicitly specifying OptionalSourceEnvironment or OptionalTargetEnvrionment will result in prompts for these.  
Press <Enter> to accept the default environment of AzCloud.

.EXAMPLE
   .\Copy-AzresourceGroup.ps1 -ResourceGroupName 'CONTOSO'  -Resume

Resumes the script after waitig for the blob copy to complete.  Press <Enter> to accept the default source and target environments of AzCloud.

.EXAMPLE
   .\Copy-AzresourceGroup.ps1 -ResourceGroupName 'CONTOSO' -OptionalNewLocation 'westus'

Specify -newLocation if the target resource group needs to be in a different region than the source
Press <Enter> to accept the default environment of AzCloud.


.EXAMPLE
   .\Copy-AzresourceGroup.ps1 -ResourceGroupName 'CONTOSO' -OptionalTargetEnvironment 'AzGermanCloud' 

Copies Resource Group CONTOSO from Az Cloud to Az German Cloud.  Press <Enter> at prompt for OptionalSourceEnvironment


.EXAMPLE
   .\Copy-AzresourceGroup.ps1 -ResourceGroupName 'CONTOSO' -OptionalSourceEnvironment 'AzUSGovernment'  -OptionalTargetEnvironment 'AzUSGovernment' 

Copies Resource Group CONTOSO from Az Government to Az Government



.PARAMETER -ResourceGroupName [string]
  Name of resource group being copied

.PARAMETER -OptionalSourceEnvironment [string]
  Name of the source Environment. e.g. AzUSGovernment, AzGermanCloud or AzChinaCloud. Defaults to AzCloud.

.PARAMETER -OptionalTargetEnvironment [string]
  Name of the target Environment. e.g. AzUSGovernment, AzGermanCloud or AzChinaCloud. Defaults to AzCloud.

.PARAMETER -OptionalNewLocation [string]
  Name of the Az location for new resource group if different than the source.

.PARAMETER -Resume [switch]
  Resumes after the file copy


.NOTES

    Original Author:   https://github.com/JeffBow
    
 ------------------------------------------------------------------------
               Copyright (C) 2016 Microsoft Corporation

 You have a royalty-free right to use, modify, reproduce and distribute
 this sample script (and/or any modified version) in any way
 you find useful, provided that you agree that Microsoft has no warranty,
 obligations or liability for any sample application or script files.
 ------------------------------------------------------------------------
#>
#Requires -Version 7.0


param(

    [Parameter(mandatory=$True,
      HelpMessage="Enter the name of the Az Resource Group you want to copy and Press <Enter> e.g. CONTOSO")]
    [string]$ResourceGroupName,

    [Parameter(mandatory=$True,
      HelpMessage="Press <Enter> to default to AzCloud or enter the Az Environment name of the source subscription. e.g. AzUSGovernment")]
    [AllowEmptyString()]
    [string]$OptionalSourceEnvironment,
    
    [Parameter(mandatory=$True,
      HelpMessage="Press <Enter> to default to AzCloud or enter the Az Environment name of the target subscription. e.g. AzGermanCloud")]
    [AllowEmptyString()]
    [string]$OptionalTargetEnvironment,

   [Parameter(mandatory=$True,
    HelpMessage="Press <Enter> to create the new resource in the same region as the source or enter a new location/region for the target.")]
    [AllowEmptyString()]
    [string]$OptionalNewLocation,

    [Parameter(mandatory=$False,
      HelpMessage="Use this switch to resume the script after waiting for the blob copy to complete")]
    [switch]$Resume



)  

$resourceGroupVmResumePath = "$env:TEMP\$resourcegroupname.resourceGroupVMs.resume.json"
$resourceGroupVmSizeResumePath = "$env:TEMP\$resourcegroupname.resourceGroupVMsize.resume.json"
$VHDstorageObjectsResumePath = "$env:TEMP\$resourcegroupname.VHDstorageObjects.resume.json"
$jsonBackupPath = "$env:TEMP\$resourcegroupname.json"
$ProgressPreference = 'SilentlyContinue'

#Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force


<###############################
 Get Storage Context function
################################>
function Get-StorageObject 
{ param($resourceGroupName, $srcURI, $srcName) 
    
    $split = $srcURI.Split('/')
    $strgDNS = $split[2]
    $splitDNS = $strgDNS.Split('.')
    $storageAccountName = $splitDNS[0]
    # add uri and storage account name to custom PSobject
    $PSobjSourceStorage = New-Object -TypeName PSObject
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name srcStorageAccount -Value $storageAccountName  
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name srcURI -Value $srcURI
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name srcName -Value $srcName
    # retrieve storage account key and storage context
    $StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $StorageAccountName).Value[0]
    $StorageContext = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $StorageAccountKey
    # add storage context to psObject
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageContext -Value $StorageContext 
    # get storage account and add other attributes to psCustom object
    $storageAccount = Get-AzStorageAccount -ResourceGroupName $resourceGroupName -Name $storageAccountName
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageEncryption -Value $storageAccount.Encryption
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageCustomDomain -Value $storageAccount.CustomDomain
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageKind -Value $storageAccount.Kind
    $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcStorageAccessTier -Value $storageAccount.AccessTier
    # get storage account sku and convert to string that is required for creation
    $skuName = $storageAccount.sku.Name.ToString()
 
    switch ($skuName) 
        { 
            'StandardLRS'   {$skuName = 'Standard_LRS'} 
            'Standard_LRS'   {$skuName = 'Standard_LRS'} 
            'StandardZRS'   {$skuName = 'Standard_ZRS'} 
            'StandardGRS'   {$skuName = 'Standard_GRS'} 
            'StandardRAGRS'{$skuName = 'Standard_RAGRS'} 
            'PremiumLRS'   {$skuName = 'Premium_LRS'} 
            'Premium_LRS'   {$skuName = 'Premium_LRS'} 
            default {$skuName = 'Standard_LRS'}
        }
     
     $PSobjSourceStorage | Add-Member -MemberType NoteProperty -Name SrcSkuName -Value $skuName
    
    return $PSobjSourceStorage

} # end of Get-StorageObject function

<###############################
  get available resources function
################################>
function get-availableResources
{ param($resourceType, $location)

    $resource = Get-AzVMUsage -Location $location | Where-Object{$_.Name.value -eq $resourceType}
    [int32]$availabe = $resource.limit - $resource.currentvalue
    return $availabe 

}
<###############################
  get blob copy status
################################>
function Get-BlobCopyStatus
{ param($context, $containerName, $blobName)
    
    if($blobName)
    {
        write-verbose "Checking VHD blob copy for $blobName" -verbose
        $blob = Get-AzStorageBlob -Context $context -container $containerName -Blob $blobName
    }
    else
    {
        write-verbose "Checking VHD blob copy for container $containerName" -verbose 
        $blob = Get-AzStorageBlob -Context $context -container $containerName 
    }

    do
    {
        $rtn = $blob | Get-AzStorageBlobCopyState
        $rtn | Select-Object Source, Status, BytesCopied, TotalBytes | Format-List
        if($rtn.status  -ne 'Success')
        {
            write-warning "VHD blob copy is not complete"
            $rh = read-host "Press <Enter> to refresh or type EXIT and press <Enter> to quit copy status updates and resume later"
            if(($rh.ToLower()) -eq 'exit')
            {
                write-output "Run script with -resume switch to continue creating VMs after file copy has completed."
                BREAK
            }
        }
    }
    while($rtn.status  -ne 'Success')

    # exit script if user breaks out of above loop   
    if($rtn.status  -ne 'Success'){EXIT}

}

<###############################
  Copy blob function
################################>
function copy-AzBlob 
{  param($srcUri, $srcContext, $destContext, $containerName)


    $split = $srcURI.Split('/')
    $blobName = $split[($split.count -1)]
    $blobSplit = $blobName.Split('.')
    $extension = $blobSplit[($blobSplit.count -1)]
    if($($extension.tolower()) -eq 'status' ){Write-Output "Status file blob $blobname skipped";return}

    if(! $containerName){$containerName = $split[3]}

    # add full path back to blobname 
    if($split.count -gt 5) 
      { 
        $i = 4
        do
        {
            $path = $path + "/" + $split[$i]
            $i++
        }
        while($i -lt $split.length -1)

        $blobName= $path + '/' + $blobName
        $blobName = $blobName.Trim()
        $blobName = $blobName.Substring(1, $blobName.Length-1)
      }
    
    
   # create container if doesn't exist    
    if (!(Get-AzStorageContainer -Context $destContext -Name $containerName -ea SilentlyContinue)) 
    { 
         try
         {
            $newRtn = New-AzStorageContainer -Context $destContext -Name $containerName -Permission Off -ea Stop 
            Write-Output "Container $($newRtn.name) was created." 
         }
         catch
         {
             $_ ; break
         }
    } 


   try 
   {
        $blobCopy = Start-AzStorageBlobCopy -ea Stop `
            -srcUri $srcUri `
            -SrcContext $srcContext `
            -DestContainer $containerName `
            -DestBlob $blobName `
            -DestContext $destContext

         write-output "$srcUri is being copied to $containerName"
    
   }
   catch
   { 
      $_ ; write-warning "Failed to copy to $srcUri to $containerName"
   }
  

} # end of copy-AzBlob function


if(! $resume){

<###############################

 Read resource group from old Sub

################################>

# Verify specified Environment
if($OptionalSourceEnvironment -and (Get-AzEnvironment -Name $OptionalSourceEnvironment) -eq $null)
{
   write-warning "The specified -OptionalSourceEnvironment could not be found. Specify one of these valid environments."
   $OptionalSourceEnvironment = (Get-AzEnvironment | Select-Object Name, ManagementPortalUrl | Out-GridView -title "Select a valid Az environment for your source subscription" -OutputMode Single).Name
}

# get Az creds for source
write-host "Enter credentials for the 'source' Az Subscription..." -f Yellow
if($OptionalSourceEnvironment)
{
   $login= Connect-AzAccount -EnvironmentName $OptionalSourceEnvironment
}
else
{
   $login= Connect-AzAccount
}

$loginID = $login.context.account.id
$sub = Get-AzSubscription
$SubscriptionId = $sub.Id

# check for multiple subs under same account and force user to pick one
if($sub.count -gt 1) 
{
    $SubscriptionId = (Get-AzSubscription | Select-Object * | Out-GridView -title "Select Target Subscription" -OutputMode Single).Id
    Select-AzSubscription -SubscriptionId $SubscriptionId | Out-Null
    $sub = Get-AzSubscription -SubscriptionId $SubscriptionId
}

# check for valid sub
if(! $SubscriptionId) 
{
   write-warning "The provided credentials failed to authenticate or are not associcated to a valid subscription. Exiting the script."
   break
}

$SubscriptionName = $sub.Name

write-host "Logged into $SubscriptionName with subscriptionID $SubscriptionId as $loginID" -f Green

# check for valid source resource group
if(-not ($sourceResourceGroup = Get-AzResourceGroup  -ResourceGroupName $resourceGroupName)) 
{
   write-warning "The provided resource group $resourceGroupName could not be found. Exiting the script."
   break
}


# create export JSON for backup purposes
$RGexport = Export-AzResourceGroup -ResourceGroupName $resourceGroupName -Path $jsonBackupPath -IncludeParameterDefaultValue -Force -wa SilentlyContinue



# get configuration details for different resources
[string] $location = $sourceResourceGroup.location
$resourceGroupStorageAccounts = Get-AzStorageAccount -ResourceGroupName $resourceGroupName
$resourceGroupManagedDisks = Get-AzDisk -ResourceGroupName $resourceGroupName
$resourceGroupVirtualNetworks = Get-AzVirtualNetwork -ResourceGroupName $resourceGroupName
$resourceGroupNICs = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName
$resourceGroupNSGs = Get-AzNetworkSecurityGroup -ResourceGroupName $resourceGroupName
$resourceGroupAvSets = Get-AzAvailabilitySet -ResourceGroupName $resourceGroupName 
$resourceGroupVMs = Get-AzVM -ResourceGroupName $resourceGroupName
$resourceGroupPIPs = Get-AzPublicIpAddress -ResourceGroupName $resourceGroupName
$resourceGroupNICs = Get-AzNetworkInterface -ResourceGroupName $resourceGroupName
$resourceGroupLBs = Get-AzLoadBalancer -ResourceGroupName $resourceGroupName
if(! $resourceGroupVMs){write-warning "No virtual machines found in resource group $resourceGroupName"}



# display what we found
write-host "The following items will be copied:" -f DarkGreen
write-host "Storage Accounts:" -f DarkGreen
$resourceGroupStorageAccounts.StorageAccountName
write-host "Managed Disks:" -f DarkGreen
$resourceGroupManagedDisks.Name
write-host "Virtual Machines:" -f DarkGreen
$resourceGroupVMs.name
write-host "Operating system disks:" -f DarkGreen
$resourceGroupVMs.storageProfile.osdisk.name
write-host "Data disks:" -f DarkGreen
$resourceGroupVMs.datadisknames
# check to make sure VMs are not running
write-host "Current status of VMs:" -f DarkGreen
$resourceGroupVMs | %{
   $status = ((get-Azvm -ResourceGroupName $resourceGroupName -Name $_.name -status).Statuses|Where-Object{$_.Code -like 'PowerState*'}).DisplayStatus
   write-output "$($_.name) status is $status" 
   if($status -eq 'VM running'){write-warning "All virtual machines in this resource group are not stopped.  Please stop all VMs and try again"; break}
}

write-host "Virtual networks:" -f DarkGreen
$resourceGroupVirtualNetworks.name
write-host "Network Security Groups:" -f DarkGreen
$resourceGroupNSGs.name
write-host "Load Balancers:" -f DarkGreen
$resourceGroupLBs.name
write-host "Public IPs:" -f DarkGreen
$resourceGroupPIPs.name



# create array of custom PSobjects that contain storage account details and security context for each VHD that is found
# this is consumed later during the copy process after you log into the target subscription
[array]$sourceVHDstorageObjects = $()
[array]$sourceMDstorageObjects = $()
write-verbose "Retrieving storage context for each source blob" -Verbose

foreach($vm in $resourceGroupVMs) 
{
    # get storage account name from VM.URI
    if($vm.storageprofile.osdisk.vhd)
    {
        $vmURI = $vm.storageprofile.osdisk.vhd.uri
        $obj = $null
        $obj = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $vmURI
        [array]$sourceVHDstorageObjects += $obj 
    }
    
    if($vm.storageProfile.datadisks)
    {
       foreach($disk in $vm.storageProfile.datadisks) 
       {
            if($disk.vhd)
            {
                $diskURI = $disk.vhd.uri
                $obj = $null
                $obj = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $diskURI
                [array]$sourceVHDstorageObjects += $obj
            }
       }
    }
}

    # start copy of all Managed Disks       
    write-verbose "Retrieving SAS access token for each managed disk" -Verbose

    foreach($md in $resourceGroupManagedDisks)
    { 

        #Get the SAS URL of the VHD blob and do a copy process to the temp storage account
        $AccessURI = $md | Grant-AzDiskAccess -Access 'Read' -DurationInSecond 10800
        $AccessSAS = $AccessURI.AccessSAS

        $PSobjMDstorage = New-Object -TypeName PSObject
        $PSobjMDstorage | Add-Member -MemberType NoteProperty -Name Name -Value $md.Name
        $PSobjMDstorage | Add-Member -MemberType NoteProperty -Name AccessSAS -Value $AccessSAS
        $PSobjMDstorage | Add-Member -MemberType NoteProperty -Name SkuName -Value $md.sku.Name.ToString()
        $PSobjMDstorage | Add-Member -MemberType NoteProperty -Name Id -Value $md.id  
        $PSobjMDstorage | Add-Member -MemberType NoteProperty -Name OsType -Value $md.OsType
        $PSobjMDstorage | Add-Member -MemberType NoteProperty -Name DiskSizeGB -Value $md.DiskSizeGB
        $PSobjMDstorage | Add-Member -MemberType NoteProperty -Name EncryptionSettings -Value $md.EncryptionSettings

        [array]$sourceMDstorageObjects += $PSobjMDstorage
    }


[array]$sourceStorageObjects = $()
#get any storage accounts and blobs that were not VHDs attached to VMs
foreach($sourceStorageAccount in $resourceGroupStorageAccounts)
{ 
  $sourceStorageAccountName = $sourceStorageAccount.StorageAccountName
  $sourceStorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $sourceStorageAccountName).Value[0]
  $sourceStorageContext = New-AzStorageContext -StorageAccountName $sourceStorageAccountName -StorageAccountKey $sourceStorageAccountKey 
  $sourceStorageContainers = Get-AzStorageContainer -Context $sourceStorageContext
  foreach($container in $sourceStorageContainers)
  {
    $blobs = Get-AzStorageBlob -Container $container.name -Context $sourceStorageContext

    foreach($blob in $blobs) 
    {
      # get storage account details from uri
      $URI = $blob.ICloudBlob.uri.Absoluteuri
      # only add to sourceStorageObjects if it isn't in sourceVHDstorageObjects - must do replace to adapt to absoluteURI
      if($sourceVHDstorageObjects.srcURI -notcontains ($URI.replace('https','http')) -and $sourceVHDstorageObjects.srcURI -notcontains $URI)
      {
        $obj = $null
        $obj = Get-StorageObject -resourceGroupName $resourceGroupName -srcURI $URI
        [array]$sourceStorageObjects += $obj 
      }
    }
  }
}

write-host "Additional storage blobs:" -f DarkGreen
$sourceStorageObjects.srcURI


} # end of if not resume



<#############################################################
##############################################################

 Recreate resource group in new Sub

##############################################################
##############################################################>


# get Az creds for target subscription
$login = $null
$sub = $null
$SourceSubscriptionID = $subscriptionID
$subscriptionID = $null

# Verify specified Environment
if($OptionalTargetEnvironment -and (Get-AzEnvironment -Name $OptionalTargetEnvironment) -eq $null)
{
   write-warning "The specified -OptionalTargetEnvironment could not be found. Select one of these valid environments."
   $OptionalTargetEnvironment = (Get-AzEnvironment | Select-Object Name, ManagementPortalUrl | Out-GridView -title "Select a valid Az environment for your target subscription" -OutputMode Single).Name
}

write-host "Disconnecting from the 'source' Az Subscription..." -f Yellow
Disconnect-AzAccount -Username $loginID | Out-Null

# get Az creds for target
write-host "Enter credentials for the 'target' Az Subscription..." -f Yellow
if($OptionalTargetEnvironment)
{
   $login= Connect-AzAccount -EnvironmentName $OptionalTargetEnvironment
}
else
{
   $login= Connect-AzAccount 
}

$loginID = $login.context.account.id
$sub = Get-AzSubscription 
$SubscriptionId = $sub.Id

# check for multiple subs under same account and force user to pick one
if($sub.count -gt 1) 
{
    $SubscriptionId = (Get-AzSubscription | Select-Object * | Out-GridView -title "Select Target Subscription" -OutputMode Single).Id
    Select-AzSubscription -SubscriptionId $SubscriptionId| Out-Null
    $sub = Get-AzSubscription -SubscriptionId $SubscriptionId
}

   

# check for valid sub
if(! $SubscriptionId) 
{
   write-warning "The provided credentials failed to authenticate or are not associcated to a valid subscription. Exiting the script."
   break
}

if($SubscriptionId -eq $SourceSubscriptionID) 
{
   write-warning "Failed to authenticate to a different subscription. Exiting the script."
   break
}

$SubscriptionName = $sub.Name

write-host "Logged into $SubscriptionName with subscriptionID $SubscriptionId as $loginID" -f Green


if(! $resume)
{
    [bool]$isSameEnv = $true
    if($OptionalTargetEnvironment -ne $OptionalSourceEnvironment)
    {
        [bool]$isSameEnv = $false
    }

    <###############################
     Verify Location
    ################################>
    $srcLocation = $location

    if($OptionalNewLocation)
    {
        $location = $OptionalNewLocation
    }

    Write-Output "Verifying specified location: $location ..."
    # Prompt for location if provided location doesn't exist in current environment.
    $location = (Get-Azlocation | Where-Object { $_.Providers -eq 'Microsoft.Compute' -and ( $_.DisplayName -like $location -or $_.location -like $location)}).location
    if(! $location) 
    {
        write-warning "$OptionalNewLocation is an invalid Az Resource Group location for this environment.  Please select a valid location and click OK"
        $location = (Get-Azlocation | Where-Object { $_.Providers -eq 'Microsoft.Compute'} | Select-Object DisplayName, Providers, Location | Out-GridView -Title "Select Az Resource Group Location" -OutputMode Single).location
    }


    <###############################
     Verify Available Resources 
    ################################>

    foreach ($vmSize in ($resourceGroupVMs.hardwareprofile.vmsize))
    {
        $cores = $null
        $cores = (Get-AzVMSize -Location $location | Where-Object{$_.Name -eq $vmSize}).NumberOfCores
        $totalCoresNeeded = $cores + $totalCoresNeeded
    }

    
    $TotalAvailabeVMs = Get-availableResources -ResourceType 'virtualMachines' -Location $location
    if($resourceGroupVMs.count -gt $TotalAvailabeVMs)
    {
        Write-Warning "Insufficent available VMs in location $location. Script halted."
        break
    }

    $TotalAvailabeCores = Get-availableResources -ResourceType 'cores' -Location $location
    if($totalCoresNeeded -gt $TotalAvailabeCores)
    {
        Write-Warning "Insufficent available cores in location $location. Script halted."
        break
    }
    

    $TotalAvailabeAVs = Get-availableResources -ResourceType 'availabilitySets' -Location $location
    if($resourceGroupAvSets.count -gt $TotalAvailabeAVs)
    {
        Write-Warning "Insufficent Availability Sets in location $location. Script halted."
        break
    }
    


    <###############################

    Create new Resource Group - using same name as source

    ################################>

    do 
    {
        $RGexists = $null
        try
        {
            $RGexists = Get-AzResourceGroup -Name $ResourceGroupName -ea stop
        }
        catch{}
        
        if($RGexists) 
        {
            write-warning "$ResourceGroupName already exists." 
            $ResourceGroupName = read-host   'Enter a different Resource Group Name'
        }  
    }
    while($RGexists)


    try
    {
        write-verbose "Creating new resource group $resourceGroupName in $location" -Verbose
        $NewResourceGroup  = New-AzResourceGroup -Name $ResourceGroupName -Location $location -ea Stop -wa SilentlyContinue
        write-output "The new resource group $resourceGroupName was created in subscription $SubscriptionName"
    }
    catch
    {
        $_
        write-warning "Failed to create the new resource group $resourceGroupName  Exiting the script."
        break
    }



  <###############################

   Create new destination storage accounts
   and copy blobs
 
   ################################>


    # initialize array to store new destination storage account names relative to srcURI
    [array]$VHDstorageObjects = @()

    # get all the unique source storage accounts from custom psobject
    $srcStorageAccountNames = $sourceStorageObjects | Select-Object -Property srcStorageAccount -Unique
    
    $VHDsrcStorageAccounts = $sourceVHDstorageObjects| Select-Object -Property srcStorageAccount -Unique
    
    # add the VHD storage accounts to $sourceStorageObjects if they're not there already
    foreach($VHDsrcStorageAccountObj in $VHDsrcStorageAccounts)
    {
        $VHDsrcStorageAccountName = $VHDsrcStorageAccountObj.srcStorageAccount
        
        if($srcStorageAccountNames.srcStorageAccount -notcontains $VHDsrcStorageAccountName )
        {
            [array]$sourceStorageObjects += $sourceVHDstorageObjects|Where-Object{$_.srcStorageAccount -eq $VHDsrcStorageAccountName}
        }
    }

    $srcStorageAccounts = $sourceStorageObjects | Select-Object -Property srcStorageAccount -Unique

    # process each source storage account - creating new destination storage account from old account name
    foreach($srcStorageAccountObj in $srcStorageAccounts)
    {
        $srcStorageAccount = $srcStorageAccountObj.srcStorageAccount 
        if($isSameEnv)
        {
            # create unique storage account name from old account name and guid
            if($srcStorageAccount.Length -gt 16)
            {
                $first16 = $srcStorageAccount.Substring(0,16)
            }
            else
            {
                $first16 = $srcStorageAccount
            }

            [string] $guid = (New-Guid).Guid
            [string] $DeststorageAccountName = "$($first16.ToLower())"+($guid.Substring(0,8))
        }
        else
        {
            $DeststorageAccountName = $srcStorageAccount
        }

        # select sku and other attributes
        $skuName = ($sourceStorageObjects | Where-Object{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property srcSkuName -Unique).srcSkuName
        $Encryption = ($sourceStorageObjects | Where-Object{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageEncryption -Unique).SrcStorageEncryption
        $CustomDomain = ($sourceStorageObjects | Where-Object{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageCustomDomain -Unique).SrcStorageCustomDomain
        $kind = ($sourceStorageObjects | Where-Object{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageKind -Unique).SrcStorageKind
        $AccessTier = ($sourceStorageObjects | Where-Object{$_.srcStorageAccount -eq $srcStorageAccount} | Select-Object -Property SrcStorageAccessTier -Unique).SrcStorageAccessTier
        
        $storageParams = @{
        "ResourceGroupName" = $resourceGroupName 
        "Name" = $DeststorageAccountName 
        "location" = $location
        "SkuName" = $skuName
        }

        # add AccessTier if kind is BlobStorage.
        if($kind -ne 'Storage') 
        {
            $storageParams.Add("Kind", $kind)
            $storageParams.Add("AccessTier", $accessTier)
        }

        # add CustomDomainName if present.
        if($CustomDomain) 
        {
            $storageParams.Add("CustomDomainName", $CustomDomain)
        }

        # add CustomDomainName if present.
        if($Encryption) 
        {
            if($Encryption.Services.Blob){$encryptionBlob  = 'Blob'}
            if($Encryption.Services.File){$encryptionFile  = 'File'}
            if($encryptionBlob){$EncryptionType = $encryptionBlob}
            if($encryptionFile){$EncryptionType = $encryptionFile}
            if($encryptionBlob -and $encryptionFile){$EncryptionType = "$encryptionBlob,$encryptionFile"}
           # remarked for newer modules, prior to 6.7, this was required
           
           #  $storageParams.Add("EnableEncryptionService", $EncryptionType)
        }
        

        # Create new storage account
        do 
        {
            try
            {
                # create new storage account
                write-verbose "Creating storage account $DeststorageAccountName in resource group $resourceGroupName at location $location" -verbose
                $newStorageAccount = New-AzStorageAccount @storageParams -ea Stop -wa SilentlyContinue 
                write-output "The storage account $DeststorageAccountName was created"
            }
            catch
            {
                $_
                write-warning "Failed to create storage account. Storage account name $DeststorageAccountName may already exists."
                $DeststorageAccountName = read-host   'Enter a different Destination Storage Account Name'
            }
        }
        while(! $newStorageAccount)


        try 
        {
            # get key and storage context of newly created storage account
            $DestStorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $DestStorageAccountName -ea Stop).Value[0] 
            $DestStorageContext = New-AzStorageContext -StorageAccountName $DestStorageAccountName -StorageAccountKey $DestStorageAccountKey -ea Stop -wa SilentlyContinue
        }
        catch 
        {
            write-warning "Could not retrieve storage account key or storage context for $DestStorageAccountName . Exiting the script."
            break
        }



        # start blob copy for VHDs attached to VMs        
        foreach($obj in $sourceVHDstorageObjects | Where-Object{$_.srcStorageAccount -eq $srcStorageAccount})
        { 
            $srcURI = $obj.srcURI

            copy-AzBlob -srcUri $srcURI -srcContext $obj.SrcStorageContext -destContext $DestStorageContext
            #copy-AzBlob -srcUri $srcURI -srcContext $obj.SrcStorageContext -destContext $DestStorageContext -containerName 'vhd-backup'
            
            # add srcURI and destination storage account name to custom PSobject
            $PSobjVHDstorage = New-Object -TypeName PSObject
            $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name destStorageContext -Value $DestStorageContext  
            $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name srcURI -Value $srcURI 

            [array]$VHDstorageObjects += $PSobjVHDstorage
        }
    
        
        # start copy for remaining blobs           
        if($srcStorageAccountNames)
        {
            foreach($obj in $sourceStorageObjects | Where-Object{$_.srcStorageAccount -eq $srcStorageAccount})
            {
                copy-AzBlob -srcUri $obj.srcURI -srcContext $obj.SrcStorageContext -destContext $DestStorageContext 
            }
        }


    } # end of foreach srcStorageAccounts

    # create temporary blob storage account to stage managed disks that will be copied 
    if($resourceGroupManagedDisks)
    {
        $cleanResourceGroupName = $resourceGroupName -replace "[^a-z0-9]", ""

        if($resourceGroupName.Length -gt 16)
        {
            $first16 = $cleanResourceGroupName.Substring(0,16)
        }
        else
        {
            $first16 = $cleanResourceGroupName 
        }

           
        [string] $guid = (New-Guid).Guid
        [string] $tempStorageAccountName = "$($first16.ToLower())"+($guid.Substring(0,8))

        $storageParams = @{
        "ResourceGroupName" = $resourceGroupName 
        "Name" = $tempstorageAccountName 
        "location" = $location
        "SkuName" = 'Standard_LRS'
        }
            
        # Create new storage account
        do 
        {
            try
            {
                # create new storage account
                write-verbose "Creating temmporary storage account $tempstorageAccountName in resource group $resourceGroupName at location $location" -verbose
                $newStorageAccount = New-AzStorageAccount @storageParams -ea Stop -wa SilentlyContinue 
                write-output "The storage account $tempstorageAccountName was created"
            }
            catch
            {
                $_
                write-warning "Failed to create temporary storage account. Storage account name $DeststorageAccountName may already exists."
                $tempstorageAccountName = read-host   'Enter a different Temporary Storage Account Name. This is used to stage managed disks.'
            }
        }
        while(! $newStorageAccount)


        try 
        {
            # get key and storage context of newly created storage account
            $tempStorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $tempStorageAccountName -ea Stop).Value[0] 
            $tempStorageContext = New-AzStorageContext -StorageAccountName $tempStorageAccountName -StorageAccountKey $tempStorageAccountKey -ea Stop -wa SilentlyContinue
            $tempContainer = New-AzStorageContainer -Name 'vhdblobs' -Context $tempStorageContext -Permission Blob  -ea Stop -wa SilentlyContinue
        }
        catch 
        {
            write-warning "Could not retrieve storage account key or storage context for $tempStorageAccountName . Exiting the script."
            break
        }

    }

    # start copy of all Managed Disks       
    foreach($md in $sourceMDstorageObjects)
    { 
        $srcMDname = $md.Name
        $srcSkuName = $md.SkuName
        $AccessSAS = $md.AccessSAS
        # $srcMDid = $md.id
        # $srcOStype = $md.OsType

        $rtn = Start-AzStorageBlobCopy -AbsoluteUri $AccessSAS -DestBlob $srcMDname -DestContainer $tempContainer.Name -destContext $tempStorageContext
        $PSobjVHDstorage = New-Object -TypeName PSObject
        $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name srcName -Value $srcMDname 
        $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name destStorageContext -Value $tempStorageContext 
        $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name srcURI -Value $rtn.ICloudBlob.Uri.AbsoluteUri
        $PSobjVHDstorage | Add-Member -MemberType NoteProperty -Name srcSkuName -Value $srcSkuName

        [array]$VHDstorageObjects += $PSobjVHDstorage
    }
    
    <###############################

    Create new network resources.  
    Vnets, NICs, Loadbalancers, PIPs

    ################################>
        
    
    # create new Network Security Groups
    foreach($srcNSG in $resourceGroupNSGs)
    {
        $nsgName = $srcNSG.name
        [array]$nsgRules = @()
       
        foreach($nsgRule in $srcNSG.SecurityRules)
        {
           
            $nsgRuleParams = @{
                "Name" = $nsgRule.Name  
                "Access" = $nsgRule.Access
                "Protocol" = $nsgRule.Protocol 
                "Direction" = $nsgRule.Direction 
                "Priority" = $nsgRule.Priority 
                "SourceAddressPrefix" = $nsgRule.SourceAddressPrefix 
                "SourcePortRange" =  $nsgRule.SourcePortRange 
                "DestinationAddressPrefix" = $nsgRule.DestinationAddressPrefix 
                "DestinationPortRange" = $nsgRule.DestinationPortRange
            }

            if($nsgRule.Description)
            {
                $nsgRuleParams.Add("Description", $nsgRule.Description)
            }

           $nsgRules += New-AzNetworkSecurityRuleConfig @nsgRuleParams
        }
    

        try
        {
            write-verbose "Creating Network Security Group $nsgName in resource group $resourceGroupName at location $location" -verbose
           $NSG = New-AzNetworkSecurityGroup -Name $nsgName -SecurityRules $nsgRules  -ResourceGroupName $ResourceGroupName -Location $location  -ea Stop -wa SilentlyContinue
            Write-Output "Network Security Group $nsgName was created"
        }
        catch
        {
            $_
            write-warning "Failed to create Network Security Group $nsgName"
        }


    }

    # create new Virtual Network(s)
    foreach($srcNetwork in $resourceGroupVirtualNetworks)
    {
        $destVNname = $srcNetwork.Name
        $destAddressPrefix = $srcNetwork.AddressSpace.AddressPrefixes
        $destDNSserver = $srcNetwork.DhcpOptions.DnsServers
        $destSubnets = $srcNetwork.Subnets
        try
        {
            write-verbose "Creating virtual network $destVNname in resource group $resourceGroupName at location $location" -verbose
            $newVirtualNetwork = New-AzVirtualNetwork -Name $destVNname -ResourceGroupName $resourceGroupName -Location $location -AddressPrefix $destAddressPrefix -DnsServer $destDNSserver -Subnet $destSubnets -Force -ea Stop -wa SilentlyContinue
            Write-Output "Virtual Network $destVNname was created"
        }
        catch
        {
            $_
            write-warning "Failed to create virtual network $destVNname"
        }

                       
        foreach($destSub in $destSubnets) 
        {         
            if($destSub.Subnets.NetworkSecurityGroup)
            {   
                try
                {
                    $NSGsplit = $destSub.Subnets.NetworkSecurityGroup.id.split('/')
                    $srcNSGname = $NSGsplit[$NSGsplit.Length -1]
                    $NSG = Get-AzNetworkSecurityGroup -Name $srcNSGname -ResourceGroupName $ResourceGroupName -ea Stop
                    $subnet = $newVirtualNetwork | Get-AzVirtualNetworkSubnetConfig  -Name $destSub.Name -ea Stop -wa SilentlyContinue
                    Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $newVirtualNetwork -Name $destSub.Name -AddressPrefix $subnet.AddressPrefix -NetworkSecurityGroup $NSG | Set-AzVirtualNetwork -ea Stop | out-null
                }
                catch
                {
                    $_
                    write-warning "Failed to add Network Security Group $srcNSGname to $($destSub.Name)"
                }
            }
          
        }

    }

    
    # create new Availability sets
    foreach($srcAVset in $resourceGroupAvSets)
    {
        $AVname = $srcAVset.name
        
        $avParams = @{
            "Name" = $AVname 
            "ResourceGroupName" = $resourceGroupName  
            "Location" = $location
            "sku" = $srcAVset.Sku
            "PlatformFaultDomainCount" = $srcAVset.PlatformFaultDomainCount
            "PlatformUpdateDomainCount" = $srcAVset.PlatformUpdateDomainCount
            "ea" = 'Stop'
            "wa" = 'SilentlyContinue'
        }
        
 
        try
        {
            write-verbose "Creating availability set $AVname in resource group $resourceGroupName at location $location" -verbose
            $NewAvailabilitySet = New-AzAvailabilitySet @avParams 
            Write-Output "Availability Set $AVname was created"
        }
        catch
        {
            $_
            write-warning "Failed to create availability set $AVname"
        } 
    
    }


    # create new PIPs
    foreach($srcPIP in $resourceGroupPIPs)
    {
        $pipName = $srcPIP.name
        $pipDomainNameLabel = $srcPIP.dnssettings.domainNameLabel

        $pipParams = @{
                "Name" = $pipName 
                "ResourceGroupName" = $resourceGroupName  
                "Location" = $location
                "AllocationMethod" = $srcPIP.PublicIpAllocationMethod
                "ea" = 'Stop'
                "wa" = 'SilentlyContinue'
        }
                
        # append 'new' to name so it is unique from existing
        if($pipDomainNameLabel)
        {
          $NewPipDomainNameLabel = $pipDomainNameLabel + 'new'
          $pipParams.Add("DomainNameLabel", $NewPipDomainNameLabel)
        }
        

        try
        {
            write-verbose "Creating public IP $pipName in resource group $resourceGroupName at location $location" -verbose
            $PIP = New-AzPublicIpAddress @pipParams
            Write-Output "Public IP $pipName was created with DomainName Label $NewPipDomainNameLabel"
        }
        catch
        {
            $_
            write-warning "Failed to create Public IP $pipName"
        }
    }




    # create new Load Balancer
    foreach($srcLB in $resourceGroupLBs)
    {
        $LBName = $srcLB.name
        $LBFrontendIpConfigurations = $srcLB.FrontendIpConfigurations
        $LBInboundNatRules = $srcLB.InboundNatRules
        $LBBackendAddressPool = $srcLB.BackendAddressPools
        $LBProbe = $srcLB.Probes
        $LoadBalancingRule = $srcLB.LoadBalancingRules
        $LBInboundNatPool = $srcLB.InboundNatPools
        $subnet = $null
        $vnet = $null

        # add IP Configs
        [array]$newLBipConfigs = @()

        foreach($LBipConfig in $LBFrontendIpConfigurations) 
        {
            $newLBipConfig = $null
              
            $LBipConfigName =  $LBipConfig.name
            $lbConfigParams = @{"Name"= $LBipConfigName} 

            # get new vnet and subnet from old vnet and subnet names
            if($LBipConfig.Subnet) 
            {
                $subsplit = $LBipConfig.Subnet.id.split('/')
                $subnetName = $subsplit[$subsplit.Length -1]
                $vnetName = $subsplit[$subsplit.Length -3]
                $subnet = $null
                $vnet = $null
                try
                {
                  $vnet = Get-AzVirtualNetwork -name $vnetName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                  $subnet = $vnet | Get-AzVirtualNetworkSubnetConfig  -Name $subnetName -ea Stop -wa SilentlyContinue
                }
                catch{}

                $lbConfigParams.Add("SubnetId", $subnet.id)
            }

            # add PublicIpAddress if present.
            if($LBipConfig.PublicIpAddress) 
            {
                $lbPubIPSplit = $LBipConfig.PublicIpAddress.id.split('/')
                $lbPubIPName = $lbPubIPSplit[$lbPubIPSplit.Length -1]
            
                try
                {
                  $lbPubIP = Get-AzPublicIpAddress -Name $lbPubIPName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                }
                catch{}
                
                if($lbPubIP)
                {
                  $lbConfigParams.Add("PublicIpAddress", $lbPubIP) 
                }
            }
            
            if($LBipConfig.PrivateIpAddress) 
            {
              $lbConfigParams.Add("PrivateIpAddress", $LBipConfig.PrivateIpAddress)  
            }   


            #create  new FrontendIPConfig
            try
              {
                write-verbose "Adding IP config $LBipConfigName to load balancer $lbName" -verbose
                $newLBipConfig = New-AzLoadBalancerFrontendIpConfig @lbConfigParams -ea Stop -wa SilentlyContinue 
                Write-Output "IP config $LBipConfigName for $lbName was added"
              }
              catch
              {
                $_
                write-warning "Failed to add IP config $LBipConfigName to load balancer $lbName"
              } 
                    
             # add other attributes
            if($LBipConfig.PrivateIpAllocationMethod) 
            {
              $newLBipConfig.PrivateIpAllocationMethod = $LBipConfig.PrivateIpAllocationMethod 
            }

             # add InboundNATruleConfigs
            if($newLBipConfig -and $LBipConfig.InboundNatRules)
            {
                foreach($InboundNatRuleID in $LBipConfig.InboundNatRules.ID) 
                {
                    $newNatRuleConfig = $null
                    $InboundNatRule = $LBInboundNatRules | Where-Object{$_.ID -eq $InboundNatRuleID}
                    
                    $inboundNatRuleParams = @{
                        "Name" = $InboundNatRule.name
                        "FrontendIpConfiguration" = $newLBipConfig
                        "Protocol" = $InboundNatRule.Protocol
                        "FrontendPort" = $InboundNatRule.FrontEndPort
                        "BackendPort" = $InboundNatRule.BackendPort
                    }

                    if($InboundNatRule.EnableFloatingIP)
                    {
                        $inboundNatRuleParams.Add("EnableFloatingIP", $null)
                    }
                    
                    $newNatRuleConfig = New-AzLoadBalancerInboundNatRuleConfig @inboundNatRuleParams  
                        
                    if($newNatRuleConfig)
                    {
                    [array]$newNatRuleConfigs +=  $newNatRuleConfig
                    }
               }
            }

            if($newLBipConfig)
            {
     
              [array]$newLBipConfigs +=  $newLBipConfig 
            }


        }

        $LBparams = @{
        "Name" = $LBName 
        "ResourceGroupName" = $resourceGroupName
        "Location" = $location 
        }

        if($newLBipConfigs)
        {
         $LBparams.Add("FrontendIpConfiguration", $newLBipConfigs)
        }

        if($newNatRuleConfigs)
        {
         $LBparams.Add("InboundNatRule", $newNatRuleConfigs)
        }
         
        try
        {
            write-verbose "Creating load balancer $LBName in resource group $resourceGroupName at location $location" -verbose
            $NewLB = New-AzLoadBalancer @LBparams -ea Stop -wa SilentlyContinue
            Write-Output "Load balancer $LBName was created"
        }
        catch
        {
            $_
            write-warning "Failed to create load balancer $LBName"
        } 

               
            
        if($LBBackendAddressPool -and $NewLB) 
        {
            $NewLB | Add-AzLoadBalancerBackendAddressPoolConfig -Name $LBBackendAddressPool.Name -ea Stop -wa SilentlyContinue | out-null
        }
        
        if($LBProbe -and $NewLB) 
        {
            # TODO:        
            #   $NewLB | Add-AzLoadBalancerProbeConfig -Name $LBProbe.Name  -RequestPath -Protocol -Port -IntervalInSeconds -ProbeCount | out-null
        }
        
            
        if($LoadBalancingRule -and $NewLB) 
        {
            # TODO:
            #$NewLB | Add-AzLoadBalancerRuleConfig -Name $LoadBalancingRule.Name -ea Stop -wa SilentlyContinue | out-null
        }

        if($LBInboundNatPool -and $NewLB) 
        {
            # TODO:
            # $NewLB |Add-AzLoadBalancerInboundNatPoolConfig -Name $LBInboundNatPool.Name  -ea Stop -wa SilentlyContinue | out-null
        }  
            
        if($NewLB) 
        {    
            try
            {
                $NewLB | Set-AzLoadBalancer -ea Stop -wa SilentlyContinue | out-null
            }
            catch
            {
                $_
                write-warning "Failed to update load balancer $LBName"
                $NewLB
            }
        }
        
    } # end of foreach loadbalancer



    # create new NICs
    foreach($srcNIC in $resourceGroupNICs)
    {
        $NicName = $srcNIC.name
        $oldIPconfigs = $srcNIC.IpConfigurations
        $NicDNS = $srcNIC.DnsSettings.AppliedDnsServers

        # add IP Configs
        [array]$NewIpConfigs = @()

        foreach($ipConfig in $oldIPconfigs) 
        {

            $ipConfigName =  $ipConfig.name

            # get new vnet and subnet from old vnet and subnet names
            if($ipconfig.Subnet)
            {
                $subsplit = $ipconfig.Subnet.id.split('/')
                $subnetName = $subsplit[$subsplit.Length -1]
                $vnetName = $subsplit[$subsplit.Length -3]
                $subnet = $null
                $vnet = $null
                try
                {
                    $vnet = Get-AzVirtualNetwork -name $vnetName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                    $subnet = $vnet | Get-AzVirtualNetworkSubnetConfig  -Name $subnetName -ea Stop -wa SilentlyContinue
               
                }
                catch{}
            }

            $ipConfigParams = @{
            "Name" = $ipConfigName
            "PrivateIpAddressVersion" = $ipConfig.PrivateIpAddressVersion
            "PrivateIpAddress" = $ipConfig.PrivateIpAddress
            }

            # add subnet if present.
            if($subnet) 
            {
                $ipConfigParams.Add( "Subnet", $subnet)
            }
            
            # add public IP if present.
            if($ipConfig.PublicIpAddress) 
            {
                $ipipsplit = $ipConfig.PublicIpAddress.id.split('/')
                $ipipName = $ipipsplit[$ipipsplit.Length -1]
                $PublicIP = Get-AzPublicIpAddress -Name $ipipName -ResourceGroupName $ResourceGroupName
                $ipConfigParams.Add("PublicIpAddress", $PublicIP)
            }

            # add LoadBalancerBackendAddressPools if present.
            if($ipConfig.LoadBalancerBackendAddressPools) 
            {
                $lbbesplit = $ipconfig.LoadBalancerBackendAddressPools.id.split('/')
                $lbbeName = $lbbesplit[$lbbesplit.Length -1]
                $lbName = $lbbesplit[$lbbesplit.Length -3]
                try
                {
                $lb = Get-AzLoadBalancer -name $lbName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                    $lbbe = $lb | Get-AzLoadBalancerBackendAddressPoolConfig -Name $lbbeName -ea Stop -wa SilentlyContinue
                }
                catch{}
                
                if($lbbe){ $ipConfigParams.Add("LoadBalancerBackendAddressPool", $lbbe) }
            }
            
            # add LoadBalancerInboundNatRules if present.
            if($ipConfig.LoadBalancerInboundNatRules) 
            {
                $lbINRsplit = $ipconfig.LoadBalancerInboundNatRules.id.split('/')
                $lbINRName = $lbINRsplit[$lbINRsplit.Length -1]
                $lbName = $lbINRsplit[$lbINRsplit.Length -3]
                try
                {
                    $lb = Get-AzLoadBalancer -name $lbName -ResourceGroupName $resourceGroupName -ea Stop -wa SilentlyContinue
                    $lbINR = $lb | Get-AzLoadBalancerInboundNatRuleConfig -Name $lbINRName -ea Stop -wa SilentlyContinue
                }
                catch{}
            
                if($lbINR){$ipConfigParams.Add("LoadBalancerInboundNatRule", $lbINR)}
            }
            
            # add ApplicationGatewayBackendAddressPools if present.
            # TODO:  need to very this can be added as is
            if($ipConfig.ApplicationGatewayBackendAddressPools) 
            {
                $ipConfigParams.Add("ApplicationGatewayBackendAddressPool", $ipConfig.ApplicationGatewayBackendAddressPools)
            }



            try
            {
                write-verbose "Adding IP config $ipConfigName to network interface $NicName" -verbose
                $NewIpConfig = New-AzNetworkInterfaceIpConfig @ipConfigParams -ea Stop -wa SilentlyContinue 
                [array]$NewIpConfigs +=  $NewIpConfig                
                Write-Output "IP config $ipConfigName for $NicName was added"
            }
            catch
            {
                $_
                write-warning "Failed to add IP config $ipConfigName to network interface $NicName"
            } 

        }

        if(! $NewIpConfigs)
        {
            $NewIpConfigs = New-AzNetworkInterfaceIpConfig -Name 'empty'
        }
        
        $NICparams = @{
        "Name" = $NicName
        "ResourceGroupName" = $resourceGroupName
        "Location" = $location
        "IpConfiguration" = $NewIpConfigs
        }
        
        # add DNS if present.
        if($NicDNS) 
        {
            $NICparams.Add("DnsServer", $NicDNS)
        }


        # add NetworkSecurityGroup if present.
        if($srcNIC.NetworkSecurityGroup) 
        {
            $NSGsplit = $srcNIC.NetworkSecurityGroup.id.split('/')
            $srcNSGname = $NSGsplit[$NSGsplit.Length -1]
            
            try
            { 
                $newNSG = Get-AzNetworkSecurityGroup -Name $srcNSGname -ResourceGroupName $ResourceGroupName
                $NICparams.Add("NetworkSecurityGroup", $newNSG)
            }
            catch
            {
                write-warning "Failed to add Network Security Group $srcNSGname to network interface $NicName"
            }
        }

        # add EnableIPForwarding if present.
        # TODO:  need to verify this switch can be splatted with explicit value of $true
        if($srcNIC.EnableIPForwarding) 
        {
            $NICparams.Add("EnableIPForwarding", $true)
        }

        
        try
        {
            write-verbose "Creating network interface $NicName in resource group $resourceGroupName at location $location" -verbose
            $NewNIC = New-AzNetworkInterface @NICparams -ea Stop -wa SilentlyContinue
            Write-Output "Network interface $NicName was created"
        }
        catch
        {
            $_
            write-warning "Failed to create network interface $NicName"
        } 

    } # end of foreach nic


    # for some reason vmSizes do not convert to json with the rest of the vm data so this step is required
    [array]$sourceVmSizeObjects = $()

    foreach($vm in $resourceGroupVMs)
    { 

        $PSobjVmSize = New-Object -TypeName PSObject
        $PSobjVmSize | Add-Member -MemberType NoteProperty -Name VmName -Value $vm.Name
        $PSobjVmSize  | Add-Member -MemberType NoteProperty -Name VmSize -Value $vm.HardwareProfile.VmSize.ToString()

        [array]$sourceVMSizeObjects += $PSobjVmSize
    }

    $sourceVMSizeObjects | ConvertTo-Json -depth 10 | Out-File $resourceGroupVMSizeresumePath
    $resourceGroupVMs | ConvertTo-Json -depth 10 | Out-File $resourceGroupVMresumePath
    $VHDstorageObjects | ConvertTo-Json | Out-File $VHDstorageObjectsResumePath

    # monitor file copy - do not proceed with VM creation until it is complete.  Allows for user to break out and use -resume switch 
    # only applies when VHD blobs are present
    if($VHDstorageObjects)
    {
        $VHDstorageObjects | ConvertTo-Json | Out-File $VHDstorageObjectsResumePath

        $VHDstorageObjects | Select-Object -Property destStorageContext -Unique | %{
    
            $containers = Get-AzStorageContainer -Context $_.destStorageContext 
            
            foreach($container in $containers)
            {
                # monitor disk copy
                Get-BlobCopyStatus -Context $_.destStorageContext -containerName $container.name
            }
        }

    }
} 
else # if not resume
{

    # check for valid source resource group
    if(-not ($targetResourceGroup = Get-AzResourceGroup  -ResourceGroupName $resourceGroupName)) 
    {
       write-warning "The provided resource group $resourceGroupName could not be found. Exiting the script."
       break
    }
    
    [string] $location = $targetResourceGroup.location

    
    try
    {
        $resourceGroupVMs = (get-content $resourceGroupVMresumePath -ea Stop) -Join "`n"| ConvertFrom-Json 
        $resourceGroupVMSizes = (get-content $resourceGroupVMSizeresumePath -ea Stop) -Join "`n"| ConvertFrom-Json 
    } 
    catch
    {
        $_
        write-warning "Failed to load resume file $resourceGroupVMresumePath  Cannot resume. Exiting script."
    }

    try 
    {
        $VHDstorageObjects = (get-content $VHDstorageObjectsResumePath -ea Stop) -Join "`n"| ConvertFrom-Json 
    }
    catch
    {
        $_
        write-warning "Failed to load resume file $VHDstorageObjectsResumePath  Cannot resume. Exiting script."
    }
}

#create managed disk from temp blob copy location after blob copy has been confirmed
if($resourceGroupVMs.storageprofile.osdisk.manageddisk -and $location -ne $srcLocation)
{
 
    foreach($mdObj in $VHDstorageObjects|Where-Object{$_.srcSkuName -ne 'NULL'})
    {
        # refresh the storage context object if -resume
        if($resume)
        {
            $tempStorageContext =  $mdObj.destStorageContext 
            $tempStorageAccountName = $tempStorageContext.StorageAccountName
            $StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $tempStorageAccountName).Value[0]
            $tempStorageContext = New-AzStorageContext -StorageAccountName $tempStorageAccountName -StorageAccountKey $StorageAccountKey
        }
        
        $mdTempContainerName = (Get-AzStorageContainer -Context $tempStorageContext).Name
        $srcMDuri = $mdObj.srcURI
        $srcMDname = $mdObj.srcName
        $srcSkuName = $mdObj.srcSkuName

        Get-BlobCopyStatus -Context $tempStorageContext -containerName $mdTempContainerName -BlobName $srcMDname
        
        write-verbose "Creating new managed disk $srcMDname in $location" -Verbose
        try
        {
            $mdiskconfig = New-AzDiskConfig -SkuName $srcSkuName -Location $location  -CreateOption Import -SourceUri $srcMDuri 
            $newMDdisk = New-AzDisk -ResourceGroupName $resourceGroupName -Disk $mdiskconfig -DiskName $srcMDname 
            write-output "The managed disk $srcMDname was created."
        }
        catch
        {
            $_
            write-warning "Failed to create new managed disk $srcMDname"
        }
        
    }

    #cleanup
    write-verbose "All managed disks have been created. Removing temporary storage account $tempStorageAccountName" -Verbose
    Remove-AzStorageAccount -ResourceGroupName $ResourceGroupName -Name $tempStorageAccountName -Force | out-null
    Write-output "The storage account $tempStorageAccountName was removed" 
  
}

<###############################

 Create new Virtual Machines.  

################################>


# create new Virtual Machine(s)
foreach($srcVM in $resourceGroupVMs)
{
    # get source VM attributes
    $VMName = $srcVM.Name
    $OSDiskName = $srcVM.StorageProfile.OsDisk.Name
    $OSType = $srcVM.storageprofile.osdisk.OsType
    $OSDiskCaching = $srcVM.StorageProfile.OsDisk.Caching
    $CreateOption = "Attach"
    if($resume)
    {  
        $VMSize = ($resourceGroupVMSizes | Where-Object {$_.VMname -eq $VMName}).VmSize
    }
    else 
    {
        $VMSize = $srcVM.HardwareProfile.VMSize
    }

    if($srcVM.AvailabilitySetReference)
    {
        $avSetRef = ($srcVM.AvailabilitySetReference.id).Split('/')
        $avSetName = $avSetRef[($avSetRef.count -1)]
        $AvailabilitySet = Get-AzAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $avSetName
    }

    Write-Output "Verifying specified VM Size of $vmSize for location $location ..."
    # Prompt for to select new if doesn't exist in current environment.
    $savedVMSize = $vmSize 
    if($vmSize  -and (Get-AzVMSize -Location $Location).name -notcontains $vmSize) 
    {
      write-warning "$savedVMSize is an invalid Az Virtual Machine Size for this location in this environment.  Please select a valid VM Size and click OK"
      $vmSize = (Get-AzVMSize -Location $Location | Select-Object Name, NumberOfCores, MemoryInMB, MaxDataDiskCount | Out-GridView -Title "Select Az VM Size" -OutputMode Single).Name
    }
   
   
    # get blob and container names from source URI for blobs
    if($srcVM.storageprofile.osdisk.vhd)
    {
        # get blob and container names from source URI
        $OSsrcURI = $srcVM.storageprofile.osdisk.vhd.uri
        $OSsplit = $OSsrcURI.Split('/')
        # TODO: assumes one level of container.  need to adjust to allow for something like container/myfolder/vhdfolder
        $OSblobName = $OSsplit[($OSsplit.count -1)]
        $OScontainerName = $OSsplit[3]
        # get the new destination storage account name from our custom object array
        $OSstorageContext = ($VHDstorageObjects| Where-Object{$_.srcURI -eq $OSsrcURI} | Select-Object -Property destStorageContext -Unique).destStorageContext
        # refresh the storage context object if -resume
        if($resume)
        {
        $osStorageAccountName = $OSstorageContext.StorageAccountName
        $StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $osStorageAccountName).Value[0]
        $OSstorageContext = New-AzStorageContext -StorageAccountName $osStorageAccountName -StorageAccountKey $StorageAccountKey
        }
        
        # set the OSdisk URI
        $OSDiskUri = "$($OSstorageContext.BlobEndPoint)$OScontainerName/$OSblobName"
    
        # verify disk copy
        Get-BlobCopyStatus -Context $OsStorageContext -containerName $OScontainerName -BlobName $OsBlobName 
    }

    # get the Network Interface Card we created previously based on the original source name
    $newNICs = @()
    foreach($nicID in $srcVM.NetworkProfile.NetworkInterfaces.id)
    {
        $NICRef = $nicID.Split('/')
        $NICName = $NICRef[($NICRef.count -1)]
        $newNICs += Get-AzNetworkInterface -Name $NICName -ResourceGroupName $ResourceGroupName 
    }
    
    
    # create VM Config
    if($AvailabilitySet)
    {
        $VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $VMSize  -AvailabilitySetID $AvailabilitySet.Id  -wa SilentlyContinue
    }
    else
    {
        $VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $VMSize -wa SilentlyContinue 
    }
    
    if($srcVM.storageprofile.osdisk.vhd)
    {
       # Set OS Disk based on OS type
        if($OStype -eq 'Windows' -or $OStype -eq '0')
        {
            $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -Name $OSDiskName -VhdUri $OSDiskUri -Caching $OSDiskCaching -CreateOption $createOption -Windows
        }
        else
        {
            $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -Name $OSDiskName -VhdUri $OSDiskUri -Caching $OSDiskCaching -CreateOption $createOption -Linux
        }
    }
    elseif($srcVM.storageprofile.osdisk.manageddisk)
    {
        $osMDisk = Get-AzDisk -DiskName $OSDiskName -ResourceGroupName $resourceGroupName
        $osDiskId = $osMDisk.id
        $osDiskSkuName= $osMDisk.Sku.Name

        if($OStype -eq 'Windows' -or $OStype -eq '0')
        {
            $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -Name $OSDiskName -ManagedDiskId $osDiskId -StorageAccountType $osDiskSkuName -Caching $OSDiskCaching -CreateOption $createOption -Windows
        }
        else
        {
            $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -Name $OSDiskName -ManagedDiskId $osDiskId -StorageAccountType $osDiskSkuName -Caching $OSDiskCaching -CreateOption $createOption -Linux
        }
    }

      # add NICs
    foreach($NIC in $newNICs)
    {
        $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $NIC.Id
    }


    # add data disk if they were present
    if($srcVM.storageProfile.datadisks)
    {
        foreach($disk in $srcVM.storageProfile.DataDisks) 
        {
            $dataDiskName = $null
            $srcURI = $null
            $blobName = $null
            $dataDiskName = $disk.Name
            $dataDiskLUN = $disk.Lun
            $diskCaching = $disk.Caching
            $DiskSizeGB = $disk.DiskSizeGB
            
            if($disk.vhd)
            { 
                $srcDiskURI = $disk.vhd.uri
                $split = $srcDiskURI.Split('/')
                # TODO: assumes one level of container.  need to adjust to allow for something like container/myfolder/vhdfolder
                $diskBlobName = $split[($split.count -1)]
                $diskContainerName = $split[3]
                # get the new destination storage account name from our custom object array
                $diskStorageContext = ($VHDstorageObjects| Where-Object{$_.srcURI -eq $srcDiskURI} | Select-Object -Property destStorageContext -Unique).destStorageContext
                # refresh the storage context object if -resume
                if($resume)
                {
                    $diskStorageAccountName = $diskStorageContext.StorageAccountName
                    $StorageAccountKey = (Get-AzStorageAccountKey -ResourceGroupName $resourceGroupName -Name $diskStorageAccountName).Value[0]
                    $diskStorageContext = New-AzStorageContext -StorageAccountName $diskStorageAccountName -StorageAccountKey $StorageAccountKey
                }

                $dataDiskUri = "$($diskStorageContext.BlobEndPoint)$diskContainerName/$diskBlobName"
            
                # Verify copy status
                Get-BlobCopyStatus -Context $diskStorageContext -containerName $diskContainerName -BlobName $diskBlobName
             
            }
                
            # determine if managed disk are used and use apppropiate attach method 
	        if($disk.vhd)
            {
                Add-AzVMDataDisk -VM $VirtualMachine -Name $dataDiskName -DiskSizeInGB $DiskSizeGB -Lun $dataDiskLUN -VhdUri $dataDiskUri -Caching $diskCaching -CreateOption $CreateOption | out-null
            }
            elseif($disk.manageddisk)
            {
                $mdDataDisk = Get-AzDisk -ResourceGroupName $resourceGroupName -DiskName $dataDiskName
                 # Write-Host ('Disk Provisioning State -> [ ' + ($mdDataDisk.ProvisioningState) + ' ]')
                 $dataDiskId = $mdDataDisk.id
                 $dataDiskSku = $mdDataDisk.sku.Name

                Add-AzVMDataDisk -VM $VirtualMachine -Name $dataDiskName -Lun $dataDiskLUN -ManagedDiskId $dataDiskId -StorageAccountType $dataDiskSku -Caching $diskCaching -CreateOption $CreateOption | out-null
            }        
        }
    }
     
    # create the VM from the config
    try
    {
        
        write-verbose "Creating Virtual Machine $VMName in resource group $resourceGroupName at location $location" -verbose
       # $VirtualMachine
        New-AzVM -ResourceGroupName $ResourceGroupName -Location $location -VM $VirtualMachine -ea Stop -wa SilentlyContinue | out-null
        write-output "Successfully created Virtual Machine $VMName"
    }
    catch
    {
         $_
         write-warning "Failed to create Virtual Machine $VMName"
    }
}


