# Copyright (c) 2026 Broadcom. All Rights Reserved.
# Broadcom Confidential. The term "Broadcom" refers to Broadcom Inc.
# and/or its subsidiaries.
#
# =============================================================================
#
# SOFTWARE LICENSE AGREEMENT
#
# Copyright (c) CA, Inc. All rights reserved.
#
# You are hereby granted a non-exclusive, worldwide, royalty-free license
# under CA, Inc.'s copyrights to use, copy, modify, and distribute this
# software in source code or binary form for use in connection with CA, Inc.
# products.
#
# This copyright notice shall be included in all copies or substantial
# portions of the software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.
#
# =============================================================================
#region InventoryHelpers
#
# Thin, mockable wrappers around PowerCLI inventory cmdlets. PowerCLI applies automatic
# parameter transformation before Pester mocks execute, preventing unit testing. These wrappers
# accept plain string parameters, enabling full test coverage of check functions.

function Get-VcfCheckMachineCertificate {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VIMachineCertificate (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER EsxOnly
        Return only ESXi host certificates.

        .PARAMETER VCenterOnly
        Return only the vCenter machine SSL certificate.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $false)] [Switch]$EsxOnly,
        [Parameter(Mandatory = $false)] [Switch]$VCenterOnly
    )
    # Confirmed live: Get-VIMachineCertificate's -EsxOnly/-VCenterOnly form mutually exclusive
    # parameter sets. Explicitly binding both switches - even with one set to $false via
    # -EsxOnly:$false - makes the parameter set ambiguous ("Parameter set cannot be resolved").
    # Only the switch that's actually requested may be passed at all.
    $parameters = @{ Server = $Server; ErrorAction = 'Stop' }
    if ($EsxOnly.IsPresent) { $parameters['EsxOnly'] = $true }
    if ($VCenterOnly.IsPresent) { $parameters['VCenterOnly'] = $true }
    return Get-VIMachineCertificate @parameters
}
function Get-VcfCheckVMInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VM (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VM -Server $Server -ErrorAction Stop
}
function Get-VcfCheckHardDiskInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VM | Get-HardDisk (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VM -Server $Server -ErrorAction Stop | Get-HardDisk -ErrorAction Stop
}
function Get-VcfCheckHardDiskInventoryForVM {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-HardDisk -VM (see file header for why this wrapper exists).

        .PARAMETER VM
        The VM object (as returned by Get-VcfCheckVMInventory) to list hard disks for.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [Object]$VM
    )
    return Get-HardDisk -VM $VM -ErrorAction Stop
}
function Get-VcfCheckVMSnapshotInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VM | Get-Snapshot (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VM -Server $Server -ErrorAction Stop | Get-Snapshot -ErrorAction Stop
}
function Get-VcfCheckVCenterExtension {
    <#
        .SYNOPSIS
        Thin, mockable wrapper returning the vCenter ExtensionManager's ExtensionList (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return (Get-View -Id 'ExtensionManager' -Server $Server -ErrorAction Stop).ExtensionList
}
function Get-VcfCheckSupervisorCluster {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-WMCluster (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-WMCluster -Server $Server -ErrorAction Stop
}
function Get-VcfCheckVMHostInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VMHost (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN. Required so hosts from other, still-connected vCenters aren't
        also returned - PowerCLI's DefaultVIServerMode is Multiple (see VcfCheck.psm1), and
        Connect-VcfCheckVCenter never disconnects a prior vCenter, so an unscoped Get-VMHost
        call returns hosts from every connected vCenter, not just this one.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VMHost -Server $Server -ErrorAction Stop
}
function Get-VcfCheckClusterInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Cluster (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-Cluster -Server $Server -ErrorAction Stop
}
function Get-VcfCheckVMHostForVM {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VMHost -VM (see file header for why this wrapper exists).

        .DESCRIPTION
        Resolves a VM's current host via a live query rather than the VM object's own cached
        `.Host` property, which can be a stale/incomplete stub depending on how that object was
        originally fetched.

        .PARAMETER VM
        The VM (as returned by Get-VcfCheckVM) to resolve the host for.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VM,
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VMHost -VM $VM -Server $Server -ErrorAction Stop
}
function Get-VcfCheckClusterForVMHost {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Cluster -VMHost (see file header for why this wrapper exists).

        .DESCRIPTION
        Resolves a host's cluster via a live query rather than the host object's own cached
        `.Parent` property, which can be a stale/incomplete stub depending on how that object was
        originally fetched.

        .PARAMETER VMHost
        The host (as returned by Get-VcfCheckVMHostForVM) to resolve the cluster for.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-Cluster -VMHost $VMHost -Server $Server -ErrorAction SilentlyContinue
}
function Get-VcfCheckVsanClusterHealth {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Cluster | Test-VsanClusterHealth (see file header for why this wrapper exists).

        .DESCRIPTION
        Test-VsanClusterHealth runs live per-host tests against vCenter's vSAN Health Service and can take
        60-120+ seconds per cluster. Clusters are health-checked one at a time (rather than piped through in a
        single call) so Write-VcfCheckSubProgress can report which cluster is currently being scanned.

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER Context
        The VcfCheck.Context object, passed through to Write-VcfCheckSubProgress.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [PSObject]$Context
    )
    $clusters = @(Get-Cluster -Server $Server -ErrorAction Stop)
    $clusterIndex = 0
    return @($clusters | ForEach-Object {
        $clusterIndex++
        Write-VcfCheckSubProgress -Context $Context -Current $clusterIndex -Total $clusters.Count -Label $_.Name -Unit 'clusters'
        $_ | Test-VsanClusterHealth -ErrorAction Stop
    })
}
function Get-VcfCheckVsanDiskGroupInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Cluster | Get-VsanDiskGroup (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-Cluster -Server $Server -ErrorAction Stop | Get-VsanDiskGroup -ErrorAction Stop
}
function Get-VcfCheckVsanDiskInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VsanDisk -VsanDiskGroup (see file header for why this wrapper exists).

        .PARAMETER VsanDiskGroup
        A VsanDiskGroup object retrieved via Get-VcfCheckVsanDiskGroupInventory.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VsanDiskGroup
    )
    return Get-VsanDisk -VsanDiskGroup $VsanDiskGroup -ErrorAction Stop
}
function Get-VcfCheckVsanStorageListForHost {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-EsxCli -V2 | vsan.storage.list.Invoke() (see file header
        for why this wrapper exists).

        .DESCRIPTION
        Reads the vsan.storage.list esxcli namespace. Several of its per-disk fields (Checksum/
        Checksum OK, In CMMDS, Used by this host, Deduplication/Compression/Encryption/Encryption
        Metadata Checksum OK) have no PowerCLI SDK equivalent (Get-VsanDisk/Get-VsanDiskGroup don't
        expose them), so this is a best-effort supplement to those cmdlets rather than the check's
        primary source - callers should treat a failure here as "detail unavailable", not a check failure.

        .PARAMETER VMHost
        The host to query (as returned by Get-VcfCheckVMHostInventory).

        .PARAMETER TimeoutSeconds
        Maximum time to wait for the esxcli round trip before giving up on this host (see
        Invoke-VcfCheckWithTimeout for why this call needs a hard timeout).
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $false)] [Int]$TimeoutSeconds = 30
    )
    $esxcli = Get-EsxCli -VMHost $VMHost -V2 -ErrorAction Stop
    return Invoke-VcfCheckWithTimeout -TimeoutSeconds $TimeoutSeconds -ArgumentList $esxcli -ScriptBlock {
        param($EsxCli)
        $EsxCli.vsan.storage.list.Invoke()
    }
}
function Get-VcfCheckEsxImageProfileForHost {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-EsxCli -V2 | software.profile.get.Invoke() (see file header
        for why this wrapper exists).

        .DESCRIPTION
        The applied image profile name, vendor, and acceptance level have no PowerCLI SDK equivalent
        (Config.Product.FullName only exposes the build string, not the profile that was actually
        applied) - this is a best-effort supplement, so callers should treat a failure here as
        "detail unavailable", not a check failure.

        .PARAMETER VMHost
        The host to query (as returned by Get-VcfCheckVMHostInventory).

        .PARAMETER TimeoutSeconds
        Maximum time to wait for the esxcli round trip before giving up on this host (see
        Invoke-VcfCheckWithTimeout for why this call needs a hard timeout).
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $false)] [Int]$TimeoutSeconds = 30
    )
    $esxcli = Get-EsxCli -VMHost $VMHost -V2 -ErrorAction Stop
    return Invoke-VcfCheckWithTimeout -TimeoutSeconds $TimeoutSeconds -ArgumentList $esxcli -ScriptBlock {
        param($EsxCli)
        $EsxCli.software.profile.get.Invoke()
    }
}
function Get-VcfCheckClusterImageBasedByMoRef {
    <#
        .SYNOPSIS
        Resolves, for every cluster SDDC Manager manages, whether it is vLCM image-managed or
        still vLCM baseline (VUM) managed.

        .DESCRIPTION
        Wraps Invoke-VcfGetClusters (no filter), keyed by each cluster's
        ManagedObjectReferenceId - the same vCenter ClusterComputeResource MoRef value
        (Cluster.ExtensionData.MoRef.Value) used elsewhere in this check as ClusterId - so a
        caller can look up IsImageBased for a cluster fetched via PowerCLI without a second,
        per-cluster SDDC Manager round trip. A VUM baseline-managed cluster has no vLCM desired
        software specification, so AddOn/Components/Firmware & Drivers Add-on do not apply to it.

        .OUTPUTS
        [Hashtable] vCenter ClusterComputeResource MoRef value -> [Bool] IsImageBased.
    #>
    [CmdletBinding()]
    [OutputType([Hashtable])]
    Param ()
    $clusters = @((Invoke-VcfGetClusters -ErrorAction Stop).Elements)
    $isImageBasedByMoRef = @{}
    foreach ($cluster in $clusters) {
        if ($cluster -and -not [String]::IsNullOrWhiteSpace($cluster.ManagedObjectReferenceId)) {
            $isImageBasedByMoRef[$cluster.ManagedObjectReferenceId] = [Bool]$cluster.IsImageBased
        }
    }
    return $isImageBasedByMoRef
}
function Get-VcfCheckClusterLcmSoftware {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetClusterSoftware (see file header for why this wrapper exists).

        .DESCRIPTION
        Returns the cluster's desired vSphere Lifecycle Manager software specification - base image,
        vendor Add-on, Components, and Firmware & Drivers Add-on (hardware support package) - the same
        breakdown shown on the vSphere Client's Cluster > Updates > Image page. Confirmed live (2026-08-17)
        against a real cluster: AddOn/Components/HardwareSupport.Packages can each be null or empty when
        not configured, and a HardwareSupport package entry can have blank Pkg/Version fields - callers
        must not assume any of these are populated.

        Not wrapped in Invoke-VcfCheckWithTimeout, unlike the esxcli wrappers above: this calls a
        cmdlet (not a bound object's own method), and a cmdlet invoked inside a bare
        [PowerShell]::Create() runspace has neither the module imported nor the caller's vCenter session
        - only a raw object's own method call survives crossing runspaces that way.

        .PARAMETER ClusterId
        The cluster's ClusterComputeResource MoRef value (Cluster.ExtensionData.MoRef.Value) - NOT the
        cluster's display name or PowerCLI Id string (which includes the MoRef type prefix).

        .PARAMETER Server
        The vCenter FQDN that owns ClusterId. Required: a domain-cNNN MoRef is only unique within its
        own vCenter, and a VCF instance keeps the management and every workload domain vCenter connected
        simultaneously, so an unscoped call can resolve against the wrong vCenter and 404.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$ClusterId,
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-GetClusterSoftware -Cluster $ClusterId -Server $Server -ErrorAction Stop
}
function Get-VcfCheckVsanClusterConfig {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Cluster | Get-VsanClusterConfiguration (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-Cluster -Server $Server -ErrorAction Stop | Get-VsanClusterConfiguration -ErrorAction Stop
}
function Get-VcfCheckHostAdvancedSettingForHost {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-AdvancedSetting -Entity (see file header for why this wrapper exists).

        .DESCRIPTION
        Takes a single already-fetched VMHost object (from Get-VcfCheckVMHostInventory) rather
        than a Server FQDN, so callers can loop hosts themselves and report per-host sub-progress -
        PowerCLI's Get-AdvancedSetting makes one API round trip per host even when piped a
        collection, so there is no bulk-fetch shortcut to preserve here.

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .PARAMETER SettingName
        The advanced setting name (e.g. 'VMkernel.Boot.execInstalledOnly').
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [String]$SettingName
    )
    return Get-AdvancedSetting -Entity $VMHost -Name $SettingName -ErrorAction Stop
}
function Get-VcfCheckHostLockdownExceptionUsers {
    <#
        .SYNOPSIS
        Thin, mockable wrapper returning a host's Lockdown Mode exception-user list (see file header for why this wrapper exists).

        .DESCRIPTION
        No PowerCLI cmdlet wraps HostAccessManager.QueryLockdownExceptions(), so this resolves the
        host's HostAccessManager MoRef via ExtensionData.ConfigManager and invokes it directly.

        .PARAMETER VMHost
        A VMHost inventory object retrieved via Get-VcfCheckVMHostInventory.

        .PARAMETER Server
        The connected vCenter FQDN.

        .OUTPUTS
        [String[]] Usernames currently in the host's Lockdown Mode exception list.
    #>
    [CmdletBinding()]
    [OutputType([String[]])]
    Param (
        [Parameter(Mandatory = $true)] [PSObject]$VMHost,
        [Parameter(Mandatory = $true)] [String]$Server
    )
    $hostAccessManager = Get-View -Id $VMHost.ExtensionData.ConfigManager.HostAccessManager -Server $Server -ErrorAction Stop
    return [String[]]@($hostAccessManager.QueryLockdownExceptions())
}
function Get-VcfCheckVCenterAdvancedSetting {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-AdvancedSetting for a vCenter-level (not per-object)
        setting (see file header for why this wrapper exists).

        .DESCRIPTION
        PowerCLI's Get-AdvancedSetting accepts the connected vCenter's own Server FQDN as both
        -Server and -Entity for a VC-level setting (as opposed to a per-host/per-VM setting,
        which needs a specific inventory object as -Entity).

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER SettingName
        The advanced setting name (e.g. 'config.SDDC.Deployed.Type').
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [String]$SettingName
    )
    return Get-AdvancedSetting -Server $Server -Entity $Server -Name $SettingName -ErrorAction Stop
}
function Get-VcfCheckSddcType {
    <#
        .SYNOPSIS
        Resolves a connected vCenter's "config.SDDC.Deployed.Type" advanced setting (e.g.
        "VCF-VxRail" for a VxRail-managed SDDC, or another value/absent for a non-VxRail one).

        .DESCRIPTION
        Queries the vCenter advanced settings to determine if the SDDC is VxRail-managed,
        which is used to gate VxRail-specific check logic. Never throws: returns $null if the
        setting cannot be resolved (e.g. not present on a non-VxRail-managed vCenter, or if the
        query itself fails), so callers treat "unknown" as non-VxRail rather than failing the check.

        .PARAMETER Server
        The connected vCenter FQDN to query.

        .OUTPUTS
        [String] the SDDC type value (e.g. "VCF-VxRail"), or $null if it could not be resolved.
    #>
    [CmdletBinding()]
    [OutputType([String])]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )

    try {
        $setting = Get-VcfCheckVCenterAdvancedSetting -Server $Server -SettingName 'config.SDDC.Deployed.Type'
        return $setting.Value
    } catch {
        return $null
    }
}
function Get-VcfCheckVsanObjectInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Cluster | Get-VsanObject (see file header for why this wrapper exists).

        .DESCRIPTION
        Iterates clusters individually (rather than one flat Get-Cluster | Get-VsanObject pipeline)
        so each returned object can be tagged with its own cluster's name via a ClusterName note
        property - Get-VsanObject's own output carries no cluster reference, and a vCenter with
        more than one vSAN-enabled cluster otherwise leaves a caller unable to say which cluster an
        unhealthy object belongs to.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    $clusters = Get-Cluster -Server $Server -ErrorAction Stop
    return @($clusters | ForEach-Object {
        $clusterName = $_.Name
        $_ | Get-VsanObject -ErrorAction Stop | ForEach-Object {
            $_ | Add-Member -NotePropertyName 'ClusterName' -NotePropertyValue $clusterName -Force -PassThru
        }
    })
}
function Get-VcfCheckVDSwitchInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VDSwitch (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-VDSwitch -Server $Server -ErrorAction Stop
}
function Get-VcfCheckDatastoreInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Datastore (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-Datastore -Server $Server -ErrorAction Stop
}
function Get-VcfCheckDrsRule {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Cluster | Get-DrsRule (see file header for why this wrapper exists).

        .DESCRIPTION
        Explicitly requests all three DRS rule types (VMAffinity, VMAntiAffinity, VMHostAffinity).
        Get-DrsRule without -Type or -VMHost only returns VMAffinity/VMAntiAffinity (VM/VM) rules
        - VM/Host affinity rules are silently excluded, which previously made a cluster with only
        VM/Host rules configured (a common VCF pattern for pinning management VMs to specific
        hosts) report as having no DRS rules at all.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Get-Cluster -Server $Server -ErrorAction Stop | Get-DrsRule -Type VMAffinity, VMAntiAffinity, VMHostAffinity -ErrorAction Stop
}
function Get-VcfCheckClusterEnablementSoftware {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetClusterEnablementSoftware (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER Cluster
        The cluster's raw MoRef value (e.g. 'domain-c9') - not the PowerCLI-formatted Id string.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [String]$Cluster
    )
    return Invoke-GetClusterEnablementSoftware -Server $Server -Cluster $Cluster -ErrorAction Stop
}
function Get-VcfCheckClusterVMHostInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-VMHost -Location $Cluster (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN (used only for mocking; PowerCLI 9 Get-VMHost operates on the current connection).

        .PARAMETER Cluster
        The cluster object (as returned by Get-VcfCheckClusterInventory) to scope hosts to.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [PSObject]$Cluster
    )
    return Get-VMHost -Location $Cluster -ErrorAction Stop
}
function Get-VcfCheckClusterDatastoreInventory {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Get-Datastore -VMHost $VMHost (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed live (2026-07-16, real lab) that Get-Datastore -Location does NOT accept a
        Cluster object: "The Location parameter accepts only Datacenter, Folder and
        DatastoreCluster objects. You specified 'ClusterImpl'." - an assumption that had never
        actually been live-tested until this check ran against a real environment. Datastores
        associated with a cluster are resolved via the cluster's own hosts (-VMHost) instead,
        which still correctly handles a datastore shared across multiple clusters - each
        cluster's own -VMHost query returns it independently, matching this check's documented
        intent (a shared datastore is evaluated against every cluster it belongs to).

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER VMHost
        The cluster's ESXi hosts (as returned by Get-VcfCheckClusterVMHostInventory) to scope
        datastores to.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [PSObject[]]$VMHost
    )
    return Get-Datastore -Server $Server -VMHost $VMHost -ErrorAction Stop
}
function Get-VcfCheckSupervisorClusterSoftware {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListNamespaceManagementSoftwareClusters (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/vcenter/namespace-management/software/clusters'
        (VMware.Sdk.vSphere) - replaces an earlier hand-rolled REST call to the same endpoint.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-ListNamespaceManagementSoftwareClusters -Server $Server -ErrorAction Stop
}
function Get-VcfCheckApplianceHealth {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around the six Invoke-GetHealth* cmdlets (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/appliance/health/<item>' (VMware.Sdk.vSphere).

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER Item
        Which health item to query: System, Mem, Storage, Swap, SoftwarePackages, or Applmgmt.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateSet('System', 'Mem', 'Storage', 'Swap', 'SoftwarePackages', 'Applmgmt')] [String]$Item
    )
    switch ($Item) {
        'System'           { return Invoke-GetHealthSystem -Server $Server -ErrorAction Stop }
        'Mem'              { return Invoke-GetHealthMem -Server $Server -ErrorAction Stop }
        'Storage'          { return Invoke-GetHealthStorage -Server $Server -ErrorAction Stop }
        'Swap'             { return Invoke-GetHealthSwap -Server $Server -ErrorAction Stop }
        'SoftwarePackages' { return Invoke-GetHealthSoftwarePackages -Server $Server -ErrorAction Stop }
        'Applmgmt'         { return Invoke-GetHealthApplmgmt -Server $Server -ErrorAction Stop }
    }
}
function Get-VcfCheckApplianceHealthMessages {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetItemHealthMessages (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/appliance/health/item/messages/<item>' (VMware.Sdk.vSphere).
        Returns the VAMI health item's ApplianceNotification list - the same "Appliance is running
        low on memory. Add more memory to the machine." text VAMI's UI shows for a non-green health
        item - which the plain /appliance/health/<item> traffic-light endpoints do not carry.

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER Item
        Which health item to query: System, Mem, Storage, Swap, SoftwarePackages, or Applmgmt.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [ValidateSet('System', 'Mem', 'Storage', 'Swap', 'SoftwarePackages', 'Applmgmt')] [String]$Item
    )
    $apiItemId = switch ($Item) {
        'SoftwarePackages' { 'software-packages' }
        default            { $Item.ToLowerInvariant() }
    }
    return Invoke-GetItemHealthMessages -Server $Server -Item $apiItemId -ErrorAction Stop
}
function Get-VcfCheckApplianceUptime {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetSystemUptime (see file header for why this wrapper exists).

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-GetSystemUptime -Server $Server -ErrorAction Stop
}
function Get-VcfCheckApplianceNetworkingProxy {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListNetworkingProxy (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/appliance/networking/proxy' (VMware.Sdk.vSphere).
        Returns a Dictionary<String, ApplianceNetworkingProxyConfig> keyed by protocol, with
        typed Enabled (bool)/Port/Username values rather than raw string values.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-ListNetworkingProxy -Server $Server -ErrorAction Stop
}
function Get-VcfCheckVCenterServices {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetServices (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/vcenter/services' (VMware.Sdk.vSphere) - replaces
        an earlier hand-rolled REST call to the same endpoint. Returns a
        Dictionary<String, VcenterServicesServiceInfo> keyed by service id, with typed State/Health.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-GetServices -Server $Server -ErrorAction Stop
}
function Get-VcfCheckApplianceSystemStorage {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListSystemStorage (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/appliance/system/storage' (VMware.Sdk.vSphere).
        Returns partition/disk mappings only, without usage numbers—see
        Get-VcfCheckApplianceStorageUsage for usage metrics.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-ListSystemStorage -Server $Server -ErrorAction Stop
}
function Get-VcfCheckApplianceStorageUsage {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-GetMonitoringQuery (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/appliance/monitoring/query' (VMware.Sdk.vSphere).
        Queries a single monitored item name (e.g. 'storage.totalsize.filesystem.root') over a
        1-hour lookback window using the MAX function.

        .PARAMETER Server
        The connected vCenter FQDN.

        .PARAMETER ItemName
        The monitored item name to query, e.g. 'storage.totalsize.filesystem.root'.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server,
        [Parameter(Mandatory = $true)] [String]$ItemName
    )
    $spec = Initialize-VcfCheckMonitoringItemDataRequest
    return Invoke-GetMonitoringQuery -Server $Server -Item $spec -Names @($ItemName) -ErrorAction Stop
}
function Initialize-VcfCheckMonitoringItemDataRequest {
    <#
        .SYNOPSIS
        Builds an ApplianceMonitoringMonitoredItemDataRequest for a 1-hour MAX-function lookback.

        .DESCRIPTION
        Thin wrapper around Initialize-ApplianceMonitoringMonitoredItemDataRequest so the request
        shape lives in one place.
    #>
    [CmdletBinding()]
    Param ()
    return Initialize-ApplianceMonitoringMonitoredItemDataRequest -Function 'MAX' -Interval 'MINUTES30' `
        -StartTime ([DateTime]::UtcNow.AddHours(-1)) -EndTime ([DateTime]::UtcNow)
}
function Get-VcfCheckSupervisorNamespace {
    <#
        .SYNOPSIS
        Thin, mockable wrapper around Invoke-ListNamespacesInstances (see file header for why this wrapper exists).

        .DESCRIPTION
        Confirmed via Get-vSphereOperation -Path '/vcenter/namespaces/instances' (VMware.Sdk.vSphere).
        Returns one VcenterNamespacesInstancesSummary per vSphere Namespace (Namespace, Cluster,
        ConfigStatus, Stats, Description, SelfServiceNamespace) - no per-TanzuKubernetesCluster
        version data is exposed by this or any other vSphere Automation SDK endpoint; that data
        lives only in the Supervisor's own Kubernetes API (TKC custom resource), reachable via
        kubectl, which this module has no SSH/kubectl execution helper for.

        .PARAMETER Server
        The connected vCenter FQDN.
    #>
    [CmdletBinding()]
    Param (
        [Parameter(Mandatory = $true)] [String]$Server
    )
    return Invoke-ListNamespacesInstances -Server $Server -ErrorAction Stop
}

#endregion InventoryHelpers
