
Set-StrictMode -Version 2.0

Add-Type -AssemblyName 'System.Windows.Forms'

function Merge-AudioVideo {
  [CmdletBinding()]
  [OutputType([void])]
  param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$VideoPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ Test-Path -Path $_ -PathType Leaf })]
    [string]$AudioPath,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ Test-Path -Path $_ -IsValid })]
    [string]$OutputPath
  )

  process {
    [string]$FfmpegExe = Join-Path -Path $PSScriptRoot -ChildPath 'ffmpeg\bin\ffmpeg.exe' -Resolve
    [string[]]$ArgumentList = @(
      '-i'
      '"{0}"' -f $VideoPath
      '-i'
      '"{0}"' -f $AudioPath
      '-c'
      'copy'
      '"{0}"' -f $OutputPath
    )
    [System.Diagnostics.Process]$Process = Start-Process -FilePath $FfmpegExe -ArgumentList $ArgumentList -WindowStyle Hidden -Wait -PassThru
    if ($Process.ExitCode -ne 0) {
      Write-Error "Failed to save audio and video using ffmpeg command: '$FfmpegExe $ArgumentList', exit code is '$($Process.ExitCode)'"
    }
  }
}


$Global:ProgressPreference = 'SilentlyContinue'

[string]$CredentialPath = Join-Path -Path ([environment]::GetFolderPath("MyDocuments")) -ChildPath 'Facebook.xml'

[Microsoft.PowerShell.Commands.WebRequestSession]$Session = New-Object -TypeName 'Microsoft.PowerShell.Commands.WebRequestSession'
$Session.Cookies.Add((New-Object System.Net.Cookie("datr", "KPrtYdJ9meGehLlOguSRQ-5k", "/", ".facebook.com")))

[string]$ContentType = 'application/x-www-form-urlencoded'

[hashtable]$Headers = @{
  'scheme' = 'https'
  'accept' = 'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.9'
}

# Get the LSD and body JAZOEST value from login page
[hashtable]$Parameters = @{
  Uri             = 'https://www.facebook.com/login'
  Method          = 'GET'
  Headers         = $Headers
  WebSession      = $Session
  ContentType     = $ContentType
  UseBasicParsing = $true
}
[Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]$Response = Invoke-WebRequest @Parameters

[string]$Lsd = $Response.InputFields | Where-Object { (@($_.PSobject.Properties.Name) -contains 'name') -and $_.name -eq 'lsd' } | Select-Object -ExpandProperty value

if ([string]::IsNullOrWhiteSpace($Lsd)) {
  throw "Failed to get LSD field from login page"
}

[string]$Jazoest = $Response.InputFields | Where-Object { (@($_.PSobject.Properties.Name) -contains 'name') -and $_.name -eq 'jazoest' } | Select-Object -ExpandProperty value

if ([string]::IsNullOrWhiteSpace($Jazoest)) {
  throw "Failed to get JAZOEST field from login page"
}

# Attempt to login on Facebook
do {
  [PSCredential]$Credential = $null
  if (Test-Path -Path $CredentialPath -PathType Leaf) {
    $Credential = Import-Clixml -Path $CredentialPath
  }

  if ($null -eq $Credential) {
    $Credential = Get-Credential -Message 'Please provide your Facebook credential'

    if ($null -eq $Credential) {
      exit 1
    }

    $Credential | Export-Clixml -Path $CredentialPath
  }

  [hashtable]$Body = @{
    jazoest = $Jazoest
    lsd     = $Lsd
    email   = $Credential.UserName
    pass    = $Credential.GetNetworkCredential().Password
  }

  [hashtable]$Parameters = @{
    Uri             = 'https://www.facebook.com/login'
    Method          = 'POST'
    Headers         = $Headers
    WebSession      = $Session
    ContentType     = $ContentType
    Body            = $Body
    UseBasicParsing = $true
  }
  [Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]$Response = Invoke-WebRequest @Parameters

  if ($Response.Content -like "*$($Parameters.Uri)*") {
    Write-Warning "Failed to authenticate on Facebook using the provided credential"
    $Credential = $null
    Remove-Item -Path $CredentialPath -Force -ErrorAction Stop
  }
} while ($null -eq $Credential)

Write-Host "Successfully authenticated on Facebook using the provided credential"

[string]$InitialDirectory = Resolve-Path -Path ~ | Join-Path -ChildPath 'Downloads' -Resolve

# Download videos until the user stops providing a URL
do {
  [string]$VideoUrl = Read-Host -Prompt 'Paste the URL of the video you want to download (press Enter to quit)'

  if ([string]::IsNullOrWhiteSpace($VideoUrl)) {
    exit
  }

  [hashtable]$Parameters = @{
    Uri             = $VideoUrl
    Method          = 'GET'
    Headers         = $Headers
    WebSession      = $Session
    ContentType     = $ContentType
    UseBasicParsing = $true
  }
  [Microsoft.PowerShell.Commands.BasicHtmlWebResponseObject]$Response = Invoke-WebRequest @Parameters

  if ($response.Content -notmatch '"dash_manifest":".*?[^\\]"') {
    throw "Failed to isolate the dash manifest"
  }

  [xml]$DashManifestXml = [xml]("{$($Matches[0])}" | ConvertFrom-Json | Select-Object -ExpandProperty dash_manifest)

  [System.Collections.Generic.List[PSCustomObject]]$Representations = [System.Collections.Generic.List[PSCustomObject]]::new()
  foreach ($RepresentationNode in $DashManifestXml.MPD.Period.AdaptationSet.Representation) {
    #if ($RepresentationNode.mimeType -notlike '*video*') {
    #  continue
    #}

    [PSCustomObject]$Representation = $null
    [PSCustomObject]$AudioRepresentation = $null
    if ($RepresentationNode.mimeType -like '*video*') {
      $Representation = [PSCustomObject]@{
        Type     = $RepresentationNode.mimeType
        Quality  = "$($RepresentationNode.FBQualityClass.ToUpperInvariant()) - $($RepresentationNode.FBQualityLabel)"
        Width    = $RepresentationNode.width
        Height   = $RepresentationNode.height
        Rate     = $RepresentationNode.frameRate
        Codecs   = $RepresentationNode.codecs
        Url      = $RepresentationNode.BaseURL
        Filename = Split-Path -Path ($RepresentationNode.BaseURL -replace '\?.*', $null) -Leaf
      }
    }
    elseif ($RepresentationNode.mimeType -like '*audio*') {
      if ($null -eq $AudioRepresentation) {
        $AudioRepresentation = [PSCustomObject]@{
          Type     = $RepresentationNode.mimeType
          Quality  = $RepresentationNode.FBEncodingTag
          Width    = $null
          Height   = $null
          Rate     = $RepresentationNode.audioSamplingRate
          Codecs   = $RepresentationNode.codecs
          Url      = $RepresentationNode.BaseURL
          Filename = Split-Path -Path ($RepresentationNode.BaseURL -replace '\?.*', $null) -Leaf
        }
      }
      else {
        Write-Warning "Found more than one audio representation"
      }
    }

    if ($null -ne $Representation) {
      $Representations.Add($Representation)
    }
  }

  [PSCustomObject[]]$Selections = @($Representations | Out-GridView -Title "Please select what you want to download" -OutputMode Multiple)

  foreach ($Selection in $Selections) {
    [string]$FileName = Split-Path -Path $Selection.Filename -Leaf
    [string]$Extension = [System.IO.Path]::GetExtension($FileName) -replace '^\.', $null

    [System.Windows.Forms.SaveFileDialog]$FileBrowser = New-Object -TypeName 'System.Windows.Forms.SaveFileDialog' -Property @{
      OverwritePrompt  = $true
      CheckPathExists  = $false
      Title            = "Save as"
      InitialDirectory = $InitialDirectory
      FileName         = $FileName
      Filter           = "$Extension (*.$Extension)|*.$Extension"
    }
    [System.Windows.Forms.DialogResult]$Result = $FileBrowser.ShowDialog()
    if ($Result -eq [System.Windows.Forms.DialogResult]::Cancel) {
      continue
    }

    $InitialDirectory = Split-Path -Path $FileBrowser.FileName

    if (Test-Path -Path $FileBrowser.FileName -PathType Leaf) {
      Remove-Item -Path $FileBrowser.FileName -Force -ErrorAction Stop
    }

    if ($null -eq $AudioRepresentation) {
      Write-Warning "Found no audio track for the requested video file"

      [hashtable]$Parameters = @{
        OutFile     = $FileBrowser.FileName
        Uri         = $Selection.Url
        Method      = 'GET'
        Headers     = $Headers
        WebSession  = $Session
        ContentType = $ContentType
      }

      Invoke-WebRequest @Parameters
    }
    else {
      [string]$VideoPath = Join-Path -Path $env:TEMP -ChildPath $Selection.Filename
      [hashtable]$Parameters = @{
        OutFile     = $VideoPath
        Uri         = $Selection.Url
        Method      = 'GET'
        Headers     = $Headers
        WebSession  = $Session
        ContentType = $ContentType
      }

      Invoke-WebRequest @Parameters

      [string]$AudioPath = Join-Path -Path $env:TEMP -ChildPath $AudioRepresentation.Filename
      [hashtable]$Parameters = @{
        OutFile     = $AudioPath
        Uri         = $AudioRepresentation.Url
        Method      = 'GET'
        Headers     = $Headers
        WebSession  = $Session
        ContentType = $ContentType
      }

      Invoke-WebRequest @Parameters

      Merge-AudioVideo -VideoPath $VideoPath -AudioPath $AudioPath -OutputPath $FileBrowser.FileName

      if (Test-Path -Path $VideoPath -PathType Leaf) {
        Remove-Item -Path $VideoPath -Force -ErrorAction Stop
      }
      
      if (Test-Path -Path $AudioPath -PathType Leaf) {
        Remove-Item -Path $AudioPath -Force -ErrorAction Stop
      }
    }

    if (Test-Path -Path $FileBrowser.FileName -PathType Leaf) {
      Write-Host "Successfully downloaded '$($FileBrowser.FileName)'"
    }
    else {
      throw "Failed to download '$($FileBrowser.FileName)'"
    }
  }
} while (-not [string]::IsNullOrWhiteSpace($VideoUrl))

exit
