# need load first mgGraph, alter Exxchange Online managemnt 
$mm = get-managementRoleAssignment  | Where-Object {$_.Role -imatch '^Application' -and $_.RoleAssigneeType -imatch 'ServicePrincipal' } | Sort-Object RoleAssigneeType | Select-Object Name,Role,RoleAssigneeName,RoleAssigneeType, AssignmentMethod, EffectiveUserName,app,CustomResourceScope,Recipient*
$applicationAccessPolicy = get-applicationAccessPolicy
# loaded 

$res = foreach ($m in $mm) {  
    $rex = get-mgServicePrincipal  -ServicePrincipalId $m.EffectiveUserName ; 
    $EffectiveScopeType = $null;
    $EffectiveScopeAddress = $null;
    if($m.RecipientWriteScope -eq 'CustomRecipientScope') {
        $EffectiveScopeType ='RecipientFilter';
        $EffectiveScopeAddress = Get-ManagementScope -Identity $m.CustomResourceScope | select-object -ExpandProperty RecipientFilter
    }
    if($m.RecipientWriteScope -eq 'Group') {
        $GroupObj = Get-Recipient -Identity $m.CustomResourceScope;
        $GroupEmailAddress = $GroupObj.PrimarySmtpAddress;
        $EffectiveScopeType = $GroupObj.RecipientTypeDetails;
        $EffectiveScopeAddress = $GroupEmailAddress;  
    }
$PCode = $null
$existingPolicy = $null;
$existingPolicy = $applicationAccessPolicy | Where-Object { $_.AppId -eq $rex.AppId  } | Select-Object -First 1 | select-object -ExpandProperty ScopeName;
if ($rex.DisplayName -match '(?i)\bP\d+') { $PCode = $Matches[0].ToUpper() }
    [pscustomobject]@{
        name                    = $m.name;
        role                    = $m.role;
        RoleAssigneeName        = $m.RoleAssigneeName;
        RoleAssigneeType        = $m.RoleAssigneeType;
        AssignmentMethod        = $m.AssignmentMethod;
        EffectiveUserName       = $m.EffectiveUserName;
        CustomResourceScope     = $m.CustomResourceScope;
        EffectiveScopeAddress   = $EffectiveScopeAddress;
        EffectiveScopeType      = $EffectiveScopeType;
        RecipientWriteScope     = $m.RecipientWriteScope;
        RADisplayName           = $rex.DisplayName;
        RAAppID                 = $rex.AppID;
        SPType                  = $rex.ServicePrincipalType;
        PCode                   = $PCode;
        existingPolicy          = $existingPolicy;
        createdDateTime         = $rex.AdditionalProperties['createdDateTime'];
    }
}
$res | select-object * 
$filename = ('_RBACforApps_{0}.xlsx' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
$res | Export-Excel -Path $filename -Verbose -Title RBACforApps -TableName RBACforAppsTBL -WorksheetName RbacforApps