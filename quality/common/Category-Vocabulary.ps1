# quality\common\Category-Vocabulary.ps1
# The one list of package categories this repo accepts.
#
# `category` reaches users: it is copied into deployment\catalogs and becomes the
# grouping in Managed Software Center. An invented value is a new, near-empty
# section in the software list rather than an error anyone sees, so the
# vocabulary is closed and adding to it is a deliberate edit here.
#
# These values are an example. Replace them with your own. If you also run
# Munki, agree one list across both repos and keep a copy in each; a shared
# module would couple their release cycles for the sake of one array.

function Get-CimianCategories {
    <#
    .SYNOPSIS
    The accepted category vocabulary, sorted.
    #>
    @(
        'Animation', 'Audio', 'Browsers', 'Communication', 'Design',
        'Development', 'Drivers', 'Firmware', 'Interactive', 'Management',
        'Modeling', 'Plugins', 'Preferences', 'Printing', 'Productivity',
        'Remediation', 'Rendering', 'Security', 'Upkeep', 'Utilities', 'Video'
    )
}

# Values that used to appear here and what they became, so a stale copy of a
# pkgsinfo or a build-info gets told where to go rather than just "unknown".
function Get-CimianRetiredCategories {
    @{
        'Music'             = 'Audio'
        'Media'             = 'Video, or Audio for music apps'
        'Docs'              = 'Productivity'
        'Remote'            = 'Utilities'
        'Network Utilities' = 'Utilities'
        'Prefs'             = 'Preferences'
        'Configuration'     = 'Preferences'
        'Extras'            = 'the category that matches what it is'
    }
}

function Test-CimianCategory {
    <#
    .SYNOPSIS
    Returns $null when the category is acceptable, otherwise the reason it is not.
    #>
    [CmdletBinding()]
    param([string]$Category)

    if ([string]::IsNullOrWhiteSpace($Category)) {
        return "has no category; expected one of: $((Get-CimianCategories) -join ', ')"
    }

    if ($Category -cin (Get-CimianCategories)) { return $null }

    $retired = Get-CimianRetiredCategories
    foreach ($key in $retired.Keys) {
        if ($Category -eq $key) {
            return "uses the retired category '$Category'; use $($retired[$key])"
        }
    }

    $near = (Get-CimianCategories) | Where-Object { $_ -eq $Category }
    if ($near) { return "has category '$Category'; the spelling is '$near'" }

    return "has unknown category '$Category'; expected one of: $((Get-CimianCategories) -join ', ')"
}
