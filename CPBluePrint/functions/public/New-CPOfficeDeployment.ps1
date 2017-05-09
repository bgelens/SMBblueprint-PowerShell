function New-CPOfficeDeployment {

	[cmdletbinding(DefaultParameterSetName="TenantId")]
	[OutputType([psobject])]
	param(
	[parameter(Mandatory=$true)]
	[ValidateNotNullOrEmpty()]
	# The location of the input CSV file.
	[String] $CSV,
	[parameter(ParameterSetName="TenantId",Mandatory=$true)]
	[ValidateNotNullOrEmpty()]
	[string] $TenantId,
	[parameter(ParameterSetName="TenantDomain",Mandatory=$true)]
	#[ValidateNotNullOrEmpty()]
	[string] $TenantDomain,
	[parameter()]
	[string] $MailDomain,
	#[ValidateNotNullOrEmpty()]
	[parameter()]
	[ValidateNotNullOrEmpty()]
	[string] $DefaultPassword = $(New-SWRandomPassword),
	[parameter(Mandatory=$true)]
	[ValidateNotNullOrEmpty()]
	[pscredential] $Credential = (Get-Credential -Message "Please provide your Partner Credentials"),
	[Parameter(DontShow)]
	[ValidateNotNullOrEmpty()]
	[object] $SyncHash = $null,
	[Parameter()]
	[switch] $NoUpdateCheck,
	[Parameter(DontShow=$true)]
	[string] $Log,
    [switch] $DisableAnonymousTelemetry
	)
	
	begin{
		$ATPLicenseName = "ADALLOM_O365"
		$Continue = $true
		if([string]::IsNullOrEmpty($Log) -eq $false){
			if(test-path $Log){} else {
				$Log = Start-Log
			}
		} else {
			$Log = Start-Log
		}
		$PSDefaultParameterValues = @{"Write-Log:Log"="$Log"}
		#if(!$PSBoundParameters.ContainsKey('NoUpdateCheck')){
		#Test-ModuleVersion -ModuleName SMBBluePrint
	#}

        $arch = ""
        if ($env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
            $arch = 64
        } else {
            $arch = 32
        }
        $null = Add-Type -Path "$global:root\assemblies\$arch\Microsoft.ApplicationInsights.dll"
        $TelClient = New-Object "Microsoft.ApplicationInsights.TelemetryClient"
        $TelClient.InstrumentationKey = $global:TelemetryId
        if ($null -ne $SyncHash) {
            $TelClient.Context.Session.Id = $SyncHash.InstanceId
        } else {
            $TelClient.Context.Session.Id = [system.guid]::NewGuid().guid
        }
        $TelClient.TrackEvent("New-CPOfficeDeployment started")
        $TelClient.Flush()

        if ($DisableAnonymousTelemetry) {
            $TelClient.TrackEvent("Telemetry opt-out")
        } else {
            $TelClient.TrackEvent("Telemetry opt-in")
            $TelClient.TrackEvent("O365 Deployment Started")
        }
        $TelClient.Flush()


		try{
			if((Test-AADPasswordComplexity -MinimumLength 8 -Password $DefaultPassword) -eq $false){
					write-log -type error -message "Password does not meet complexity requirements"
					return
			}
			$DeploymentJob = new-object psobject -Property @{
				Type="Office"
				Duration = "00:00:00"
				Completed = $false
				Status = @{
					ProvisionedUsers = @()
					ProvisionedGroups = @()
				}
				Error=$null
				Log = $Log
			}
			if($SyncHash){
				$SyncHash.DeploymentJob = ([ref]$DeploymentJob).value
			}
			$DeploymentStart = get-date
			$null = Connect-Cloud -Credential $Credential
			# Hash both internal and external tenant information
		<#	$TenantDomainHash = @{}
			foreach($Item in (get-msolpartnercontract -all)){
				$TenantHash.Add($Item.TenantId,$Item.DefaultDomainName)
			}
			$CompanyInfo = Get-MsolCompanyInformation
			$TenantHash.Add($CompanyInfo.ObjectId,$CompanyInfo.InitialDomain)
			#>
			$Tenant = Get-Tenant -TenantId $TenantId -TenantDomain $TenantDomain
			$TenantId = $Tenant.Id
			$null = Connect-Cloud -Credential $Credential -TenantId $TenantId
			#$PSDefaultParameterValues.Add('*-MSOL*:TenantId',$TenantId)
			$DefaultDomain = $(
				$VerifiedDomains = Get-AzureADDomain
				if($MailDomain){
					if($VerifiedDomains.Name -contains $MailDomain){
						$MailDomain
						write-log "Using the specified domain '$MailDomain' as mail domain"
					} else {
						throw "Mail Domain not present or verified in the tenant"
					}
				} else {
					$MailDomain = ($VerifiedDomains.where{$_.IsDefault -eq $true}).Name
					$MailDomain
					write-log "Using the default domain ($MailDomain) as mail domain"
					
				}
		
			)
				
			#write-log "Using default domain '$DefaultDomain' as mail suffix"
			
			write-log "Getting available licenses from O365"
			$Licenses = Get-O365License -TenantId $TenantId
			write-log "Generating O365 Deployment Inventory"
			$Inventory = ConvertTo-O365 -Path $CSV -Licenses $Licenses -Separator ','
			write-log "Creating CSP admin account"
			$CSPAdminCredential = new-cspadmin -DomainName $MailDomain

			
			
		} catch {
            if (!$DisableAnonymousTelemetry) {
                $TelClient.TrackEvent("O365 Deployment failed")
                $TelException = New-Object "Microsoft.ApplicationInsights.DataContracts.ExceptionTelemetry"
                $TelException.Exception = $_.Exception
                $TelClient.TrackException($TelException)
                $TelClient.Flush()
            }
			Write-Log -Type Error -Message "Error during Office 365 Connection: $_"
			$Continue = $false
			
		}
	}
	
	
	
	process{
		if($Continue -eq $false){
			return
		}
		try {
			
			##### Exchange Connection
			write-log "Opening remote session to Exchange online"
			$Connect = $false
			while($Connect -eq $false){
				try{
					$Session = Connect-O365 -Credential $CSPAdminCredential
					$Connect = $true
				} catch {
					if($_.Exception.Message -like "*403*"){
						write-log "CSP Admin Account not ready yet. Retrying Connection in 60 seconds"
						start-sleep -Seconds 60
					} else {throw $_}
				}
			}
			write-log -type verbose -message "Connection succeeded. Importing Exchange Online PS Session."
			#####
			
			write-log -type information -message "Provisioning Users"
			$OneDriveUsers = @()
			$EnableATP = $false
			$i = 0
			foreach($User in $Inventory.Users){
				$i++
				Write-Progress -Id 1 -Activity "Deploying O365 Solution"`
				-Status "Provisioning Users "`
				-CurrentOperation "$i/$($Inventory.Users.Count)"`
				-PercentComplete (($i/$($Inventory.Users.Count))*100)
				$UserParameters = @{
					Username=[Regex]::Replace("$($User.First).$($User.Last)@$($DefaultDomain)",'[^a-zA-Z0-9\@\.\-]', '')
					FirstName=$User.First
					LastName=$User.Last
					Title=$User.Title
					Password=$DefaultPassword
					License=$($User.Licenses.Id)
					MobilePhone=$User.Mobile
					Country=$User.Country
				}
				$ReturnUser = New-O365User @UserParameters
				$User.Login = $ReturnUser.UserPrincipalName
				$User.Password = $DefaultPassword
				$Inventory.Groups|where{$_.Owner -eq $User}|foreach{$_.Owner = $User}
				
				$DeploymentJob.Status.ProvisionedUsers += $User
				$OneDriveUsers += $ReturnUser.UserPrincipalName
				if(($EnableATP -eq $false) -and ($User.Licenses|where{$_.Name -in $global:ATPLicenseName})){
					$EnableATP = $true
				}
				
			}
			Write-Progress -Id 1 -Completed -Activity "Deploying 0365 Solution"
			#write-log "Waiting some time to allow the user mailboxes to provision"
			#Start-Sleep -Seconds 30
			if($EnableATP){
	
				write-log "At least one O365 ATP License is assigned, setting up ATP policies and rules"
				Write-Progress -Id 1 -Activity "Deploying O365 Solution"`
				-Status "Provisioning ATP "
				try {
					Enable-O365ATP -MailDomain $DefaultDomain
				} catch {
					write-log -type warning -message $_
				}
				Write-Progress -Id 1 -Completed -Activity "Deploying 0365 Solution"
			}

			write-log -type information -message "Provisioning Groups"
			$i = 1
			if($Inventory.Groups.Count -gt 0){
				foreach($Group in $Inventory.Groups){
					Write-Progress -Id 1 -Activity "Deploying O365 Solution"`
					-Status "Provisioning Groups"`
					-CurrentOperation "$i/$($Inventory.Groups.Count)"`
					-PercentComplete (($i/$($Inventory.Groups.Count))*100)
					$null = New-O365Group -GroupName $Group.Name -Type office -owner ($Group.Owner.Login)
					$DeploymentJob.Status.ProvisionedGroups += $Group
					$i++
				}
				Write-Progress -Id 1 -Completed -Activity "Deploying 0365 Solution"
				write-log "Populating Group Memberships"
				$i = 1
				foreach($User in $Inventory.Users){
					Write-Progress -Id 1 -Activity "Deploying O365 Solution"`
					-Status "Provisioning Group Memberships"`
					-CurrentOperation "$i/$($Inventory.Users.Count)"`
					-PercentComplete (($i/$($Inventory.Users.Count))*100)
					foreach($Group in $User.Groups){
						if(($Group.Owner).Login -ne $User.Login){
							$null = Add-O365UserToGroup -UserName $User.Login -GroupName $Group.Name -Type Office
						} else {
							write-log -type information -message "$User is owner of the group $Group, membership creation skipped"
						}
					}
					$i++
				}
				Write-Progress -Id 1 -Completed -Activity "Deploying 0365 Solution"
			}

			write-log -type information -message "Provisioning Onedrives"
			Write-Progress -Id 1 -Activity "Deploying O365 Solution"`
				-Status "Provisioning Onedrives"`
				-PercentComplete -1
			$OnMicrosoftDomain = ((Get-AzureADDomain).where{$_.Name -like "*onmicrosoft.com"}).Name
			$TenantName = $OnMicrosoftDomain.split(".")[0]
			$TenantSPAdminUrl = "https://$($TenantName)-admin.sharepoint.com"
			write-log -message "Using $TenantSPAdminUrl as admin url for SP online" -type verbose
			$null = Initialize-O365OneDrive -Users $OneDriveUsers -Credential $CSPAdminCredential -SPOAdminUrl $TenantSPAdminUrl
			Write-Progress -Id 1 -Completed -Activity "Deploying 0365 Solution"
			
			
			
			

		} catch {
            if (!$DisableAnonymousTelemetry) {
                $TelClient.TrackEvent("O365 Deployment failed")
                $TelException = New-Object "Microsoft.ApplicationInsights.DataContracts.ExceptionTelemetry"
                $TelException.Exception = $_.Exception
                $TelClient.TrackException($TelException)
                $TelClient.Flush()
            }
            $DeploymentJob.Error = $_
			write-log -type error -message "$_ @ $($_.InvocationInfo.ScriptLineNumber) - $($_.InvocationInfo.Line))"  
		}
		finally{
			get-pssession|Remove-PSSession
			$DeploymentEnd = get-date
			$DeploymentDuration = New-TimeSpan -Start $DeploymentStart -End $DeploymentEnd
			$DeploymentJob.Duration = $("{0:HH:mm:ss}" -f ([datetime]$DeploymentDuration.Ticks))
			$DeploymentJob.Completed = $true
			([ref]$DeploymentJob).Value
            if (!$DisableAnonymousTelemetry) {
                $TelClient.TrackEvent("O365 Deployment finished")
                $TelClient.Flush()
            }
		}
		
	}
	end{
		write-log -message "Deployment Complete"
	}
}