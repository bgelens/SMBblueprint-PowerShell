function Get-O365License {
	[cmdletbinding()]
	[OutputType([HashTable])]
	param(
	[Parameter(Mandatory=$true)]
	[ValidateNotNullOrEmpty()]
	[string]$TenantId
	)
	$Licenses = @{};
	$Users = (Get-AzureADUser -All $true)
    if ($null -ne $Users) {
        if ($Users | Get-Member -MemberType Property -Name AssignedLicenses) {
            $Usage = $Users.AssignedLicenses|group -Property SkuId
        }
        else {
            $Usage = $null
        }
    }
    
	(Get-AzureADSubscribedSku).foreach{
		$License = New-Object License
		$License.Id = $_.SkuId
		$License.Name = $_.SkuPartNumber
		$License.Available = ($_.PrePaidUnits.enabled - $($Usage.where{$_.Name -eq $License.Id}).Count)
		$Licenses.Add($License.Name,$License)
	}
	$Licenses
}