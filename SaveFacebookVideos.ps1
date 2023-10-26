
Set-StrictMode -Version 2.0

trap { Write-Error -ErrorRecord $_; Pause; exit -1; }

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

  [PSCustomObject[]]$blobAttachments = @()
  [PSCustomObject]$video = $null

  if ($Response.Content -match '<script[^>]+?>(?<Json>.*?blob_attachments.*?)</script>') {
    [string]$JsonScript = $Matches['Json']
    if ($JsonScript -notmatch '"blob_attachments":\[(((?<Open>{)[^{}]*)+((?<Close-Open>})[^{}]*)+)*(?(Open)(?!))\]') {
      throw "Failed to isolate the blob attachments data"
    }

    $blobAttachments = @("{$($Matches['Close'])}" | ConvertFrom-Json)
  }

  if ($Response.Content -match '<script[^>]+?>(?<Json>.*?"dash_manifest".*?)</script>') {
    [string]$JsonScript = $Matches['Json']

    [string]$braceMatchingRegex = '(?>{(?<LEVEL>)|}(?<-LEVEL>)|(?!{|}).)+(?(LEVEL)(?!))'
    [string]$regex = "(?i){${braceMatchingRegex}dash_manifest${braceMatchingRegex}}"
    if ($JsonScript -notmatch $regex) {
      throw "Failed to isolate the video data"
    }

    $video = $Matches[0] | ConvertFrom-Json
  }

  [PSCustomObject]$Representation = $null
  [PSCustomObject]$AudioRepresentation = $null
  [System.Collections.Generic.List[PSCustomObject]]$Representations = [System.Collections.Generic.List[PSCustomObject]]::new()
  if ($null -ne $video) {
    if ($null -ne $video.dash_manifest) {
      [xml]$DashManifestXml = [xml]($video.dash_manifest)

      foreach ($RepresentationNode in $DashManifestXml.MPD.Period.AdaptationSet.Representation) {
        [string]$baseUrl = $RepresentationNode.Attributes['BaseURL'] | Select-Object -ExpandProperty Value
        [string]$mimeType = $RepresentationNode.Attributes['mimeType'] | Select-Object -ExpandProperty Value
        [string]$codecs = $RepresentationNode.Attributes['codecs'] | Select-Object -ExpandProperty Value

        if ($mimeType -like '*video*') {
          if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            if (-not [string]::IsNullOrWhiteSpace($video.browser_native_hd_url)) {
              $baseUrl = $video.browser_native_hd_url
            }
            else {
              $baseUrl = $video.browser_native_sd_url
            }

            if ([string]::IsNullOrWhiteSpace($baseUrl)) {
              throw "Unable to get URL"
            }
          }

          [string]$frameRate = $RepresentationNode.Attributes['frameRate'] | Select-Object -ExpandProperty Value
          [string]$fbQualityClass = $RepresentationNode.Attributes['FBQualityClass'] | Select-Object -ExpandProperty Value
          [string]$fBQualityLabel = $RepresentationNode.Attributes['FBQualityLabel'] | Select-Object -ExpandProperty Value
          [string]$width = $RepresentationNode.Attributes['width'] | Select-Object -ExpandProperty Value
          [string]$height = $RepresentationNode.Attributes['height'] | Select-Object -ExpandProperty Value

          $Representation = [PSCustomObject]@{
            Type     = $mimeType
            Quality  = "$($fbQualityClass.ToUpperInvariant()) - $($fBQualityLabel)"
            Width    = $width
            Height   = $height
            Rate     = $frameRate
            Codecs   = $codecs
            Url      = $baseUrl
            Filename = ($baseUrl -replace '\?.*', $null) | Split-Path -Leaf
          }
        }
        elseif ($mimeType -like '*audio*') {
          if ([string]::IsNullOrWhiteSpace($baseUrl)) {
            continue
          }

          [string]$fbEncodingTag = $RepresentationNode.Attributes['FBEncodingTag'] | Select-Object -ExpandProperty Value
          [string]$audioSamplingRate = $RepresentationNode.Attributes['audioSamplingRate'] | Select-Object -ExpandProperty Value

          if ($null -eq $AudioRepresentation) {
            $AudioRepresentation = [PSCustomObject]@{
              Type     = $mimeType
              Quality  = $fbEncodingTag
              Width    = $null
              Height   = $null
              Rate     = $audioSamplingRate
              Codecs   = $codecs
              Url      = $baseUrl
              Filename = ($baseUrl -replace '\?.*', $null) | Split-Path -Leaf
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
    }
    else {
      if ($null -ne $video.browser_native_sd_url) {
        $Representation = [PSCustomObject]@{
          Type     = 'video'
          Quality  = 'SD'
          Width    = $null
          Height   = $null
          Rate     = $null
          Codecs   = $null
          Url      = $video.browser_native_sd_url
          Filename = Split-Path -Path ($video.browser_native_sd_url -replace '\?.*', $null) -Leaf
        }
        $Representations.Add($Representation)
      }
      if ($null -ne $video.browser_native_hd_url) {
        $Representation = [PSCustomObject]@{
          Type     = 'video'
          Quality  = 'SD'
          Width    = $null
          Height   = $null
          Rate     = $null
          Codecs   = $null
          Url      = $video.browser_native_hd_url
          Filename = Split-Path -Path ($video.browser_native_hd_url -replace '\?.*', $null) -Leaf
        }
        $Representations.Add($Representation)
      }
    }
  }

  foreach ($blobAttachment in $blobAttachments) {
    if ($blobAttachments.__typename -ne 'MessageVideo') {
      continue
    }
    [string]$url = if (-not [string]::IsNullOrWhiteSpace($blobAttachment.hdUrl)) { $blobAttachment.hdUrl } else { $blobAttachment.sdUrl }
    $Representation = [PSCustomObject]@{
      Type     = 'video'
      Quality  = if ($blobAttachment.sdUrl -eq $blobAttachment.hdUrl) { 'SD' } else { 'HD' }
      Width    = $blobAttachment.original_dimensions.x
      Height   = $blobAttachment.original_dimensions.y
      Rate     = $null
      Codecs   = $null
      Url      = $url
      Filename = ($url -replace '\?.*', $null) | Split-Path -Leaf
    }
    $Representations.Add($Representation)
  }

  if ($Representations.Count -eq 0) {
    throw "Found nothing to download"
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
      if ($Representations.Count -gt 1) {
        Write-Warning "Found no audio track for the requested video file"
      }

      [hashtable]$Parameters = @{
        OutFile     = $FileBrowser.FileName
        Uri         = $Selection.Url
        Method      = 'GET'
        Headers     = $Headers
        WebSession  = $Session
        ContentType = $ContentType
      }

      Write-Host "Downloading '$($FileBrowser.FileName | Split-Path -Leaf)', please wait"
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

      Write-Host "Downloading video data '$($VideoPath | Split-Path -Leaf)', please wait"
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

      Write-Host "Downloading audio data from '$($AudioPath | Split-Path -Leaf)', please wait"
      Invoke-WebRequest @Parameters

      Write-Host "Merging audio and video data, please wait"
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
