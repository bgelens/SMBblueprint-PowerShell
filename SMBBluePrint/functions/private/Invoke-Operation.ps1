function Invoke-Operation {
    [cmdletbinding()]
    param(
        [switch] $Wait,
        [scriptblock] $Code ={},
        [hashtable] $Parameters,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [hashtable] $SyncHash,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Root,
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string] $Log,
        [bool] $DisableAnonymousTelemetry
    )
    try {
        if(!$Root){
            if($SyncHash.Root){
                $Root = $SyncHash.Root
            } else {
                throw "Invalid Root"
            }
        }
        if(!$Log){
            if($SyncHash.Log){
                $Log = $SyncHash.Log
            } else {
                throw "Invalid Log"
            }
        }
        $Runspace = [runspacefactory]::CreateRunspace()
        $Runspace.ApartmentState = "STA"
        $Runspace.ThreadOptions = "ReuseThread"
        $Runspace.Open()
        $Runspace.SessionStateProxy.SetVariable("SyncHash",$SyncHash)
        $Runspace.SessionStateProxy.SetVariable("Code",$Code)
        $Runspace.SessionStateProxy.SetVariable("Parameters",$Parameters)
        $Runspace.SessionStateProxy.SetVariable("Runspace",$Runspace)
        $Runspace.SessionStateProxy.SetVariable("Log",$Log)
        $Runspace.SessionStateProxy.SetVariable("Root",$Root)
        $Runspace.SessionStateProxy.SetVariable("SMBInstances",$global:SMBInstances)
        $Runspace.SessionStateProxy.SetVariable("InstanceId",$SyncHash.InstanceId)
        $Runspace.SessionStateProxy.SetVariable("DisableAnonymousTelemetry",$DisableAnonymousTelemetry)
        $SyncHash.Root = $Root
        $SyncHash.Log = $Log
        [scriptblock] $_Code = {}
        <#  if($GUI){
                    $_Code = {
                        try{
                            $Code|out-file c:\temp\invoke-operation_GUI.txt
                            $SyncHash.GUI.Dispatcher.invoke(
                                "Render",
                                [action]$Code
                            )
                            $SyncHash.GUI.Dispatcher.invoke(
                                "Render",
                                {}
                            )
                        } catch {
                           
                        }
                    }
                } else { #>
        $_Code = $Code
        #  }

        $PSinstance = [powershell]::Create()
        $null = $PSInstance.AddScript({
                $ErrorActionPreference = "Stop"
                $global:Root = $global:SMBInstances[$InstanceId].Root
                $global:SMBInstances = $SMBInstances
    
                foreach($Item in (get-childitem -Path "$($SyncHash.Root)\functions" -Include "*.ps1" -Recurse -Force)){
                    . $Item.FullName
                }
                <#    if(($Log -ne $null) -and ((test-path $Log) -ne $false)){
			
                } else {
                    $Log = Start-Log -InstanceId $InstanceId
                }
                $PSDefaultParameterValues = @{"Write-Log:Log"="$Log"} #>
                Register-Classes
                Set-ModuleVariable
                
                $Log = $global:SMBInstances[$InstanceId].Log
                $global:SMBInstances[$InstanceId].Error = $Error
                $PSDefaultParameterValues = @{"Write-Log:Log"=$Log}
                    
            }
        )
        $null = $PSInstance.AddScript($_Code)
        $null = $PSInstance.AddScript({
                $RunSpace.Close()
                $Runspace.Dispose()
            }
                    
        )
        $PSInstance.Runspace = $Runspace
     
        $job = $null
        if($Wait){
            $job = $PSinstance.Invoke()
        } else {
            $job = $PSinstance.BeginInvoke()
        }
        return $job
    } catch {
        write-log -message "Error while invoking operation: $_" -type Error
            
    }


}