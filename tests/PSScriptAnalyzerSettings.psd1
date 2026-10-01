@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost',                          # interactive console tool: colored menu/status output is intended
        'PSReviewUnusedParameter',                        # script parameters are read by the functions through script scope
        'PSUseSingularNouns',                             # Invoke-Updates / Invoke-Graphics ... are section names
        'PSUseShouldProcessForStateChangingFunctions'     # the script has its own -WhatIf switch (Invoke-Action)
    )
}
