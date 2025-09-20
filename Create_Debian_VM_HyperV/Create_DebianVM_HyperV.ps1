<# 
 New-HVMDebian-Download.ps1
 Cria e inicia uma VM Debian no Hyper-V (Gen2/UEFI), baixando a ISO antes.
 Todos os artefatos da VM (config, disco, snapshots, smart paging) ficam no mesmo diretório.

 Aluno: edite SOMENTE o bloco "VARIÁVEIS QUE O ALUNO PODE EDITAR".
#>

# =====================[ VARIÁVEIS QUE O ALUNO PODE EDITAR ]=====================
$VMName            = "Debian12_02"

# Link direto para a ISO (será baixada se não existir)
$ISOUrl            = "https://spsenacbr-my.sharepoint.com/:u:/g/personal/fernando_pdias_sp_senac_br/EWweJTZrNEhOk_TRUU2-pq8BvM76s20MlO-U5q2MevVqVg?e=hP7anY&download=1"
$ISOPath           = "ISOs\debian12-preseed.iso"

# Recursos de rede
$SwitchName        = "Default Switch"
$NetAdapterName    = "Ethernet"

# Recursos da VM
$CPUCount          = 1
$MemoryStartupGB   = 1
$VHDSizeGB         = 20

# Pasta raiz da VM
$VMBaseDir         = "C:\VMs\$VMName"

# Secure Boot: "Off" recomendado para Debian
$SecureBoot        = "Off"
# ===============================================================================

# ===========================[ NÃO EDITAR DAQUI PARA BAIXO ]=====================
$ErrorActionPreference = "Stop"

function Assert-Admin {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
              ).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
  if (-not $isAdmin) { throw "Execute este script como Administrador." }
}

function Ensure-Path { param([string]$Path) if (-not (Test-Path $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null } }

function Ensure-Switch-External {
  param([string]$Name, [string]$Adapter)
  $sw = Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue
  if ($sw) { Write-Host "vSwitch '$Name' já existe." -ForegroundColor DarkGray; return }
  $net = Get-NetAdapter -Name $Adapter -ErrorAction SilentlyContinue
  if (-not $net) { throw "Adaptador de rede '$Adapter' não encontrado. Use Get-NetAdapter para conferir o nome." }
  Write-Host "Criando vSwitch Externo '$Name' no adaptador '$Adapter'..." -ForegroundColor Cyan
  New-VMSwitch -Name $Name -NetAdapterName $Adapter -AllowManagementOS $true | Out-Null
}

function Download-FileWithProgress {
    param (
        [string]$Url,
        [string]$OutFile
    )

    $httpClient = New-Object System.Net.Http.HttpClient
    $response = $httpClient.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
    $totalBytes = $response.Content.Headers.ContentLength

    $stream = $response.Content.ReadAsStreamAsync().Result
    $fileStream = [System.IO.FileStream]::new($OutFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    $buffer = New-Object byte[] (8192)  # 8KB buffer
    $totalRead = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
        $fileStream.Write($buffer, 0, $read)
        $totalRead += $read

        $elapsedSec = [Math]::Max($sw.Elapsed.TotalSeconds, 0.1)
        $speedKBs = [Math]::Round(($totalRead / 1024) / $elapsedSec, 2)
        $percent = if ($totalBytes) { [Math]::Round(($totalRead / $totalBytes) * 100, 2) } else { 0 }

        Write-Progress -Activity "Baixando ISO..." -Status "$percent% - $speedKBs KB/s" -PercentComplete $percent
    }

    $fileStream.Close()
    $stream.Close()
    $httpClient.Dispose()
    Write-Host "✅ Download concluído: $OutFile" -ForegroundColor Green
}


try {
  Assert-Admin

  # Garantir pasta da ISO
  Ensure-Path -Path (Split-Path $ISOPath)

  # Baixar ISO se não existir
  if (-not (Test-Path $ISOPath)) {
    Write-Host "Baixando ISO do Debian..." -ForegroundColor Cyan
    Download-FileWithProgress -Url $ISOUrl -OutFile $ISOPath
  } else {
    Write-Host "ISO já existe em: $ISOPath" -ForegroundColor DarkGray
  }


  # Preparar pasta da VM
  Ensure-Path -Path $VMBaseDir
  $VHDPath = Join-Path $VMBaseDir "$VMName.vhdx"

  $MemoryStartupBytes = [UInt64]($MemoryStartupGB * 1GB)
  $VHDSizeBytes       = [UInt64]($VHDSizeGB * 1GB)

  Ensure-Switch-External -Name $SwitchName -Adapter $NetAdapterName

  $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
  if (-not $vm) {
    Write-Host "Criando VM '$VMName' (Gen2/UEFI)..." -ForegroundColor Cyan
    New-VM -Name $VMName `
           -Generation 2 `
           -MemoryStartupBytes $MemoryStartupBytes `
           -NewVHDPath $VHDPath -NewVHDSizeBytes $VHDSizeBytes `
           -SwitchName $SwitchName `
           -Path $VMBaseDir | Out-Null

    Set-VM -Name $VMName -SnapshotFileLocation $VMBaseDir -SmartPagingFilePath $VMBaseDir | Out-Null
  }

  # CPU e memória
  Set-VM -Name $VMName -ProcessorCount $CPUCount -MemoryStartupBytes $MemoryStartupBytes | Out-Null

  # Secure Boot
  if ($SecureBoot -eq "Off") { Set-VMFirmware -VMName $VMName -EnableSecureBoot Off }
  else { Set-VMFirmware -VMName $VMName -EnableSecureBoot On -SecureBootTemplate $SecureBoot }

  # DVD com ISO
  $dvd = Get-VMDvdDrive -VMName $VMName -ErrorAction SilentlyContinue
  if (-not $dvd) { Add-VMDvdDrive -VMName $VMName -Path $ISOPath | Out-Null }
  else { Set-VMDvdDrive -VMName $VMName -Path $ISOPath | Out-Null }

  # Boot pelo DVD
  $dvdDrive = Get-VMDvdDrive -VMName $VMName
  Set-VMFirmware -VMName $VMName -FirstBootDevice $dvdDrive

  # Iniciar VM
  if ((Get-VM -Name $VMName).State -ne 'Running') { Start-VM -Name $VMName | Out-Null }
  Start-Process vmconnect.exe "localhost","$VMName" -ErrorAction SilentlyContinue

  Write-Host "`n✅ VM '$VMName' criada e iniciada com sucesso!" -ForegroundColor Green
  Write-Host "   ISO: $ISOPath"
  Write-Host "   Pasta da VM: $VMBaseDir"
  Write-Host "   Disco: $VHDSizeGB GB"
  Write-Host "   vCPU/RAM: $CPUCount / $MemoryStartupGB GB"

} catch {
  Write-Error $_.Exception.Message
  exit 1
}
