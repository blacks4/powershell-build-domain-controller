#Requires -RunAsAdministrator
#Requires -Version 5.1

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

Import-Module ActiveDirectory

function New-RandomPassword {
    param([int]$Length = 24)

    $upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $lower   = "abcdefghijkmnopqrstuvwxyz"
    $digits  = "23456789"
    $special = "!@#$%^&*-_=+?"
    $all     = ($upper + $lower + $digits + $special).ToCharArray()

    $chars = @(
        $upper[(Get-Random -Minimum 0 -Maximum $upper.Length)]
        $lower[(Get-Random -Minimum 0 -Maximum $lower.Length)]
        $digits[(Get-Random -Minimum 0 -Maximum $digits.Length)]
        $special[(Get-Random -Minimum 0 -Maximum $special.Length)]
    )

    while ($chars.Count -lt $Length) {
        $chars += $all[(Get-Random -Minimum 0 -Maximum $all.Length)]
    }

    -join ($chars | Sort-Object { Get-Random })
}

function Ensure-UserInOu {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SamAccountName,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$OuDn,

        [Parameter(Mandatory = $true)]
        [string]$DnsRoot,

        [Parameter(Mandatory = $true)]
        [string]$Password
    )

    $user = Get-ADUser -LDAPFilter "(sAMAccountName=$SamAccountName)" -Properties DistinguishedName -ErrorAction SilentlyContinue

    if (-not $user) {
        $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force

        New-ADUser `
            -Name $Name `
            -DisplayName $Name `
            -SamAccountName $SamAccountName `
            -UserPrincipalName "$SamAccountName@$DnsRoot" `
            -Path $OuDn `
            -AccountPassword $securePassword `
            -Enabled $true `
            -PasswordNeverExpires $true `
            -ChangePasswordAtLogon $false

        return [pscustomobject]@{
            User    = Get-ADUser -Identity $SamAccountName -Properties DistinguishedName
            Created = $true
        }
    }

    return [pscustomobject]@{
        User    = Get-ADUser -Identity $SamAccountName -Properties DistinguishedName
        Created = $false
    }
}

function Grant-VaultBindFullControlOnVaultUsers {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OuDn,

        [Parameter(Mandatory = $true)]
        [string]$NetBiosName,

        [Parameter(Mandatory = $true)]
        [string]$SamAccountName
    )

    $schemaNamingContext = (Get-ADRootDSE).schemaNamingContext
    $userSchemaObject = Get-ADObject `
        -SearchBase $schemaNamingContext `
        -LDAPFilter "(lDAPDisplayName=user)" `
        -Properties schemaIDGUID

    $userObjectGuid = New-Object Guid (,$userSchemaObject.schemaIDGUID)
    $identity       = New-Object System.Security.Principal.NTAccount("$NetBiosName\$SamAccountName")

    $acl = Get-Acl -Path "AD:$OuDn"

    $existingRule = $acl.Access | Where-Object {
        $_.IdentityReference -eq $identity -and
        $_.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and
        $_.ActiveDirectoryRights -band [System.DirectoryServices.ActiveDirectoryRights]::GenericAll -and
        $_.InheritanceType -eq [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents -and
        $_.InheritedObjectType -eq $userObjectGuid
    }

    if ($existingRule) {
        return
    }

    $rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $identity,
        [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
        [System.Security.AccessControl.AccessControlType]::Allow,
        [Guid]::Empty,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents,
        $userObjectGuid
    )

    $acl.AddAccessRule($rule)
    Set-Acl -Path "AD:$OuDn" -AclObject $acl
}

$domain   = Get-ADDomain
$domainDn = $domain.DistinguishedName
$dnsRoot  = $domain.DNSRoot
$netbios  = $domain.NetBIOSName
$ouDn     = "OU=vault,$domainDn"

if (-not (Get-ADOrganizationalUnit -LDAPFilter "(ou=vault)" -SearchBase $domainDn -SearchScope OneLevel -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name "vault" -Path $domainDn -ProtectedFromAccidentalDeletion $false
}

$vaultBindPassword = New-RandomPassword
$vaultBindResult = Ensure-UserInOu `
    -SamAccountName "vault_bind" `
    -Name "vault_bind" `
    -OuDn $ouDn `
    -DnsRoot $dnsRoot `
    -Password $vaultBindPassword

Grant-VaultBindFullControlOnVaultUsers `
    -OuDn $ouDn `
    -NetBiosName $netbios `
    -SamAccountName "vault_bind"

$baseUsers = @(
    @{ Sam = "sally"; Name = "sally" },
    @{ Sam = "bob";   Name = "bob" },
    @{ Sam = "john";  Name = "john" },
    @{ Sam = "jane";  Name = "jane" }
)

foreach ($baseUser in $baseUsers) {
    $generatedPassword = New-RandomPassword
    $result = Ensure-UserInOu `
        -SamAccountName $baseUser.Sam `
        -Name $baseUser.Name `
        -OuDn $ouDn `
        -DnsRoot $dnsRoot `
        -Password $generatedPassword

    $baseUser.Created  = $result.Created
    $baseUser.Password = if ($result.Created) { $generatedPassword } else { $null }
    $baseUser.DN       = $result.User.DistinguishedName
}

$vaultBindUser = $vaultBindResult.User

Write-Host ""
Write-Host "Vault bind account created/updated successfully." -ForegroundColor Green
Write-Host "vault_bind DN: $($vaultBindUser.DistinguishedName)" -ForegroundColor Yellow
if ($vaultBindPassword) {
    if ($vaultBindResult.Created) {
        Write-Host "vault_bind password: $vaultBindPassword" -ForegroundColor Yellow
    } else {
        Write-Host "vault_bind password: unchanged (account already existed)" -ForegroundColor Yellow
    }
} else {
    Write-Host "vault_bind password: unchanged (account already existed)" -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Base users:" -ForegroundColor Green

foreach ($baseUser in $baseUsers) {
    if ($baseUser.Created) {
        Write-Host "account: $($baseUser.Sam) | password: $($baseUser.Password) | DN: $($baseUser.DN)" -ForegroundColor Yellow
    } else {
        Write-Host "account: $($baseUser.Sam) | password: unchanged (account already existed) | DN: $($baseUser.DN)" -ForegroundColor Yellow
    }
}
