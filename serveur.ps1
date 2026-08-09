# Cockpit PC - serveur local de collecte de la machine
# Lit la machine OU IL TOURNE, sert une API JSON a l'interface web du dossier.
# Langage sans accents (PowerShell 5.1 lit l'ANSI) : c'est voulu.

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------
$script:Dossier    = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:DossierLog = Join-Path $script:Dossier 'logs'
$script:Port       = 8219
$script:FichReseau = Join-Path $script:DossierLog 'reseau.jsonl'
$script:FichEntree = Join-Path $script:DossierLog 'entrees.jsonl'
$script:FichTerm   = Join-Path $script:DossierLog 'terminaux.jsonl'
$script:FichRun    = Join-Path $script:DossierLog 'serveur.log'
$script:FichPid    = Join-Path $script:DossierLog 'serveur.pid'
$script:FichEtat   = Join-Path $script:DossierLog 'base-services.json'

New-Item -ItemType Directory -Path $script:DossierLog -Force | Out-Null

function Ecrire-Log([string]$m) {
    $l = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    Add-Content -Path $script:FichRun -Value $l -Encoding UTF8
}
function Log-Evenement([string]$fich, [object]$obj) {
    try {
        $ligne = $obj | ConvertTo-Json -Compress -Depth 6
        Add-Content -Path $fich -Value $ligne -Encoding UTF8
        # on ne laisse pas grossir le journal sans fin
        $nb = (Get-Content $fich -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
        if ($nb -gt 30000) {
            Get-Content $fich | Select-Object -Skip ($nb - 15000) | Set-Content $fich -Encoding UTF8
        }
    } catch { }
}

# ---------------------------------------------------------------------------
# Caches memoires (evitent de relire des choses lentes a chaque requete)
# ---------------------------------------------------------------------------
$script:CacheTaches   = $null
$script:CacheTachesLe = $null
$script:CacheServicesInstalls   = $null
$script:CacheServicesInstallsLe = $null
$script:CacheLogiciels   = $null
$script:CacheLogicielsLe = $null
$script:DnsCache = @{}
$script:VuesConnexions = @{}   # cle "proc|ip|port" -> lastSeen epoch
$script:FreqConnexions = @{}   # cle -> {compteur, dernier}
$script:VuesEntrees = @{}      # connexions entrantes vues
$script:FreqEntrees = @{}      # frequence des entrees
$script:ProcsConsolePrec = @{}
$script:DejaLogServices = @{}
$script:HeureDemarrage = Get-Date
$script:SnapshotServices = $null
$script:ErreursWindows = $null
$script:ErreursWindowsLe = $null

function Resolve-Hote([string]$ip) {
    if (-not $ip -or $ip -match '^(127\.|0\.0\.0\.0|::|10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)') { return $null }
    if ($script:DnsCache.ContainsKey($ip)) { return $script:DnsCache[$ip] }
    $h = $null
    try {
        $t = [System.Net.Dns]::GetHostEntryAsync($ip)
        if ($t.Wait(400)) { $h = $t.Result.HostName }
    } catch { }
    if ($script:DnsCache.Count -gt 500) { $script:DnsCache.Clear() }
    $script:DnsCache[$ip] = $h
    return $h
}

# ---------------------------------------------------------------------------
# Collectes
# ---------------------------------------------------------------------------
function Get-CpuRam {
    $ram = Get-CimInstance Win32_OperatingSystem
    $cpu = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $tot = [math]::Round($ram.TotalVisibleMemorySize / 1MB, 1)
    $lib = [math]::Round($ram.FreePhysicalMemory / 1MB, 1)
    return @{
        cpu        = [int]$cpu
        ramTotal   = $tot
        ramLibre   = $lib
        ramUse     = [math]::Round($tot - $lib, 1)
        ramPct     = if ($tot -gt 0) { [math]::Round((($tot - $lib) / $tot) * 100) } else { 0 }
        uptime     = ((Get-Date) - $script:HeureDemarrage).TotalHours
        systemeUp  = ((Get-Date) - $ram.LastBootUpTime).TotalDays
    }
}

function Get-Disques {
    $out = @()
    Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
        $libre = [math]::Round($_.FreeSpace / 1GB, 1)
        $taille = [math]::Round($_.Size / 1GB, 1)
        $out += [PSCustomObject]@{
            lettre = $_.DeviceID
            libre  = $libre
            total  = $taille
            pct    = if ($taille -gt 0) { [int](($libre / $taille) * 100) } else { 0 }
        }
    }
    return $out
}

function Get-ServicesVue {
    $svc = Get-CimInstance Win32_Service | Select-Object Name, DisplayName, State, StartMode, PathName
    $installs = @{}
    if ($script:CacheServicesInstalls) {
        foreach ($e in $script:CacheServicesInstalls) {
            if (-not $installs.ContainsKey($e.nom)) { $installs[$e.nom] = $e }
        }
    }
    $out = @()
    foreach ($s in $svc) {
        $dateInstall = if ($installs.ContainsKey($s.Name)) { $installs[$s.Name].date } else { $null }
        $out += [PSCustomObject]@{
            nom      = $s.Name
            affiche  = $s.DisplayName
            etat     = $s.State
            demarrage= $s.StartMode
            chemin   = $s.PathName
            installeLe = $dateInstall
        }
    }
    return @{ services = $out; countActifs = @($svc | Where-Object State -eq 'Running').Count }
}

function Get-ServicesInstalls {
    if ($script:CacheServicesInstalls -and ((Get-Date) - $script:CacheServicesInstallsLe).TotalMinutes -lt 20) {
        return $script:CacheServicesInstalls
    }
    $d = Get-Date '2026-08-01'
    $out = @()
    Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7045 } -ErrorAction SilentlyContinue |
        Where-Object { $_.TimeCreated -ge $d } |
        ForEach-Object {
            $msg = $_.Message
            $nom = $null; $chemin = $null; $auto = $null
            if ($msg -match 'Nom du service\s*:\s*(.+?)(?:\r?\n)') { $nom = $Matches[1].Trim() }
            if ($msg -match 'Nom du fichier de service\s*:\s*(.+?)(?:\r?\n)') { $chemin = $Matches[1].Trim() }
            if ($msg -match 'Type de d.marrage du service\s*:\s*(.+?)(?:\r?\n)') { $auto = $Matches[1].Trim() }
            if ($nom) {
                $out += [PSCustomObject]@{ nom = $nom; chemin = $chemin; date = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'); demarrage = $auto }
            }
        }
    $script:CacheServicesInstalls = $out
    $script:CacheServicesInstallsLe = Get-Date
    return $out
}

function Get-TachesVue {
    if ($script:CacheTaches -and ((Get-Date) - $script:CacheTachesLe).TotalSeconds -lt 45) {
        return $script:CacheTaches
    }
    $out = @()
    Get-ScheduledTask -ErrorAction SilentlyContinue | ForEach-Object {
        $info = Get-ScheduledTaskInfo -TaskName $_.TaskName -TaskPath $_.TaskPath -ErrorAction SilentlyContinue
        $cmd = ''
        foreach ($a in $_.Actions) { if ($a.Execute) { $cmd = $a.Execute; if ($a.Arguments) { $cmd += ' ' + $a.Arguments }; break } }
        $ms = $false
        if ($_.TaskPath -like '\Microsoft\*' -or $_.TaskPath -like '\Windows\*' -or $_.TaskPath -like '\GoogleUserPEH\*') { $ms = $true }
        $out += [PSCustomObject]@{
            nom = $_.TaskName
            chemin = $_.TaskPath
            etat = $_.State.ToString()
            ms = $ms
            dernier = if ($info -and $info.LastRunTime -and $info.LastRunTime -gt (Get-Date 2000)) { $info.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
            prochain = if ($info -and $info.NextRunTime -and $info.NextRunTime -gt (Get-Date 2000)) { $info.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
            cmd = $cmd
        }
    }
    $script:CacheTaches = $out
    $script:CacheTachesLe = Get-Date
    return $out
}

function Get-ConnexionsVue {
    $conns = Get-NetTCPConnection -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -and $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::1?$|::)' }
    $procs = @{}
    Get-Process -ErrorAction SilentlyContinue | ForEach-Object { $procs[$_.Id] = $_.ProcessName }
    $out = @()
    foreach ($c in $conns) {
        $pname = if ($procs.ContainsKey($c.OwningProcess)) { $procs[$c.OwningProcess] } else { "pid:$($c.OwningProcess)" }
        $out += [PSCustomObject]@{
            proc = $pname
            pid  = $c.OwningProcess
            etat = $c.State.ToString()
            ip   = $c.RemoteAddress
            port = $c.RemotePort
            local= $c.LocalPort
            hote = (Resolve-Hote $c.RemoteAddress)
        }
    }
    return $out
}

function Get-ConnexionsEntrantesVue {
    $portsEcoute = @{}   # port -> nom du processus qui ecoute
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object {
            $proc = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            if (-not $proc) { $proc = "pid:$($_.OwningProcess)" }
            if (-not $portsEcoute.ContainsKey([int]$_.LocalPort)) { $portsEcoute[[int]$_.LocalPort] = $proc }
        }
    $out = @()
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalAddress -and $_.RemoteAddress -and
            $_.LocalAddress -notmatch '^(127\.|0\.0\.0\.0|::1?$|::)' -and
            $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::1?$|::)' -and
            $portsEcoute.ContainsKey([int]$_.LocalPort)
        } |
        ForEach-Object {
            $out += [PSCustomObject]@{
                proc = $portsEcoute[[int]$_.LocalPort]
                pid  = $_.OwningProcess
                etat = $_.State.ToString()
                ip   = $_.RemoteAddress
                port = $_.LocalPort
                local= $_.LocalAddress
                hote = (Resolve-Hote $_.RemoteAddress)
            }
        }
    return $out
}

function Get-PortsVue {    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object {
        $pname = $null
        $proc = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($proc) { $pname = $proc.ProcessName }
        [PSCustomObject]@{
            port = $_.LocalPort
            proc = $pname
            pid  = $_.OwningProcess
            addr = $_.LocalAddress
        }
    } | Sort-Object port
}

function Get-ProcessusVue {
    Get-Process -ErrorAction SilentlyContinue | Sort-Object CPU -Descending |
        Select-Object -First 25 |
        ForEach-Object {
            [PSCustomObject]@{
                nom = $_.ProcessName
                pid = $_.Id
                cpu = if ($_.CPU) { [math]::Round($_.CPU, 1) } else { 0 }
                mem = if ($_.WorkingSet64) { [math]::Round($_.WorkingSet64 / 1MB) } else { 0 }
                demarre = if ($_.StartTime) { $_.StartTime.ToString('HH:mm:ss') } else { '' }
            }
        }
}

function Get-LogicielsRecents {
    if ($script:CacheLogiciels -and ((Get-Date) - $script:CacheLogicielsLe).TotalMinutes -lt 15) {
        return $script:CacheLogiciels
    }
    $out = @()
    $chemins = @(
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($p in $chemins) {
        Get-ItemProperty $p -ErrorAction SilentlyContinue | ForEach-Object {
            $di = $_.InstallDate
            if ($_.DisplayName -and $di -and $di -ge '20260801') {
                $out += [PSCustomObject]@{
                    nom = $_.DisplayName
                    version = $_.DisplayVersion
                    date = if ($di.Length -eq 8) { $di.Substring(0,4) + '-' + $di.Substring(4,2) + '-' + $di.Substring(6,2) } else { $di }
                }
            }
        }
    }
    $out = $out | Sort-Object date -Descending | Select-Object -Unique nom, version, date
    $script:CacheLogiciels = $out
    $script:CacheLogicielsLe = Get-Date
    return $out
}

function Get-ErreursWindows {
    if ($script:ErreursWindows -and ((Get-Date) - $script:ErreursWindowsLe).TotalSeconds -lt 30) {
        return $script:ErreursWindows
    }
    $out = @()
    foreach ($log in @('System', 'Application')) {
        Get-WinEvent -FilterHashtable @{ LogName = $log; Level = 2; StartTime = (Get-Date).AddHours(-24) } -ErrorAction SilentlyContinue |
            Select-Object -First 12 |
            ForEach-Object {
                $out += [PSCustomObject]@{
                    log = $log
                    date = $_.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
                    source = $_.ProviderName
                    id = $_.Id
                    msg = ($_.Message -split "`r?`n" | Select-Object -First 2) -join ' '
                }
            }
    }
    $out = $out | Sort-Object date -Descending | Select-Object -First 20
    $script:ErreursWindows = $out
    $script:ErreursWindowsLe = Get-Date
    return $out
}

function Get-AutostartVue {
    $out = @()
    $chemins = @(
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'
    )
    foreach ($p in $chemins) {
        Get-ItemProperty $p -ErrorAction SilentlyContinue | Get-Member -MemberType NoteProperty |
            Where-Object { $_.Name -notin @('PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') } |
            ForEach-Object { $out += [PSCustomObject]@{ cle = $p.Split(':')[-1]; nom = $_.Name; cmd = (Get-ItemProperty $p).$($_.Name) } }
    }
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    Get-ChildItem $startup -ErrorAction SilentlyContinue | ForEach-Object {
        $out += [PSCustomObject]@{ cle = 'Demarrage'; nom = $_.Name; cmd = $_.FullName }
    }
    return $out
}

# ---------------------------------------------------------------------------
# Enregistrement de l'historique (connexions sortantes + fenetres terminal)
# ---------------------------------------------------------------------------
function Enregistrer-Instants {
    # 1) connexions sortantes nouvelles ou revenues
    $maintenant = (Get-Date).ToUniversalTime().Ticks
    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -and $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::1?$|::)' } |
        ForEach-Object {
            $proc = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            if (-not $proc) { $proc = "pid:$($_.OwningProcess)" }
            $cle = "$proc|$($_.RemoteAddress)|$($_.RemotePort)"
            if (-not $script:VuesConnexions.ContainsKey($cle)) {
                $script:VuesConnexions[$cle] = $maintenant
                Log-Evenement $script:FichReseau @{
                    date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    type = 'connexion'
                    proc = $proc
                    pid  = $_.OwningProcess
                    ip   = $_.RemoteAddress
                    port = $_.RemotePort
                    hote = (Resolve-Hote $_.RemoteAddress)
                }
                if (-not $script:FreqConnexions.ContainsKey($cle)) {
                    $script:FreqConnexions[$cle] = @{ n = 0; dernier = '' }
                }
                $script:FreqConnexions[$cle].n++
                $script:FreqConnexions[$cle].dernier = (Get-Date).ToString('HH:mm:ss')
            } else {
                # connexion deja connue : on marque son retour
                if (-not $script:FreqConnexions.ContainsKey($cle)) { $script:FreqConnexions[$cle] = @{ n = 0; dernier = '' } }
                $script:FreqConnexions[$cle].n++
                $script:FreqConnexions[$cle].dernier = (Get-Date).ToString('HH:mm:ss')
            }
        }

    # purge des connexions disparues depuis > 10 min
    $disparues = @($script:VuesConnexions.GetEnumerator() | Where-Object { $maintenant - $_.Value -gt 6000000000 })
    foreach ($kv in $disparues) { $script:VuesConnexions.Remove($kv.Key) }
    if ($script:VuesConnexions.Count -gt 3000) { $script:VuesConnexions.Clear() }

    # 1bis) connexions ENTRANTES : un port en ecoute local recu un hote distant
    $portsEcoute = @{}   # port -> nom du processus qui ecoute
    Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
        ForEach-Object {
            $proc = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName
            if (-not $proc) { $proc = "pid:$($_.OwningProcess)" }
            if (-not $portsEcoute.ContainsKey([int]$_.LocalPort)) { $portsEcoute[[int]$_.LocalPort] = $proc }
        }

    Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object {
            $_.LocalAddress -and $_.RemoteAddress -and
            $_.LocalAddress -notmatch '^(127\.|0\.0\.0\.0|::1?$|::)' -and
            $_.RemoteAddress -notmatch '^(127\.|0\.0\.0\.0|::1?$|::)' -and
            $portsEcoute.ContainsKey([int]$_.LocalPort)
        } |
        ForEach-Object {
            $proc = $portsEcoute[[int]$_.LocalPort]
            $cle = "$proc|$($_.RemoteAddress)|$($_.LocalPort)"
            if (-not $script:VuesEntrees.ContainsKey($cle)) {
                $script:VuesEntrees[$cle] = $maintenant
                Log-Evenement $script:FichEntree @{
                    date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    type = 'entree'
                    proc = $proc
                    pid  = $_.OwningProcess
                    ip   = $_.RemoteAddress
                    port = $_.LocalPort
                    hote = (Resolve-Hote $_.RemoteAddress)
                }
                if (-not $script:FreqEntrees.ContainsKey($cle)) {
                    $script:FreqEntrees[$cle] = @{ n = 0; dernier = '' }
                }
                $script:FreqEntrees[$cle].n++
                $script:FreqEntrees[$cle].dernier = (Get-Date).ToString('HH:mm:ss')
            } else {
                if (-not $script:FreqEntrees.ContainsKey($cle)) { $script:FreqEntrees[$cle] = @{ n = 0; dernier = '' } }
                $script:FreqEntrees[$cle].n++
                $script:FreqEntrees[$cle].dernier = (Get-Date).ToString('HH:mm:ss')
            }
        }
    $disparuesE = @($script:VuesEntrees.GetEnumerator() | Where-Object { $maintenant - $_.Value -gt 6000000000 })
    foreach ($kv in $disparuesE) { $script:VuesEntrees.Remove($kv.Key) }

    # 2) fenetres de terminal nouvelles
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('cmd.exe','conhost.exe','powershell.exe','pwsh.exe','wscript.exe','cscript.exe','mshta.exe','WindowsTerminal.exe','wt.exe') } |
        ForEach-Object {
            [PSCustomObject]@{
                pid = $_.ProcessId
                nom = $_.Name
                cmd = $_.CommandLine
                parent = $_.ParentProcessId
            }
        }
    $procsActuels = @{}
    foreach ($p in $procs) { $procsActuels[$p.pid] = $p }
    foreach ($p in $procs) {
        if (-not $script:ProcsConsolePrec.ContainsKey($p.pid)) {
            # nouvelle fenetre : on la signale (sauf si c'est nous)
            $moi = $PID
            if ($p.pid -ne $moi -and $p.parent -ne $moi) {
                Log-Evenement $script:FichTerm @{
                    date   = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    type   = 'terminal'
                    nom    = $p.nom
                    pid    = $p.pid
                    parent = $p.parent
                    cmd    = $p.cmd
                }
            }
        }
    }
    $script:ProcsConsolePrec = $procsActuels
}

# ---------------------------------------------------------------------------
# Snapshot des services : signale ce qui change depuis le lancement
# ---------------------------------------------------------------------------
function Init-SnapshotServices {
    $script:SnapshotServices = @{}
    Get-CimInstance Win32_Service | ForEach-Object { $script:SnapshotServices[$_.Name] = $_.State }
    if (Test-Path $script:FichEtat) {
        try {
            $ancien = Get-Content $script:FichEtat -Raw | ConvertFrom-Json
            foreach ($p in $ancien.PSObject.Properties) {
                if (-not $script:SnapshotServices.ContainsKey($p.Name)) {
                    Log-Evenement $script:FichTerm @{
                        date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                        type = 'service-disparu'
                        nom  = $p.Name
                    }
                }
            }
        } catch { }
    }
    # sauvegarde de l'etat courant
    $json = @{}; foreach ($k in $script:SnapshotServices.Keys) { $json[$k] = $script:SnapshotServices[$k] }
    $json | ConvertTo-Json -Depth 3 | Set-Content $script:FichEtat -Encoding UTF8
}

function Verifier-ServicesChanges {
    $maintenant = @{}
    Get-CimInstance Win32_Service | ForEach-Object { $maintenant[$_.Name] = $_.State }
    foreach ($k in $maintenant.Keys) {
        if ($script:SnapshotServices -and $script:SnapshotServices.ContainsKey($k)) {
            if ($maintenant[$k] -ne $script:SnapshotServices[$k] -and -not $script:DejaLogServices.ContainsKey($k)) {
                $script:DejaLogServices[$k] = $true
                Log-Evenement $script:FichTerm @{
                    date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    type = 'service-etat'
                    nom  = $k
                    avant = $script:SnapshotServices[$k]
                    apres = $maintenant[$k]
                }
            }
        } else {
            if (-not $script:DejaLogServices.ContainsKey("+$k")) {
                $script:DejaLogServices["+$k"] = $true
                Log-Evenement $script:FichTerm @{
                    date = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                    type = 'service-nouveau'
                    nom  = $k
                    etat = $maintenant[$k]
                }
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Toutes les donnees d'un coup pour l'interface
# ---------------------------------------------------------------------------
function Get-VueComplete {
    $listeLogs = @()
    if (Test-Path $script:FichReseau) { $listeLogs += (Get-Content $script:FichReseau | Select-Object -Last 500) }
    if (Test-Path $script:FichEntree) { $listeLogs += (Get-Content $script:FichEntree | Select-Object -Last 300) }
    if (Test-Path $script:FichTerm)   { $listeLogs += (Get-Content $script:FichTerm   | Select-Object -Last 300) }
    $logs = @()
    foreach ($l in $listeLogs) {
        try { $logs += ($l | ConvertFrom-Json) } catch { }
    }
    $logs = $logs | Sort-Object date -Descending | Select-Object -First 500

    $freq = @()
    foreach ($kv in $script:FreqConnexions.GetEnumerator()) {
        $parts = $kv.Key -split '\|'
        $freq += [PSCustomObject]@{
            proc = $parts[0]
            ip   = if ($parts.Length -gt 1) { $parts[1] } else { '' }
            port = if ($parts.Length -gt 2) { $parts[2] } else { '' }
            n    = $kv.Value.n
            dernier = $kv.Value.dernier
        }
    }

    $freqE = @()
    foreach ($kv in $script:FreqEntrees.GetEnumerator()) {
        $parts = $kv.Key -split '\|'
        $freqE += [PSCustomObject]@{
            proc = $parts[0]
            ip   = if ($parts.Length -gt 1) { $parts[1] } else { '' }
            port = if ($parts.Length -gt 2) { $parts[2] } else { '' }
            n    = $kv.Value.n
            dernier = $kv.Value.dernier
        }
    }

    $svc = Get-ServicesVue
    $infos = Get-CimInstance Win32_OperatingSystem
    $ipLocale = ''
    try { $ipLocale = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -notmatch 'Loopback' -and $_.IPAddress -notmatch '^169\.' } | Select-Object -First 1).IPAddress } catch { }

    return @{
        horodatage = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        machine = @{
            nom     = $env:COMPUTERNAME
            user    = $env:USERNAME
            ip      = $ipLocale
            version = $infos.Caption + ' (' + $infos.Version + ')'
            serveurDepuis = $script:HeureDemarrage.ToString('HH:mm:ss')
        }
        cpuRam    = Get-CpuRam
        disques   = Get-Disques
        services  = $svc
        installations  = Get-ServicesInstalls
        taches    = Get-TachesVue
        connexions = @(Get-ConnexionsVue)
        connexionsEntrantes = @(Get-ConnexionsEntrantesVue)
        ports     = @(Get-PortsVue)
        processus = @(Get-ProcessusVue)
        logiciels = @(Get-LogicielsRecents)
        erreurs   = @(Get-ErreursWindows)
        autostart = @(Get-AutostartVue)
        logs      = @($logs)
        frequences = @($freq)
        frequencesEntrantes = @($freqE)
    }
}

# ---------------------------------------------------------------------------
# Serveur HTTP
# ---------------------------------------------------------------------------
function Servir-Fichier([System.Net.HttpListenerContext]$ctx, [string]$relatif) {
    $chemin = Join-Path $script:Dossier $relatif
    if (-not (Test-Path $chemin)) { $ctx.Response.StatusCode = 404; $ctx.Response.Close(); return }
    $ext = [System.IO.Path]::GetExtension($chemin).ToLower()
    $mime = switch ($ext) {
        '.html' { 'text/html; charset=utf-8' }
        '.css'  { 'text/css; charset=utf-8' }
        '.js'   { 'application/javascript; charset=utf-8' }
        '.png'  { 'image/png' }
        '.ico'  { 'image/x-icon' }
        default { 'application/octet-stream' }
    }
    $bytes = [System.IO.File]::ReadAllBytes($chemin)
    $ctx.Response.ContentType = $mime
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

function Repondre-Json([System.Net.HttpListenerContext]$ctx, [object]$donnees, [int]$code = 200) {
    $json = $donnees | ConvertTo-Json -Depth 12 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $ctx.Response.StatusCode = $code
    $ctx.Response.ContentType = 'application/json; charset=utf-8'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $ctx.Response.Close()
}

function Arreter-Serveur {
    Ecrire-Log "arret demande"
    $script:VuesConnexions.Clear()
    try { $script:Ecoute.Stop() } catch { }
}

# ---------------------------------------------------------------------------
# Boucle principale
# ---------------------------------------------------------------------------
function Main {
    Set-Content -Path $script:FichPid -Value $PID -Encoding UTF8
    Ecrire-Log "demarrage (pid $PID, port $($script:Port))"
    Init-SnapshotServices

    $script:Ecoute = New-Object System.Net.HttpListener
    $script:Ecoute.Prefixes.Add("http://127.0.0.1:$($script:Port)/")
    $script:Ecoute.Start()

    $dernierInstant = Get-Date

    while ($true) {
        # tache periodique : enregistrer les connexions + fenetres toutes les 12 s
        if ((Get-Date) - $dernierInstant -gt [TimeSpan]::FromSeconds(12)) {
            try {
                Enregistrer-Instants
                Verifier-ServicesChanges
            } catch { }
            $dernierInstant = Get-Date
        }

        if (-not $script:Ecoute.IsListening) { break }

        try {
            $ctx = $script:Ecoute.GetContext()
        } catch {
            if ($script:Ecoute.IsListening) { Start-Sleep -Milliseconds 200 }
            continue
        }

        $req = $ctx.Request
        $url = $req.Url.AbsolutePath
        try {
            switch -Regex ($url) {
                '^/api/vue$' {
                    Repondre-Json $ctx (Get-VueComplete)
                }
                '^/api/arret$' {
                    Repondre-Json $ctx @{ ok = $true }
                    Arreter-Serveur
                    return
                }
                '^/api/raccourci$' {
                    Repondre-Json $ctx @{ ok = $true }
                    try {
                        $s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $env:USERPROFILE 'Desktop\Cockpit-PC.lnk'))
                        $s.TargetPath = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
                        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -Command `"& { `$p = Start-Process -FilePath (Join-Path '$($script:Dossier)' 'lanceur.cmd') -WorkingDirectory '$($script:Dossier)'; }`""
                        $s.Save()
                    } catch { }
                }
                '^/api/(.*)$' {
                    Repondre-Json $ctx @{ erreur = 'route inconnue' } 404
                }
                '^/(index.html)?$' { Servir-Fichier $ctx 'interface\index.html' }
                '^/style.css$'     { Servir-Fichier $ctx 'interface\style.css' }
                '^/app.js$'        { Servir-Fichier $ctx 'interface\app.js' }
                default            { Servir-Fichier $ctx 'interface\index.html' }
            }
        } catch {
            try { Repondre-Json $ctx @{ erreur = $_.Exception.Message } 500 } catch { }
        }
    }

    Ecrire-Log "arret propre"
}

try {
    Main
} catch {
    Ecrire-Log "ERREUR GLOBALE : $($_.Exception.Message)"
}
