param(
    [Parameter(Mandatory = $true)]
    [string]$StateFile,

    [Parameter(Mandatory = $true)]
    [string]$CancelFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type -TypeDefinition @'
using System.Windows.Forms;

namespace MacWinClip
{
    public sealed class PassiveProgressForm : Form
    {
        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }
    }
}
'@ -ReferencedAssemblies 'System.Windows.Forms'

if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    throw 'Progress UI must run in an STA PowerShell process.'
}

function U([string]$Value) {
    return [Text.RegularExpressions.Regex]::Unescape($Value)
}

# Keep this source ASCII-only so Windows PowerShell 5.1 can load it without a BOM.
$Text = @{
    WaitingForState = U '\u7b49\u5f85\u4f20\u8f93\u72b6\u6001\u2026'
    FileTransfer = U '\u6587\u4ef6\u4f20\u8f93'
    Preparing = U '\u6b63\u5728\u51c6\u5907\u6587\u4ef6'
    Transferring = U '\u6b63\u5728\u4f20\u8f93\u6587\u4ef6'
    Verifying = U '\u6b63\u5728\u6821\u9a8c\u6587\u4ef6'
    Waiting = U '\u7b49\u5f85\u53e6\u4e00\u53f0\u7535\u8111'
    SendingToMac = U '\u6b63\u5728\u53d1\u9001\u5230 Mac'
    ReceivingFromMac = U '\u6b63\u5728\u4ece Mac \u63a5\u6536'
    Done = U '\u5df2\u5b8c\u6210'
    Error = U '\u4f20\u8f93\u5931\u8d25'
    Canceled = U '\u5df2\u53d6\u6d88'
    Cancel = U '\u53d6\u6d88\u4f20\u8f93'
    Canceling = U '\u6b63\u5728\u53d6\u6d88\u2026'
    Close = U '\u5173\u95ed'
    Calculating = U '\u6b63\u5728\u8ba1\u7b97\u901f\u5ea6'
    Remaining = U '\u9884\u8ba1\u5269\u4f59'
    PreparingMessage = U '\u6b63\u5728\u51c6\u5907\u8981\u4f20\u8f93\u7684\u6587\u4ef6\u2026'
    TransferringMessage = U '\u8bf7\u4fdd\u6301\u4e24\u53f0\u7535\u8111\u5728\u7ebf\uff0c\u6587\u672c\u548c\u622a\u56fe\u540c\u6b65\u4e0d\u53d7\u5f71\u54cd'
    VerifyingMessage = U '\u6b63\u5728\u6821\u9a8c\u6587\u4ef6\u5b8c\u6574\u6027\u2026'
    WaitingMessage = U '\u6587\u4ef6\u5df2\u51c6\u5907\u597d\uff0c\u7b49\u5f85\u53e6\u4e00\u53f0\u7535\u8111\u63a5\u6536\u2026'
    CompletedMessage = U '\u53ef\u5728\u76ee\u6807\u4f4d\u7f6e\u67e5\u770b\u6587\u4ef6'
    CanceledMessage = U '\u4f20\u8f93\u5df2\u53d6\u6d88'
    CloseHint = U '\u5173\u95ed\u7a97\u53e3\u4e0d\u4f1a\u53d6\u6d88\u4f20\u8f93'
    ProgressAccessibility = U '\u6587\u4ef6\u4f20\u8f93\u8fdb\u5ea6'
    NoName = U '\u6b63\u5728\u51c6\u5907\u6587\u4ef6\u2026'
    Hours = U '\u5c0f\u65f6'
    Minutes = U '\u5206'
    Seconds = U '\u79d2'
}

function Format-Bytes([double]$Value) {
    if ($Value -ge 1GB) { return '{0:0.00} GiB' -f ($Value / 1GB) }
    if ($Value -ge 1MB) { return '{0:0.0} MiB' -f ($Value / 1MB) }
    if ($Value -ge 1KB) { return '{0:0.0} KiB' -f ($Value / 1KB) }
    return '{0:0} B' -f [Math]::Max(0, $Value)
}

function Format-Duration([double]$Seconds) {
    $whole = [Math]::Max(0, [Math]::Ceiling($Seconds))
    $hours = [Math]::Floor($whole / 3600)
    $minutes = [Math]::Floor(($whole % 3600) / 60)
    $secondsPart = $whole % 60
    if ($hours -gt 0) {
        return "$hours $($Text.Hours) $minutes $($Text.Minutes)"
    }
    if ($minutes -gt 0) {
        return "$minutes $($Text.Minutes) $secondsPart $($Text.Seconds)"
    }
    return "$secondsPart $($Text.Seconds)"
}

function Get-StageText([string]$Stage) {
    switch ($Stage.ToLowerInvariant()) {
        'preparing' { return $Text.Preparing }
        'transferring' { return $Text.Transferring }
        'sending' { return $Text.Transferring }
        'receiving' { return $Text.Transferring }
        'verifying' { return $Text.Verifying }
        'waiting' { return $Text.Waiting }
        'done' { return $Text.Done }
        'error' { return $Text.Error }
        'canceled' { return $Text.Canceled }
        'cancelled' { return $Text.Canceled }
        default {
            if ([string]::IsNullOrWhiteSpace($Stage)) {
                return $Text.WaitingForState
            }
            return $Stage
        }
    }
}

function Get-DirectionText([string]$Direction) {
    switch ($Direction.ToLowerInvariant()) {
        'sending to mac' { return $Text.SendingToMac }
        'receiving from mac' { return $Text.ReceivingFromMac }
        default {
            if ([string]::IsNullOrWhiteSpace($Direction)) {
                return $Text.FileTransfer
            }
            return $Direction
        }
    }
}

function Get-StageMessage([string]$Stage, [string]$BackendMessage) {
    switch ($Stage.ToLowerInvariant()) {
        'preparing' { return $Text.PreparingMessage }
        'transferring' { return $Text.TransferringMessage }
        'sending' { return $Text.TransferringMessage }
        'receiving' { return $Text.TransferringMessage }
        'verifying' { return $Text.VerifyingMessage }
        'waiting' { return $Text.WaitingMessage }
        'done' { return $Text.CompletedMessage }
        'canceled' { return $Text.CanceledMessage }
        'cancelled' { return $Text.CanceledMessage }
        'error' {
            if ([string]::IsNullOrWhiteSpace($BackendMessage)) {
                return $Text.Error
            }
            return $BackendMessage
        }
        default {
            if ([string]::IsNullOrWhiteSpace($BackendMessage)) {
                return (Get-StageText $Stage)
            }
            return $BackendMessage
        }
    }
}

[Windows.Forms.Application]::EnableVisualStyles()

$form = [MacWinClip.PassiveProgressForm]::new()
$form.Text = 'MacWinClip'
$form.ClientSize = [Drawing.Size]::new(560, 360)
$form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $true
$form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
$form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = [Drawing.SizeF]::new(96, 96)
$form.BackColor = [Drawing.Color]::FromArgb(243, 244, 246)
$form.ShowInTaskbar = $true

$card = [Windows.Forms.Panel]::new()
$card.Location = [Drawing.Point]::new(20, 18)
$card.Size = [Drawing.Size]::new(520, 264)
$card.BackColor = [Drawing.Color]::White
$card.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($card)

$directionLabel = [Windows.Forms.Label]::new()
$directionLabel.Location = [Drawing.Point]::new(20, 18)
$directionLabel.Size = [Drawing.Size]::new(370, 28)
$directionLabel.Font = [Drawing.Font]::new('Segoe UI', 12, [Drawing.FontStyle]::Bold)
$directionLabel.Text = $Text.FileTransfer
$card.Controls.Add($directionLabel)

$percentLabel = [Windows.Forms.Label]::new()
$percentLabel.Location = [Drawing.Point]::new(402, 14)
$percentLabel.Size = [Drawing.Size]::new(96, 34)
$percentLabel.Font = [Drawing.Font]::new('Segoe UI Variable Display', 16, [Drawing.FontStyle]::Regular)
$percentLabel.ForeColor = [Drawing.Color]::FromArgb(45, 45, 45)
$percentLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$percentLabel.Text = [char]0x2014
$card.Controls.Add($percentLabel)

$stageLabel = [Windows.Forms.Label]::new()
$stageLabel.Location = [Drawing.Point]::new(20, 48)
$stageLabel.Size = [Drawing.Size]::new(478, 20)
$stageLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$stageLabel.ForeColor = [Drawing.Color]::FromArgb(96, 96, 96)
$stageLabel.Text = $Text.WaitingForState
$card.Controls.Add($stageLabel)

$fileLabel = [Windows.Forms.Label]::new()
$fileLabel.Location = [Drawing.Point]::new(20, 79)
$fileLabel.Size = [Drawing.Size]::new(478, 24)
$fileLabel.Font = [Drawing.Font]::new('Segoe UI', 9.5, [Drawing.FontStyle]::Bold)
$fileLabel.AutoEllipsis = $true
$fileLabel.Text = $Text.NoName
$card.Controls.Add($fileLabel)

$barTrack = [Windows.Forms.Panel]::new()
$barTrack.Location = [Drawing.Point]::new(20, 112)
$barTrack.Size = [Drawing.Size]::new(478, 8)
$barTrack.BackColor = [Drawing.Color]::FromArgb(225, 227, 230)
$barTrack.AccessibleRole = [Windows.Forms.AccessibleRole]::ProgressBar
$barTrack.AccessibleName = $Text.ProgressAccessibility
$card.Controls.Add($barTrack)

$barFill = [Windows.Forms.Panel]::new()
$barFill.Location = [Drawing.Point]::new(0, 0)
$barFill.Size = [Drawing.Size]::new(0, 8)
$barFill.BackColor = [Drawing.Color]::FromArgb(75, 85, 91)
$barTrack.Controls.Add($barFill)

$amountLabel = [Windows.Forms.Label]::new()
$amountLabel.Location = [Drawing.Point]::new(20, 130)
$amountLabel.Size = [Drawing.Size]::new(230, 20)
$amountLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$amountLabel.ForeColor = [Drawing.Color]::FromArgb(96, 96, 96)
$amountLabel.Text = '0 B'
$card.Controls.Add($amountLabel)

$rateLabel = [Windows.Forms.Label]::new()
$rateLabel.Location = [Drawing.Point]::new(250, 130)
$rateLabel.Size = [Drawing.Size]::new(248, 20)
$rateLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$rateLabel.ForeColor = [Drawing.Color]::FromArgb(96, 96, 96)
$rateLabel.TextAlign = [Drawing.ContentAlignment]::MiddleRight
$rateLabel.Text = $Text.Calculating
$card.Controls.Add($rateLabel)

$statusPanel = [Windows.Forms.Panel]::new()
$statusPanel.Location = [Drawing.Point]::new(20, 162)
$statusPanel.Size = [Drawing.Size]::new(478, 80)
$statusPanel.BorderStyle = [Windows.Forms.BorderStyle]::FixedSingle
$statusPanel.BackColor = [Drawing.Color]::FromArgb(247, 247, 248)
$card.Controls.Add($statusPanel)

$statusTitle = [Windows.Forms.Label]::new()
$statusTitle.Location = [Drawing.Point]::new(12, 8)
$statusTitle.Size = [Drawing.Size]::new(446, 20)
$statusTitle.Font = [Drawing.Font]::new('Segoe UI', 9, [Drawing.FontStyle]::Bold)
$statusTitle.ForeColor = [Drawing.Color]::FromArgb(45, 45, 45)
$statusTitle.Text = $Text.WaitingForState
$statusPanel.Controls.Add($statusTitle)

$messageLabel = [Windows.Forms.Label]::new()
$messageLabel.Location = [Drawing.Point]::new(12, 32)
$messageLabel.Size = [Drawing.Size]::new(452, 40)
$messageLabel.Font = [Drawing.Font]::new('Segoe UI', 8.5)
$messageLabel.ForeColor = [Drawing.Color]::FromArgb(96, 96, 96)
$messageLabel.AutoEllipsis = $false
$messageLabel.Text = $Text.WaitingForState
$statusPanel.Controls.Add($messageLabel)

$cancelButton = [Windows.Forms.Button]::new()
$cancelButton.Text = $Text.Cancel
$cancelButton.Location = [Drawing.Point]::new(412, 298)
$cancelButton.Size = [Drawing.Size]::new(128, 44)
$cancelButton.UseVisualStyleBackColor = $true
$form.AcceptButton = $null
$form.CancelButton = $null
$form.Controls.Add($cancelButton)

$script:samples = [Collections.Generic.List[object]]::new()
$script:lastTransferred = [int64]-1
$script:lastName = ''
$script:terminalAt = $null
$script:terminalState = $false
$script:marqueeOffset = -96

function Reset-Samples([int64]$Transferred, [string]$Name, [DateTime]$Now) {
    $script:samples.Clear()
    $script:samples.Add([pscustomobject]@{ At = $Now; Bytes = $Transferred }) | Out-Null
    $script:lastTransferred = $Transferred
    $script:lastName = $Name
}

function Get-Speed([int64]$Transferred, [string]$Name, [DateTime]$Now) {
    if ($Name -ne $script:lastName -or $Transferred -lt $script:lastTransferred) {
        Reset-Samples $Transferred $Name $Now
        return [double]0
    }

    if ($script:samples.Count -eq 0) {
        Reset-Samples $Transferred $Name $Now
    } elseif ($Transferred -ne $script:lastTransferred) {
        $script:samples.Add([pscustomobject]@{ At = $Now; Bytes = $Transferred }) | Out-Null
        $script:lastTransferred = $Transferred
    }

    while ($script:samples.Count -gt 1 -and ($Now - $script:samples[0].At).TotalSeconds -gt 5) {
        $script:samples.RemoveAt(0)
    }

    if ($script:samples.Count -lt 2) {
        return [double]0
    }

    $first = $script:samples[0]
    $last = $script:samples[$script:samples.Count - 1]
    $seconds = ($last.At - $first.At).TotalSeconds
    if ($seconds -le 0 -or $last.Bytes -lt $first.Bytes) {
        return [double]0
    }
    return [Math]::Max(0, ($last.Bytes - $first.Bytes) / $seconds)
}

$cancelButton.Add_Click({
    if ($script:terminalState) {
        $form.Close()
        return
    }

    try {
        [IO.File]::WriteAllText($CancelFile, 'cancel', [Text.UTF8Encoding]::new($false))
        $cancelButton.Enabled = $false
        $cancelButton.Text = $Text.Canceling
        $statusTitle.Text = $Text.Canceling
    } catch {
        $statusTitle.Text = $Text.Error
        $messageLabel.Text = $_.Exception.Message
        $statusTitle.ForeColor = [Drawing.Color]::FromArgb(196, 43, 28)
        $statusPanel.BackColor = [Drawing.Color]::FromArgb(253, 240, 238)
    }
})

$timer = [Windows.Forms.Timer]::new()
$timer.Interval = 250
$timer.Add_Tick({
    $now = [DateTime]::UtcNow
    if ($null -ne $script:terminalAt -and ($now - $script:terminalAt).TotalSeconds -ge 4) {
        $form.Close()
        return
    }

    if (-not (Test-Path -LiteralPath $StateFile)) {
        return
    }

    try {
        $state = Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        $stage = [string]$state.stage
        $stageKey = $stage.ToLowerInvariant()
        $transferred = [Math]::Max([int64]0, [int64]$state.transferred)
        $total = [Math]::Max([int64]0, [int64]$state.total)
        $name = [string]$state.name
        $message = [string]$state.message
        $direction = [string]$state.direction
        $terminal = $stageKey -in 'done', 'error', 'canceled', 'cancelled'
        $speed = Get-Speed $transferred $name $now

        if ([string]::IsNullOrWhiteSpace($name)) { $name = $Text.NoName }

        $directionLabel.Text = Get-DirectionText $direction
        $stageLabel.Text = Get-StageText $stage
        $fileLabel.Text = $name
        $statusTitle.Text = Get-StageText $stage
        $messageLabel.Text = Get-StageMessage $stage $message

        $ratio = if ($total -gt 0) {
            [Math]::Min(1, [Math]::Max(0, $transferred / [double]$total))
        } else {
            [double]0
        }

        if ($stageKey -eq 'done') {
            $ratio = 1
        }

        $amountLabel.Text = if ($total -gt 0) {
            "$(Format-Bytes $transferred) / $(Format-Bytes $total)"
        } else {
            Format-Bytes $transferred
        }

        $transferStage = $stageKey -in 'transferring', 'sending', 'receiving'
        $showExactProgress = $terminal -or ($transferStage -and $total -gt 0)
        $indeterminate = -not $terminal -and (
            $stageKey -in 'preparing', 'verifying' -or
            ($transferStage -and $total -le 0)
        )
        if ($indeterminate) {
            $percentLabel.Text = [char]0x2014
            $barFill.Width = 96
            $script:marqueeOffset += 28
            if ($script:marqueeOffset -gt $barTrack.ClientSize.Width) {
                $script:marqueeOffset = -96
            }
            $barFill.Left = $script:marqueeOffset
        } elseif ($showExactProgress) {
            $percentLabel.Text = '{0}%' -f [Math]::Floor($ratio * 100)
            $barFill.Left = 0
            $barFill.Width = [Math]::Min(
                $barTrack.ClientSize.Width,
                [Math]::Max(0, [int][Math]::Round($ratio * $barTrack.ClientSize.Width))
            )
        } else {
            $percentLabel.Text = [char]0x2014
            $barFill.Left = 0
            $barFill.Width = 0
        }
        $barTrack.AccessibleDescription = $percentLabel.Text

        if ($speed -gt 0 -and -not $terminal -and $transferred -lt $total) {
            $eta = Format-Duration (($total - $transferred) / $speed)
            $rateLabel.Text = "$(Format-Bytes $speed)/s  $($Text.Remaining) $eta"
        } elseif ($terminal) {
            $rateLabel.Text = Get-StageText $stage
        } elseif ($stageKey -eq 'waiting') {
            $rateLabel.Text = $Text.Waiting
        } else {
            $rateLabel.Text = $Text.Calculating
        }

        if ($terminal) {
            $script:terminalState = $true
            $cancelButton.Enabled = $true
            $cancelButton.Text = $Text.Close
            if ($stageKey -eq 'done' -and $null -eq $script:terminalAt) {
                $script:terminalAt = $now
            } elseif ($stageKey -ne 'done') {
                $script:terminalAt = $null
            }

            switch ($stageKey) {
                'done' {
                    $statusTitle.ForeColor = [Drawing.Color]::FromArgb(45, 45, 45)
                    $statusPanel.BackColor = [Drawing.Color]::FromArgb(247, 247, 248)
                }
                { $_ -in 'canceled', 'cancelled' } {
                    $statusTitle.ForeColor = [Drawing.Color]::FromArgb(96, 96, 96)
                    $statusPanel.BackColor = [Drawing.Color]::FromArgb(247, 247, 248)
                }
                default {
                    $statusTitle.ForeColor = [Drawing.Color]::FromArgb(196, 43, 28)
                    $statusPanel.BackColor = [Drawing.Color]::FromArgb(255, 247, 246)
                }
            }
        } else {
            $script:terminalState = $false
            $script:terminalAt = $null
            $statusTitle.ForeColor = [Drawing.Color]::FromArgb(45, 45, 45)
            $statusPanel.BackColor = [Drawing.Color]::FromArgb(247, 247, 248)
            if ($stageKey -in 'preparing', 'transferring', 'sending', 'receiving', 'verifying', 'waiting') {
                $messageLabel.Text = "$(Get-StageMessage $stage $message)`r`n$($Text.CloseHint)"
            }
        }
    } catch {
        # A state writer may be replacing the file. Keep the last valid frame.
    }
})

$form.Add_Shown({ $timer.Start() })
$form.Add_FormClosed({
    $timer.Stop()
    $timer.Dispose()
})
[Windows.Forms.Application]::Run($form)
